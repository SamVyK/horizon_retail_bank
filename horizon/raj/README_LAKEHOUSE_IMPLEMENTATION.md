# Delta lakehouse implementation and Report 1

This component consumes the integrated PostgreSQL `dw` warehouse and writes a local Delta lakehouse for cross-source activity reporting. It reuses upstream resolved identities and supplies a consistent downstream analytical input. Lakehouses can store structured data; this implementation handles **structured warehouse CSV exports only**, not unstructured data.

See the [project README](../../README.md) for the shared lab, full reset/build and other components. The [original component README](README.md) remains available for historical context and the separate dataset-preview route.

## Code and execution map

Paths below are relative to `horizon/raj/`.

| Entry point | Implementing functions | Behaviour |
| --- | --- | --- |
| [scripts/02_export_maedeh_warehouse.py](scripts/02_export_maedeh_warehouse.py) | [prepare.py](raj_lakehouse/prepare.py): `export()` | Requires `WAREHOUSE_DSN`; verifies seven relations and exports ordered `SELECT *` queries in one read-only repeatable-read database transaction. Temporary CSVs are published only after export completes. |
| `scripts/08_register_warehouse_csv.py` | `prepare.register_csv()` | Checks seven filenames and registers a user-supplied handoff; exporter must confirm a common snapshot. It does not prove that provenance. |
| [scripts/03_build_lakehouse.py](scripts/03_build_lakehouse.py) | [build.py](raj_lakehouse/build.py): `index()`, `normalise()`, `build()` | Validates dimensions/relationships and activity, then overwrites bronze, silver, gold and audit Delta snapshots. |
| [scripts/04_report_activity_trends.py](scripts/04_report_activity_trends.py) | [report.py](raj_lakehouse/report.py): `report()`, `chart()`, `render_page()` | Checks input fingerprint; queries gold through DuckDB, writes monthly Delta aggregate, CSV/SVG/JSON evidence and two equivalent HTML report filenames. |
| [scripts/05_verify_results.py](scripts/05_verify_results.py) | [verify.py](raj_lakehouse/verify.py): `verify()` | Performs 16 reconciliation checks; writes JSON and exits nonzero if any fail. |
| [scripts/06_delta_history.py](scripts/06_delta_history.py) | `verify.history()` | Reads gold activity's Delta version/history and, when available, previous-version row count. |
| [scripts/07_consolidate_sql.py](scripts/07_consolidate_sql.py) | [consolidate.py](raj_lakehouse/consolidate.py): `consolidate()` | Inventories SQL/Cypher and hashes; requires `team_sql/order.json`. Does not execute SQL. |
| Package support | [common.py](raj_lakehouse/common.py): `read_input()`, `fingerprint()`, `location()`, `dump()`; [cli.py](raj_lakehouse/cli.py): `main()` | Mode-specific paths/provenance, SHA-256 input identity, JSON replacement and CLI dispatch. |

CLI mode defaults to `dataset-preview`. **Always pass `--mode warehouse` for build/report/verify/history against the shared warehouse.** Export itself always uses the warehouse route. Offline `prepare.preview()` uses the supplied mapping reference and assigns preview surrogate keys; it is not a connection to Maedeh's database.

## Seven-table handoff

`export()` checks `to_regclass()` for every required table before exporting any. Each [warehouse export query](sql/warehouse_export) orders by its surrogate key. CSV destinations are under `data/warehouse/`:

| Required PostgreSQL relation | Exported filename |
| --- | --- |
| `dw.dim_customer` | `dim_customer.csv` |
| `dw.dim_account` | `dim_account.csv` |
| `dw.dim_card` | `dim_card.csv` |
| `dw.dim_digital_user` | `dim_digital_user.csv` |
| `dw.fact_core_transaction` | `fact_core_transaction.csv` |
| `dw.fact_card_transaction` | `fact_card_transaction.csv` |
| `dw.fact_digital_event` | `fact_digital_event.csv` |

`data/warehouse/handoff.json` records mode, creation time, database and origin. The exporter does not modify PostgreSQL. Its database read is snapshot-consistent, but replacing the seven host CSVs is sequential, not a filesystem-wide atomic transaction. Do not build concurrently with export.

## Bronze, silver and gold semantics

| Layer/path beneath `output/warehouse/lakehouse/` | Actual contents |
| --- | --- |
| `bronze/<seven input table names>/` | Received warehouse snapshot with fields represented as strings. Preserves received CSV values/rows, not original CSV byte formatting or PostgreSQL types. **Already integrated upstream**, not raw disconnected source ingestion. |
| `silver/dim_customer/` | `customer_key`, `enterprise_customer_key` |
| `silver/dim_account/`, `silver/dim_card/`, `silver/dim_digital_user/` | Surrogate key, natural entity ID and `customer_key`, after dimension validation |
| `silver/activity_event/` | Accepted standard activity records with source-prefixed activity ID, enterprise customer, source entity, timestamp, activity/status, decimal amount, currency, direction, synthetic label and out-of-window flag |
| `gold/fact_activity/` | **The same accepted Arrow table** passed to `silver/activity_event` in `build()`. No further gold filtering or aggregation occurs here. |
| `gold/dim_customer/` | Enterprise customer key, segment, risk category and state |
| `gold/monthly_activity/` | Separate all-history DuckDB aggregate created by `report.report()`, not by `build()` |
| `audit/quality_issues/` | Rejected-row reasons and retained-row warnings, with severity/source/record ID |

`normalise()` runs before any Delta write. Fatal dimension problems stop the build. Successful validation is followed by independent `mode='overwrite'` Delta writes, not a single transaction across all tables.

### Logical layer diagrams

The supplied diagrams show logical keys and relationships, not declared Delta primary-key or foreign-key constraints. Row counts shown are recorded baseline observations for the supplied synthetic snapshot, not newly executed results or universal targets. `TIMESTAMP_NTZ` denotes the unzoned timestamp semantics used by the Arrow schema.

#### Bronze: received warehouse snapshots

![Bronze logical model of the seven integrated warehouse snapshots](https://github.com/user-attachments/assets/4a447e70-15f1-4382-9132-e91a9a45ae3e)

*Figure 1. Bronze preserves the seven received warehouse tables as string-valued Delta snapshots. Identity integration has already occurred in PostgreSQL; the connecting keys describe inherited logical relationships.*

#### Silver: identity references and accepted activity

![Silver logical model of identity references and standardised activity events](https://github.com/user-attachments/assets/03841474-ce2d-4deb-862f-0b7e968843a3)

*Figure 2. Silver retains key references in four dimensions and standardises accepted records into `activity_event`. Dashed source-entity joins depend on `source_system`; `audit/quality_issues` is a separate sidecar. Relationship checks run in Python.*

#### Gold: detailed activity and monthly aggregation

![Gold logical model of customer activity and derived monthly summaries](https://github.com/user-attachments/assets/54b423c6-cb57-4ffc-b721-87a1e5f9e4dc)

*Figure 3. Gold exposes `dim_customer` and `fact_activity`; the latter receives the same accepted Arrow table as silver `activity_event`. `report.py` separately derives `monthly_activity` through DuckDB aggregation. The dashed arrow indicates lineage, not a foreign key.*

### Actual validation and warning rules

| Condition | Implemented policy |
| --- | --- |
| Empty dimensions; blank/duplicate customer surrogate or enterprise key | Stop with `ValueError`. |
| Blank/duplicate account/card/digital-user surrogate or natural ID | Stop; these dimension indexes must be unique. Whitespace is not explicitly trimmed. |
| Account/card/digital user references unknown `customer_key` | Stop the build. |
| Empty warehouse table | Build raises an error; this check occurs during the bronze loop, so earlier tables may already have been written. |
| Missing/duplicate source activity ID | Reject every occurrence of that ID within its fact source, not just later duplicates. Fact surrogate-key uniqueness is not separately checked. |
| Fact references unknown dimension surrogate key | Reject with `unmatched_dimension_key`. |
| Timestamp unparseable/missing or timezone-aware | Reject with `invalid_or_zoned_timestamp`. ISO-format source wall-clock timestamps are preserved as unzoned microsecond timestamps; no timezone or UTC conversion is inferred. |
| Amount invalid | Reject nonfinite, negative, over-two-decimal, or ≥10^16 values. Core/card amounts are required. Digital amounts may be absent except for exact activity types `Fund Transfer` and `BPAY Payment`. Values are not silently rounded. |
| Fraud indicator | Accept case-normalised `TRUE`, `FALSE`, `T`, `F`; reject other values. These remain synthetic labels. |
| Activity type/status missing | Reject. Digital `Login` uses `login_status`; other activities use `transaction_status`. No comprehensive status/type enumeration is enforced. |
| Core/card currency | Must be three uppercase alphabetic characters; this is format validation, not verification against a currency registry. |
| Digital currency absent from input contract | A digital amount gets `UNSPECIFIED` plus a warning; an amount-free event gets null currency. No AUD inference. |
| Outside 2024-01-01 through 2026-09-30 inclusive | Retain accepted records, set `outside_reporting_window`, record a warning. Older card history is not discarded. |

Custom report dates do not change the build's default-window warning flag. A row may generate multiple warnings; warning totals are not counts of distinct problematic events.

## Reporting, audit and Delta evidence

Report 1 registers gold activity as an Arrow table in DuckDB and runs [sql/report_1](sql/report_1). `01_monthly_activity.sql` groups all retained history; `report()` separately filters exact inclusive dates before regrouping the selected window, so partial months are handled. `02_successful_values.sql` covers successful core/card values by source/currency; digital amounts are excluded from that comparison. Status detail includes failures/reversals/pending records, and the customer timeline uses all retained history (HTML shows up to 100 rows; CSV keeps all matches).

Counts are source records, not unique banking operations; a digital event and core posting may describe the same operation. Gross recorded value is not a net balance or fraud loss. No exchange-rate conversion is implemented.

| Output | Meaning |
| --- | --- |
| `data/warehouse/handoff.json` | Input provenance declaration; does not contain a DSN |
| `output/warehouse/build_summary.json` | Source fact totals, accepted/rejected totals, source counts and warning frequencies |
| `output/warehouse/lakehouse/audit/quality_issues/` | Delta table of REJECT/WARNING records; rejected input stays available in bronze |
| `output/warehouse/lakehouse/manifest.json` | Mode, origin, creation time, input hash, timestamp policy and table versions/row counts; report step adds monthly aggregate metadata |
| `output/warehouse/verification.json` | Boolean result, 16 individual checks and currency-separated monetary reconciliation |
| `output/warehouse/delta_history.json` | Current gold activity version, rows, Delta history and previous-version row count when version > 0 |
| `output/warehouse/reports/` | HTML brief/trends, monthly all-history and selected-window CSVs, successful-values/status/timeline CSVs, `monthly_activity.svg`, `report_1_metrics.json` |

`fingerprint()` hashes each of the seven table names plus its CSV bytes in fixed order with SHA-256. It excludes `handoff.json`. Reporting rejects inputs whose hash differs from the completed build manifest; verification also checks it. This detects changed input bytes, not authoritative origin or independent data correctness. JSON files are individually replaced through temporary files; this does not make the whole pipeline atomic.

Each table has its own `_delta_log` and version sequence. Re-running overwrites its current snapshot while normally advancing history. `history()` inspects **gold/fact_activity only**, not an all-table audit. Delta history is not CDC, an immutable backup, or a guarantee that old files remain available indefinitely.

## Run only Raj's component (PowerShell)

Prerequisites: the external shared lab is running, its PostgreSQL warehouse is already loaded, `python` and `postgres` are Compose service names, and `<LAB_PATH>\workspace` is mounted at `/workspace`. Do not use `run_all.ps1` for this route: it resets the whole project. These commands read PostgreSQL and replace Raj's exported/current derived files only.

Replace `<LAB_PATH>` and the DSN placeholders using your private lab credentials. The DSN uses the **container-network** PostgreSQL host (normally `postgres`) and container port 5432; URL-encode credential characters where needed. Do not commit the value. The password prompt keeps the DSN out of the command text.

```powershell
Set-Location '<LAB_PATH>'
$Py = (docker compose -f .\docker-compose.yml ps -q python).Trim()
if (-not $Py) { throw 'Start the external lab Python service first.' }
$Raj = '/workspace/horizon/raj/scripts'
docker exec $Py python -m pip install -r /workspace/horizon/raj/requirements.txt
$PrivateDsn = Read-Host 'Enter postgresql://<USER>:<PASSWORD>@postgres:5432/<DATABASE>' -AsSecureString
$env:WAREHOUSE_DSN = [System.Net.NetworkCredential]::new('', $PrivateDsn).Password
try {
    docker exec -e WAREHOUSE_DSN $Py python "$Raj/02_export_maedeh_warehouse.py"
    if ($LASTEXITCODE -ne 0) { throw 'Warehouse export failed.' }
} finally {
    Remove-Item Env:WAREHOUSE_DSN -ErrorAction SilentlyContinue
    $PrivateDsn = $null
}
foreach ($Script in @('03_build_lakehouse.py', '04_report_activity_trends.py', '05_verify_results.py', '06_delta_history.py')) {
    docker exec $Py python "$Raj/$Script" --mode warehouse
    if ($LASTEXITCODE -ne 0) { throw "Failed: $Script" }
}
Start-Process .\workspace\horizon\raj\output\warehouse\reports\Report_1_Activity_Brief.html
```

Pinned dependencies in [requirements.txt](requirements.txt): `deltalake==1.2.1`, `pyarrow==21.0.0`, `duckdb==1.4.1`, `psycopg[binary]==3.2.10`. Internet/package access is needed for installation. Docker passes the private DSN to the export process; the script does not persist it in handoff metadata.

To change only the report window/customer after a valid build:

```powershell
docker exec $Py python "$Raj/04_report_activity_trends.py" --mode warehouse --start 2024-01-01 --end 2026-09-30 --customer ENT_C000001
docker exec $Py python "$Raj/05_verify_results.py" --mode warehouse
```

Change the ISO dates and enterprise customer key as required. Report generation overwrites the monthly aggregate and report files, even for a custom window; the monthly Delta table always covers all history. If using manually supplied seven CSVs, run `08_register_warehouse_csv.py` instead of export, confirm their common snapshot yourself, then build/report/verify/history. Do not mix preview inputs with warehouse evidence.

## The 16 reconciliation checks

Verified against `verify.verify()` (two initial checks, four per source, two final checks):

| # | Check |
| --- | --- |
| 1 | Input snapshot fingerprint matches completed build manifest |
| 2 | Gold activity IDs are unique |
| 3 | CORE accepted source record IDs match gold |
| 4 | CORE accepted plus rejected source rows account for input |
| 5 | CORE accepted monetary sums reconcile by currency |
| 6 | CORE accepted synthetic-label count is preserved |
| 7 | CARD accepted source record IDs match gold |
| 8 | CARD accepted plus rejected source rows account for input |
| 9 | CARD accepted monetary sums reconcile by currency |
| 10 | CARD accepted synthetic-label count is preserved |
| 11 | DIGITAL accepted source record IDs match gold |
| 12 | DIGITAL accepted plus rejected source rows account for input |
| 13 | DIGITAL accepted monetary sums reconcile by currency |
| 14 | DIGITAL accepted synthetic-label count is preserved |
| 15 | All-history monthly event counts sum to gold row count |
| 16 | Digital monetary rows retain `UNSPECIFIED`, never silently AUD |

Monetary totals are independently summed from accepted input with `Decimal`; normalisation is not reused. Rejected membership is determined by audit `(source_system, source_record_id)` pairs. These checks validate the seven-table handoff → gold/report path, not upstream source-to-warehouse ETL, every silver/bronze value, all monthly measures or other workstreams.

### Recorded baseline observations

These values come from committed [build_summary.json](output/warehouse/build_summary.json), [verification.json](output/warehouse/verification.json), [report_1_metrics.json](output/warehouse/reports/report_1_metrics.json) and Delta artifacts. **They were not newly executed for this documentation update and are not universal acceptance targets.**

| Observation | Recorded value |
| --- | --- |
| Source fact rows / accepted / rejected | 28,500 / 28,500 / 0 |
| Accepted by source | CORE 9,500; CARD 9,500; DIGITAL 9,500 |
| Selected default-window records | 24,366 |
| Retained out-of-window records | 4,134; baseline card history starts 2018-01-29 |
| Digital amounts with unspecified currency | 765 |
| Digital amount reconciliation | 285,107.09 `UNSPECIFIED`; not a currency-comparable banking total |
| Recorded verification | All 16 checks true; source/gold currency differences zero |
| Committed Delta snapshots | Version 0 and 1 logs are present; versions depend on reruns |

Zero rejected records means the implemented rules accepted this snapshot, not that all data is correct. Historical integrated notes also report 338 synthetic fraud labels; treat that as a recorded dataset observation, not a detector performance metric.

## SQL consolidation and missing prerequisites

`consolidate()` scans `sql/` and `team_sql/` for `.sql`/`.cypher`, records inferred engine/owner, SHA-256 and execution-status caveats, reads `team_sql/order.json`, then writes `consolidated/script_inventory.json` and `warehouse_export_queries.sql`. It does not run scripts or prove they executed successfully. Inferred ownership/engine labels require review; even the Maedeh execution wording is a reported historical claim, not independent evidence.

**`horizon/raj/team_sql/order.json` and the `team_sql/` directory are absent in the inspected repository.** Running `scripts/07_consolidate_sql.py` currently fails while reading that required order file. It is not called by the integrated runner. Restore an owner-confirmed script/order handoff before using consolidation; do not treat owner folders elsewhere as automatically inventoried by this function.

The shared lab `docker-compose.yml` is also external. [tests/test_lakehouse.py](tests/test_lakehouse.py) loads `dataset-preview`, not `warehouse`; its required preview handoff is not committed here, so the warehouse CSVs alone do not satisfy that unit-test setup. Preparing preview additionally requires the source ZIP layout used by `prepare.preview()`; the default `input/team_dataset.zip` is absent. No successful unit-test or live lab run is claimed here.

## Limitations

Relationships are checked in Python, not declared Delta primary-key/foreign-key constraints. Silver and gold activity currently duplicate the same accepted table; the layer naming does not imply extra transformation. Tables are local snapshots, processing materialises inputs in memory, and writes are not atomic across tables. A failure can leave a partially updated lakehouse with a stale manifest; finish a successful build/report/verification before using results.

Delta versions provide table-level history, not continuous source change capture or immutable backup. Synthetic fraud labels, supplied identity mappings, unzoned timestamps and missing digital currency constrain interpretation. No unstructured ingestion or automatic downstream refresh after live staging events is implemented.
