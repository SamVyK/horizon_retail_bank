# Horizon Retail Bank – Data Fabric (Governance Layer)

32113 Advanced Database – Assignment 2
Owner: Shubham Bhardwaj (25755442)

The data fabric workstream adds a governance layer on top of the
integrated warehouse. It does not move or change warehouse data. It
**describes** the data (catalog), **traces** it (lineage), **tests** it
(data quality) and **protects** it (roles and masked views).

## Files

| File | Purpose |
|---|---|
| `06_governance_setup.sql` | Creates schemas `governance` and `secure`, the catalog, lineage, quality rules, functions, roles and masked views |
| `07_run_governance.sql` | Runs one governance cycle: refresh catalog, run all quality rules, show results |
| `08_report3_lineage_quality.sql` | Report 3: creates report views (Part A) and runs queries R3.1–R3.15 (Part B) |
| `run_governance.py` | Optional: runs 06 → 07 → 08 from the lab Python container and prints every result |

## Run order

The warehouse must exist first:

```
01 → 02 → 02b → 03 → 04 → 05   (integrated warehouse, Maedeh)
06 → 07 → 08                   (data fabric, this folder)
```

All three governance scripts are safe to re-run. Re-running 06 resets
the governance metadata and quality history. Re-running 07 adds a new
quality run, which builds the trend shown in R3.14.

## Running in the Lab Environment

Docker Desktop must be running and `docker ps` must show
`student-postgres` and `student-python`.

### Option A – psql inside the Postgres container (most reliable)

From the `advanced-database-lab` folder:

```bash
# copy the governance scripts into the Postgres container
docker cp workspace/governance student-postgres:/tmp/governance

# run them in order against horizon_dw
docker exec -it student-postgres psql -U student -d horizon_dw -f /tmp/governance/06_governance_setup.sql
docker exec -it student-postgres psql -U student -d horizon_dw -f /tmp/governance/07_run_governance.sql
docker exec -it student-postgres psql -U student -d horizon_dw -f /tmp/governance/08_report3_lineage_quality.sql
```

### Option B – CloudBeaver

1. Create a connection to database **horizon_dw** (host `postgres`,
   port `5432`, user `student`, password `student`).
2. Open each script in a SQL editor and run it with **Execute script**
   (Alt+X), not Execute statement.
3. The access test (R3.15) prints NOTICE messages in the output panel.

### Option C – Python runner

Place this folder at `workspace/governance`, then:

```bash
docker compose exec python python /workspace/governance/run_governance.py
docker compose exec python python /workspace/governance/run_governance.py --report-only
```

## Expected results (tested on the supplied synthetic data)

| Check | Expected |
|---|---|
| Objects catalogued (first run of 07) | 27 |
| Lineage flows | 27 |
| Quality rules | 21 (20 control, 1 profile) |
| Rules passed / failed / info / errors | 15 / 5 / 1 / 0 |
| Row-level pass rate | 95.46% |
| Layer reconciliation | all 7 entities RECONCILED |
| Access matrix | all 18 checks OK |
| Access test | fraud_analyst and compliance_auditor DENIED on `dw.dim_customer`, ALLOWED on `secure.v_customer_masked` |

The five failing rules are real findings in the source data, not errors
in the scripts:

| Rule | Finding |
|---|---|
| DQ_TIM_01 | 3,186 of 4,504 ACTIVE cards are past their expiry date |
| DQ_TIM_02 | 4,134 card transactions fall outside the 2024–2026 window in the data dictionary |
| DQ_CON_03 | 86 card transactions occur outside the card's issue–expiry period |
| DQ_UNI_01 | 303 customers share an email with another customer |
| DQ_CON_05 | 2 digital events occur before the user registered |

DQ_TIM_01 depends on today's date, so its count can grow over time.

## Troubleshooting

| Message | Cause and fix |
|---|---|
| `Warehouse not found` | Not connected to `horizon_dw`, or scripts 01–05 have not run |
| `permission denied to create role` | The `student` login is not a superuser. Run 06 as the Postgres admin user, or ask for CREATEROLE |
| `relation governance.v_... does not exist` | 08 was run before 07, or 06 was re-run after 08. Run 07 then 08 |
| `No module named psycopg2` (Option C) | Use Option A or B, or install with `pip install psycopg2-binary` in the Python container |

## How the pieces work (for the presentation)

**Catalog.** `refresh_catalog()` reads PostgreSQL's own metadata
(`information_schema`) for every schema listed in
`governance.managed_schema`, counts rows with dynamic SQL, and joins the
business owner and description from `governance.table_description`.
Technical metadata is collected automatically; only business meaning is
written by hand.

**Sensitivity classification.** `classify_column()` tags each column
from its name: PII_DIRECT, PII_QUASI, DEVICE_NETWORK, FINANCIAL,
IDENTIFIER or GENERAL. New columns are classified as soon as the catalog
refreshes. This is a simple form of the "active metadata" idea behind a
data fabric.

**Lineage.** `governance.lineage` stores one row per data flow, naming
the script that performs it. `trace_upstream()` walks the flows
backwards with a recursive query (`WITH RECURSIVE`), so any warehouse
table can be traced back to its source CSV files.

**Quality.** Rules are stored as data in `governance.dq_rule`. Each rule
holds SQL that returns `(rows_checked, rows_failed)`.
`run_quality_checks()` runs each rule with `EXECUTE` and records results
per run. Each rule runs in its own exception block, so one broken rule
is logged as ERROR without stopping the run. Most rules come from the
business rules in the source data dictionary (`Schema.xlsx`).

**Access.** Three group roles represent job functions. Masked views in
schema `secure` hide direct identifiers. Because a view runs with its
owner's privileges, analysts can read the view without any access to
the underlying table. `v_access_matrix` compares the documented policy
with what PostgreSQL actually enforces (`has_table_privilege`).

## Adding another workstream to the catalog

To catalog a new schema (for example the lakehouse layer), run:

```sql
INSERT INTO governance.managed_schema VALUES
  ('lakehouse_gold', 'LAKEHOUSE', 5, 'Raj Chhadia', 'Gold-layer analytical tables');
INSERT INTO governance.lineage
  (source_object, target_object, lineage_type, transformation_script, transformation_summary)
VALUES ('dw.fact_core_transaction', 'lakehouse_gold.<table>', 'TRANSFORM',
        '<script name>', '<what the script does>');
```

Then run 07 again.
