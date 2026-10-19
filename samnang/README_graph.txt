Horizon Retail Bank - Graph workstream (relationship analysis)
32113 Advanced Database - Assignment 2

FILES
  06_graph_layer.sql                 builds the graph schema from dw
  06b_import_fraud_scenarios.sql     loads fraud_scenario_reference.csv
                                     (answer key, used only for check V6)
  07_report2_connected_entities.sql  Report 2 views, report queries, validation
  08_load_graph_to_neo4j.py          copies the graph into the lab's Neo4j
  09_report2_neo4j.cypher            Report 2 as pictures in Neo4j Browser

NEO4J (after 06 has run in PostgreSQL)
  1. Copy 08 and 09 into the lab's workspace folder, e.g.
     C:\advanced-database-lab\workspace\horizon\
  2. In PowerShell, from the lab folder:
       docker exec -it student-python python /workspace/horizon/08_load_graph_to_neo4j.py
     If the warehouse is not in the "lab" database, add the name:
       docker exec -it -e PG_DBNAME=horizon_dw student-python python /workspace/horizon/08_load_graph_to_neo4j.py
  3. The script ends with a PostgreSQL -> Neo4j count check that must
     say RESULT: MATCH (47578 nodes, 55578 relationships, 342 links).
  4. Open http://localhost:7474, log in as neo4j / password, and run the
     queries in 09 one at a time. N3-N9 draw the rings as networks.
  Safe to re-run: it replaces the previous Horizon graph in Neo4j.

REQUIREMENTS
  The warehouse already loaded in the same database
  (Maedeh's 01 -> 02 -> 02b -> 03 -> 04). No extensions needed.
  Tested on PostgreSQL 16 with the full Horizon dataset; uses only
  features from PostgreSQL 13+. 06 takes about 4 seconds.

HOW TO RUN (CloudBeaver SQL editor on the database that holds staging and dw)
  1. Open 06_graph_layer.sql and run the whole file with Execute script
     (Alt+X), not Ctrl+Enter. It ends with a node/edge count table.
  2. Open 06b_import_fraud_scenarios.sql. Change the CSV path to where
     the file is on the database server (e.g. /tmp/horizon_data/ after
     docker cp). Execute script.
  3. Open 07_report2_connected_entities.sql.
     Run Part A (the four CREATE VIEW statements) once.
     Run each Part B query (R2.1 - R2.8) on its own and screenshot it.
     Run each Part C check (V1 - V6) and confirm the expected result.

  If CloudBeaver has trouble with the procedure/function blocks in 06,
  run the file with psql inside the container instead:
    docker cp 06_graph_layer.sql student-postgres:/tmp/
    docker exec -it student-postgres psql -U student -d lab -f /tmp/06_graph_layer.sql

AFTER A NEW WAREHOUSE LOAD
  CALL graph.refresh_graph();
  (Views in 07 do not need to be recreated.)

RE-RUNNING 06
  06 drops and recreates the whole graph schema, including the 07 views.
  Re-run 07 Part A afterwards. Do not put other objects in the graph
  schema, as they would be dropped too.

WHAT IS IN THE GRAPH (Horizon dataset)
  10 node types, about 47,600 nodes and 55,600 edges, covering all three
  source systems. Note: on card transactions, device_reference is the
  merchant's terminal or payment gateway (see Schema.xlsx), so it is a
  TERMINAL node, not a customer DEVICE.

HOW CUSTOMERS ARE LINKED
  Shared device or shared IP address   -> always a link
  Shared payee / external account /
  card terminal                        -> only if 2+ customers sent
                                          fraud-flagged activity through it
  Anything shared by more than 10 customers (billers, popular merchants,
  office IPs) is a supernode and never links customers.

SETTINGS (table graph.config), change then CALL graph.refresh_graph();
  max_customers_per_entity            default 10
  min_fraud_customers_for_weak_link   default 2

USEFUL FUNCTION
  SELECT * FROM graph.fn_neighbourhood('CUSTOMER:ENT_C000021', 4);

EXPECTED RESULTS (Horizon dataset)
  V1  graph node counts = warehouse counts (5000 / 7500 / 5000 / 4000)
  V2  graph event counts = fact counts on all 5 rows
  V3  338 = 338 fraud flags
  V4  0 bad links
  V5  0 customers without a cluster, 0 links crossing clusters
  V6  Shared Device Ring (5), Suspicious Beneficiary (7), Account
      Takeover (7) and Rapid Transaction Burst (8): each found as ONE
      group at HIGH priority. Benign Shared Device: one group at LOW.
