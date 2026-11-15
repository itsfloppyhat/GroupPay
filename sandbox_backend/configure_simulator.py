#!/usr/bin/env python3
"""Pair an installed Debug simulator app using only the local backend token."""
import argparse
import os
import subprocess
from server import Config, read_env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", default="booted", help="Simulator UDID, or booted if exactly one is running")
    args = parser.parse_args()
    try:
        config = Config.from_env(read_env())
    except ValueError as error:
        raise SystemExit(str(error)) from None
    # Only a loopback proxy token goes into the simulator. Marqeta provider keys
    # remain on the Mac and are never passed as arguments, output, or app settings.
    child_env = {key: value for key, value in os.environ.items()
                 if not key.startswith("MARQETA_") and not key.startswith("SIMCTL_CHILD_MARQETA_")}
    child_env["SIMCTL_CHILD_GROUP_PAY_BACKEND_URL"] = "http://127.0.0.1:8787"
    child_env["SIMCTL_CHILD_GROUP_PAY_BACKEND_TOKEN"] = config.client_token
    command = ["xcrun", "simctl", "launch", "--terminate-running-process", args.device,
               "com.itsfloppyhat.GroupPay", "--configure-sandbox"]
    result = subprocess.run(command, env=child_env, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit("Unable to launch Group Pay. Install its Debug build, boot the selected simulator, and try again.")
    print("Group Pay launched. Open its sandbox settings to verify the saved local connection.")
    print("Open Profile → Advanced settings → Card connection → Save & check connection.")


if __name__ == "__main__":
    main()
