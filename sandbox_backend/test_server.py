"""Offline behavioral/security tests. No credentials or network calls to Marqeta."""
import copy
from dataclasses import replace
import http.client
from http.server import HTTPServer
import json
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request

from server import APIError, Config, Issuer, Marqeta, NoRedirect, ProviderError, handler_for, sandbox_url, validate_request

CLIENT_TOKEN = "test-local-client-token-which-is-at-least-32-characters"
CONFIG = Config.from_env({"GROUP_PAY_CLIENT_TOKEN": CLIENT_TOKEN,
                          "MARQETA_APPLICATION_TOKEN": "test-app-credential",
                          "MARQETA_ADMIN_ACCESS_TOKEN": "test-admin-credential"})
BILL = {"billID": "8800755C-AE74-4510-93AE-A10A6C28EDFE", "cycle": 1, "amountCents": 1001,
        "currency": "USD", "leaderID": "leader-private-account",
        "members": [{"accountID": "leader-private-account", "approved": True, "shareCents": 500},
                    {"accountID": "guest-private-account", "approved": True, "shareCents": 501}]}


class FakeMarqeta:
    def __init__(self):
        self.records = {}
        self.calls = []
        self.timeout_after_create = set()
        self.timeout_before_create = set()
        self.pending_funding = False
        self.reject_resource = None

    def request(self, method, path, body=None):
        self.calls.append((method, path, copy.deepcopy(body)))
        if method == "GET":
            resource, token = path.rsplit("/", 1)
            if (resource, token) not in self.records:
                raise ProviderError(404)
            return copy.deepcopy(self.records[(resource, token)])
        if path == self.reject_resource:
            raise ProviderError(403)
        if path in self.timeout_before_create:
            self.timeout_before_create.remove(path)
            raise ProviderError(None)
        key = (path, body["token"])
        if key in self.records:
            raise ProviderError(409)
        result = copy.deepcopy(body)
        if path == "/users":
            result["active"] = True
        if path == "/cards":
            result.update(state="ACTIVE", last_four="9876", created_time="2026-11-14T20:00:00Z",
                          pan="4111111111119876", cvv_number="123")
        if path == "/gpaorders":
            result.update(state="PENDING" if self.pending_funding else "COMPLETION", response={"code": "0000"})
        self.records[key] = result
        if path in self.timeout_after_create:
            self.timeout_after_create.remove(path)
            raise ProviderError(None)
        return copy.deepcopy(result)

    def posts(self, resource):
        return [call for call in self.calls if call[:2] == ("POST", resource)]


class ValidationTests(unittest.TestCase):
    def expect_invalid(self, body):
        with self.assertRaises(APIError) as result:
            validate_request(body)
        self.assertEqual(result.exception.status, 422)

    def test_exact_integer_cents_and_approval_validation(self):
        for value in (True, False, 1.0, "1001", 0, -1, 10_000_001, None):
            with self.subTest(amount=value):
                body = copy.deepcopy(BILL)
                body["amountCents"] = value
                self.expect_invalid(body)
        for key, value in (("approved", 1), ("approved", False), ("shareCents", True),
                           ("shareCents", 500.0), ("shareCents", -1)):
            with self.subTest(key=key, value=value):
                body = copy.deepcopy(BILL)
                body["members"][0][key] = value
                self.expect_invalid(body)

    def test_missing_claim_duplicate_claim_and_bad_total(self):
        variants = []
        body = copy.deepcopy(BILL)
        body["members"][1]["accountID"] = "leader-private-account"
        variants.append(body)
        body = copy.deepcopy(BILL)
        body["leaderID"] = "not-a-member"
        variants.append(body)
        body = copy.deepcopy(BILL)
        body["members"][1]["shareCents"] = 500
        variants.append(body)
        body = copy.deepcopy(BILL)
        body["members"][1]["accountID"] = ""
        variants.append(body)
        body = copy.deepcopy(BILL)
        body["currency"] = "EUR"
        variants.append(body)
        body = copy.deepcopy(BILL)
        body["cycle"] = True
        variants.append(body)
        for body in variants:
            with self.subTest(body=body):
                self.expect_invalid(body)

    def test_one_cent_and_maximum_exact(self):
        for total in (1, 10_000_000):
            body = copy.deepcopy(BILL)
            body["amountCents"] = total
            body["members"][0]["shareCents"] = 0
            body["members"][1]["shareCents"] = total
            self.assertEqual(validate_request(body)["amountCents"], total)

    def test_only_official_sandbox_origin_allowed(self):
        self.assertEqual(sandbox_url("https://sandbox-api.marqeta.com:443/v3/"), CONFIG.base_url)
        for url in ("https://api.marqeta.com/v3", "http://sandbox-api.marqeta.com/v3",
                    "https://sandbox-api.marqeta.com.evil.test/v3", "https://sandbox-api.marqeta.com:444/v3",
                    "https://user@sandbox-api.marqeta.com/v3", "https://sandbox-api.marqeta.com/v3?x=1",
                    "https://sandbox-api.marqeta.com/v3#fragment", "https://localhost/v3"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                sandbox_url(url)

    def test_redirects_rejected_without_following(self):
        redirect = NoRedirect()
        req = urllib.request.Request(CONFIG.base_url + "/users", headers={"Authorization": "secret"})
        for status in (301, 302, 303, 307, 308):
            with self.subTest(status=status), self.assertRaises(ProviderError):
                redirect.redirect_request(req, None, status, "redirect", {}, "https://evil.test/")

    def test_provider_path_cannot_override_origin(self):
        client = Marqeta(CONFIG)
        for path in ("//evil.test/users", "https://evil.test", "/users?show_pan=true", "/../users"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                client.request("GET", path)


class IssuerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "issuance.sqlite3"
        self.provider = FakeMarqeta()
        self.issuer = Issuer(CONFIG, self.path, self.provider)

    def tearDown(self):
        self.issuer.close()
        self.temp.cleanup()

    def assert_api_error(self, code, callback):
        with self.assertRaises(APIError) as result:
            callback()
        self.assertEqual(result.exception.code, code)
        return result.exception

    def test_success_masked_result_and_durable_replay(self):
        result = self.issuer.issue(BILL)
        self.assertEqual(set(result), {"provider", "cardToken", "lastFour", "state", "loadedCents", "remainingCents", "createdAt"})
        self.assertEqual(result["loadedCents"], 1001)
        self.assertEqual(result["remainingCents"], 1001)
        self.assertEqual(result["lastFour"], "9876")
        order = self.provider.posts("/gpaorders")[0][2]
        self.assertEqual(order["amount"], 10.01)
        for _, _, body in self.provider.calls:
            if body:
                self.assertLessEqual(len(body["token"]), 36)
        first_count = len(self.provider.calls)
        reordered = copy.deepcopy(BILL)
        reordered["members"].reverse()
        reordered["billID"] = reordered["billID"].lower()
        self.assertEqual(self.issuer.issue(reordered), result)
        self.assertEqual(len(self.provider.calls), first_count)
        self.issuer.close()
        self.issuer = Issuer(CONFIG, self.path, self.provider)
        self.assertEqual(self.issuer.issue(BILL), result)
        self.assertEqual(len(self.provider.posts("/gpaorders")), 1)
        self.assertEqual(self.issuer.lookup(BILL["billID"], 1), (200, result))
        self.issuer.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        raw = self.path.read_bytes()
        for secret in ("4111111111119876", CONFIG.application_token, CONFIG.admin_token, CLIENT_TOKEN,
                       "leader-private-account", "guest-private-account", "cvv_number"):
            self.assertNotIn(secret.encode(), raw)

    def test_card_and_funding_timeout_after_provider_accepts_recovers_once(self):
        self.provider.timeout_after_create = {"/cards", "/gpaorders"}
        self.issuer.issue(BILL)
        self.assertEqual(len(self.provider.posts("/cards")), 1)
        self.assertEqual(len(self.provider.posts("/gpaorders")), 1)
        self.issuer.issue(BILL)
        self.assertEqual(len(self.provider.posts("/gpaorders")), 1)

    def test_timeout_before_funding_response_never_blindly_reposts(self):
        self.provider.timeout_before_create = {"/gpaorders"}
        self.assert_api_error("sandbox_unavailable", lambda: self.issuer.issue(BILL))
        status, body = self.issuer.lookup(BILL["billID"], 1)
        self.assertEqual(status, 202)
        self.assertEqual(body["status"], "pending")
        self.issuer.close()
        self.issuer = Issuer(CONFIG, self.path, self.provider)
        self.assert_api_error("reconciliation_pending", lambda: self.issuer.issue(BILL))
        self.assertEqual(len(self.provider.posts("/gpaorders")), 1)
        # A delayed provider completion is found by its original token next time.
        sent = self.provider.posts("/gpaorders")[0][2]
        self.provider.records[("/gpaorders", sent["token"])] = {**sent, "state": "COMPLETION", "response": {"code": "0000"}}
        self.assertEqual(self.issuer.issue(BILL)["loadedCents"], 1001)
        self.assertEqual(len(self.provider.posts("/gpaorders")), 1)

    def test_pending_funding_is_not_saved_as_complete(self):
        self.provider.pending_funding = True
        self.assert_api_error("funding_pending", lambda: self.issuer.issue(BILL))
        self.assertEqual(self.issuer.lookup(BILL["billID"], 1)[0], 202)
        for (resource, _), record in self.provider.records.items():
            if resource == "/gpaorders":
                record["state"] = "COMPLETION"
        self.issuer.issue(BILL)
        self.assertEqual(len(self.provider.posts("/gpaorders")), 1)

    def test_changed_snapshot_conflicts_before_network(self):
        self.issuer.issue(BILL)
        count = len(self.provider.calls)
        for kind in ("total", "shares", "leader"):
            body = copy.deepcopy(BILL)
            if kind == "total":
                body["amountCents"] += 1
                body["members"][1]["shareCents"] += 1
            elif kind == "shares":
                body["members"][0]["shareCents"] += 1
                body["members"][1]["shareCents"] -= 1
            else:
                body["leaderID"] = "guest-private-account"
            self.assert_api_error("bill_changed", lambda: self.issuer.issue(body))
        self.assertEqual(len(self.provider.calls), count)

    def test_new_cycle_is_an_isolated_user_card_and_load(self):
        one = self.issuer.issue(BILL)
        body = copy.deepcopy(BILL)
        body["cycle"] = 2
        two = self.issuer.issue(body)
        self.assertNotEqual(one["cardToken"], two["cardToken"])
        self.assertEqual(len(self.provider.posts("/users")), 2)
        self.assertEqual(len(self.provider.posts("/gpaorders")), 2)
        self.assertEqual(len(self.provider.posts("/cardproducts")), 1)
        self.assertEqual(len(self.provider.posts("/fundingsources/program")), 1)

    def test_application_change_rejected_but_admin_rotation_allowed(self):
        original = self.issuer.issue(BILL)
        self.issuer.close()
        self.issuer = Issuer(replace(CONFIG, admin_token="rotated-admin"), self.path, self.provider)
        self.assertEqual(self.issuer.issue(BILL), original)
        self.issuer.close()
        self.issuer = Issuer(replace(CONFIG, application_token="different-application"), self.path, self.provider)
        count = len(self.provider.calls)
        self.assert_api_error("sandbox_changed", lambda: self.issuer.issue(BILL))
        self.assert_api_error("sandbox_changed", lambda: self.issuer.lookup(BILL["billID"], 1))
        self.assertEqual(len(self.provider.calls), count)

    def test_missing_credentials_block_before_network(self):
        self.issuer.close()
        self.issuer = Issuer(replace(CONFIG, application_token="", admin_token=""), self.path, self.provider)
        self.assert_api_error("not_configured", lambda: self.issuer.issue(BILL))
        self.assertEqual(self.provider.calls, [])

    def test_permission_denied_stays_pending_and_can_retry_after_fix(self):
        self.provider.reject_resource = "/cardproducts"
        self.assert_api_error("sandbox_access_denied", lambda: self.issuer.issue(BILL))
        self.assertEqual(self.issuer.lookup(BILL["billID"], 1)[0], 202)
        self.provider.reject_resource = None
        self.issuer.issue(BILL)
        self.assertEqual(len(self.provider.posts("/gpaorders")), 1)

    def test_same_intent_concurrent_requests_create_once(self):
        results, errors = [], []
        def run():
            try:
                results.append(self.issuer.issue(BILL))
            except Exception as error:
                errors.append(error)
        threads = [threading.Thread(target=run) for _ in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertFalse(errors)
        self.assertEqual(len(results), 4)
        self.assertTrue(all(result == results[0] for result in results))
        self.assertEqual(len(self.provider.posts("/gpaorders")), 1)


class HTTPTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.issuer = Issuer(replace(CONFIG, application_token="", admin_token=""), Path(self.temp.name) / "test.sqlite3", FakeMarqeta())
        self.http = HTTPServer(("127.0.0.1", 0), handler_for(self.issuer))
        self.thread = threading.Thread(target=self.http.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.http.shutdown()
        self.thread.join()
        self.http.server_close()
        self.issuer.close()
        self.temp.cleanup()

    def request(self, method, path, body=None, token=None, extra=None):
        headers = {"Host": "127.0.0.1:8787", "Content-Type": "application/json"}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        headers.update(extra or {})
        client = http.client.HTTPConnection("127.0.0.1", self.http.server_port, timeout=2)
        client.request(method, path, None if body is None else json.dumps(body), headers)
        response = client.getresponse()
        result = response.status, json.loads(response.read())
        client.close()
        return result

    def test_health_public_status_authenticated(self):
        self.assertEqual(self.request("GET", "/health"), (200, {"ready": False}))
        self.assertEqual(self.request("GET", "/v1/status")[0], 401)
        self.assertEqual(self.request("GET", "/v1/status", token="wrong")[0], 401)
        self.assertEqual(self.request("GET", "/v1/status", token=CLIENT_TOKEN),
                         (200, {"ready": False, "environment": "sandbox"}))

    def test_issuing_requires_bearer_and_configured_provider(self):
        self.assertEqual(self.request("POST", "/v1/cards", BILL)[0], 401)
        status, body = self.request("POST", "/v1/cards", BILL, token=CLIENT_TOKEN)
        self.assertEqual(status, 503)
        self.assertEqual(body["error"], "not_configured")
        self.assertEqual(self.issuer.provider.calls, [])

    def test_browser_origin_and_foreign_host_rejected(self):
        self.assertEqual(self.request("GET", "/health", extra={"Origin": "https://evil.test"})[0], 403)
        self.assertEqual(self.request("GET", "/health", extra={"Host": "evil.test:8787"})[0], 403)

    def test_unknown_lookup_and_routes(self):
        self.assertEqual(self.request("GET", "/v1/cards/" + BILL["billID"] + "/1", token=CLIENT_TOKEN)[0], 404)
        self.assertEqual(self.request("GET", "/v1/status?token=leak", token=CLIENT_TOKEN)[0], 404)
        self.assertEqual(self.request("POST", "/v1/cards/" + BILL["billID"] + "/1/simulate-payment", {}, token=CLIENT_TOKEN)[0], 404)


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for name in ("server.py", "storage.py", "setup.py"):
            shutil.copy(Path(__file__).parent / name, self.root / name)

    def tearDown(self):
        self.temp.cleanup()

    def run_setup(self, *args):
        completed = subprocess.run([sys.executable, str(self.root / "setup.py"), *args],
                                   input="", text=True, capture_output=True, check=True, timeout=5)
        env = dict(line.split("=", 1) for line in (self.root / ".env").read_text().splitlines()
                   if line and not line.startswith("#"))
        return completed.stdout + completed.stderr, env

    def test_noninteractive_setup_generates_private_token_without_printing(self):
        output, env = self.run_setup()
        self.assertGreaterEqual(len(env["GROUP_PAY_CLIENT_TOKEN"]), 32)
        self.assertNotIn(env["GROUP_PAY_CLIENT_TOKEN"], output)
        self.assertEqual(stat.S_IMODE((self.root / ".env").stat().st_mode), 0o600)

    def test_setup_repairs_empty_token_and_retains_provider_credentials_privately(self):
        path = self.root / ".env"
        path.write_text("GROUP_PAY_CLIENT_TOKEN=\nMARQETA_APPLICATION_TOKEN=private-app\nMARQETA_ADMIN_ACCESS_TOKEN=private-admin\n")
        path.chmod(0o644)
        output, env = self.run_setup()
        self.assertGreaterEqual(len(env["GROUP_PAY_CLIENT_TOKEN"]), 32)
        self.assertEqual(env["MARQETA_APPLICATION_TOKEN"], "private-app")
        self.assertEqual(env["MARQETA_ADMIN_ACCESS_TOKEN"], "private-admin")
        self.assertNotIn("private-app", output)
        self.assertNotIn("private-admin", output)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        _, second = self.run_setup()
        self.assertEqual(second["GROUP_PAY_CLIENT_TOKEN"], env["GROUP_PAY_CLIENT_TOKEN"])


if __name__ == "__main__":
    unittest.main()
