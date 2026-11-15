#!/usr/bin/env python3
"""Copy quiescent local recovery records to Firestore without provider requests.

Run before cloud traffic, with local issuance stopped. Reruns create missing
records or require exact matches; existing cloud state is never overwritten.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import uuid

from storage import FirestoreStore, StoreConflict, StoreError, safe_result


ROOT = Path(__file__).resolve().parent


def load_snapshot(path):
    db = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True)
    try:
        db.execute("BEGIN")
        intents = db.execute("SELECT namespace,bill_id,cycle,digest,result FROM intents").fetchall()
        columns = {row[1] for row in db.execute("PRAGMA table_info(attempts)")}
        owner_column = "owner" if "owner" in columns else "NULL"
        attempts = db.execute("SELECT namespace,resource,token,started," + owner_column + " FROM attempts").fetchall()
        db.execute("COMMIT")
    finally:
        db.close()
    parsed, keys = [], set()
    for namespace, bill_id, cycle, digest, raw_result in intents:
        if (not re.fullmatch(r"[0-9a-f]{64}", namespace) or not re.fullmatch(r"[0-9a-f]{64}", digest)
                or bill_id != str(uuid.UUID(bill_id)).upper() or type(cycle) is not int or not 1 <= cycle <= 1_000_000
                or (bill_id, cycle) in keys):
            raise ValueError("Invalid local recovery snapshot.")
        keys.add((bill_id, cycle))
        result = None if raw_result is None else safe_result(json.loads(raw_result))
        parsed.append((bill_id, cycle, namespace, digest, result))
    valid_attempts = []
    for namespace, resource, token, started, owner in attempts:
        if (not re.fullmatch(r"[0-9a-f]{64}", namespace)
                or resource not in ("/cardproducts", "/fundingsources/program", "/users", "/cards", "/gpaorders")
                or not re.fullmatch(r"[A-Za-z0-9_-]{1,36}", token) or started != 1
                or (owner is not None and str(uuid.UUID(owner)) != owner)):
            raise ValueError("Invalid local recovery snapshot.")
        valid_attempts.append((namespace, resource, token, owner))
    return parsed, valid_attempts


def import_snapshot(store, intents, attempts):
    # Install uncertain-attempt fences first. Traffic must still remain stopped.
    attempt_count = sum(store.import_attempt(*row) for row in attempts)
    intent_count = sum(store.import_intent(*row) for row in intents)
    return {"status": "complete", "intentsVerified": len(intents), "attemptsVerified": len(attempts),
            "intentsCreated": intent_count, "attemptsCreated": attempt_count}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--database", default="(default)")
    parser.add_argument("--collection-prefix", default="group_pay")
    parser.add_argument("--source", type=Path, default=ROOT / "data" / "issuance.sqlite3")
    parser.add_argument("--gcloud-user", action="store_true", help="Use the signed-in gcloud user for this one import; no credential file is written")
    args = parser.parse_args()
    store = None
    try:
        if os.environ.get("FIRESTORE_EMULATOR_HOST"):
            raise ValueError("A cloud migration cannot target an emulator.")
        intents, attempts = load_snapshot(args.source)
        credentials = None
        if args.gcloud_user:
            from google.oauth2.credentials import Credentials
            token = subprocess.check_output(["gcloud", "auth", "print-access-token"], stderr=subprocess.DEVNULL, timeout=30).decode().strip()
            if not token:
                raise ValueError("Missing local access token.")
            credentials = Credentials(token=token)
        store = FirestoreStore(project=args.project, database=args.database, collection_prefix=args.collection_prefix, credentials=credentials)
        print(json.dumps(import_snapshot(store, intents, attempts), separators=(",", ":")))
    except StoreConflict:
        print('{"status":"failed","reason":"existing_cloud_state_conflicts"}')
        raise SystemExit(1)
    except StoreError:
        print('{"status":"failed","reason":"durable_storage_unavailable"}')
        raise SystemExit(1)
    except Exception:
        print('{"status":"failed","reason":"check_source_and_cloud_access"}')
        raise SystemExit(1)
    finally:
        if store is not None:
            store.close()


if __name__ == "__main__":
    main()
