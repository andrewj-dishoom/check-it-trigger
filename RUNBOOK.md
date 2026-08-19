# Check It ingestion — runbook (Cloud Run → Drive → Weld)

Replaces the old `check-it-trigger` Cloud Build + R pipeline. Check It only offers
a **monthly-expiring bearer token**, so a monthly key-swap is unavoidable — this
design makes it a monitored 2-minute task instead of a silent multi-month outage.

## 🔑 Rotating the token — start here

**Easiest (no command line): the Key Manager web app.**
→ **`checkit-key-manager`** — https://github.com/dishoom-insight/checkit-key-manager
Open the app URL (ask the data team if you don't have it), sign in with your
Dishoom Google account, paste the new token, click **Update and test**. It shows a
status light and a clear ✅/❌. Roberto, Michael and Andrew have access. This is the
recommended path — anyone can do it without knowing the setup.

**CLI fallback (`rotate-token.ps1`)** — if the app is down:
1. Generate a new API token in the Check It portal (reports.checkit.net).
2. `.\rotate-token.ps1` — prompts for the token, stores it, runs a test fetch.
   (Or manually: `gcloud secrets versions add checkit-auth-key --data-file=token.txt --project jp-gs-379412`, then `gcloud run jobs execute check-it-fetch --region europe-west2 --wait`.)

Both paths do the same two things: add a new `checkit-auth-key` secret version and
run the `check-it-fetch` job. No redeploy — the job reads `:latest`.

## Architecture
```
Cloud Scheduler (06:00 Europe/London, daily)
  └─► Cloud Run Job  check-it-fetch    (image in Artifact Registry, built once)
        token ← Secret Manager  checkit-auth-key
        Check It API → 4 dated CSVs → 4 Google Drive folders
  └─► Weld google-drive syncs → BigQuery check_it.*  → Dataform → gold H&S dashboards
```

## Monitoring (three layers — a dead token can't hide)
1. **Cloud Run failure alert** — Cloud Monitoring policy `check-it-fetch failed execution` emails the data team on any failed run (see `alert-policy.json`).
2. **Weld sync-failure email** — enabled in Weld → Notifications.
3. **Dataform freshness assertion** — `assert_hs_feed_freshness` reds if `check_it` is >3 days stale.

## Deploy / update the fetcher
Build once to Artifact Registry; the job re-runs the image on schedule (no per-run build):
```
gcloud builds submit --tag europe-west2-docker.pkg.dev/jp-gs-379412/pipelines/check-it-fetch:latest .
gcloud run jobs update check-it-fetch --region europe-west2 --image europe-west2-docker.pkg.dev/jp-gs-379412/pipelines/check-it-fetch:latest
```

## Config (Cloud Run Job env vars)
| Var | Default | Notes |
|---|---|---|
| `CHECKIT_AUTH_KEY` | *(Secret Manager)* | the monthly token |
| `LOOKBACK_DAYS` | `2` | rolling window; `100` for a full backfill (needs ~16 GiB for that one run) |
| `DRIVE_FOLDER_REPORTS` / `_ALERTS` / `_JOBS` / `_LOCATIONS` | — | target Drive folder ids |

Steady state: `LOOKBACK_DAYS=2`, `--memory 1Gi --cpu 1`.

## If it breaks
- Failure alert fires → open the Cloud Run execution logs.
  - `401/403 .../reports` → token expired → rotate (app or script above).
  - `DRIVE_FOLDER_* not set` / Drive 404 → folder id wrong or not shared with the runtime SA.
  - Empty 200s → check whether Check It changed the API contract.

## History / known gaps
- The old bespoke feed froze 2026-04-21; its final state is archived in
  `a_bronze_raw_layer.checkit_snapshot_20260421_*`.
- The API serves only ~100 days, so **2026-04-22 → ~2026-05-04 is permanently lost**.
- Drive folders accumulate (~15 MB/day for reports) — archive or prune yearly.
