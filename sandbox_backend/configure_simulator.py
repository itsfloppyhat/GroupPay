#!/usr/bin/env python3
"""Pair an installed Debug simulator app using only the local backend token."""
import argparse
import os
from pathlib import Path
import plistlib
import subprocess
import urllib.parse
from server import Config, read_env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="booted", help="Simulator UDID, or booted if exactly one is running")
    parser.add_argument("--hosted", action="store_true", help="Explicitly pair with the Cloud Run URL bundled in GroupPay/Info.plist")
    args = parser.parse_args()
    try:
        config = Config.from_env(read_env())
    except ValueError as error:
        raise SystemExit(str(error)) from None
    address = "http://127.0.0.1:8787"
    if args.hosted:
        with (Path(__file__).resolve().parents[1] / "GroupPay" / "Info.plist").open("rb") as source:
            address = plistlib.load(source).get("GroupPayCardServiceURL", "")
        parsed = urllib.parse.urlsplit(address)
        if (parsed.scheme != "https" or not parsed.hostname or not parsed.hostname.endswith(".run.app")
                or parsed.username or parsed.password or parsed.port not in (None, 443)
                or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
            raise SystemExit("A valid Cloud Run address must be bundled before hosted pairing.")
    # Only the Group Pay client token goes into the simulator. Marqeta provider keys
    # remain on the Mac and are never passed as arguments, output, or app settings.
    child_env = {key: value for key, value in os.environ.items()
                 if not key.startswith("MARQETA_") and not key.startswith("SIMCTL_CHILD_MARQETA_")}
    child_env["SIMCTL_CHILD_GROUP_PAY_BACKEND_URL"] = address
    child_env["SIMCTL_CHILD_GROUP_PAY_BACKEND_TOKEN"] = config.client_token
    command = ["xcrun", "simctl", "launch", "--terminate-running-process", args.device,
               "com.itsfloppyhat.GroupPay", "--configure-sandbox"]
    result = subprocess.run(command, env=child_env, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit("Unable to launch Group Pay. Install its Debug build, boot the selected simulator, and try again.")
    print("Group Pay launched. Check the saved connection in Profile.")
    print("Open Profile → Team access → Check connection." if args.hosted else
          "Open Profile → Advanced settings → Card connection → Save & check connection.")


if __name__ == "__main__":
    main()
