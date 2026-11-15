"""Portion-scoped, expiring browser approvals for the trusted sandbox beta."""
from __future__ import annotations

import hashlib
import hmac
import time
import uuid
from pathlib import Path

from flask import jsonify, request, send_from_directory
from server import APIError
from storage import StoreConflict

FIELDS = {"invitationID", "billID", "memberID", "cycle", "title", "name",
          "foodCents", "taxCents", "feeCents", "tipCents"}


def validate_portion(data):
    if not isinstance(data, dict) or set(data) != FIELDS:
        raise APIError(422, "invalid_request", "")
    for key in ("invitationID", "billID", "memberID"):
        try:
            if str(uuid.UUID(data[key])).upper() != data[key]:
                raise ValueError()
        except (ValueError, TypeError, AttributeError):
            raise APIError(422, "invalid_request", "") from None
    if type(data["cycle"]) is not int or not 1 <= data["cycle"] <= 1_000_000:
        raise APIError(422, "invalid_request", "")
    for key in ("title", "name"):
        if not isinstance(data[key], str) or not 1 <= len(data[key].strip()) <= 200:
            raise APIError(422, "invalid_request", "")
    for key in ("foodCents", "taxCents", "feeCents", "tipCents"):
        if type(data[key]) is not int or not 0 <= data[key] <= 10_000_000:
            raise APIError(422, "invalid_request", "")
    if sum(data[k] for k in ("foodCents", "taxCents", "feeCents", "tipCents")) > 10_000_000:
        raise APIError(422, "invalid_request", "")
    return dict(data)


class FirestoreGuestStore:
    def __init__(self, store):
        self.store = store

    def change(self, invitation_id, operation):
        ref = self.store._reference("guest_invitations", invitation_id)
        def update(transaction):
            existing = self.store._record(ref, transaction)
            revised = operation(existing)
            if revised != existing:
                transaction.set(ref, revised)
            return revised
        return self.store._run(update)


class GuestService:
    def __init__(self, store, secret, clock=time.time):
        self.store, self.secret, self.clock = store, secret.encode(), clock

    def token(self, invitation_id):
        signature = hmac.new(self.secret, ("guest-v1:" + invitation_id).encode(), hashlib.sha256).hexdigest()
        return invitation_id + "." + signature

    def identify(self, token):
        if not isinstance(token, str) or len(token) != 101:
            raise APIError(404, "guest_unavailable", "")
        invitation_id = token[:36]
        if not hmac.compare_digest(token, self.token(invitation_id)):
            raise APIError(404, "guest_unavailable", "")
        return invitation_id

    def create(self, data):
        data = validate_portion(data)
        def create(existing):
            if existing is not None:
                if existing["portion"] != data:
                    raise StoreConflict("bill_changed")
                return existing
            return {"portion": data, "expiresAt": int(self.clock()) + 7 * 86400,
                    "approvedTipCents": None, "closed": False}
        return self.store.change(data["invitationID"], create)

    def read(self, invitation_id):
        def read(existing):
            if existing is None:
                raise StoreConflict("guest_unavailable")
            return existing
        return self.store.change(invitation_id, read)

    def approve(self, invitation_id, data):
        if (not isinstance(data, dict) or set(data) != {"tipCents"}
                or type(data["tipCents"]) is not int):
            raise APIError(422, "invalid_request", "")
        def approve(existing):
            if existing is None or existing["closed"] or self.clock() >= existing["expiresAt"]:
                raise StoreConflict("guest_unavailable")
            portion = existing["portion"]
            # Permit an exact tip up to the original tip or 100% of the subtotal.
            if not 0 <= data["tipCents"] <= max(portion["foodCents"], portion["tipCents"]):
                raise StoreConflict("invalid_request")
            if sum(portion[k] for k in ("foodCents", "taxCents", "feeCents")) + data["tipCents"] > 10_000_000:
                raise StoreConflict("invalid_request")
            if existing["approvedTipCents"] is not None:
                if existing["approvedTipCents"] != data["tipCents"]:
                    raise StoreConflict("guest_already_approved")
                return existing
            return {**existing, "approvedTipCents": data["tipCents"]}
        return self.store.change(invitation_id, approve)

    def close(self, invitation_id):
        def close(existing):
            if existing is None:
                raise StoreConflict("guest_unavailable")
            return {**existing, "closed": True}
        return self.store.change(invitation_id, close)

    def public(self, record):
        return {**record, "expired": self.clock() >= record["expiresAt"]}


def register_guest_routes(app, service):
    assets = Path(__file__).parent / "guest_web"

    @app.get("/guest")
    def guest_page():
        return send_from_directory(assets, "index.html")

    @app.get("/guest/<name>")
    def guest_asset(name):
        if name not in ("guest.js", "guest.css"):
            raise APIError(404, "not_found", "")
        return send_from_directory(assets, name)

    def require_service():
        if service is None:
            raise APIError(503, "not_configured", "")
        return service

    @app.post("/v1/guest-invitations")
    def create_guest():
        svc = require_service()
        record = svc.create(request.get_json())
        return jsonify(**svc.public(record), token=svc.token(record["portion"]["invitationID"]))

    @app.get("/v1/guest-invitations/<invitation_id>")
    def read_guest(invitation_id):
        svc = require_service()
        return jsonify(svc.public(svc.read(invitation_id)))

    @app.post("/v1/guest-invitations/<invitation_id>/close")
    def close_guest(invitation_id):
        svc = require_service()
        return jsonify(svc.public(svc.close(invitation_id)))

    @app.route("/guest-api/portion", methods=["GET", "POST"], provide_automatic_options=False)
    def guest_portion():
        svc = require_service()
        header = request.headers.get("Authorization", "")
        if not header.startswith("Guest "):
            raise APIError(404, "guest_unavailable", "")
        invitation_id = svc.identify(header[6:])
        record = (svc.approve(invitation_id, request.get_json()) if request.method == "POST"
                  else svc.read(invitation_id))
        return jsonify(svc.public(record))
