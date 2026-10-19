HORIZON RETAIL BANK - INTEGRATED PROTOTYPE (LAB ENVIRONMENT)
32113 Advanced Database - Assignment 2

One folder, one run order, one script. Builds every working component
of the prototype in the lab containers, in the right order, and writes
a dated log that can be used as run evidence.

  Component                         Owner     Engine            Report
  --------------------------------  --------  ----------------  --------
  Staging + integrated warehouse    Maedeh    PostgreSQL        -
  Delta lakehouse                   Raj       Python + DuckDB   Report 1
  Graph layer (+ Neo4j copy)        Samnang   PostgreSQL, Neo4j Report 2
  Data fabric (governance)          Shubham   PostgreSQL        Report 3
  Change notifications (streaming)  Somit     PostgreSQL+Python demo only

  Somit's part (updated version, TRUNCATE removed) is included. It is a
  change-notification prototype: any insert/update/delete on
  staging.digital_users is pushed live to a Python listener. It does NOT
  apply fraud rules, raise alerts or produce a Report 4.
  -> Describe it in the report as exactly that (a working prototype of
     the event channel), not as live fraud alerting, and update the
     architecture diagram/summary to match.


FOLDER LAYOUT  (must be at <lab folder>\workspace\horizon)
  run_all.ps1              runs everything below, in order
  00_reset_all.sql         drops/rebuilds the 5 Horizon schemas
  data\                    put the 9 CSV files here (not included)
  maedeh\                  01-05 (01 and 02b are lab versions, see below)
  samnang\                 06, 06b, 07, register_graph_in_governance,
                           08 (Neo4j loader), 09 (Neo4j queries)
  shubham\                 06, 07, 08 governance + Report 3 (unchanged)
  somit\                   1-3 setup, insert/update/delete test feed,
                           listen.py (unchanged) and listen_lab.py
  raj\                     lakehouse package, scripts, SQL (unchanged)

  The 9 CSV files: core_customers, core_accounts, core_transactions,
  cards, card_transactions, digital_users, digital_events,
  entity_mapping_reference, fraud_scenario_reference (.csv)

  Changes made for integration (all other files are as their owners sent):
  - maedeh\01_create_schemas_lab.sql: only the two CREATE SCHEMA lines
    (the lab database already exists).
  - maedeh\02b_import_staging_lab.sql: CSV path /tmp/horizon_data/.
  - 00_reset_all.sql: new; also drops Shubham's governance/secure schemas.
  - samnang\register_graph_in_governance.sql: new; adds the graph to
    Shubham's catalog, lineage and quality rules.
  - somit\listen_lab.py: copy of listen.py with host "postgres" (the
    lab container name) instead of "localhost"; nothing else changed.
  - Everything runs in database "lab" (not horizon_dw). Shubham's and
    Raj's code work there unchanged.


HOW TO RUN  (PowerShell, in the lab folder, e.g. C:\advanced-database-lab)
  1. docker compose start
  2. powershell -ExecutionPolicy Bypass -File .\workspace\horizon\run_all.ps1

  Takes about 1-2 minutes (longer the first time: it installs Raj's 4
  Python libraries into the lab's Python container, needs internet).
  Stops at the first failing step and names it. Every step's output is
  saved in workspace\horizon\run_log_<date>_<time>.txt.
  Options: -SkipRaj, -SkipNeo4j, -SkipStreaming, -Database <name>

  Running the script again is safe: it always starts by resetting the
  five Horizon schemas and rebuilding them from the CSVs.


RUN ORDER  (what run_all.ps1 does; use this order in CloudBeaver too)
   1  00_reset_all.sql
   2  maedeh  01 -> 02 -> 02b -> 03 -> 04 -> 05
   3  samnang 06_graph_layer -> 06b_import_fraud_scenarios
              -> 07_report2_connected_entities
   4  shubham 06_governance_setup
   5  samnang register_graph_in_governance
   6  shubham 07_run_governance -> 08_report3_lineage_quality
   6b somit   1._create_extension_tcn -> 2._add_pk -> 3._create_trigger
              (his 2 and 3 fail if run twice on the same table; run_all
              always runs them on a freshly rebuilt staging, so they pass)
   7  raj     02 export -> 03 build -> 04 report -> 05 verify -> 06 history
              (all with --mode warehouse, in the lab Python container)
   8  samnang 08_load_graph_to_neo4j.py

  Why this order: Shubham's 06 resets governance, so the graph is
  registered after it; his 07 then catalogs and checks everything,
  including the graph. If anyone re-runs Shubham's 06 on its own, also
  re-run register_graph_in_governance and his 07.


EXPECTED RESULTS  (rehearsed twice on a fresh database with the
supplied dataset; each full SQL pass took about 7 seconds)

  Warehouse (Maedeh)
    dim_customer 5000, dim_account 7500, dim_card 5000,
    dim_digital_user 4000, each fact table 9500
    05 checks: 0 missing records, 0 amount differences, 338 fraud flags

  Graph (Samnang)
    47,578 nodes, 55,578 edges, 342 customer links
    Groups: HIGH 7 (33 customers), MEDIUM 8, LOW 78
    Planted scenarios found as ONE group each, HIGH: Shared Device Ring
    (5), Suspicious Beneficiary (7), Account Takeover (7), Rapid
    Transaction Burst (8). Benign Shared Device (2): one group, LOW.

  Governance (Shubham), combined run
    38 objects and 465 columns catalogued, 46 lineage flows
    23 rules: 17 PASS, 5 FAIL, 1 INFO, 0 ERROR
    (20 of Shubham's rules + 2 graph rules DQ_GRA_01/02, both PASS)
    Control rule pass rate 77.3%, row pass rate 95.97%
    Layer reconciliation 7/7 RECONCILED, access matrix 18/18 OK
    The 5 FAILs are real findings in the data (see Shubham's README).
    DQ_TIM_01 (expired active cards) grows slightly each day.
    NOTE: Shubham's README numbers (27 objects, 21 rules, 95.46%) are
    from his solo run; quote the combined-run numbers in the report.

  Lakehouse (Raj), from his README and an independent check of his
  validation on this warehouse
    Gold fact_activity 28,500 accepted, 0 rejected; 338 fraud labels
    4,134 older card records kept outside the 2024-2026 window
    765 digital amounts with unspecified currency
    05 verify: all checks PASS
    Report: raj\output\warehouse\reports\Report_1_Activity_Brief.html

  Change notifications (Somit)
    Insert 6 test users + 2 updates (3 rows) + delete = 15 live
    notifications in the listener; after delete_test_live.sql staging
    is back to 4,000 digital users and governance still shows 7/7
    RECONCILED with unchanged rule results.

  Neo4j (Samnang)
    Loader ends with: nodes 47578 -> 47578, relationships 55578 -> 55578,
    customer links 342 -> 342, RESULT: MATCH
    Browser: http://localhost:7474 (neo4j / password), queries in
    samnang\09_report2_neo4j.cypher


LIVE NOTIFICATION DEMO (Somit), after run_all.ps1 has finished
  Window 1 (keep open):
    docker exec -it student-python python /workspace/horizon/somit/listen_lab.py
  Window 2, one at a time, watching window 1:
    docker exec student-postgres psql -U student -d lab -f /tmp/horizon_sql/somit/insert_test_live_feed.sql
    docker exec student-postgres psql -U student -d lab -f /tmp/horizon_sql/somit/update_test_live_feed.sql
    docker exec student-postgres psql -U student -d lab -f /tmp/horizon_sql/somit/delete_test_live.sql
  ALWAYS finish with the delete script: the test rows sit in staging and
  would otherwise show up in Shubham's catalog and reconciliation.
  Ctrl+C stops the listener.


WHAT WAS NOT TESTED HERE
  The PostgreSQL steps were rehearsed for real (PostgreSQL 16; the lab
  uses 15, no newer features are used). Raj's Delta/DuckDB steps and the
  Neo4j connection could not be run outside the lab; their logic was
  tested against the same warehouse data. The first run_all.ps1 run in
  the lab confirms the rest. Check the log for "ALL STEPS COMPLETED".


STILL TO DO BEFORE SUBMISSION  (owners)
  Raj      Add comments in raj_lakehouse\*.py (brief: fully commented).
           tests\test_lakehouse.py line 11: 'dataset-preview' ->
           'warehouse', otherwise the tests need the preview data.
  Shubham  classify_column(): add display_name|customer_a_name|
           customer_b_name to the PII_DIRECT pattern, so customer names
           in the graph are tagged as personal data.
           Use database "lab" in his README instructions.
  Somit    Add comments to his scripts and fill in his readme.
           Make 2._add_pk.sql and 3._create_trigger.sql safe to re-run
           (e.g. DROP TRIGGER IF EXISTS before CREATE TRIGGER).
           The plan's end-to-end test + demo video are still his tasks.
  Maedeh   Retake warehouse screenshots in the lab (CloudBeaver), not
           pgAdmin; database is now "lab".
  All      Use numbers from the combined run (this README / run log).
  Team     Describe streaming as change notifications (no fraud alerts,
           no Report 4) in the architecture diagram, introduction and
           executive summary.


TROUBLESHOOTING
  "container ... is not running"   docker compose start in the lab folder
  "missing data\..."               copy all 9 CSVs into workspace\horizon\data
  "must be <lab folder>\workspace\horizon"
                                   move this folder there (the Python
                                   container only sees workspace)
  Raj install step fails           container has no internet; run once with
                                   internet, or use -SkipRaj and Raj's own
                                   compose.yaml (see raj\README.md)
  Neo4j step fails                 wait 30 s after docker compose start and
                                   re-run; or -SkipNeo4j and run 08 later
  Any FAILED step                  open the run log, read the error under
                                   the step name, fix, and re-run the script


INTERACTIVE DASHBOARD AND LIVE FRAUD ALERTS  (added 19 Oct 2026)
  run_all.ps1 / run_all_mac.sh now also:
    - install live fraud alerts (somit/live_lab/01_live_setup.sql):
      Somit's 4 rules from Live Events/fraud.py run in PostgreSQL triggers
      and write to staging.fraud_events
    - generate Horizon_Dashboard.html from the database
      (generate_dashboard.py; option -SkipDashboard to skip)
  For live alerts in the dashboard, keep this running in a second window:
      Windows:  python workspace\horizon\somit\live_lab\live_server.py
      Mac:      python3 workspace/horizon/somit/live_lab/live_server.py
  then open http://localhost:8765 (chapter G = Live events).
  Needs Python 3 on the computer (standard library only).
  Mac users: bash workspace/horizon/run_all_mac.sh (PostgreSQL parts).
