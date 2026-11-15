#!/usr/bin/env python3
"""Reviewable Cloud Run deployment stages. The default plan performs no cloud calls.

Secrets are uploaded only as subprocess stdin. No credentials enter argv,
source archives, images, local deployment manifests, or command output.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
SERVICE = "group-pay-sandbox"
REPOSITORY = "group-pay"
RUNTIME_ACCOUNT = "group-pay-runtime"
BUILD_ACCOUNT = "group-pay-build"
SOURCES = ("Dockerfile", ".dockerignore", "requirements-cloud.txt", "server.py", "storage.py", "cloud_app.py", "cloud/gunicorn.conf.py")
SECRETS = {
    "MARQETA_APPLICATION_TOKEN": "group-pay-marqeta-application-token",
    "MARQETA_ADMIN_ACCESS_TOKEN": "group-pay-marqeta-admin-access-token",
    "GROUP_PAY_CLIENT_TOKEN": "group-pay-client-token",
    "MARQETA_CARD_PRODUCT_TOKEN": "group-pay-card-product-token",
    "MARQETA_FUNDING_SOURCE_TOKEN": "group-pay-funding-source-token",
}
REQUIRED_SECRETS = tuple(SECRETS)[:3]
APIS = ("run.googleapis.com", "cloudbuild.googleapis.com", "artifactregistry.googleapis.com", "secretmanager.googleapis.com", "firestore.googleapis.com", "logging.googleapis.com", "iam.googleapis.com")


class DeploymentError(Exception):
    pass


def command(args: list[str], *, data: bytes | None = None, allow_failure=False) -> subprocess.CompletedProcess:
    # Capture everything. gcloud error bodies are never echoed because they may
    # include API responses or input details. Failed action names are sufficient.
    completed = subprocess.run(["gcloud", *args, "--quiet"], input=data, capture_output=True, check=False)
    if completed.returncode and not allow_failure:
        raise DeploymentError("Google Cloud action failed: " + " ".join(args[:3]) + ". Check permissions and resource state in Google Cloud; no response body was printed.")
    return completed


def exists(args: list[str]) -> bool:
    result = command(args, allow_failure=True)
    if result.returncode == 0:
        return True
    # Fail closed on IAM/auth/network failures rather than mistaking them for a
    # missing resource and provisioning in an unintended context.
    message = result.stderr.decode("utf-8", errors="replace").upper()
    if any(code in message for code in ("NOT_FOUND", "NOT FOUND", "DOES NOT EXIST", "COULD NOT BE FOUND")):
        return False
    raise DeploymentError("Could not inspect an existing resource. Check Google Cloud authentication and permissions.")


def validate(args):
    if not re.fullmatch(r"[a-z][a-z0-9-]{4,61}[a-z0-9]", args.project):
        raise DeploymentError("Use a Google Cloud project ID, not its display name or number.")
    if not re.fullmatch(r"[a-z]+-[a-z]+[0-9]", args.region):
        raise DeploymentError("Use a region such as us-central1.")
    if args.database != "(default)" and not re.fullmatch(r"[a-z][a-z0-9-]{2,61}[a-z0-9]", args.database):
        raise DeploymentError("Invalid Firestore database ID.")


def addresses(args):
    runtime = f"{RUNTIME_ACCOUNT}@{args.project}.iam.gserviceaccount.com"
    builder = f"{BUILD_ACCOUNT}@{args.project}.iam.gserviceaccount.com"
    bucket = f"gs://{args.project}-group-pay-source"
    return runtime, builder, bucket


def plan(args):
    runtime, builder, bucket = addresses(args)
    print(json.dumps({
        "action": "plan only; no cloud calls or secret reads",
        "project": args.project, "region": args.region,
        "service": SERVICE, "firestoreDatabase": args.database,
        "runtimeIdentity": runtime, "buildIdentity": builder,
        "sourceBucket": bucket, "artifactRepository": REPOSITORY,
        "billing": "request-based", "minimumInstances": 0, "maximumInstances": 1,
        "cpu": 1, "memory": "512Mi", "concurrency": 8, "requestTimeoutSeconds": 120,
        "transport": "public HTTPS; application Bearer token required except /health",
        "runtimeRoles": ["roles/datastore.user", "roles/secretmanager.secretAccessor on the five named secrets only"],
        "secretNames": list(SECRETS.values()), "uploadedSourceAllowlist": list(SOURCES),
        "limits": {"newIntentsPerUTCDayForTeam": 100, "maxCardCents": 50000},
        "stages": ["prepare", "upload-secrets", "quiesce local server and migrate_storage.py", "deploy --migration-reviewed"],
    }, indent=2))


def prepare(args):
    runtime, builder, bucket = addresses(args)
    project = ["--project", args.project]
    print("Enabling required APIs.")
    command(["services", "enable", *APIS, *project])
    for account, email, display in ((RUNTIME_ACCOUNT, runtime, "Group Pay sandbox runtime"), (BUILD_ACCOUNT, builder, "Group Pay container builder")):
        if not exists(["iam", "service-accounts", "describe", email, *project]):
            command(["iam", "service-accounts", "create", account, "--display-name", display, *project])
    if not exists(["artifacts", "repositories", "describe", REPOSITORY, "--location", args.region, *project]):
        command(["artifacts", "repositories", "create", REPOSITORY, "--repository-format", "docker", "--location", args.region, "--immutable-tags", *project])
    command(["artifacts", "repositories", "add-iam-policy-binding", REPOSITORY, "--location", args.region,
             "--member", "serviceAccount:" + builder, "--role", "roles/artifactregistry.writer", *project])
    if not exists(["storage", "buckets", "describe", bucket, *project]):
        command(["storage", "buckets", "create", bucket, "--location", args.region, "--uniform-bucket-level-access", "--public-access-prevention", *project])
    command(["storage", "buckets", "add-iam-policy-binding", bucket, "--member", "serviceAccount:" + builder,
             "--role", "roles/storage.objectViewer", *project])
    for email, role in ((runtime, "roles/datastore.user"), (builder, "roles/logging.logWriter")):
        command(["projects", "add-iam-policy-binding", args.project, "--member", "serviceAccount:" + email,
                 "--role", role, "--condition=None", *project])
    if not exists(["firestore", "databases", "describe", "--database", args.database, *project]):
        command(["firestore", "databases", "create", "--database", args.database, "--location", args.region,
                 "--type", "firestore-native", "--delete-protection", *project])
    for secret in SECRETS.values():
        if not exists(["secrets", "describe", secret, *project]):
            command(["secrets", "create", secret, "--replication-policy", "automatic", "--labels", "app=group-pay,environment=sandbox", *project])
        command(["secrets", "add-iam-policy-binding", secret, "--member", "serviceAccount:" + runtime,
                 "--role", "roles/secretmanager.secretAccessor", *project])
    print("Resources are prepared. No credentials were read or uploaded, and no Cloud Run service was deployed.")


def read_private_settings(path: Path) -> dict[str, str]:
    if not path.is_file() or stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise DeploymentError("The settings file must exist and be private (chmod 600).")
    result = {}
    for source in path.read_text().splitlines():
        source = source.strip()
        if not source or source.startswith("#"):
            continue
        key, separator, value = source.partition("=")
        key, value = key.strip(), value.strip()
        if not separator or not re.fullmatch(r"[A-Z_]+", key) or key in result:
            raise DeploymentError("Invalid private settings file. Duplicate names and shell expressions are not supported.")
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        result[key] = value
    # Reuse sandbox origin and credential-format validation, without importing
    # the server's read_env helper (which merges ambient environment variables).
    sys.path.insert(0, str(ROOT))
    from server import Config
    try:
        config = Config.from_env(result)
        if not config.ready:
            raise ValueError()
    except Exception:
        raise DeploymentError("The private settings file does not contain valid sandbox credentials and a client token.") from None
    return result


def upload_secrets(args):
    values = read_private_settings(args.env_file)
    for environment, secret in SECRETS.items():
        value = values.get(environment, "")
        if not value:
            if environment in REQUIRED_SECRETS:
                raise DeploymentError("A required sandbox credential is missing.")
            continue
        command(["secrets", "versions", "add", secret, "--data-file=-", "--project", args.project], data=value.encode())
    print("Sandbox secrets uploaded through stdin. Values were not printed or included in command arguments.")


def latest_secret_bindings(args) -> list[str]:
    bindings = []
    for environment, secret in SECRETS.items():
        result = command(["secrets", "versions", "list", secret, "--filter", "state=ENABLED", "--sort-by=~createTime", "--limit=1",
                          "--format=value(name)", "--project", args.project])
        name = result.stdout.decode().strip()
        version = name.rsplit("/", 1)[-1]
        if not version:
            if environment in REQUIRED_SECRETS:
                raise DeploymentError("Upload all three required secrets before deployment.")
            continue
        if not version.isdigit():
            raise DeploymentError("Could not resolve an immutable secret version.")
        bindings.append(f"{environment}={secret}:{version}")
    return bindings


def stage_source(destination: Path, image: str):
    for relative in SOURCES:
        source = ROOT / relative
        if not source.is_file() or source.is_symlink():
            raise DeploymentError("A required allowlisted build file is missing or is a symlink: " + relative)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    build = {
        "steps": [{"name": "gcr.io/cloud-builders/docker", "args": ["build", "--pull", "-t", image, "."]}],
        "images": [image], "options": {"logging": "CLOUD_LOGGING_ONLY"}, "timeout": "1200s",
    }
    (destination / "cloudbuild.yaml").write_text(json.dumps(build, indent=2))


def deploy(args):
    if not args.migration_reviewed:
        raise DeploymentError("Stop the local server and migrate its issuance journal before first cloud traffic. Then pass --migration-reviewed; see cloud/README.md.")
    runtime, builder, bucket = addresses(args)
    bindings = latest_secret_bindings(args)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8]
    image = f"{args.region}-docker.pkg.dev/{args.project}/{REPOSITORY}/{SERVICE}:beta-{stamp}"
    with tempfile.TemporaryDirectory(prefix="group-pay-source-") as temporary:
        staged = Path(temporary)
        stage_source(staged, image)
        print("Building from the explicit source allowlist; local secrets and databases are excluded.")
        command(["builds", "submit", str(staged), "--config", str(staged / "cloudbuild.yaml"),
                 "--service-account", f"projects/{args.project}/serviceAccounts/{builder}",
                 "--gcs-source-staging-dir", bucket + "/source", "--region", args.region, "--project", args.project])
    print("Deploying the small-team sandbox service with pinned Secret Manager versions.")
    command(["run", "deploy", SERVICE, "--image", image, "--region", args.region, "--project", args.project,
             "--service-account", runtime, "--allow-unauthenticated", "--ingress", "all", "--port", "8080",
             "--cpu", "1", "--memory", "512Mi", "--concurrency", "8", "--timeout", "120",
             "--min", "0", "--max", "1", "--min-instances", "0", "--max-instances", "1",
             "--cpu-throttling", "--no-cpu-boost", "--execution-environment", "gen2", "--no-session-affinity",
             "--set-env-vars", f"GOOGLE_CLOUD_PROJECT={args.project},FIRESTORE_DATABASE={args.database},MARQETA_BASE_URL=https://sandbox-api.marqeta.com/v3",
             "--set-secrets", ",".join(bindings)])
    result = command(["run", "services", "describe", SERVICE, "--region", args.region, "--project", args.project, "--format=value(status.url)"])
    address = result.stdout.decode().strip()
    if re.fullmatch(r"https://[a-z0-9-]+\.[a-z0-9-]+\.run\.app|https://[a-z0-9-]+\.run\.app", address):
        print("Cloud Run URL: " + address)
    else:
        print("Deployed. Get the HTTPS service URL from the Cloud Run console.")
    print("Bundle that public URL in project.yml as GroupPayCardServiceURL and regenerate the Xcode project. Testers enter only the shared code under Profile > Team access.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", nargs="?", choices=("plan", "prepare", "upload-secrets", "deploy"), default="plan")
    parser.add_argument("--project", required=True)
    parser.add_argument("--region", default="us-central1")
    parser.add_argument("--database", default="(default)")
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env")
    parser.add_argument("--execute", action="store_true", help="Required for stages that create billable resources, grant access, upload secrets, or deploy.")
    parser.add_argument("--migration-reviewed", action="store_true", help="Confirm the local issuance journal was migrated while the local server was stopped.")
    args = parser.parse_args()
    try:
        validate(args)
        if args.stage == "plan":
            plan(args)
            return
        if not args.execute:
            raise DeploymentError("This stage changes Google Cloud. Review the plan, then explicitly add --execute.")
        if not shutil.which("gcloud"):
            raise DeploymentError("Install the official Google Cloud CLI and sign in before executing a stage.")
        {"prepare": prepare, "upload-secrets": upload_secrets, "deploy": deploy}[args.stage](args)
    except (DeploymentError, OSError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
