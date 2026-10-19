# Team ZIP contents and final handoff

This clean ZIP is **code and instructions**, not a copy of Raj's running Docker machine. Its `input/team_dataset.zip` contains synthetic source data for reproducibility. `team_sql/Maedeh/` preserves the copies and original authorship of her upstream scripts and ERDs. All Raj code, SQL and tests needed to run preview or warehouse mode are included.

## Keep in the share ZIP

- Root: `README.md`, `.env.example` with placeholders, `.gitignore`, `compose.yaml`, `Dockerfile`, `requirements.txt`, `run_preview.py`.
- Raj implementation: `raj_lakehouse/*.py`, `scripts/*.py`, `sql/report_1/*.sql`, `sql/warehouse_export/*.sql`, `tests/test_lakehouse.py`.
- Source/reference: `input/team_dataset.zip`, `team_sql/Maedeh/` and `team_sql/order.json`/`README.md`.
- Documentation: `docs/EVIDENCE_HANDOFF.md` and this manifest.

## Add before calling the ZIP a completed evidence package

From Raj's **final warehouse-mode run**, add the sanitized files and screenshots listed in `docs/EVIDENCE_HANDOFF.md`. The ZIP currently does not contain them because Raj's `output/warehouse` is on his Windows computer. The report editor also needs his dated individual logbook entry, actual command output and video timestamp or link. Do not represent a preview HTML/PNG as warehouse evidence.

## Leave out

- `.env`, database passwords, DSNs and personal machine paths.
- `data/warehouse/*.csv` and raw database dumps/volumes. Team members can rerun the export from their approved loaded warehouse or get a consistent authorized snapshot.
- `output/` full Delta tables and Parquet data, `data/dataset-preview/`, `__pycache__/`, `.pyc`, `.venv/`, temporary logs and duplicate old prototypes.
- `example_results/` from the preview mode, stale generated inventories and older guidance PDFs. The current README plus live evidence should be the handoff reference.

Keep one agreed integration copy of the repository/ZIP, let each owner add their files under `team_sql/<Owner>/`, rerun script 07, and record each owner's actual execution result. The clean ZIP does not claim graph, fabric or streaming implementation.
