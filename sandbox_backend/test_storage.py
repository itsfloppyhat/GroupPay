"""Offline multi-instance durability tests; the fake models atomic Firestore retries."""
import copy
from datetime import datetime, timezone
import hashlib
import json
import multiprocessing
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest
import uuid

from migrate_storage import import_snapshot, load_snapshot
from server import APIError, Issuer, validate_request
from storage import FirestoreStore, SQLiteStore, StoreConflict, StoreLimit, StoreUnavailable
from test_server import BILL, CONFIG, FakeMarqeta


class RetryConflict(Exception):
    pass


class FakeFirestoreEngine:
    def __init__(self):
        self.lock = threading.Lock()
        self.records = {}
        self.versions = {}
        self.local = threading.local()
        self.fail_after_commit_collection = None

    def client(self):
        return FakeFirestoreClient(self)

    def transactional(self, callback):
        def run(transaction):
            for _ in range(100):
                transaction.reads, transaction.writes = {}, []
                self.local.in_transaction = True
                try:
                    result = callback(transaction)
                    with self.lock:
                        if any(self.versions.get(key, 0) != version for key, version in transaction.reads.items()):
                            raise RetryConflict()
                        for action, key, value in transaction.writes:
                            if action == "create" and key in self.records:
                                raise RetryConflict()
                        for action, key, value in transaction.writes:
                            if action == "delete":
                                self.records.pop(key, None)
                            elif action == "update":
                                self.records[key].update(copy.deepcopy(value))
                            else:
                                self.records[key] = copy.deepcopy(value)
                            self.versions[key] = self.versions.get(key, 0) + 1
                        if self.fail_after_commit_collection and any(self.fail_after_commit_collection in key[0] for _, key, _ in transaction.writes):
                            self.fail_after_commit_collection = None
                            raise OSError("Simulated lost commit acknowledgement")
                    return result
                except RetryConflict:
                    continue
                finally:
                    self.local.in_transaction = False
            raise RuntimeError("Transaction retry budget exhausted")
        return run


class FakeSnapshot:
    def __init__(self, record):
        self.record = copy.deepcopy(record)
        self.exists = record is not None

    def to_dict(self):
        return copy.deepcopy(self.record)


class FakeDocument:
    def __init__(self, engine, collection, key):
        self.engine, self.key = engine, (collection, key)

    def get(self, transaction):
        if transaction.writes:
            raise AssertionError("Firestore does not allow reads after writes")
        with self.engine.lock:
            transaction.reads[self.key] = self.engine.versions.get(self.key, 0)
            snapshot = FakeSnapshot(self.engine.records.get(self.key))
        time.sleep(0.0005)  # Force interleavings between separate instance transactions.
        return snapshot


class FakeCollection:
    def __init__(self, engine, name):
        self.engine, self.name = engine, name

    def document(self, key):
        return FakeDocument(self.engine, self.name, key)


class FakeTransaction:
    def __init__(self):
        self.reads, self.writes = {}, []

    def create(self, ref, data):
        self.writes.append(("create", ref.key, copy.deepcopy(data)))

    def set(self, ref, data):
        self.writes.append(("set", ref.key, copy.deepcopy(data)))

    def update(self, ref, data):
        self.writes.append(("update", ref.key, copy.deepcopy(data)))

    def delete(self, ref):
        self.writes.append(("delete", ref.key, None))


class FakeFirestoreClient:
    def __init__(self, engine):
        self.engine = engine

    def collection(self, name):
        return FakeCollection(self.engine, name)

    def transaction(self):
        return FakeTransaction()

    def close(self):
        pass


def fake_store(engine, **kwargs):
    return FirestoreStore(client=engine.client(), transactional=engine.transactional, **kwargs)


def process_claim(path, event, output):
    """Independent Python processes share only a SQLite file."""
    store = SQLiteStore(Path(path))
    event.wait(5)
    output.put(store.claim_attempt("namespace", "/gpaorders", "funding-token") is not None)
    store.close()


class SQLiteDurabilityTests(unittest.TestCase):
    def test_independent_processes_only_one_funding_permission(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.sqlite3"
            SQLiteStore(path).close()
            context = multiprocessing.get_context("spawn")
            start, output = context.Event(), context.Queue()
            processes = [context.Process(target=process_claim, args=(str(path), start, output)) for _ in range(4)]
            for process in processes:
                process.start()
            start.set()
            winners = [output.get(timeout=10) for _ in processes]
            for process in processes:
                process.join(10)
                self.assertEqual(process.exitcode, 0)
            self.assertEqual(sum(winners), 1)
            reopened = SQLiteStore(path)
            self.assertIsNone(reopened.claim_attempt("namespace", "/gpaorders", "funding-token"))
            reopened.close()

    def test_legacy_schema_migrates_without_releasing_uncertain_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.sqlite3"
            db = sqlite3.connect(path)
            db.execute("CREATE TABLE intents(namespace TEXT,bill_id TEXT,cycle INTEGER,digest TEXT,result TEXT,PRIMARY KEY(namespace,bill_id,cycle))")
            db.execute("CREATE TABLE attempts(namespace TEXT,resource TEXT,token TEXT,started INTEGER NOT NULL,PRIMARY KEY(namespace,resource,token))")
            db.execute("INSERT INTO intents VALUES ('sandbox','bill',1,'digest',NULL)")
            db.execute("INSERT INTO attempts VALUES ('sandbox','/gpaorders','token',1)")
            db.commit()
            db.close()
            store = SQLiteStore(path)
            self.assertIsNone(store.reserve_intent("sandbox", "bill", 1, "digest").result)
            self.assertIsNone(store.claim_attempt("sandbox", "/gpaorders", "token"))
            self.assertFalse(store.clear_attempt("sandbox", "/gpaorders", "token", "random-owner"))
            with self.assertRaises(StoreConflict):
                store.reserve_intent("other-sandbox", "bill", 1, "digest")
            store.close()

    def test_old_owner_cannot_clear_new_owner_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            store = SQLiteStore(Path(directory) / "state.sqlite3")
            one = store.claim_attempt("ns", "/gpaorders", "token")
            self.assertTrue(store.clear_attempt("ns", "/gpaorders", "token", one))
            two = store.claim_attempt("ns", "/gpaorders", "token")
            self.assertNotEqual(one, two)
            self.assertFalse(store.clear_attempt("ns", "/gpaorders", "token", one))
            self.assertIsNone(store.claim_attempt("ns", "/gpaorders", "token"))
            store.close()


class FirestoreDurabilityTests(unittest.TestCase):
    def setUp(self):
        self.engine = FakeFirestoreEngine()
        self.store = fake_store(self.engine)

    def test_concurrent_claims_and_owner_fencing_across_instances(self):
        stores = [fake_store(self.engine) for _ in range(10)]
        winners, errors = [], []
        def claim(store):
            try:
                winners.append(store.claim_attempt("ns", "/gpaorders", "one"))
            except Exception as error:
                errors.append(error)
        threads = [threading.Thread(target=claim, args=(store,)) for store in stores]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        owners = [owner for owner in winners if owner is not None]
        self.assertFalse(errors)
        self.assertEqual(len(winners), 10)
        self.assertEqual(len(owners), 1)
        self.assertTrue(self.store.clear_attempt("ns", "/gpaorders", "one", owners[0]))
        new_owner = self.store.claim_attempt("ns", "/gpaorders", "one")
        self.assertNotEqual(new_owner, owners[0])
        self.assertFalse(self.store.clear_attempt("ns", "/gpaorders", "one", owners[0]))
        self.assertIsNone(fake_store(self.engine).claim_attempt("ns", "/gpaorders", "one"))

    def test_quota_atomic_across_instances_and_retries_do_not_count(self):
        successes, errors = [], []
        def reserve(number):
            try:
                fake_store(self.engine, daily_limit=5).reserve_intent("ns", str(number), 1, "digest")
                successes.append(number)
            except StoreLimit:
                pass
            except Exception as error:
                errors.append(error)
        threads = [threading.Thread(target=reserve, args=(number,)) for number in range(20)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertFalse(errors)
        self.assertEqual(len(successes), 5)
        for number in successes:
            fake_store(self.engine, daily_limit=5).reserve_intent("ns", str(number), 1, "digest")
        quota_records = [record for (collection, _), record in self.engine.records.items() if collection.endswith("daily_quota")]
        self.assertEqual(quota_records[0]["count"], 5)
        with self.assertRaises(StoreLimit):
            fake_store(self.engine, daily_limit=5).reserve_intent("different-namespace", "new-bill", 1, "digest")

    def test_same_intent_race_counts_once_and_binds_namespace_and_snapshot(self):
        errors = []
        def reserve():
            try:
                fake_store(self.engine).reserve_intent("ns", "bill", 1, "digest")
            except Exception as error:
                errors.append(error)
        threads = [threading.Thread(target=reserve) for _ in range(10)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        quotas = [record["count"] for (collection, _), record in self.engine.records.items() if collection.endswith("daily_quota")]
        self.assertFalse(errors)
        self.assertEqual(quotas, [1])
        for namespace, digest, expected in (("other", "digest", "sandbox_changed"), ("ns", "changed", "bill_changed")):
            with self.assertRaises(StoreConflict) as caught:
                fake_store(self.engine).reserve_intent(namespace, "bill", 1, digest)
            self.assertEqual(caught.exception.code, expected)
        with self.assertRaises(StoreConflict):
            fake_store(self.engine).lookup_intent("other", "bill", 1)

    def test_quota_rolls_over_utc_without_recharging_previous_intent(self):
        today = datetime(2026, 11, 14, 23, 59, tzinfo=timezone.utc)
        tomorrow = datetime(2026, 11, 15, 0, 1, tzinfo=timezone.utc)
        one = fake_store(self.engine, daily_limit=1, clock=lambda: today)
        one.reserve_intent("ns", "first", 1, "digest")
        with self.assertRaises(StoreLimit):
            one.reserve_intent("ns", "second", 1, "digest")
        two = fake_store(self.engine, daily_limit=1, clock=lambda: tomorrow)
        two.reserve_intent("ns", "first", 1, "digest")
        two.reserve_intent("ns", "second", 1, "digest")
        quotas = [record["count"] for (collection, _), record in self.engine.records.items() if collection.endswith("daily_quota")]
        self.assertEqual(sorted(quotas), [1, 1])

    def test_unknown_commit_before_post_is_fail_closed(self):
        provider = FakeMarqeta()
        issuer = Issuer(CONFIG, provider=provider, store=self.store)
        self.engine.fail_after_commit_collection = "attempts"
        with self.assertRaises(APIError) as caught:
            issuer.issue(BILL)
        self.assertEqual(caught.exception.code, "storage_unavailable")
        self.assertFalse(any(method == "POST" for method, _, _ in provider.calls))
        with self.assertRaises(APIError) as caught:
            Issuer(CONFIG, provider=provider, store=fake_store(self.engine)).issue(BILL)
        self.assertEqual(caught.exception.code, "reconciliation_pending")
        self.assertFalse(any(method == "POST" for method, _, _ in provider.calls))

    def test_complete_issuance_concurrent_instances_and_restart_do_not_reload(self):
        engine = self.engine
        class ThreadSafeProvider(FakeMarqeta):
            def __init__(self):
                super().__init__()
                self.lock = threading.Lock()
            def request(self, *args, **kwargs):
                if getattr(engine.local, "in_transaction", False):
                    raise AssertionError("Provider request inside transaction")
                with self.lock:
                    return super().request(*args, **kwargs)
        provider = ThreadSafeProvider()
        issuers = [Issuer(CONFIG, provider=provider, store=fake_store(engine)) for _ in range(6)]
        errors = []
        def issue(issuer):
            try:
                issuer.issue(BILL)
            except APIError as error:
                if error.code != "reconciliation_pending":
                    errors.append(error)
        threads = [threading.Thread(target=issue, args=(issuer,)) for issuer in issuers]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertFalse(errors)
        result = Issuer(CONFIG, provider=provider, store=fake_store(engine)).issue(BILL)
        for issuer in issuers:
            self.assertEqual(issuer.issue(BILL), result)
        for resource in ("/cardproducts", "/fundingsources/program", "/users", "/cards", "/gpaorders"):
            self.assertEqual(len(provider.posts(resource)), 1)
        stored = json.dumps(list(engine.records.values()))
        for secret in (CONFIG.application_token, CONFIG.admin_token, "leader-private-account", "4111111111119876", "cvv_number"):
            self.assertNotIn(secret, stored)

    def test_completed_funding_recovers_after_result_commit_failure(self):
        provider = FakeMarqeta()
        self.store.reserve_intent(CONFIG.namespace, BILL["billID"], 1,
            hashlib.sha256(json.dumps(validate_request(BILL), sort_keys=True, separators=(',', ':')).encode()).hexdigest())
        self.engine.fail_after_commit_collection = "intents"
        with self.assertRaises(APIError) as caught:
            Issuer(CONFIG, provider=provider, store=self.store).issue(BILL)
        self.assertEqual(caught.exception.code, "storage_unavailable")
        count = len(provider.calls)
        result = Issuer(CONFIG, provider=provider, store=fake_store(self.engine)).issue(BILL)
        self.assertEqual(result["loadedCents"], 1001)
        self.assertEqual(len(provider.calls), count)
        self.assertEqual(len(provider.posts("/gpaorders")), 1)

    def test_import_is_idempotent_preserves_pending_and_completed_and_no_quota_charge(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "source.sqlite3"
            issuer = Issuer(CONFIG, path, FakeMarqeta())
            expected = issuer.issue(BILL)
            # Retain a second pending intent and its uncertain funding marker.
            pending_id = str(uuid.uuid4()).upper()
            issuer.store.reserve_intent(CONFIG.namespace, pending_id, 1, "a" * 64)
            issuer.store.claim_attempt(CONFIG.namespace, "/gpaorders", "uncertain-order")
            issuer.close()
            intents, attempts = load_snapshot(path)
            first = import_snapshot(self.store, intents, attempts)
            again = import_snapshot(fake_store(self.engine), intents, attempts)
            self.assertEqual(first["intentsCreated"], 2)
            self.assertEqual(again["intentsCreated"], 0)
            self.assertEqual(again["attemptsCreated"], 0)
            self.assertEqual(self.store.lookup_intent(CONFIG.namespace, BILL["billID"], 1).result, expected)
            self.assertIsNone(self.store.lookup_intent(CONFIG.namespace, pending_id, 1).result)
            self.assertIsNone(self.store.claim_attempt(CONFIG.namespace, "/gpaorders", "uncertain-order"))
            self.assertFalse(any(collection.endswith("daily_quota") for collection, _ in self.engine.records))
            changed = dict(expected, loadedCents=1002, remainingCents=1002)
            with self.assertRaises(StoreConflict):
                self.store.import_intent(BILL["billID"], 1, CONFIG.namespace, intents[0][3], changed)


if __name__ == "__main__":
    unittest.main()
