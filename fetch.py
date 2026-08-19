#!/usr/bin/env python3
"""
Check It -> Google Drive fetcher (Cloud Run Job).

Replaces the Cloud Build + R pipeline. Calls the Check It reporting API and
writes one dated CSV per entity into per-entity Google Drive folders that a Weld
google-drive sync ingests (the same pattern as Alert65).

Design choices vs the old script.R:
  * Python, not R  -> no rocker/tidyverse image, no per-run CRAN drift.
  * Writes CSVs to Drive -> Weld owns the load, history, and monitoring
    (Weld has no GCS connector, so the landing zone is Drive, like Alert65).
  * APPEND history: every run writes a NEW dated file, never overwrites, so
    BigQuery accumulates full history. The old WRITE_TRUNCATE lost everything
    older than the rolling 100-day API window on each run.
  * FAILS LOUD: any endpoint that does not return 200 makes the whole run exit
    non-zero, so a dead/expired token shows up as a FAILED Cloud Run execution
    (and a Cloud Monitoring alert) instead of a silent multi-month freeze.
  * No service-account key file. Cloud Run runs AS a service account; we use
    Application Default Credentials. The Check It bearer token comes from Secret
    Manager, injected as the CHECKIT_AUTH_KEY env var.

Env vars:
  CHECKIT_AUTH_KEY   (from Secret Manager) - the monthly Check It bearer token
  CHECKIT_BASE_URL   default https://reports.checkit.net/api
  LOOKBACK_DAYS      default 7   (routine overlap; set 100 for a full backfill)
  RUN_DATE           optional YYYY-MM-DD override (default: today, UTC)
  DRIVE_FOLDER_REPORTS / _ALERTS / _JOBS / _LOCATIONS - target Drive folder ids
"""

import csv
import io
import os
import sys
from datetime import date, datetime, timedelta, timezone

import requests
from google.auth import default as google_auth_default
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

BASE_URL = os.environ.get("CHECKIT_BASE_URL", "https://reports.checkit.net/api")
AUTH_KEY = os.environ.get("CHECKIT_AUTH_KEY", "")
LOOKBACK_DAYS = int(os.environ.get("LOOKBACK_DAYS", "7"))
DRIVE_SCOPES = ["https://www.googleapis.com/auth/drive.file"]

# entity -> (endpoint, extra query params, Drive folder-id env var). Mirrors
# script.R: report_data = /reports service_type=workmanagement (no event_type);
# alerts_data = /reports service_type=automatedmonitoring + the 5 event types;
# job_data = /jobs; location_data = /locations (no date window).
EVENT_TYPES = "checkReport,jobOverdue,jobCancelled,sensorAlert,zigbeeBatteryAlert"
ENTITIES = {
    "reports": {
        "endpoint": "/reports",
        "params": {"service_type": "workmanagement"},
        "windowed": True,
        "folder_env": "DRIVE_FOLDER_REPORTS",
    },
    "alerts": {
        "endpoint": "/reports",
        "params": {"service_type": "automatedmonitoring", "event_type": EVENT_TYPES},
        "windowed": True,
        "folder_env": "DRIVE_FOLDER_ALERTS",
    },
    "jobs": {
        "endpoint": "/jobs",
        "params": {"limit": "1000"},
        "windowed": True,
        "folder_env": "DRIVE_FOLDER_JOBS",
    },
    "locations": {
        "endpoint": "/locations",
        "params": {},
        "windowed": False,
        "folder_env": "DRIVE_FOLDER_LOCATIONS",
    },
}


def log(msg: str) -> None:
    print(f"[check-it-fetch] {msg}", flush=True)


def run_date() -> date:
    override = os.environ.get("RUN_DATE")
    if override:
        return datetime.strptime(override, "%Y-%m-%d").date()
    return datetime.now(timezone.utc).date()


def fetch_day(endpoint: str, params: dict, day: date | None) -> list[dict]:
    """One GET. Returns parsed CSV rows. Raises on any non-200 (fail loud)."""
    q = dict(params)
    if day is not None:
        q["start_time"] = day.strftime("%d-%m-%Y")
        q["end_time"] = (day + timedelta(days=1)).strftime("%d-%m-%Y")
    resp = requests.get(
        f"{BASE_URL}{endpoint}",
        params=q,
        headers={"Authorization": f"Bearer {AUTH_KEY}", "Accept": "text/csv"},
        timeout=120,
    )
    if resp.status_code != 200:
        raise RuntimeError(
            f"{endpoint} returned {resp.status_code} for {q.get('start_time','-')}: "
            f"{resp.text[:300]}"
        )
    text = resp.text.strip()
    if not text:
        return []
    return list(csv.DictReader(io.StringIO(text)))


def fetch_entity(name: str, spec: dict, rd: date) -> list[dict]:
    if not spec["windowed"]:
        rows = fetch_day(spec["endpoint"], spec["params"], None)
        log(f"{name}: {len(rows)} rows")
        return rows
    all_rows: list[dict] = []
    for offset in range(LOOKBACK_DAYS, -1, -1):
        day = rd - timedelta(days=offset)
        all_rows.extend(fetch_day(spec["endpoint"], spec["params"], day))
    log(f"{name}: {len(all_rows)} rows over {LOOKBACK_DAYS + 1} days")
    return all_rows


def rows_to_csv_bytes(rows: list[dict]) -> bytes:
    if not rows:
        return b""
    fields: list[str] = []
    seen = set()
    for r in rows:
        for k in r:
            if k not in seen:
                seen.add(k)
                fields.append(k)
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=fields)
    w.writeheader()
    w.writerows(rows)
    return buf.getvalue().encode("utf-8")


def upload_to_drive(drive, folder_id: str, filename: str, data: bytes) -> None:
    media = MediaIoBaseUpload(io.BytesIO(data), mimetype="text/csv", resumable=False)
    drive.files().create(
        body={"name": filename, "parents": [folder_id]},
        media_body=media,
        fields="id",
        supportsAllDrives=True,  # required for Shared Drives
    ).execute()


def main() -> int:
    if not AUTH_KEY:
        log("FATAL: CHECKIT_AUTH_KEY is empty (Secret Manager not wired?)")
        return 2

    rd = run_date()
    stamp = rd.strftime("%Y-%m-%d")
    creds, _ = google_auth_default(scopes=DRIVE_SCOPES)
    drive = build("drive", "v3", credentials=creds, cache_discovery=False)

    failures = []
    for name, spec in ENTITIES.items():
        folder_id = os.environ.get(spec["folder_env"], "")
        if not folder_id:
            failures.append(f"{name}: {spec['folder_env']} not set")
            continue
        try:
            rows = fetch_entity(name, spec, rd)
            if not rows:
                log(f"{name}: WARNING empty result, writing nothing")
                continue
            data = rows_to_csv_bytes(rows)
            fname = f"check_it_{name}_{stamp}.csv"
            upload_to_drive(drive, folder_id, fname, data)
            log(f"{name}: uploaded {fname} ({len(data)} bytes)")
        except Exception as exc:  # noqa: BLE001 - surface every failure
            log(f"{name}: FAILED - {exc}")
            failures.append(f"{name}: {exc}")

    if failures:
        log(f"RUN FAILED ({len(failures)} of {len(ENTITIES)} entities): {failures}")
        return 1
    log("RUN OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
