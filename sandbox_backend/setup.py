#!/usr/bin/env python3
"""Create private settings; optionally collect sandbox credentials in a local terminal."""
import argparse
import getpass
import os
from pathlib import Path
import secrets
from server import sandbox_url


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--credentials", action="store_true", help="Prompt for provider credentials without echoing them")
    parser.add_argument("--show-client-token", action="store_true", help="Print only the local app token to your terminal")
    args = parser.parse_args()
    path = Path(__file__).resolve().parent / ".env"
    values = {"MARQETA_BASE_URL": "https://sandbox-api.marqeta.com/v3", "MARQETA_APPLICATION_TOKEN": "",
              "MARQETA_ADMIN_ACCESS_TOKEN": "", "GROUP_PAY_CLIENT_TOKEN": secrets.token_urlsafe(32),
              "MARQETA_CARD_PRODUCT_TOKEN": "", "MARQETA_FUNDING_SOURCE_TOKEN": ""}
    if path.exists():
        os.chmod(path, 0o600)
        for line in path.read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                key, separator, value = line.partition("=")
                if separator and key in values:
                    values[key] = value.strip()
    if len(values["GROUP_PAY_CLIENT_TOKEN"]) < 32 or any(c.isspace() for c in values["GROUP_PAY_CLIENT_TOKEN"]):
        values["GROUP_PAY_CLIENT_TOKEN"] = secrets.token_urlsafe(32)
    if args.credentials:
        values["MARQETA_BASE_URL"] = sandbox_url(input("Sandbox base URL [https://sandbox-api.marqeta.com/v3]: ").strip() or values["MARQETA_BASE_URL"])
        values["MARQETA_APPLICATION_TOKEN"] = getpass.getpass("Application token (hidden): ").strip()
        values["MARQETA_ADMIN_ACCESS_TOKEN"] = getpass.getpass("Admin access token (hidden): ").strip()
        if any("\n" in value or "\r" in value for value in values.values()):
            raise SystemExit("Invalid settings input.")
    os.umask(0o077)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write("# Private local settings. Never commit or share this file.\n")
        for key, value in values.items():
            output.write(f"{key}={value}\n")
    os.chmod(path, 0o600)
    print("Private settings ready in sandbox_backend/.env (permissions 0600).")
    if args.show_client_token:
        print("Local app token (not a Marqeta credential): " + values["GROUP_PAY_CLIENT_TOKEN"])
    if not args.credentials:
        print("To enter Marqeta credentials locally, run: python3 sandbox_backend/setup.py --credentials")
    print("Start the backend with: python3 sandbox_backend/server.py")


if __name__ == "__main__":
    main()
