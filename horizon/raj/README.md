# Horizon Retail Bank — Raj's lakehouse and Report 1

This folder contains Raj's Assignment 2 work: a Delta lakehouse fed by Maedeh's integrated PostgreSQL warehouse, Report 1 on activity trends, source-to-gold reconciliation and an inventory for SQL scripts section 6(c). The other owners provide the graph, fabric and streaming components. This package alone does not demonstrate those components or the full team video.

## Architecture and ownership

```text
Core, card and digital synthetic sources
    ↓ Maedeh's PostgreSQL staging and dw load
Seven dw dimensions and facts in the lab PostgreSQL container
    ↓ Raj's read-only repeatable-read export (02)
Seven CSV files in data/warehouse/
    ↓ Raj's validation and Delta writes (03)
Bronze → Silver → Gold, with quality issues in Audit
    ↓ Raj's DuckDB SQL over gold (04)
Report 1 HTML/CSV/SVG → reconciliation (05) → Delta history (06)
```

On Raj's computer **two Compose projects share one Docker Desktop engine**. The existing `advance-database-lab` project runs `student-postgres`, which contains the loaded `dw` tables in database `lab`. This folder's `compose.yaml` starts **only one Python container**. It reaches the lab's published PostgreSQL port at `host.docker.internal:5432`. It does not create a second database. This folder is bind-mounted into `/workspace`, so output appears on Windows.

## Prerequisites

- Docker Desktop running with Linux containers.
- The lab PostgreSQL container running, with all seven `dw` tables loaded. Maedeh's unchanged DDL, ETL, checks and ERDs are in `team_sql/Maedeh/` for reference. Do not rerun import/load scripts on already populated tables.
- An account with `SELECT` access to `dw`. Keep the actual host, port, user, password and database in local `.env`; never share it.
- Open **Windows CMD** in the project root containing `compose.yaml` and this README. The Docker commands also work in PowerShell.

| Four dimensions | Three facts |
|---|---|
| `dw.dim_customer`, `dw.dim_account`, `dw.dim_card`, `dw.dim_digital_user` | `dw.fact_core_transaction`, `dw.fact_card_transaction`, `dw.fact_digital_event` |

The eight original CSVs in Maedeh's staging import are **not** Raj's seven `dw` exports. Raj's final mode reads the warehouse tables, not staging files.

## Run from the loaded lab warehouse

### 1. Configure the connection

```bat
copy .env.example .env
notepad .env
```

Set `WAREHOUSE_DSN` with the database that **actually contains** `dw`. Raj's loaded lab database is `lab`, while Maedeh's independent README describes a possible `horizon_dw` database. Use `host.docker.internal` from the Python container if PostgreSQL publishes port 5432 on Windows. URL-encode reserved characters in the password. Do not paste the DSN into screenshots or team messages.

### 2. Start the container

```bat
docker ps --filter "name=student-postgres"
docker compose config --services
docker compose up -d --build
```

The first command should show the lab PostgreSQL container; the second should show only `python`. Run the next commands **one at a time**. Stop on an error instead of continuing to a stale report.

### 3. Export, build, report and check

```bat
docker compose exec python python scripts/02_export_maedeh_warehouse.py
docker compose exec python python scripts/03_build_lakehouse.py --mode warehouse
docker compose exec python python scripts/04_report_activity_trends.py --mode warehouse
docker compose exec python python scripts/05_verify_results.py --mode warehouse
docker compose exec python python scripts/06_delta_history.py --mode warehouse
docker compose exec python python scripts/07_consolidate_sql.py
docker compose exec python python -m unittest discover -s tests -v
```

Script 02 reads all seven tables in a read-only, repeatable-read transaction and writes `data/warehouse/*.csv`; it does not modify PostgreSQL. Script 03 validates keys, timestamps and amounts and writes Delta bronze, silver, gold and audit tables with Parquet and `_delta_log`. Script 04 uses DuckDB queries on gold and writes Report 1 and monthly Delta aggregates. Script 05 independently checks source/gold IDs, counts, per-currency sums, source labels and monthly counts. Script 06 reads actual Delta versions. Script 07 inventories script owners, engines and checksums; it **does not run** those scripts. The unit tests check Raj's contract, not other team workstreams.

Open the report on Windows:

```bat
start "" "output\warehouse\reports\Report_1_Activity_Brief.html"
```

Its input label must say **Integrated warehouse export**. Use the new `Report_1_Activity_Brief.html`, not the old preview PNG or an already open browser tab. Script 04 also refreshes the older `Report_1_Activity_Trends.html` filename for compatibility.

### Expected observations for the supplied synthetic dataset

| Measure | Expected result |
|---|---:|
| Source activity facts | 9,500 core + 9,500 card + 9,500 digital |
| Gold `fact_activity` | 28,500 accepted; 0 rejected under implemented rules |
| Default report period | 2024-01-01 to 2026-09-30 inclusive; 24,366 records |
| In-period source mix | Core 9,500; card 5,366; digital 9,500 |
| Older card records retained outside period | 4,134 |
| Digital monetary records with unspecified currency | 765 |
| Raj's reported warehouse-mode verification | 16 PASS checks |
| First warehouse-mode Delta history result | Version 0; 28,500 gold activity rows |

October 2025 has 889 combined source records, the highest month in the default period. These are **source records**, not unique payments. Different inputs or dates will change the results.

## Evidence locations

| File | Why it matters |
|---|---|
| `data/warehouse/handoff.json` | Database name, origin and export time. |
| `output/warehouse/build_summary.json` | Source, accepted, rejected and warning totals. |
| `output/warehouse/lakehouse/manifest.json` | Delta table rows and versions; `_delta_log` proves a real Delta table. |
| `output/warehouse/reports/Report_1_Activity_Brief.html` | Source-mix, trend, currency, status and customer views with a visible period and provenance. |
| `output/warehouse/reports/*.csv` and `report_1_metrics.json` | Query outputs and report numbers. |
| `output/warehouse/verification.json` | Individual machine-readable reconciliation results. |
| `output/warehouse/delta_history.json` | Observed current and, if available, previous Delta version. |
| `consolidated/script_inventory.json` | Available script mapping; **not** execution proof. |

Capture **warehouse-mode** screenshots and a dated run log for your individual contribution record. [The evidence handoff checklist](docs/EVIDENCE_HANDOFF.md) lists exactly what to capture and send. If your working folder contains `example_results/`, those files are a **dataset preview**; never present them as a live warehouse run.

## Show a previous Delta version

A new output folder begins at version 0. If you want to demonstrate a previous version, run 03, 04, 05 and 06 again in order without changing the input:

```bat
docker compose exec python python scripts/03_build_lakehouse.py --mode warehouse
docker compose exec python python scripts/04_report_activity_trends.py --mode warehouse
docker compose exec python python scripts/05_verify_results.py --mode warehouse
docker compose exec python python scripts/06_delta_history.py --mode warehouse
```

Inspect actual version numbers and current/previous row counts on your machine. Full-snapshot overwrites demonstrate batch versioning; this code does not implement continuous CDC or a transaction across all Delta tables.

## Alternative ways to prepare input

**Seven CSV exports from Maedeh:** Put `dim_customer.csv`, `dim_account.csv`, `dim_card.csv`, `dim_digital_user.csv`, `fact_core_transaction.csv`, `fact_card_transaction.csv` and `fact_digital_event.csv` in `data/warehouse/`. Export complete tables with headers and surrogate keys from one consistent snapshot. Run `scripts/08_register_warehouse_csv.py`, then 03–06 with `--mode warehouse`. Record who made the snapshot. Do not run 02 afterwards unless you intend to replace the CSVs.

**Offline preview only:** `docker compose exec python python run_preview.py` reads `input/team_dataset.zip` and uses the supplied identity reference to prepare warehouse-shaped CSVs. It writes to `output/dataset-preview/`; it does **not** connect to Maedeh's warehouse and is not final integration evidence.

## File and layer guide

| File group | Implementation and owner |
|---|---|
| `scripts/01–08` | Thin command entry points; Raj except Maedeh's upstream warehouse and shared handoff. |
| `raj_lakehouse/prepare.py` | Preview adapter, read-only PostgreSQL export and CSV registration. |
| `raj_lakehouse/build.py` | Actual Delta bronze/silver/gold/audit writes and validation. |
| `raj_lakehouse/report.py`, `sql/report_1/` | DuckDB queries, trend graphic, Activity Brief HTML and CSV. |
| `raj_lakehouse/verify.py` | Independent reconciliation and Delta history read. |
| `raj_lakehouse/consolidate.py` | SQL/Cypher file inventory and PostgreSQL export-query bundle. |
| `sql/warehouse_export/` | Seven read-only PostgreSQL SELECTs against Maedeh's `dw` schema. |
| `team_sql/Maedeh/` | Unchanged upstream SQL/README/ERDs, with authorship retained. |

Bronze preserves received warehouse tables. Silver validates dimension/customer relationships and brings activities into a common structure while retaining source IDs and statuses. Audit records warnings and rejections. Gold contains a customer dimension, one activity fact per accepted source record, and monthly aggregates. Exact decimal values and source wall-clock timestamps are preserved. Digital currency is not inferred. A digital interaction and a core posting can represent the same operation; never sum three source volumes as unique payments. Synthetic source fraud flags are labels, not model predictions.

For section 6(c), gather **Divaakar's source DDL/data scripts, Samnang's graph import and Report 2 queries, Shubham's fabric/Report 3 scripts, and Somit's streaming/Report 4 scripts** into separate owner folders. Record each engine, dependency, command and run result. PostgreSQL, DuckDB, Neo4j Cypher and Python are different engines; do not concatenate their code into one executable SQL file.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Docker Desktop Linux engine pipe missing | Start Docker Desktop and wait for Linux containers. |
| `student-postgres` not running | Start the **lab** project; Raj's Compose runs Python only. |
| Password authentication failed | Confirm CloudBeaver's actual login/database. Update local `.env`, then `docker compose up -d --force-recreate python`. |
| `relation dw... does not exist` | Check that the DSN points at the database containing all seven `dw` tables. |
| `COPY FROM C:/...` fails in CloudBeaver | This is Maedeh's upstream **server-side** import. PostgreSQL inside Docker cannot see a Windows path unless mounted; follow her README. |
| Input fingerprint changed | After a new export, rerun 03 before 04/05; never mix old gold with new CSVs. |
| Old HTML still opens | Check `raj_lakehouse/report.py` contains `Report_1_Activity_Brief.html`, rerun 04 and open the new filename. |
| Verification fails | Read the named failure in `verification.json`, fix the input/build and preserve the failing result in the logbook. |
| PASS text then process termination | Check the actual exit code and generated JSON before recording a pass. |

## Clean team handoff

Send code, SQL, this README, the synthetic input ZIP, unchanged Maedeh SQL reference, and tests. Add **your own** sanitized `warehouse` evidence from the checklist. Do **not** send `.env`, PostgreSQL volumes/dumps, generated `data/warehouse` CSVs, full `output/` Delta/Parquet directories, `__pycache__`, local file paths or preview screenshots presented as warehouse proof. Teammates can reproduce the code against their loaded lab database; one agreed integration machine should produce the end-to-end video.
