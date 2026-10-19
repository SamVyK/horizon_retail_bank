Horizon Retail Bank – Integrated Data Warehouse
32113 Advanced Database – Assignment 2

IMPLEMENTATION ENVIRONMENTS
The warehouse was initially developed and tested locally using
PostgreSQL and pgAdmin in the horizon_dw database.

The integrated team prototype was subsequently run using PostgreSQL
in the Docker lab environment, with warehouse validation repeated
through CloudBeaver against the lab database.

For the integrated setup and execution order, follow
README_INTEGRATED.txt in the parent horizon folder.
The local setup instructions below describe the original standalone
warehouse implementation.

PURPOSE
Integrate the supplied Core Banking, Card Processing and
Digital Banking CSV datasets in PostgreSQL.

The staging schema retains raw source values as text.
The dw schema contains four dimensions and three fact tables.
Customer identities are linked using entity_mapping_reference.csv.

REQUIREMENTS
- PostgreSQL and pgAdmin.
- Tested with PostgreSQL 18.
- Permission to create the horizon_dw database if it does not exist.
- The six SQL files listed below:
  01_create_schemas.sql
  02_create_staging_tables.sql
  02b_import_staging.sql
  03_create_warehouse_tables.sql
  04_load_warehouse.sql
  05_validation_checks.sql
- The eight original CSV files supplied with the dataset.

EXECUTION ORDER – NEW DATABASE
1. Open pgAdmin Query Tool connected to the postgres database.
   In 01_create_schemas.sql, select and execute only:
   CREATE DATABASE horizon_dw;
   Auto-commit must be enabled. Do not use BEGIN/COMMIT.
   Skip this statement if horizon_dw already exists.

2. Open a new Query Tool connected to horizon_dw.
   In 01_create_schemas.sql, select and execute only the two
   CREATE SCHEMA statements.
   Do not run the entire 01 file at once.

3. Run 02_create_staging_tables.sql.

4. Import the eight CSV files using either method below.

5. Run 03_create_warehouse_tables.sql.

6. Run the entire 04_load_warehouse.sql.

7. Run the checks in 05_validation_checks.sql individually
   to inspect each result.

CSV IMPORT
Each CSV must be imported into its matching staging table:

core_customers.csv           -> staging.core_customers
core_accounts.csv            -> staging.core_accounts
core_transactions.csv        -> staging.core_transactions
cards.csv                    -> staging.cards
card_transactions.csv        -> staging.card_transactions
digital_users.csv            -> staging.digital_users
digital_events.csv           -> staging.digital_events
entity_mapping_reference.csv -> staging.entity_mapping_reference

Method A – SQL:
Edit all eight paths in 02b_import_staging.sql to point to
the CSV folder, then run the entire file.
Use forward slashes in Windows paths.
The files must be accessible to the PostgreSQL server
and readable by its service account.
The database role must have permission for server-side COPY.
The script refuses to import if staging already contains data.
If an import fails, run ROLLBACK; in the same Query Tool
before correcting the problem and retrying.

Method B – pgAdmin:
Right-click each staging table and select Import/Export Data.
Choose Import and the matching CSV file.
Use CSV format, Header Yes, delimiter comma, and double
quotes for both Quote and Escape.
Preserve the original CSV column order.

Use only one import method. Do not import the same data twice.

TRANSFORMATION POLICY
- Remove leading and trailing whitespace from text fields.
- Convert emails to lowercase.
- Remove whitespace from phone numbers and convert recognised
  Australian local numbers to international +61 format.
- Preserve other phone formats after whitespace removal.
- Convert selected codes and status fields to uppercase;
  other categories retain their source case.
- Convert date, timestamp, numeric and Boolean fields
  to their warehouse data types.
- Resolve warehouse foreign keys through source IDs
  and the supplied customer mapping.
- Retain source fraud indicators and risk scores.
  These are source labels, not calculated fraud predictions.

EXPECTED WAREHOUSE ROW COUNTS
dim_customer             5000
dim_account              7500
dim_card                 5000
dim_digital_user         4000
fact_core_transaction    9500
fact_card_transaction    9500
fact_digital_event       9500

VALIDATION
The validation script checks:
- Staging counts and customer mappings.
- Warehouse counts.
- Source transactions/events missing from the warehouse:
  expected 0 for each source.
- Source and warehouse amount totals:
  expected difference 0; card totals are checked by currency.
- Customer integration across the three systems.
- Fraud label preservation:
  expected TRUE counts are core 105, card 112, digital 121;
  expected label mismatches are 0.
- Phone and email consistency:
  expected 4000 linked users, 4000 phone matches
  and 4000 email matches.

RERUNNING AND ERROR HANDLING
In 01, CREATE DATABASE runs once and must be skipped if
horizon_dw already exists. The two CREATE SCHEMA statements
can be rerun because they use IF NOT EXISTS.
02 and 03 create tables/indexes and should run once
on a new database.

04 uses ON CONFLICT DO NOTHING to skip existing business IDs.
It does not update existing records.
All seven loads run in one transaction.
If execution fails, run ROLLBACK; in the same Query Tool,
correct the error, then rerun the entire file.
A successful COMMIT completes the load.

05 is read-only and can be rerun.

DESIGN NOTES
Facts link to customers through the account, card
and digital user dimensions.
Monthly analysis can use the stored timestamps;
this prototype has no separate date dimension.
Account balances represent the supplied current snapshot.
The prototype does not maintain dimension change history.

REFERENCE FILES
Schema.xlsx describes the source fields.
fraud_scenario_reference.csv is a separate validation reference;
it is not imported by these warehouse scripts.

DIAGRAMS
ERD2.jpg shows warehouse columns, keys and relationships.
ERD.jpg additionally shows column data types.