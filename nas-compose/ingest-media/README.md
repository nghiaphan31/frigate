# ingest-media (DSM Container Manager)

- Image: `python:3.11-slim`
- Volumes:
  - `/volume1:/mnt/nas`
  - `/volume1/run/nas-pipelines:/work`
- Command: `/bin/bash -lc /work/tools/run_ingest.sh`
- Le script `tools/run_ingest.sh` gère:
  - heartbeat dans `/work/runs/current_01-media/heartbeat`
  - log horodaté dans `/work/logs/ingest-01-media_<ts>.log`
  - apt/pip minimum + exécution `tools/ingest_media.py` avec:
    - `--list /work/config/candidates_01-media_2025-10-12.lst`
    - `--mount-root /mnt/nas`
    - `--cas-root /mnt/nas/truth/cas/med`
    - `--run-dir /work/runs/<ts>_ingest-01-media`
