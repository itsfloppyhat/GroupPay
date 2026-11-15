# Group Pay cloud sandbox

This deploys the existing Marqeta **sandbox** adapter to a small Cloud Run service so invited testers can reach it from their own iPhones. It never uses Marqeta production, returns no full card number or CVV, and does not pay a real merchant.

## Trust boundary

The HTTPS endpoint is publicly reachable. `/health` is a safe public health check; `/v1/status`, `/v1/cards`, and card lookups require the team's shared Bearer token. Browser-origin requests are rejected and CORS is not enabled.

The shared token is for a **small trusted beta group**. It is not a CloudKit identity assertion. A token holder can submit approval claims and read another known bill's masked issuance result. CloudKit share permissions and app-side approval checks do not make those claims independently verifiable by this backend. Do not open this service to untrusted users or use it for real money until server-verifiable user authentication, authorization, approval records, and auditing replace that trust model.

Marqeta credentials stay in Secret Manager. The public service URL is bundled in the app as `GroupPayCardServiceURL`. Testers enter only the shared team access code under **Profile → Team access**; no credentials are compiled into the app, source, or image. Rotate the client token when someone leaves the group. No token belongs in a URL.

## Limits and durable state

- At most **$500.00 per new cloud sandbox intent**, in exact integer USD cents. Previously reserved local intents remain recoverable after migration, including larger bills; their original immutable request must match before any provider reconciliation.
- At most **100 new issuance intents per UTC day for the whole team**, reserved transactionally with the new intent. Retries/reconciliation do not consume another intent quota. A failed first attempt still reserves its intent and quota.
- Firestore Native stores immutable intent bindings, masked results, and provider-attempt markers. There is **no SQLite fallback** in Cloud Run and no TTL on these records. Losing or manually deleting this journal can undermine reconciliation safety; retain it across redeployments and credential rotation.
- Every uncertain provider operation is reconciled by its original resource token, never blindly repeated. A request timeout does not mean a provider operation failed.
- Cloud Run uses request-based billing, minimum 0 / maximum 1 instance, 1 CPU, 512 MiB, concurrency 8, and a 120-second request timeout. Scaling limits and the application quota are not spending guarantees. Builds, image storage, Firestore, secrets, logging, and source storage may incur separate charges; review billing alerts and budget controls.

The runtime identity receives `roles/datastore.user` in the dedicated project and `roles/secretmanager.secretAccessor` on the five named Group Pay secrets only. The separate build identity can read the private source bucket, write the image repository, and write build logs. Neither gets Owner or Editor. The deployer needs permissions to provision these resources, grant the listed IAM bindings, act as both service accounts, build, and deploy a Cloud Run service with public transport.

## Review and deploy

Requirements: official `gcloud` CLI, a selected **project ID**, billing enabled for that project, and a private `sandbox_backend/.env` containing the existing sandbox credentials and client token. The helper always supplies `--project`; it does not change the global gcloud project setting. It does not create/link a billing account or change budget controls.

Run from the repository root. Substitute your own project ID for `group-pay-itsfloppyhat` if necessary.

```sh
# This prints a concrete plan only: no cloud calls and no credential reads.
python3 sandbox_backend/cloud/manage.py plan --project group-pay-itsfloppyhat

# Explicit execution creates missing resources, enables APIs, and grants the documented access.
python3 sandbox_backend/cloud/manage.py prepare --project group-pay-itsfloppyhat --execute

# Uploads credential values from the private .env through stdin, never command arguments.
python3 sandbox_backend/cloud/manage.py upload-secrets --project group-pay-itsfloppyhat --execute
```

The default region is `us-central1` and Firestore database is `(default)`; optional `--region` / `--database` flags must be consistent across stages. Existing resources are retained. Preparation does not read credentials or deploy an endpoint. Secret upload creates new versions without printing values. Deployment resolves and pins enabled numeric secret versions, including optional product/funding-source secrets if uploaded; it does not use `latest` references.

### Preserve the local issuance journal first

Before the first cloud deployment, stop the local server so its SQLite journal cannot change during migration. **Do not delete or replace the original journal.** Install the cloud dependencies into a temporary virtual environment and run the migration provided alongside the storage implementation:

```sh
python3 -m venv /tmp/group-pay-cloud-venv
/tmp/group-pay-cloud-venv/bin/python -m pip install -r sandbox_backend/requirements-cloud.txt
/tmp/group-pay-cloud-venv/bin/python sandbox_backend/migrate_storage.py \
  --project group-pay-itsfloppyhat --database '(default)' --gcloud-user
```

The migration reads the local journal, makes no Marqeta calls, preserves completed results and uncertain-attempt markers, and refuses conflicting remote state. It does not charge the new-intent quota. If this is a genuinely new installation with no journal, record that fact instead. Inspect the migration's safe count summary before proceeding. Legacy bills above the cloud $500 cap remain available for lookup and exact-request reconciliation; new large intents are rejected.

```sh
python3 sandbox_backend/cloud/manage.py deploy --project group-pay-itsfloppyhat \
  --migration-reviewed --execute
```

Deployment builds from an explicit allowlist into a fresh temporary directory, then deploys the image. `.env`, `data`, Git metadata, device credentials, migration outputs, and tests are never submitted. The checked-in `.dockerignore` and `.gcloudignore` also use allowlists. The helper captures command output and never prints API error bodies. A failed stage stops with an action name; inspect the Google Cloud console for detailed resource/permission failures.

The helper prints the service URL. Set it in `project.yml` as the `GroupPayCardServiceURL` Info.plist property and regenerate the Xcode project. Privately distribute only the shared client token; testers enter it under **Profile → Team access**. Test an unauthenticated `/health`, an authenticated `/v1/status`, a small new sandbox bill, and replay the same bill to verify durable reconciliation. Do not put bearer tokens in copied commands or shell history; use the app settings or an input prompt. Platform request logs may contain URLs and status codes; the application and Gunicorn do not log headers, request bodies, credentials, or provider responses.

## Local offline checks

```sh
cd sandbox_backend
/tmp/group-pay-cloud-venv/bin/python -m unittest test_server test_storage test_cloud_app
```

HTTP tests inject a fake issuer, and storage tests use isolated transaction-model fakes and actual multi-process SQLite. They do not deploy anything or contact Marqeta. Running the cloud service itself requires Firestore and ADC; a misconfigured cloud service fails startup instead of silently storing state on an ephemeral disk.

## API

- `GET /health` → `{ "status": "ok", "environment": "sandbox" }`.
- `GET /v1/status` → readiness, environment, `$500` cent limit, daily intent limit; Bearer required.
- `POST /v1/cards` → existing approved-bill request format; Bearer required. Only masked card metadata is returned.
- `GET /v1/cards/{billID}/{cycle}` → masked saved result, `202` reconciliation pending, or safe error; Bearer required.

The API does not expose provider secrets, full PAN/CVV, a real payment route, or a Firestore client key. Local development remains loopback-only on port 8787; only this Cloud Run adapter binds `0.0.0.0:$PORT`.

References: [Cloud Run billing settings](https://docs.cloud.google.com/run/docs/configuring/billing-settings), [service identity](https://docs.cloud.google.com/run/docs/configuring/services/service-identity), [secrets](https://docs.cloud.google.com/run/docs/configuring/services/secrets), [Firestore transactions](https://docs.cloud.google.com/firestore/native/docs/manage-data/transactions), [Flask](https://pypi.org/project/Flask/), [Gunicorn](https://pypi.org/project/gunicorn/), [Firestore Python client](https://pypi.org/project/google-cloud-firestore/).

## Configured project cost controls

On November 14, 2026, project `group-pay-itsfloppyhat` was configured with a $5/month Cloud Run spend cap and $5/month project-wide budget alerts at 50%, 80%, and 100%. The Run cap pauses new Cloud Run usage when estimated gross charges cross the threshold, with possible enforcement delay; it resets monthly. It does not cap Firestore, Secret Manager, image/source storage, builds, or other services. The project-wide budget only alerts. See [spend-cap behavior](https://docs.cloud.google.com/billing/docs/how-to/budgets-spend-caps) and [Cloud Run pricing](https://cloud.google.com/run/pricing).

The local journal was migrated before cloud traffic: one completed intent and five attempt markers, verified by an idempotent second import. Keep that original journal. Four independent real Firestore clients also passed isolated concurrency, quota, replay, conflict, and ownership-fencing checks; all test records were removed.
