"""Small trusted-team sandbox service. No real-money or CloudKit authentication."""
from __future__ import annotations

from datetime import datetime
import hmac
import json
import os
import re

from flask import Flask, jsonify, request
from werkzeug.exceptions import HTTPException
from guest import GuestService, FirestoreGuestStore, register_guest_routes
from storage import StoreConflict, StoreUnavailable

from server import APIError, Config, Issuer, MAX_BODY, MAX_CENTS, TOKEN, validate_request

MAX_CARD_CENTS = 50_000
DAILY_NEW_INTENT_LIMIT = 100

# Never send exception text, provider bodies, credentials, or submitted data to a client.
ERRORS = {
    "guest_unavailable": (404, "This guest invitation is unavailable or closed."),
    "guest_already_approved": (409, "This portion has already been approved."),
    "unauthorized": (401, "Enter the shared sandbox client token in Group Pay settings."),
    "origin_not_allowed": (403, "Browser-origin requests are not supported."),
    "not_found": (404, "No card issuance or route was found."),
    "invalid_json": (400, "Send valid JSON with unique field names."),
    "invalid_request": (422, "Send a valid approved bill with exact integer-cent USD amounts and unique accounts."),
    "request_too_large": (413, "The request must be no larger than 32 KB."),
    "invalid_content_type": (415, "Send application/json."),
    "amount_limit": (422, "Cloud sandbox cards are limited to $500.00 each."),
    "daily_limit_reached": (429, "The team's daily limit of 100 new sandbox issuance intents has been reached. Existing intents can still be reconciled."),
    "bill_changed": (409, "This bill cycle already has an issuance attempt for different amounts or members."),
    "sandbox_changed": (409, "This bill cycle belongs to another sandbox application. Restore its original sandbox settings to reconcile it."),
    "not_configured": (503, "Sandbox credentials are not configured on the backend."),
    "storage_unavailable": (503, "Durable recovery is temporarily unavailable. Retry the same bill to reconcile any prior issuance."),
    "reconciliation_pending": (503, "An earlier sandbox request may still be processing. Retry the same bill; no duplicate funding request will be sent."),
    "sandbox_access_denied": (502, "Marqeta rejected sandbox access. Ask the backend owner to check its credentials and permissions."),
    "sandbox_unavailable": (503, "The sandbox request did not complete. Retry the same bill to reconcile its original resources."),
    "missing_resource": (422, "A configured sandbox resource does not exist."),
    "invalid_card_product": (422, "Use an active GPA-funded virtual-card sandbox product with automatic activation and JIT funding disabled."),
    "inactive_funding_source": (422, "The configured sandbox funding source is inactive."),
    "inactive_user": (422, "The synthetic sandbox user is inactive."),
    "invalid_card_state": (502, "The sandbox card is not active for the expected account and product."),
    "invalid_provider_result": (502, "The sandbox returned an invalid result. Retry the same bill to reconcile it."),
    "funding_mismatch": (502, "The sandbox funding result does not match this bill. No additional load was attempted."),
    "funding_pending": (503, "Sandbox funding is pending. Retry the same bill to reconcile the original order."),
    "funding_declined": (502, "The sandbox declined the funding order. No additional load was attempted."),
    "internal_error": (500, "The backend could not complete the request. Retry the same bill to reconcile any prior issuance."),
}


def _error(code: str):
    code = code if code in ERRORS else "internal_error"
    status, message = ERRORS[code]
    return jsonify(error=code, message=message), status


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def _reject_constant(_value):
    raise ValueError("invalid number")


def _masked_card(result: object) -> dict:
    """Defensive response projection, including when replaying stored results."""
    if not isinstance(result, dict):
        raise APIError(502, "invalid_provider_result", "")
    required = ("provider", "cardToken", "lastFour", "state", "loadedCents", "remainingCents", "createdAt")
    if any(key not in result for key in required):
        raise APIError(502, "invalid_provider_result", "")
    loaded, remaining = result["loadedCents"], result["remainingCents"]
    if (result["provider"] != "marqetaSandbox" or result["state"] != "ACTIVE"
            or not isinstance(result["cardToken"], str) or not TOKEN.fullmatch(result["cardToken"])
            or not isinstance(result["lastFour"], str) or not re.fullmatch(r"[0-9]{4}", result["lastFour"])
            or type(loaded) is not int or not 1 <= loaded <= MAX_CENTS
            or type(remaining) is not int or not 0 <= remaining <= loaded):
        raise APIError(502, "invalid_provider_result", "")
    try:
        stamp = result["createdAt"]
        if not isinstance(stamp, str) or len(stamp) > 40 or datetime.fromisoformat(stamp.replace("Z", "+00:00")).tzinfo is None:
            raise ValueError()
    except (ValueError, TypeError):
        raise APIError(502, "invalid_provider_result", "") from None
    return {key: result[key] for key in required}


def configured_issuer(env: dict[str, str] | None = None) -> Issuer:
    """Use service-account ADC and Firestore exclusively; never read a .env file."""
    env = dict(os.environ if env is None else env)
    try:
        config = Config.from_env(env)
        if not config.ready:
            raise ValueError()
        project = env.get("GOOGLE_CLOUD_PROJECT", "")
        database = env.get("FIRESTORE_DATABASE", "(default)")
        if not re.fullmatch(r"[a-z][a-z0-9-]{4,61}[a-z0-9]", project):
            raise ValueError()
        if database != "(default)" and not re.fullmatch(r"[a-z][a-z0-9-]{2,61}[a-z0-9]", database):
            raise ValueError()
        if env.get("FIRESTORE_EMULATOR_HOST"):
            raise ValueError()
        from storage import FirestoreStore
        store = FirestoreStore(project=project, database=database, daily_limit=DAILY_NEW_INTENT_LIMIT)
        return Issuer(config, store=store)
    except Exception:
        raise RuntimeError("Cloud sandbox startup configuration is incomplete or durable storage could not be initialized.") from None


def create_app(issuer=None, guest_service=None) -> Flask:
    issuer = issuer if issuer is not None else configured_issuer()
    if guest_service is None and hasattr(getattr(issuer, "store", None), "client"):
        guest_service = GuestService(FirestoreGuestStore(issuer.store), issuer.config.client_token)
    app = Flask(__name__)
    app.config.update(MAX_CONTENT_LENGTH=MAX_BODY, DEBUG=False, TESTING=False, PROPAGATE_EXCEPTIONS=False)
    app.url_map.merge_slashes = False
    app.logger.disabled = True
    app.logger.propagate = False

    @app.before_request
    def authenticate():
        guest_browser = request.path == "/guest-api/portion"
        guest_asset = request.path in ("/guest", "/guest/guest.js", "/guest/guest.css") and request.method in ("GET", "HEAD")
        if guest_browser:
            # Only same-origin browser fetches with a portion-specific credential.
            origin = request.headers.get("Origin")
            if origin is not None and origin not in (request.host_url.rstrip("/"), "https://" + request.host):
                return _error("origin_not_allowed")
            if request.headers.get("Sec-Fetch-Site") == "cross-site":
                return _error("origin_not_allowed")
        elif request.headers.get("Origin") is not None:
            return _error("origin_not_allowed")
        if request.query_string:
            return _error("not_found")
        if request.path == "/health" and request.method in ("GET", "HEAD"):
            return None
        if guest_browser or guest_asset:
            return None
        supplied = request.headers.get("Authorization", "").encode("utf-8")
        expected = ("Bearer " + issuer.config.client_token).encode("utf-8")
        if not hmac.compare_digest(supplied, expected):
            return _error("unauthorized")
        return None

    @app.after_request
    def secure_response(response):
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Content-Security-Policy"] = "default-src 'none'"
        if request.path == "/guest" or request.path.startswith("/guest/"):
            response.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'self'; style-src 'self'; font-src data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Referrer-Policy"] = "no-referrer"
        return response

    register_guest_routes(app, guest_service)

    @app.route("/health", methods=["GET"], provide_automatic_options=False)
    def health():
        return jsonify(status="ok", environment="sandbox")

    @app.route("/v1/status", methods=["GET"], provide_automatic_options=False)
    def status():
        return jsonify(ready=issuer.config.ready, environment="sandbox", maxAmountCents=MAX_CARD_CENTS,
                       dailyNewIntentLimit=DAILY_NEW_INTENT_LIMIT, supportedPricingVersions=[1, 2],
                       supportsGuestApprovals=guest_service is not None)

    @app.route("/v1/cards", methods=["POST"], provide_automatic_options=False)
    def issue():
        if request.mimetype != "application/json":
            return _error("invalid_content_type")
        raw = request.get_data(cache=False)
        if not raw or len(raw) > MAX_BODY:
            return _error("request_too_large")
        try:
            data = json.loads(raw, parse_constant=_reject_constant, object_pairs_hook=_unique_object)
        except (ValueError, UnicodeError, RecursionError):
            return _error("invalid_json")
        validated = validate_request(data)
        # amountCents is merchant funding; the v2 service fee stays outside the
        # card balance and must not reduce the advertised $500 card allowance.
        if validated["amountCents"] > MAX_CARD_CENTS:
            # The cloud cap applies to NEW intents. A migrated local intent may
            # be larger and must remain recoverable. This lookup is read-only;
            # Issuer still checks its immutable namespace/digest before work.
            try:
                issuer.lookup(validated["billID"], validated["cycle"])
            except APIError as error:
                if error.code == "not_found":
                    return _error("amount_limit")
                raise
        return jsonify(_masked_card(issuer.issue(validated)))

    @app.route("/v1/cards/<bill_id>/<cycle>", methods=["GET"], provide_automatic_options=False)
    def lookup(bill_id, cycle):
        if not re.fullmatch(r"[0-9A-Fa-f-]{36}", bill_id) or not re.fullmatch(r"[1-9][0-9]{0,6}", cycle) or int(cycle) > 1_000_000:
            return _error("invalid_request")
        code, body = issuer.lookup(bill_id, int(cycle))
        if code == 202:
            return jsonify(status="pending", message="Retry creation with the same approved bill to reconcile the original issuance."), 202
        if code != 200:
            return _error("internal_error")
        return jsonify(_masked_card(body))

    @app.errorhandler(StoreConflict)
    def guest_conflict(error):
        return _error(error.code)

    @app.errorhandler(StoreUnavailable)
    def guest_storage_error(_error_value):
        return _error("storage_unavailable")

    @app.errorhandler(APIError)
    def api_error(error):
        return _error(error.code)

    @app.errorhandler(HTTPException)
    def http_error(error):
        if error.code == 413:
            return _error("request_too_large")
        if error.code == 400:
            return _error("invalid_json")
        return _error("not_found")

    @app.errorhandler(Exception)
    def unknown_error(_error_value):
        return _error("internal_error")

    return app
