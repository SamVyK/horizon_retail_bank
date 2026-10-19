HORIZON RETAIL BANK - RUNNING THE PROTOTYPE IN THE LAB ENVIRONMENT
32113 Advanced Database - Assignment 2

Builds Maedeh's integrated warehouse (staging + dw) and Samnang's graph
layer (graph) inside the lab's PostgreSQL database "lab", then copies the
graph into Neo4j. Rehearsed end to end on a fresh database twice.

FOLDER LAYOUT (inside your lab folder, e.g. C:\advanced-database-lab)
  workspace\horizon\data\     the 9 CSV files (the 8 source files +
                              fraud_scenario_reference.csv)
  workspace\horizon\sql\      the SQL files from this bundle
  workspace\horizon\python\   08_load_graph_to_neo4j.py, 09_report2_neo4j.cypher

FILES THAT DIFFER FROM MAEDEH'S ORIGINALS
  01_create_schemas_lab.sql   only the two CREATE SCHEMA lines (the lab
                              database already exists)
  02b_import_staging_lab.sql  CSV path changed to /tmp/horizon_data/
  00_reset_lab.sql            new, optional: wipe and start again
  02, 03, 04, 05 are unchanged.

------------------------------------------------------------------
STEP 1  Start the lab (PowerShell, in the lab folder)
  docker compose start

STEP 2  Copy the CSVs into the PostgreSQL container
  docker cp .\workspace\horizon\data student-postgres:/tmp/horizon_data
  docker exec -u root student-postgres chmod -R a+rX /tmp/horizon_data
  docker exec student-postgres ls /tmp/horizon_data
  -> must list the 9 CSV files.
  (If /tmp/horizon_data already exists, remove it first:
   docker exec -u root student-postgres rm -rf /tmp/horizon_data)

STEP 3  Open a SQL editor on the lab database in CloudBeaver
  http://localhost:8978 -> PostgreSQL@postgres -> Databases -> lab
  Select "lab", then click the SQL button in the top toolbar.
  Check the editor toolbar shows the lab database.

  For every SQL file below:
    a. Open the file in VS Code, Ctrl+A, Ctrl+C.
    b. In the CloudBeaver editor: Ctrl+A, Delete, Ctrl+V.
    c. Run the WHOLE file with Execute script (Alt+X, or the
       "execute script" button). Ctrl+Enter only runs one statement.

STEP 4  Warehouse (Maedeh)                              expected result
  01_create_schemas_lab.sql      no rows; F5 on lab shows staging, dw
  02_create_staging_tables.sql   no rows; staging has 8 tables
  02b_import_staging_lab.sql     counts: 5000 7500 9500 5000 9500 4000 9500 5000
  03_create_warehouse_tables.sql no rows; dw has 7 tables
  04_load_warehouse.sql          no rows (COMMIT)
  05_validation_checks.sql       run checks one at a time (Ctrl+Enter);
                                 values in Maedeh's README

STEP 5  Graph (Samnang)
  06_graph_layer.sql             last result: node/edge counts (19 rows)
  06b_import_fraud_scenarios.sql 10 scenario types
  07_report2_connected_entities.sql
                                 Execute script once (creates the views),
                                 then re-run R2.x / V1-V6 one at a time
                                 with Ctrl+Enter for screenshots

STEP 6  Neo4j (Samnang)
  docker exec -it student-python python /workspace/horizon/python/08_load_graph_to_neo4j.py
  -> must end with "RESULT: MATCH"
  Open http://localhost:7474 (neo4j / password), run 09 queries one by one.

------------------------------------------------------------------
IF SOMETHING GOES WRONG
  "could not open file ... No such file"  -> repeat Step 2 and check ls.
  "Staging already contains data"         -> 02b already ran; carry on
                                             from 03, or reset (below).
  "relation ... already exists"           -> 02 or 03 already ran; reset.
  "current transaction is aborted"        -> run ROLLBACK; then fix and
                                             re-run the whole file.
  CloudBeaver error near "$$" in 06       -> use the psql route below.

  RESET: run 00_reset_lab.sql, then start again from 01.

  PSQL ROUTE (runs everything without CloudBeaver; also good for the demo):
    docker cp .\workspace\horizon\sql student-postgres:/tmp/horizon_sql
    foreach ($f in "01_create_schemas_lab","02_create_staging_tables","02b_import_staging_lab","03_create_warehouse_tables","04_load_warehouse","06_graph_layer","06b_import_fraud_scenarios","07_report2_connected_entities") { docker exec student-postgres psql -U student -d lab -v ON_ERROR_STOP=1 -f /tmp/horizon_sql/$f.sql }
