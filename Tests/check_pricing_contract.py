#!/usr/bin/env python3
"""Compile the app's actual pricing encoder and validate its payloads server-side.

No credentials, cloud services, or provider calls are used. Requires Xcode's Swift
compiler and Python's standard library; run from any working directory.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "sandbox_backend"))
from server import validate_request


def main():
    with tempfile.TemporaryDirectory(prefix="group-pay-pricing-contract-") as temporary:
        executable = str(Path(temporary) / "fixtures")
        subprocess.run(["xcrun", "swiftc", "-swift-version", "6",
                        str(ROOT / "GroupPay" / "Models.swift"),
                        str(ROOT / "GroupPay" / "SandboxIssuanceRequest.swift"),
                        str(ROOT / "Tests" / "PricingContractFixtures.swift"), "-o", executable], check=True)
        fixtures = json.loads(subprocess.check_output([executable]))
    for fixture in fixtures:
        payload = fixture["payload"]
        canonical = validate_request(payload)
        assert canonical["amountCents"] == fixture["expectedCardCents"], fixture["name"]
        assert sum(p["shareCents"] for p in canonical["members"]) == fixture["expectedChargeCents"], fixture["name"]
        assert canonical.get("feeCents", 0) == fixture["expectedFeeCents"], fixture["name"]
        reversed_payload = {**payload, "members": list(reversed(payload["members"]))}
        assert validate_request(reversed_payload) == canonical, fixture["name"]
        assert validate_request(canonical) == canonical, fixture["name"]
        if fixture["name"] == "legacy-digest":
            digest = hashlib.sha256(json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            assert digest == "ef83e51d8fed04ded1ccc4b387b8b08077e5357f74414061834ea873859938eb"
            assert "pricingVersion" not in payload
    print(f"Passed {len(fixtures)} Swift-to-Python pricing contract fixtures using the app's actual encoder.")


if __name__ == "__main__":
    main()
