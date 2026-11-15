"""Offline cloud HTTP and deployment-boundary tests; no cloud/provider calls."""
import copy
from dataclasses import replace
from importlib.util import module_from_spec, spec_from_file_location
import io
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest.mock import patch

from cloud_app import create_app, configured_issuer, DAILY_NEW_INTENT_LIMIT, MAX_CARD_CENTS
from server import APIError, Config

CLIENT_TOKEN = "offline-team-test-token-with-more-than-32-characters"
ENV = {"GROUP_PAY_CLIENT_TOKEN": CLIENT_TOKEN, "MARQETA_APPLICATION_TOKEN": "test-app",
       "MARQETA_ADMIN_ACCESS_TOKEN": "test-admin", "GOOGLE_CLOUD_PROJECT": "group-pay-test"}
CONFIG = Config.from_env(ENV)
BILL = {"billID": "8800755C-AE74-4510-93AE-A10A6C28EDFE", "cycle": 1, "amountCents": 1001,
        "currency": "USD", "leaderID": "leader",
        "members": [{"accountID": "leader", "approved": True, "shareCents": 500},
                    {"accountID": "guest", "approved": True, "shareCents": 501}]}
RESULT = {"provider": "marqetaSandbox", "cardToken": "37b6d795-6a25-4f0b-86df-471fa847e231", "lastFour": "9876",
          "state": "ACTIVE", "loadedCents": 1001, "remainingCents": 1001, "createdAt": "2026-11-14T20:00:00Z"}


class FakeIssuer:
    config = CONFIG
    def __init__(self):
        self.calls = []
        self.error = None
        self.result = dict(RESULT)
        self.lookup_status = 200
        self.lookup_missing = False

    def issue(self, data):
        self.calls.append(copy.deepcopy(data))
        if self.error:
            raise self.error
        return self.result

    def lookup(self, _bill_id, _cycle):
        if self.lookup_missing:
            raise APIError(404, "not_found", "")
        if self.error:
            raise self.error
        return self.lookup_status, self.result


class CloudHTTPTests(unittest.TestCase):
    def setUp(self):
        self.issuer = FakeIssuer()
        self.app = create_app(self.issuer)
        self.client = self.app.test_client()
        self.auth = {"Authorization": "Bearer " + CLIENT_TOKEN}

    def post(self, body=None, **kwargs):
        return self.client.post("/v1/cards", json=BILL if body is None else body, headers=self.auth, **kwargs)

    def test_health_is_public_but_status_is_authenticated(self):
        self.assertEqual(self.client.get("/health").json, {"status": "ok", "environment": "sandbox"})
        self.assertEqual(self.client.get("/v1/status").status_code, 401)
        self.assertEqual(self.client.get("/v1/status", headers={"Authorization": "Bearer wrong"}).status_code, 401)
        result = self.client.get("/v1/status", headers=self.auth)
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.json["maxAmountCents"], MAX_CARD_CENTS)
        self.assertEqual(result.json["dailyNewIntentLimit"], DAILY_NEW_INTENT_LIMIT)

    def test_auth_is_constant_time_and_all_card_routes_protected(self):
        with patch("cloud_app.hmac.compare_digest", wraps=__import__("hmac").compare_digest) as compare:
            self.assertEqual(self.client.post("/v1/cards", json=BILL).status_code, 401)
            compare.assert_called_once()
        self.assertEqual(self.client.get("/v1/cards/" + BILL["billID"] + "/1").status_code, 401)
        self.assertEqual(self.issuer.calls, [])

    def test_browser_origins_and_cors_preflight_rejected(self):
        for method, path in (("GET", "/health"), ("POST", "/v1/cards"), ("OPTIONS", "/v1/cards")):
            response = self.client.open(path, method=method, headers={**self.auth, "Origin": "https://elsewhere.test"})
            self.assertEqual(response.status_code, 403)
            self.assertNotIn("Access-Control-Allow-Origin", response.headers)
        self.assertEqual(self.client.options("/v1/cards", headers=self.auth).status_code, 404)

    def test_query_tokens_unknown_routes_and_methods_are_not_accepted(self):
        for path in ("/health?token=secret", "/v1/status?ignored=1", "/v1/cards/anything/1", "/v1/cards/" + BILL["billID"] + "/1000001"):
            self.assertIn(self.client.get(path, headers=self.auth).status_code, (404, 422))
        self.assertEqual(self.client.delete("/v1/cards", headers=self.auth).status_code, 404)

    def test_payload_is_limited_to_32_kib(self):
        response = self.client.post("/v1/cards", data=b"x" * 32769, content_type="application/json", headers=self.auth)
        self.assertEqual(response.status_code, 413)
        self.assertEqual(self.issuer.calls, [])

    def test_only_valid_json_without_duplicate_keys_or_nonfinite_numbers(self):
        for body in (b"{broken", b'{"cycle":1,"cycle":2}', b'{"amountCents":NaN}', b'\xff', b"[]"):
            result = self.client.post("/v1/cards", data=body, content_type="application/json", headers=self.auth)
            self.assertIn(result.status_code, (400, 422))
        self.assertEqual(self.issuer.calls, [])

    def test_content_type_is_required(self):
        result = self.client.post("/v1/cards", data=json.dumps(BILL), content_type="text/plain", headers=self.auth)
        self.assertEqual(result.status_code, 415)

    def test_cents_approval_and_amount_caps_enforced_before_provider(self):
        self.issuer.lookup_missing = True
        for amount in (True, 10.01, "1001", 0, MAX_CARD_CENTS + 1):
            body = copy.deepcopy(BILL)
            body["amountCents"] = amount
            if type(amount) is int and amount > 500:
                body["members"][1]["shareCents"] = amount - 500
            self.assertEqual(self.post(body).status_code, 422)
        body = copy.deepcopy(BILL)
        body["members"][1]["approved"] = False
        self.assertEqual(self.post(body).status_code, 422)
        self.assertEqual(self.issuer.calls, [])

    def test_issue_and_lookup_only_return_masked_allowlisted_fields(self):
        self.issuer.result.update(pan="4111111111119876", cvv="123", credentials="must-not-leak")
        result = self.post()
        self.assertEqual(result.status_code, 200)
        self.assertEqual(result.json, RESULT)
        self.assertEqual(self.client.get("/v1/cards/" + BILL["billID"] + "/1", headers=self.auth).json, RESULT)
        self.assertEqual(self.issuer.calls[0]["amountCents"], 1001)
        self.assertEqual(self.issuer.calls[0]["members"][0]["accountID"], "guest")

    def test_invalid_stored_result_never_leaks(self):
        for key, value in (("lastFour", "4111111111119876"), ("loadedCents", True), ("createdAt", "no-date"), ("provider", "production")):
            self.issuer.result = {**RESULT, key: value}
            response = self.post()
            self.assertEqual(response.status_code, 502)
            self.assertEqual(response.json["error"], "invalid_provider_result")

    def test_errors_are_safe_and_allowlisted(self):
        secret = "do-not-echo-private-credential-or-provider-body"
        for error in (APIError(503, "storage_unavailable", secret), APIError(429, "daily_limit_reached", secret),
                      APIError(409, "bill_changed", secret), APIError(400, secret, secret), RuntimeError(secret)):
            with self.subTest(error=type(error)):
                self.issuer.error = error
                with patch("sys.stderr", new_callable=io.StringIO) as stderr:
                    response = self.post()
                self.assertNotIn(secret, response.get_data(as_text=True))
                self.assertNotIn(secret, stderr.getvalue())
                self.assertEqual(response.mimetype, "application/json")

    def test_pending_lookup_uses_fixed_message(self):
        self.issuer.lookup_status = 202
        self.issuer.result = {"message": "private-provider-body"}
        response = self.client.get("/v1/cards/" + BILL["billID"] + "/1", headers=self.auth)
        self.assertEqual(response.status_code, 202)
        self.assertEqual(response.json["status"], "pending")
        self.assertNotIn("private-provider-body", response.get_data(as_text=True))

    def test_all_responses_disable_caching_without_cors(self):
        for response in (self.client.get("/health"), self.client.get("/v1/status"), self.post()):
            self.assertEqual(response.headers["Cache-Control"], "no-store")
            self.assertEqual(response.headers["X-Content-Type-Options"], "nosniff")
            self.assertNotIn("Access-Control-Allow-Origin", response.headers)


class CloudConfigurationTests(unittest.TestCase):
    def test_no_sqlite_fallback_and_exact_firestore_configuration(self):
        sentinel = object()
        fake_storage = types.ModuleType("storage")
        with patch.dict("sys.modules", {"storage": fake_storage}), patch("cloud_app.Issuer") as issuer:
            fake_storage.FirestoreStore = __import__("unittest.mock", fromlist=["Mock"]).Mock(return_value=sentinel)
            configured_issuer(ENV)
            fake_storage.FirestoreStore.assert_called_once_with(project="group-pay-test", database="(default)", daily_limit=100)
            self.assertEqual(issuer.call_args.kwargs, {"store": sentinel})
            fake_storage.FirestoreStore.side_effect = RuntimeError("credential-do-not-print")
            with self.assertRaisesRegex(RuntimeError, "startup configuration") as caught:
                configured_issuer(ENV)
            self.assertNotIn("credential-do-not-print", str(caught.exception))
            self.assertEqual(issuer.call_count, 1)

    def test_bad_startup_configuration_rejected(self):
        for updates in ({"GOOGLE_CLOUD_PROJECT": ""}, {"GROUP_PAY_CLIENT_TOKEN": "short"},
                        {"MARQETA_APPLICATION_TOKEN": ""}, {"MARQETA_BASE_URL": "https://api.marqeta.com/v3"},
                        {"FIRESTORE_EMULATOR_HOST": "localhost:8081"}):
            with self.subTest(updates=updates), self.assertRaises(RuntimeError):
                configured_issuer({**ENV, **updates})


class LegacyRecoveryTests(unittest.TestCase):
    def test_existing_large_local_intent_replays_but_changed_snapshot_conflicts(self):
        from server import Issuer
        from test_server import FakeMarqeta
        with tempfile.TemporaryDirectory() as directory:
            provider = FakeMarqeta()
            issuer = Issuer(CONFIG, Path(directory) / "journal.sqlite3", provider)
            try:
                large = copy.deepcopy(BILL)
                large["amountCents"] = 60_001
                large["members"][1]["shareCents"] = 59_501
                saved = issuer.issue(large)  # Existing local intent, later migrated.
                calls = len(provider.calls)
                client = create_app(issuer).test_client()
                headers = {"Authorization": "Bearer " + CLIENT_TOKEN}
                replay = client.post("/v1/cards", json=large, headers=headers)
                self.assertEqual(replay.status_code, 200)
                self.assertEqual(replay.json, saved)
                self.assertEqual(client.get("/v1/cards/" + BILL["billID"] + "/1", headers=headers).json, saved)
                changed = copy.deepcopy(large)
                changed["members"][0]["shareCents"] += 1
                changed["members"][1]["shareCents"] -= 1
                response = client.post("/v1/cards", json=changed, headers=headers)
                self.assertEqual(response.status_code, 409)
                self.assertEqual(response.json["error"], "bill_changed")
                fresh = {**large, "cycle": 2}
                response = client.post("/v1/cards", json=fresh, headers=headers)
                self.assertEqual(response.status_code, 422)
                self.assertEqual(response.json["error"], "amount_limit")
                self.assertEqual(len(provider.calls), calls)
            finally:
                issuer.close()


class DeploymentBoundaryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = spec_from_file_location("cloud_manage", Path(__file__).parent / "cloud" / "manage.py")
        cls.manage = module_from_spec(spec)
        spec.loader.exec_module(cls.manage)

    def test_plan_has_no_cloud_calls_or_secret_reads(self):
        args = types.SimpleNamespace(project="group-pay-test", region="us-central1", database="(default)")
        with patch.object(self.manage, "command") as call, patch.object(Path, "read_text") as read, patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.manage.plan(args)
        call.assert_not_called()
        read.assert_not_called()
        self.assertEqual(json.loads(stdout.getvalue())["maximumInstances"], 1)

    def test_build_context_is_exact_allowlist(self):
        with tempfile.TemporaryDirectory() as source, tempfile.TemporaryDirectory() as destination:
            root = Path(source)
            for name in self.manage.SOURCES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("allowed")
            (root / ".env").write_text("secret")
            (root / "data").mkdir()
            (root / "data" / "issuance.sqlite3").write_text("private-state")
            with patch.object(self.manage, "ROOT", root):
                self.manage.stage_source(Path(destination), "us-central1-docker.pkg.dev/group-pay-test/group-pay/test:v1")
            files = {str(p.relative_to(destination)) for p in Path(destination).rglob("*") if p.is_file()}
            self.assertEqual(files, set(self.manage.SOURCES) | {"cloudbuild.yaml"})

    def test_secret_values_go_only_to_stdin(self):
        args = types.SimpleNamespace(project="group-pay-test", env_file=Path("ignored-private-env"))
        secret_values = {key: "private-value-" + key for key in self.manage.REQUIRED_SECRETS}
        with patch.object(self.manage, "read_private_settings", return_value=secret_values), patch.object(self.manage, "command") as call, patch("sys.stdout", new_callable=io.StringIO) as stdout:
            self.manage.upload_secrets(args)
        self.assertEqual(call.call_count, 3)
        for entry in call.call_args_list:
            self.assertNotIn("private-value-", " ".join(entry.args[0]))
            self.assertTrue(entry.kwargs["data"].startswith(b"private-value-"))
        self.assertNotIn("private-value-", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
