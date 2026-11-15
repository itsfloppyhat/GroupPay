#!/usr/bin/env python3
"""Loopback-only Marqeta sandbox adapter. Never use for production money."""
from __future__ import annotations

import base64
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import re
import threading
import urllib.error
import urllib.parse
import urllib.request
import uuid

from storage import SQLiteStore, StoreConflict, StoreError, StoreLimit

ROOT = Path(__file__).resolve().parent
MAX_CENTS = 10_000_000
MAX_BODY = 32_768
TOKEN = re.compile(r"^[A-Za-z0-9_-]{1,36}$")


class APIError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code, self.message = status, code, message


class ProviderError(Exception):
    """Contains only status, never provider response bodies or credentials."""
    def __init__(self, status: int | None):
        self.status = status
        super().__init__(f"Sandbox provider request failed ({status or 'network'}).")


def sandbox_url(value: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(value)
        valid = (parsed.scheme == "https" and parsed.hostname == "sandbox-api.marqeta.com"
                 and parsed.port in (None, 443) and parsed.username is None and parsed.password is None
                 and parsed.path.rstrip("/") == "/v3" and not parsed.query and not parsed.fragment)
    except ValueError:
        valid = False
    if not valid:
        raise ValueError("MARQETA_BASE_URL must be https://sandbox-api.marqeta.com/v3. Production and redirects are disabled.")
    return "https://sandbox-api.marqeta.com/v3"


def read_env(path: Path = ROOT / ".env") -> dict[str, str]:
    values = {}
    if path.exists():
        os.chmod(path, 0o600)
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, separator, value = line.partition("=")
            if not separator or not re.fullmatch(r"[A-Z_]+", key.strip()):
                raise ValueError("Invalid local settings format. Use one NAME=value per line.")
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            values[key.strip()] = value
    values.update(os.environ)
    return values


@dataclass(frozen=True)
class Config:
    base_url: str
    application_token: str
    admin_token: str
    client_token: str
    product_token: str = ""
    funding_token: str = ""

    @classmethod
    def from_env(cls, env: dict[str, str]) -> Config:
        base = sandbox_url(env.get("MARQETA_BASE_URL", "https://sandbox-api.marqeta.com/v3"))
        optional = [env.get("MARQETA_CARD_PRODUCT_TOKEN", ""), env.get("MARQETA_FUNDING_SOURCE_TOKEN", "")]
        if any(token and not TOKEN.fullmatch(token) for token in optional):
            raise ValueError("Optional resource tokens must be 1–36 letters, numbers, underscores, or hyphens.")
        client = env.get("GROUP_PAY_CLIENT_TOKEN", "")
        if len(client) < 32 or any(c.isspace() for c in client):
            raise ValueError("Run setup.py to create a local client token of at least 32 characters.")
        app, admin = env.get("MARQETA_APPLICATION_TOKEN", ""), env.get("MARQETA_ADMIN_ACCESS_TOKEN", "")
        if any(c in app + admin for c in "\r\n") or ":" in app:
            raise ValueError("Invalid credential format.")
        return cls(base, app, admin, client, *optional)

    @property
    def ready(self) -> bool:
        return bool(self.application_token and self.admin_token)

    @property
    def namespace(self) -> str:
        return hashlib.sha256((self.base_url + "\0" + self.application_token).encode()).hexdigest()


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ProviderError(code)


class Marqeta:
    def __init__(self, config: Config):
        self.config = config
        # Do not inherit HTTP(S)_PROXY or forward credentials via redirects.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, method: str, path: str, body: dict | None = None) -> dict:
        if not path.startswith("/") or "?" in path or "#" in path or ".." in path or path.startswith("//"):
            raise ValueError("Invalid provider resource path.")
        data = None if body is None else json.dumps(body, separators=(",", ":"), allow_nan=False).encode()
        auth = base64.b64encode((self.config.application_token + ":" + self.config.admin_token).encode()).decode()
        req = urllib.request.Request(self.config.base_url + path, data=data, method=method,
                                     headers={"Authorization": "Basic " + auth, "Accept": "application/json", "Content-Type": "application/json"})
        try:
            with self.opener.open(req, timeout=20) as response:
                raw = response.read(2_000_001)
                if len(raw) > 2_000_000:
                    raise ProviderError(None)
                result = json.loads(raw, parse_float=Decimal)
                if not isinstance(result, dict):
                    raise ProviderError(None)
                return result
        except urllib.error.HTTPError as error:
            # Deliberately discard all provider bodies, which could contain sensitive data.
            error.close()
            raise ProviderError(error.code) from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError):
            raise ProviderError(None) from None


def validate_request(data: object) -> dict:
    def fail(message: str):
        raise APIError(422, "invalid_request", message)
    if not isinstance(data, dict):
        fail("Send a bill object.")
    try:
        bill_id = str(uuid.UUID(data.get("billID", ""))).upper()
    except (ValueError, TypeError, AttributeError):
        fail("A valid billID UUID is required.")
    cycle, cents = data.get("cycle"), data.get("amountCents")
    if type(cycle) is not int or not 1 <= cycle <= 1_000_000:
        fail("cycle must be a positive integer no greater than 1,000,000.")
    if type(cents) is not int or not 1 <= cents <= MAX_CENTS:
        fail("amountCents must be an integer from 1 to 10,000,000.")
    if data.get("currency") != "USD":
        fail("Only USD sandbox cards are supported.")
    leader = data.get("leaderID")
    if not isinstance(leader, str) or not 1 <= len(leader) <= 256 or leader.strip() != leader:
        fail("A leaderID is required.")
    members = data.get("members")
    if not isinstance(members, list) or not 2 <= len(members) <= 50:
        fail("The bill must have between 2 and 50 approved members.")
    people = []
    for member in members:
        if not isinstance(member, dict):
            fail("Each member must be an object.")
        account, approved, share = member.get("accountID"), member.get("approved"), member.get("shareCents")
        if not isinstance(account, str) or not 1 <= len(account) <= 256 or account.strip() != account:
            fail("Every member must have claimed a unique account.")
        if approved is not True or type(share) is not int or not 0 <= share <= MAX_CENTS:
            fail("Every member must approve a valid integer-cent portion.")
        people.append({"accountID": account, "approved": True, "shareCents": share})
    identities = [p["accountID"] for p in people]
    if len(set(identities)) != len(identities) or identities.count(leader) != 1:
        fail("Each account must be unique, and the leader must be a member.")
    if sum(p["shareCents"] for p in people) != cents:
        fail("Member portions must add up to the bill total.")
    return {"billID": bill_id, "cycle": cycle, "amountCents": cents, "currency": "USD", "leaderID": leader,
            "members": sorted(people, key=lambda p: p["accountID"])}


def cents_of(value) -> int:
    try:
        amount = Decimal(str(value)) * 100
        if not amount.is_finite() or amount != amount.to_integral_value():
            raise InvalidOperation
        return int(amount)
    except (ValueError, InvalidOperation):
        raise APIError(502, "invalid_provider_result", "The sandbox returned an invalid amount.") from None


class Issuer:
    def __init__(self, config: Config, db_path: Path | None = None, provider=None, *, store=None):
        self.config, self.provider = config, provider or Marqeta(config)
        self.store = store if store is not None else SQLiteStore(db_path or ROOT / "data" / "issuance.sqlite3")
        self.db = getattr(self.store, "db", None)  # Local diagnostics/backwards compatibility.
        self.lock = threading.Lock()

    def close(self):
        self.store.close()

    def _store(self, method, *args):
        try:
            return getattr(self.store, method)(*args)
        except StoreLimit:
            raise APIError(429, "daily_limit_reached", "The shared daily test-card limit has been reached. Existing bills can still be recovered.") from None
        except StoreConflict as error:
            if error.code == "sandbox_changed":
                raise APIError(409, "sandbox_changed", "This bill cycle belongs to another sandbox application. Restore its original sandbox settings to reconcile it.") from None
            raise APIError(409, "bill_changed", "This bill cycle already has an issuance attempt for different approved amounts or members.") from None
        except StoreError:
            raise APIError(503, "storage_unavailable", "Durable card recovery is temporarily unavailable. Retry the same bill; no new create request is sent without a saved reservation.") from None

    def token(self, bill_id: str, cycle: int, kind: str) -> str:
        namespace = uuid.uuid5(uuid.NAMESPACE_URL, self.config.namespace)
        return str(uuid.uuid5(namespace, f"{bill_id}:{cycle}:{kind}"))

    def _get(self, resource: str, token: str) -> dict | None:
        try:
            result = self.provider.request("GET", resource + "/" + token)
            if result.get("token") != token:
                raise APIError(502, "invalid_provider_result", "The sandbox returned an unexpected resource.")
            return result
        except ProviderError as error:
            if error.status == 404:
                return None
            raise

    def ensure(self, resource: str, token: str, body: dict, *, external=False) -> dict:
        """GET before every POST. Once POST began, later calls reconcile only.

        Durable attempt markers make a timeout/crash safe even if the provider
        accepted a request but its response never reached this process.
        """
        found = self._get(resource, token)
        if found is not None:
            if found.get("token") != token:
                raise APIError(502, "invalid_provider_result", "The sandbox returned an unexpected resource.")
            return found
        if external:
            raise APIError(422, "missing_resource", "The configured sandbox resource token does not exist.")
        owner = self._store("claim_attempt", self.config.namespace, resource, token)
        if owner is None:
            # Another process may have completed between our first GET and claim.
            recovered = self._get(resource, token)
            if recovered is not None:
                return recovered
            raise APIError(503, "reconciliation_pending", "A prior sandbox request may still be processing. Retry to reconcile it; no second funding request will be sent.")
        try:
            result = self.provider.request("POST", resource, {**body, "token": token})
        except ProviderError as error:
            # A definitive client-side rejection (except duplicates/timeouts) did
            # not create a resource; allow an explicit later retry after fixing setup.
            if error.status is not None and 400 <= error.status < 500 and error.status not in (408, 409, 422, 429):
                self._store("clear_attempt", self.config.namespace, resource, token, owner)
            # Duplicate or uncertain replies must be reconciled by token, never replayed.
            if error.status in (409, 422) or error.status is None or (error.status and error.status >= 500):
                recovered = self._get(resource, token)
                if recovered is not None:
                    return recovered
            raise
        if result.get("token") != token:
            raise APIError(502, "invalid_provider_result", "The sandbox returned an unexpected resource.")
        return result

    def issue(self, data: object) -> dict:
        request = validate_request(data)
        if not self.config.ready:
            raise APIError(503, "not_configured", "Add your Marqeta sandbox credentials to the Mac's local settings and restart the backend.")
        encoded = json.dumps(request, sort_keys=True, separators=(",", ":"))
        digest = hashlib.sha256(encoded.encode()).hexdigest()
        bid, cycle, cents = request["billID"], request["cycle"], request["amountCents"]
        with self.lock:
            existing = self._store("reserve_intent", self.config.namespace, bid, cycle, digest)
            if existing.result is not None:
                return existing.result
            try:
                product_token = self.config.product_token or self.token("shared", 0, "product-v1")
                funding_token = self.config.funding_token or self.token("shared", 0, "funding-v1")
                product = self.ensure("/cardproducts", product_token, {
                    "name": "Group Pay Sandbox Virtual", "active": True,
                    "start_date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                    "config": {"fulfillment": {"payment_instrument": "VIRTUAL_PAN"},
                               "card_life_cycle": {"activate_upon_issue": True},
                               "poi": {"ecommerce": True, "atm": False}}}, external=bool(self.config.product_token))
                config = product.get("config", {})
                if not product.get("active", False) or config.get("fulfillment", {}).get("payment_instrument") != "VIRTUAL_PAN":
                    raise APIError(422, "invalid_card_product", "Choose an active VIRTUAL_PAN sandbox card product.")
                if not config.get("card_life_cycle", {}).get("activate_upon_issue", False):
                    raise APIError(422, "invalid_card_product", "The sandbox card product must activate cards upon issue.")
                jit = config.get("jit_funding", {})
                if any(isinstance(v, dict) and v.get("enabled") for v in jit.values()):
                    raise APIError(422, "invalid_card_product", "Use a GPA-funded sandbox product with JIT funding disabled.")
                source = self.ensure("/fundingsources/program", funding_token,
                                     {"name": "Group Pay Sandbox Funding", "active": True}, external=bool(self.config.funding_token))
                if source.get("active") is not True:
                    raise APIError(422, "inactive_funding_source", "The sandbox program funding source is inactive.")
                user_token, card_token, order_token = (self.token(bid, cycle, kind) for kind in ("user", "card", "funding"))
                user = self.ensure("/users", user_token, {"first_name": "Group Pay", "last_name": "Sandbox"})
                if user.get("active") is not True:
                    raise APIError(422, "inactive_user", "The synthetic sandbox user is inactive. Activate it in the Marqeta sandbox dashboard before retrying.")
                card = self.ensure("/cards", card_token, {"user_token": user_token, "card_product_token": product_token})
                if card.get("user_token") != user_token or card.get("card_product_token") != product_token or card.get("state") != "ACTIVE":
                    raise APIError(502, "invalid_card_state", "The sandbox card is not active for the expected account and product.")
                last_four = card.get("last_four")
                if not isinstance(last_four, str) or not re.fullmatch(r"[0-9]{4}", last_four):
                    raise APIError(502, "invalid_provider_result", "The sandbox did not return valid masked card details.")
                # Python's JSON conversion emits the exact two-decimal value for this
                # bounded range; all arithmetic and validation stay in integer cents.
                amount = float(Decimal(cents) / 100)
                order = self.ensure("/gpaorders", order_token, {"user_token": user_token, "amount": amount,
                                    "currency_code": "USD", "funding_source_token": funding_token})
                if (order.get("user_token") != user_token or order.get("currency_code") != "USD"
                        or cents_of(order.get("amount")) != cents):
                    raise APIError(502, "funding_mismatch", "The sandbox funding result does not match this bill. No additional load was attempted.")
                if order.get("state") not in ("COMPLETION", "CLEARED"):
                    raise APIError(503, "funding_pending", "Sandbox funding has not completed. Retry to reconcile the original funding order.")
                response_code = order.get("response", {}).get("code")
                if response_code not in (None, "0000"):
                    raise APIError(502, "funding_declined", "The sandbox declined this funding order. No additional load was attempted.")
                try:
                    created_date = datetime.fromisoformat(card.get("created_time", "").replace("Z", "+00:00"))
                    if created_date.tzinfo is None:
                        created_date = created_date.replace(tzinfo=timezone.utc)
                except (AttributeError, ValueError):
                    raise APIError(502, "invalid_provider_result", "The sandbox did not return a valid creation date.") from None
                created = created_date.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
                result = {"provider": "marqetaSandbox", "cardToken": card_token, "lastFour": last_four,
                          "state": "ACTIVE", "loadedCents": cents, "remainingCents": cents, "createdAt": created}
                return self._store("complete_intent", self.config.namespace, bid, cycle, digest, result)
            except ProviderError as error:
                if error.status in (401, 403):
                    raise APIError(502, "sandbox_access_denied", "Marqeta rejected sandbox access. Check your sandbox credentials and permissions.") from None
                raise APIError(503, "sandbox_unavailable", "The Marqeta sandbox request did not complete. Retry the same bill to safely reconcile its original resources.") from None

    def lookup(self, bill_id: str, cycle: int) -> tuple[int, dict]:
        try:
            bid = str(uuid.UUID(bill_id)).upper()
        except ValueError:
            raise APIError(422, "invalid_request", "A valid billID is required.") from None
        if type(cycle) is not int or not 1 <= cycle <= 1_000_000:
            raise APIError(422, "invalid_request", "A valid bill cycle is required.")
        with self.lock:
            intent = self._store("lookup_intent", self.config.namespace, bid, cycle)
        if intent is None:
            raise APIError(404, "not_found", "No card issuance has been requested for this bill cycle.")
        if intent.result is not None:
            return 200, intent.result
        return 202, {"status": "pending", "message": "Retry creation with the same approved bill to reconcile the original issuance."}


def handler_for(issuer: Issuer):
    class Handler(BaseHTTPRequestHandler):
        server_version = "GroupPaySandbox"
        sys_version = ""
        def setup(self):
            super().setup()
            self.connection.settimeout(30)
        def log_message(self, format, *args):
            pass  # Do not log URLs, bodies, headers, or tokens.
        def respond(self, status, body):
            encoded = json.dumps(body, separators=(",", ":")).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.end_headers()
            self.wfile.write(encoded)
        def auth(self):
            expected = "Bearer " + issuer.config.client_token
            supplied = self.headers.get("Authorization", "")
            if not hmac.compare_digest(supplied.encode(), expected.encode()):
                raise APIError(401, "unauthorized", "Enter the local backend client token in Group Pay settings.")
        def dispatch(self):
            host = self.headers.get("Host", "")
            if host not in ("127.0.0.1:8787", "localhost:8787") or self.headers.get("Origin") is not None:
                raise APIError(403, "loopback_only", "This development backend accepts only local app requests.")
            parsed = urllib.parse.urlsplit(self.path)
            if parsed.query or parsed.fragment:
                raise APIError(404, "not_found", "Unknown route.")
            if self.command == "GET" and parsed.path == "/health":
                return 200, {"ready": issuer.config.ready}
            self.auth()
            if self.command == "GET" and parsed.path == "/v1/status":
                return 200, {"ready": issuer.config.ready, "environment": "sandbox"}
            if self.command == "GET":
                match = re.fullmatch(r"/v1/cards/([0-9A-Fa-f-]{36})/([1-9][0-9]{0,6})", parsed.path)
                if match:
                    return issuer.lookup(match[1], int(match[2]))
            if self.command == "POST" and parsed.path == "/v1/cards":
                if self.headers.get("Transfer-Encoding"):
                    raise APIError(400, "invalid_request", "Chunked requests are not supported.")
                try:
                    size = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    raise APIError(400, "invalid_request", "Invalid request length.") from None
                if not 0 < size <= MAX_BODY:
                    raise APIError(413, "request_too_large", "The request must be no larger than 32 KB.")
                if self.headers.get_content_type() != "application/json":
                    raise APIError(415, "invalid_content_type", "Send application/json.")
                try:
                    data = json.loads(self.rfile.read(size), parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
                except (ValueError, UnicodeError):
                    raise APIError(400, "invalid_json", "Send valid JSON.") from None
                return 200, issuer.issue(data)
            raise APIError(404, "not_found", "Unknown route.")
        def handle_request(self):
            try:
                status, body = self.dispatch()
                self.respond(status, body)
            except APIError as error:
                self.respond(error.status, {"error": error.code, "message": error.message})
            except (BrokenPipeError, ConnectionResetError, TimeoutError):
                return
            except Exception:
                self.respond(500, {"error": "internal_error", "message": "The local backend could not complete this request. Retry the same bill to reconcile any prior issuance."})
        do_GET = handle_request
        do_POST = handle_request
    return Handler


def main():
    os.umask(0o077)
    try:
        config = Config.from_env(read_env())
        issuer = Issuer(config, ROOT / "data" / "issuance.sqlite3")
        server = HTTPServer(("127.0.0.1", 8787), handler_for(issuer))
    except (ValueError, OSError, StoreError) as error:
        print(str(error))
        raise SystemExit(1)
    print("Group Pay sandbox backend: http://127.0.0.1:8787")
    print("Sandbox credentials configured." if config.ready else "Waiting for sandbox credentials in sandbox_backend/.env.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        issuer.close()


if __name__ == "__main__":
    main()
