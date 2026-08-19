# check-it-fetch

Pulls Health & Safety data from the **Check It** API (checkit.net) into BigQuery,
via Google Drive + Weld. Runs as a scheduled **Cloud Run Job** on GCP project
`jp-gs-379412`.

Replaces the previous Cloud Build + R pipeline (the old `script.R` / `cloudbuild.yaml`
in this repo's history), which pushed a Docker image on every run, truncate-loaded
BigQuery (losing history), and failed silently when the Check It token expired —
undetected for ~4 months in 2026.

## What it does
Each run: reads the token from Secret Manager → calls the Check It API
(`/locations`, `/jobs`, `/reports` ×2 service types) for a rolling window → writes
one dated CSV per entity to four Google Drive folders → four Weld `google-drive`
syncs land them in `jp-gs-379412.check_it.{report_data, alerts_data, job_data,
location_data}` → Dataform models them into the gold H&S layer.

## Files
| File | |
|---|---|
| `fetch.py` | the fetcher |
| `Dockerfile` / `requirements.txt` | lean pinned `python:3.12-slim` image |
| `RUNBOOK.md` | **operations — token rotation, monitoring, break/fix, deploy** |
| `rotate-token.ps1` | CLI monthly token rotation (fallback to the web app) |
| `alert-policy.json` | Cloud Monitoring failed-execution alert |

## Token rotation
The Check It token expires ~monthly. Rotate it with the **[checkit-key-manager](https://github.com/dishoom-insight/checkit-key-manager)** web app (no CLI), or `rotate-token.ps1` as a fallback. See `RUNBOOK.md`.

## Design notes
- **Append, not truncate** — each run writes a new dated file; BigQuery keeps full history; Dataform dedups the overlap on the event `id`.
- **Fails loud** — any non-200 exits non-zero → a failed Cloud Run execution → a Cloud Monitoring alert.
- **No key files** — runs as a service account (ADC); the token lives only in Secret Manager.
- **Drive, not GCS** — Weld has a Google-Drive connector but no GCS one (mirrors the Alert65 pipeline).
