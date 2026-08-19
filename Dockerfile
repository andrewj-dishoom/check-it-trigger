# Lean, pinned image. Built ONCE and pushed to Artifact Registry — the Cloud Run
# Job re-runs it on a schedule, so there is no per-run image build (the thing that
# made the old Cloud Build pipeline slow and fragile).
FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY fetch.py .

ENTRYPOINT ["python", "/app/fetch.py"]
