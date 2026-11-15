"""Durable issuance state; provider requests must never run inside store transactions.

Firestore collections must be retained without TTL deletion. Each bill/cycle has
one globally bound intent; a durable, owner-fenced attempt grants at most one
worker permission to send a provider create request. An uncertain attempt never
expires automatically. The local SQLite schema is migrated in place.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import sqlite3
import threading
from typing import Protocol
import uuid


class StoreError(Exception):
    """Safe storage failures, without database/provider details."""


class StoreUnavailable(StoreError):
    def __init__(self):
        super().__init__("Durable issuance storage is unavailable.")


class StoreConflict(StoreError):
    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


class StoreLimit(StoreError):
    def __init__(self):
        super().__init__("The daily test-card limit has been reached.")


@dataclass(frozen=True)
class Intent:
    result: dict | None


class IssuanceStore(Protocol):
    def reserve_intent(self, namespace: str, bill_id: str, cycle: int, digest: str) -> Intent: ...
    def lookup_intent(self, namespace: str, bill_id: str, cycle: int) -> Intent | None: ...
    def complete_intent(self, namespace: str, bill_id: str, cycle: int, digest: str, result: dict) -> dict: ...
    def claim_attempt(self, namespace: str, resource: str, token: str) -> str | None: ...
    def clear_attempt(self, namespace: str, resource: str, token: str, owner: str) -> bool: ...
    def close(self) -> None: ...


def safe_result(value: dict) -> dict:
    """Only the public masked-card contract may be persisted or read back."""
    keys = {"provider", "cardToken", "lastFour", "state", "loadedCents", "remainingCents", "createdAt"}
    if not isinstance(value, dict) or set(value) != keys:
        raise StoreUnavailable()
    if (value["provider"] != "marqetaSandbox" or value["state"] != "ACTIVE"
            or not isinstance(value["cardToken"], str)
            or re.fullmatch(r"[A-Za-z0-9_-]{1,36}", value["cardToken"]) is None
            or not isinstance(value["lastFour"], str) or re.fullmatch(r"[0-9]{4}", value["lastFour"]) is None
            or type(value["loadedCents"]) is not int or not 1 <= value["loadedCents"] <= 10_000_000
            or type(value["remainingCents"]) is not int or not 0 <= value["remainingCents"] <= value["loadedCents"]):
        raise StoreUnavailable()
    try:
        date = datetime.fromisoformat(value["createdAt"].replace("Z", "+00:00"))
        if date.tzinfo is None:
            raise ValueError()
    except (AttributeError, TypeError, ValueError):
        raise StoreUnavailable() from None
    return dict(value)


def checked_intent(record: dict, namespace: str, digest: str | None = None) -> Intent:
    if not isinstance(record, dict) or not isinstance(record.get("namespace"), str) or not isinstance(record.get("digest"), str):
        raise StoreUnavailable()
    if record.get("schema", 1) != 1:
        raise StoreUnavailable()
    if not hmac.compare_digest(record["namespace"], namespace):
        raise StoreConflict("sandbox_changed")
    if digest is not None and not hmac.compare_digest(record["digest"], digest):
        raise StoreConflict("bill_changed")
    result = record.get("result")
    return Intent(None if result is None else safe_result(result))


class SQLiteStore:
    """Local durable store, safe across independent processes/connections."""
    def __init__(self, path: Path):
        self.lock = threading.RLock()
        self.db = None
        try:
            path = Path(path)
            path.parent.mkdir(parents=True, exist_ok=True)
            self.db = sqlite3.connect(str(path), timeout=15, check_same_thread=False, isolation_level=None)
            os.chmod(path, 0o600)
            self.db.execute("PRAGMA journal_mode=WAL")
            with self._transaction():
                self.db.execute("CREATE TABLE IF NOT EXISTS intents (namespace TEXT, bill_id TEXT, cycle INTEGER, digest TEXT, result TEXT, PRIMARY KEY(namespace,bill_id,cycle))")
                # Bind each bill/cycle globally, including across credential changes.
                self.db.execute("CREATE UNIQUE INDEX IF NOT EXISTS intent_bill_cycle ON intents(bill_id,cycle)")
                self.db.execute("CREATE TABLE IF NOT EXISTS attempts (namespace TEXT, resource TEXT, token TEXT, started INTEGER NOT NULL, owner TEXT, PRIMARY KEY(namespace,resource,token))")
                columns = {row[1] for row in self.db.execute("PRAGMA table_info(attempts)")}
                if "owner" not in columns:
                    self.db.execute("ALTER TABLE attempts ADD COLUMN owner TEXT")
        except StoreError:
            self.close()
            raise
        except Exception:
            self.close()
            raise StoreUnavailable() from None

    @contextmanager
    def _transaction(self):
        with self.lock:
            try:
                self.db.execute("BEGIN IMMEDIATE")
                yield
                self.db.execute("COMMIT")
            except BaseException as error:
                if self.db.in_transaction:
                    self.db.execute("ROLLBACK")
                if isinstance(error, (StoreError, KeyboardInterrupt, SystemExit)):
                    raise
                raise StoreUnavailable() from None

    def _read(self, bill_id: str, cycle: int) -> dict | None:
        row = self.db.execute("SELECT namespace,digest,result FROM intents WHERE bill_id=? AND cycle=?", (bill_id, cycle)).fetchone()
        if row is None:
            return None
        return {"namespace": row[0], "digest": row[1], "result": None if row[2] is None else json.loads(row[2])}

    def reserve_intent(self, namespace, bill_id, cycle, digest):
        with self._transaction():
            record = self._read(bill_id, cycle)
            if record is not None:
                return checked_intent(record, namespace, digest)
            self.db.execute("INSERT INTO intents(namespace,bill_id,cycle,digest,result) VALUES (?,?,?,?,NULL)", (namespace, bill_id, cycle, digest))
            return Intent(None)

    def lookup_intent(self, namespace, bill_id, cycle):
        with self._transaction():
            record = self._read(bill_id, cycle)
            return None if record is None else checked_intent(record, namespace)

    def complete_intent(self, namespace, bill_id, cycle, digest, result):
        result = safe_result(result)
        with self._transaction():
            record = self._read(bill_id, cycle)
            if record is None:
                raise StoreUnavailable()
            existing = checked_intent(record, namespace, digest)
            if existing.result is not None:
                return existing.result
            self.db.execute("UPDATE intents SET result=? WHERE bill_id=? AND cycle=?", (json.dumps(result), bill_id, cycle))
            return result

    def claim_attempt(self, namespace, resource, token):
        owner = str(uuid.uuid4())
        with self._transaction():
            existing = self.db.execute("SELECT 1 FROM attempts WHERE namespace=? AND resource=? AND token=?", (namespace, resource, token)).fetchone()
            if existing:
                return None
            self.db.execute("INSERT INTO attempts(namespace,resource,token,started,owner) VALUES (?,?,?,1,?)", (namespace, resource, token, owner))
            return owner

    def clear_attempt(self, namespace, resource, token, owner):
        with self._transaction():
            cursor = self.db.execute("DELETE FROM attempts WHERE namespace=? AND resource=? AND token=? AND owner=?", (namespace, resource, token, owner))
            return cursor.rowcount == 1

    def close(self):
        if self.db is not None:
            self.db.close()
            self.db = None


class FirestoreStore:
    """Cloud-only store. Requires google-cloud-firestore; never falls back to disk.

    Injected client/transactional parameters are for offline transaction-model
    tests. Production uses Application Default Credentials and server-side IAM.
    No cardholder identities, provider credentials, PANs, or CVVs are stored.
    """
    def __init__(self, project: str | None = None, database: str = "(default)",
                 collection_prefix: str = "group_pay", daily_limit: int = 100,
                 *, client=None, transactional=None, clock=None, credentials=None):
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,62}", collection_prefix):
            raise ValueError("Invalid Firestore collection prefix.")
        if type(daily_limit) is not int or not 1 <= daily_limit <= 100:
            raise ValueError("The shared daily test-card limit must be between 1 and 100.")
        try:
            if client is None or transactional is None:
                from google.cloud import firestore
                if client is None:
                    client = firestore.Client(project=project, database=database, credentials=credentials)
                if transactional is None:
                    transactional = firestore.transactional
        except Exception:
            raise StoreUnavailable() from None
        self.client, self.transactional = client, transactional
        self.prefix, self.daily_limit = collection_prefix, daily_limit
        self.clock = clock or (lambda: datetime.now(timezone.utc))

    def _reference(self, collection: str, *key_parts):
        key = hashlib.sha256(json.dumps(key_parts, separators=(",", ":")).encode()).hexdigest()
        return self.client.collection(self.prefix + "_" + collection).document(key)

    def _run(self, callback):
        try:
            # Callback retries contain only reads/writes, never provider requests.
            return self.transactional(callback)(self.client.transaction())
        except StoreError:
            raise
        except Exception:
            raise StoreUnavailable() from None

    @staticmethod
    def _record(reference, transaction):
        snapshot = reference.get(transaction=transaction)
        return snapshot.to_dict() if snapshot.exists else None

    def reserve_intent(self, namespace, bill_id, cycle, digest):
        reference = self._reference("intents", bill_id, cycle)
        day = self.clock().astimezone(timezone.utc).date().isoformat()
        quota = self._reference("daily_quota", day)
        def reserve(transaction):
            record = self._record(reference, transaction)
            if record is not None:
                return checked_intent(record, namespace, digest)
            usage = self._record(quota, transaction)
            count = 0 if usage is None else usage.get("count")
            if type(count) is not int or count < 0:
                raise StoreUnavailable()
            if count >= self.daily_limit:
                raise StoreLimit()
            # All reads precede writes. Reservation and daily quota commit together.
            transaction.create(reference, {"schema": 1, "namespace": namespace, "digest": digest, "result": None})
            transaction.set(quota, {"day": day, "count": count + 1})
            return Intent(None)
        return self._run(reserve)

    def lookup_intent(self, namespace, bill_id, cycle):
        reference = self._reference("intents", bill_id, cycle)
        def lookup(transaction):
            record = self._record(reference, transaction)
            return None if record is None else checked_intent(record, namespace)
        return self._run(lookup)

    def complete_intent(self, namespace, bill_id, cycle, digest, result):
        result = safe_result(result)
        reference = self._reference("intents", bill_id, cycle)
        def complete(transaction):
            record = self._record(reference, transaction)
            if record is None:
                raise StoreUnavailable()
            existing = checked_intent(record, namespace, digest)
            if existing.result is not None:
                return existing.result
            transaction.update(reference, {"result": result})
            return result
        return self._run(complete)

    def claim_attempt(self, namespace, resource, token):
        reference = self._reference("attempts", namespace, resource, token)
        owner = str(uuid.uuid4())
        def claim(transaction):
            if self._record(reference, transaction) is not None:
                return None
            transaction.create(reference, {"schema": 1, "owner": owner})
            return owner
        return self._run(claim)

    def clear_attempt(self, namespace, resource, token, owner):
        reference = self._reference("attempts", namespace, resource, token)
        def clear(transaction):
            record = self._record(reference, transaction)
            if record is None or record.get("owner") != owner:
                return False
            transaction.delete(reference)
            return True
        return self._run(clear)

    def close(self):
        close = getattr(self.client, "close", None)
        if close:
            close()

    def import_intent(self, bill_id, cycle, namespace, digest, result):
        """Historical migration only; exact create-or-match, with no daily charge."""
        result = None if result is None else safe_result(result)
        reference = self._reference("intents", bill_id, cycle)
        expected = {"schema": 1, "namespace": namespace, "digest": digest, "result": result}
        def import_record(transaction):
            record = self._record(reference, transaction)
            if record is None:
                transaction.create(reference, expected)
                return True
            checked_intent(record, namespace, digest)
            if record != expected:
                raise StoreConflict("migration_conflict")
            return False
        return self._run(import_record)

    def import_attempt(self, namespace, resource, token, owner):
        reference = self._reference("attempts", namespace, resource, token)
        # Legacy SQLite markers had no owner; give them a stable unclaimable fence.
        owner = owner or str(uuid.uuid5(uuid.NAMESPACE_URL, "group-pay-import:" + namespace + ":" + resource + ":" + token))
        expected = {"schema": 1, "owner": owner}
        def import_record(transaction):
            record = self._record(reference, transaction)
            if record is None:
                transaction.create(reference, expected)
                return True
            if record != expected:
                raise StoreConflict("migration_conflict")
            return False
        return self._run(import_record)
