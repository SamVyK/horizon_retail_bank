-- =====================================================================
-- register_graph_in_governance.sql
-- Horizon Retail Bank | 32113 Advanced Database | Assignment 2
-- Owner: Samnang Vyvath Khun (graph workstream)
--
-- PURPOSE
-- Registers the graph workstream with Shubham's data fabric (governance
-- layer), following the "Adding another workstream to the catalog"
-- section of his README:
--   1. adds schema graph to the governed schemas
--   2. records the business meaning and owner of each graph table/view,
--      and of the fraud scenario answer key loaded by 06b
--   3. records lineage: warehouse -> graph tables -> report views
--   4. adds two data quality rules that check the graph against dw
--
-- RUN ORDER
--   After: 06_graph_layer.sql, 06b_import_fraud_scenarios.sql and
--          Shubham's 06_governance_setup.sql.
--   Then:  Shubham's 07_run_governance.sql (refreshes the catalog and
--          runs every rule, including the two below).
--   Safe to re-run (every insert is an upsert). If Shubham's setup
--   script is re-run, it resets governance, so run this file again.
-- =====================================================================


-- 0. Stop with a clear message if either layer is missing.
DO $$
BEGIN
    IF to_regclass('governance.managed_schema') IS NULL THEN
        RAISE EXCEPTION 'Governance layer not found: run Shubham''s 06_governance_setup.sql first.';
    END IF;
    IF to_regclass('graph.node') IS NULL THEN
        RAISE EXCEPTION 'Graph layer not found: run 06_graph_layer.sql first.';
    END IF;
END;
$$;


-- 1. Govern the graph schema (layer GRAPH is already allowed by the
--    CHECK constraint in Shubham's managed_schema table).
INSERT INTO governance.managed_schema
       (schema_name, layer, layer_order, technical_owner, description)
VALUES ('graph', 'GRAPH', 5, 'Samnang Vyvath Khun',
        'Property graph derived from dw: nodes, edges, customer links and clusters for relationship-based fraud analysis.')
ON CONFLICT (schema_name) DO UPDATE
   SET layer = EXCLUDED.layer, layer_order = EXCLUDED.layer_order,
       technical_owner = EXCLUDED.technical_owner, description = EXCLUDED.description;


-- 2. Business meaning and ownership (business owners are fictitious
--    roles, in the same style as the rest of the catalog).
INSERT INTO governance.table_description
       (schema_name, table_name, source_system, business_owner, description, grain)
VALUES
 ('graph','config','Integrated','Head of Fraud Investigations',
  'Thresholds that decide when a shared entity links customers.','One row per setting'),
 ('graph','node','Integrated','Head of Fraud Investigations',
  'Every customer, account, card, digital user, device, IP, payee, external account, terminal and merchant as a graph node.','One row per entity'),
 ('graph','edge','Integrated','Head of Fraud Investigations',
  'Relationships between nodes, aggregated from the three fact tables.','One row per relationship type between two nodes'),
 ('graph','customer_entity','Integrated','Head of Fraud Investigations',
  'Bridge from each customer to every entity reached through their accounts, cards and digital logins.','One row per customer, entity and intermediate node'),
 ('graph','customer_link','Integrated','Head of Fraud Investigations',
  'Customer-to-customer links through a shared device, IP or fraud-linked payee/terminal.','One row per customer pair per shared entity'),
 ('graph','customer_cluster','Integrated','Head of Fraud Investigations',
  'Connected group (possible fraud ring) that each customer belongs to.','One row per customer'),
 ('graph','v_customer_link_detail','Integrated','Head of Fraud Investigations',
  'Report 2 view: customer links with names and the shared entity.','One row per customer link'),
 ('graph','v_cluster_summary','Integrated','Head of Fraud Investigations',
  'Report 2 view: connected groups with review priority.','One row per group of 2+ customers'),
 ('graph','v_shared_entities','Integrated','Head of Fraud Investigations',
  'Report 2 view: devices, IPs, payees and terminals reached by 2+ customers.','One row per shared entity'),
 ('graph','v_collection_points','Integrated','Head of Fraud Investigations',
  'Report 2 view: destinations receiving fraud-flagged activity from 2+ customers.','One row per collection point'),
 ('staging','fraud_scenario_reference','Reference Data','Head of Fraud Investigations',
  'Answer key of planted fraud and legitimate scenarios supplied with the synthetic dataset. Used only to validate the graph (07 check V6).','One row per scenario record')
ON CONFLICT (schema_name, table_name) DO UPDATE
   SET source_system = EXCLUDED.source_system, business_owner = EXCLUDED.business_owner,
       description = EXCLUDED.description, grain = EXCLUDED.grain;


-- 3. Lineage: how data reaches the graph and its report views.
--    Matches the build steps in 06_graph_layer.sql (graph.refresh_graph).
INSERT INTO governance.lineage
       (source_object, target_object, lineage_type, transformation_script,
        transformation_summary, recorded_by)
VALUES
 ('file:fraud_scenario_reference.csv','staging.fraud_scenario_reference','INGEST','06b_import_fraud_scenarios.sql','CSV copied as TEXT, unchanged','Samnang Vyvath Khun'),
 ('dw.dim_customer',          'graph.node','TRANSFORM','06_graph_layer.sql','One CUSTOMER node per enterprise customer','Samnang Vyvath Khun'),
 ('dw.dim_account',           'graph.node','TRANSFORM','06_graph_layer.sql','One ACCOUNT node per account','Samnang Vyvath Khun'),
 ('dw.dim_card',              'graph.node','TRANSFORM','06_graph_layer.sql','One CARD node per card','Samnang Vyvath Khun'),
 ('dw.dim_digital_user',      'graph.node','TRANSFORM','06_graph_layer.sql','One DIGITAL_USER node per digital user','Samnang Vyvath Khun'),
 ('dw.fact_digital_event',    'graph.node','TRANSFORM','06_graph_layer.sql','DEVICE, IP_ADDRESS and BENEFICIARY nodes from event values','Samnang Vyvath Khun'),
 ('dw.fact_core_transaction', 'graph.node','TRANSFORM','06_graph_layer.sql','BENEFICIARY and EXTERNAL_ACCOUNT nodes from payment references','Samnang Vyvath Khun'),
 ('dw.fact_card_transaction', 'graph.node','TRANSFORM','06_graph_layer.sql','TERMINAL and MERCHANT nodes','Samnang Vyvath Khun'),
 ('dw.fact_digital_event',    'graph.edge','TRANSFORM','06_graph_layer.sql','USED_DEVICE, LOGGED_IN_FROM and PAID edges, aggregated','Samnang Vyvath Khun'),
 ('dw.fact_core_transaction', 'graph.edge','TRANSFORM','06_graph_layer.sql','PAID and SENT_TO edges, aggregated','Samnang Vyvath Khun'),
 ('dw.fact_card_transaction', 'graph.edge','TRANSFORM','06_graph_layer.sql','USED_TERMINAL and PURCHASED_AT edges, aggregated','Samnang Vyvath Khun'),
 ('graph.node',               'graph.edge','KEY_LOOKUP','06_graph_layer.sql','Edges reference node_id','Samnang Vyvath Khun'),
 ('graph.edge',               'graph.customer_entity','TRANSFORM','06_graph_layer.sql','Two-hop customer -> entity bridge','Samnang Vyvath Khun'),
 ('graph.customer_entity',    'graph.customer_link','TRANSFORM','06_graph_layer.sql','Customers sharing a device/IP, or a payee/terminal used for fraud','Samnang Vyvath Khun'),
 ('graph.customer_link',      'graph.customer_cluster','TRANSFORM','06_graph_layer.sql','Connected groups by label propagation','Samnang Vyvath Khun'),
 ('graph.customer_cluster',   'graph.v_cluster_summary','DERIVED_VIEW','07_report2_connected_entities.sql','Group size, fraud counts and review priority','Samnang Vyvath Khun'),
 ('graph.customer_link',      'graph.v_customer_link_detail','DERIVED_VIEW','07_report2_connected_entities.sql','Links with names and shared entity','Samnang Vyvath Khun'),
 ('graph.customer_entity',    'graph.v_shared_entities','DERIVED_VIEW','07_report2_connected_entities.sql','Entities reached by 2+ customers','Samnang Vyvath Khun'),
 ('graph.edge',               'graph.v_collection_points','DERIVED_VIEW','07_report2_connected_entities.sql','Fraud-flagged inflows per destination','Samnang Vyvath Khun')
ON CONFLICT (source_object, target_object) DO NOTHING;


-- 4. Data quality rules for the graph. Each returns (rows_checked,
--    rows_failed) in the same contract as Shubham's other rules.
INSERT INTO governance.dq_rule
       (rule_id, rule_name, dq_dimension, target_object, rule_description,
        check_sql, severity, tolerance_pct, rule_source)
VALUES
('DQ_GRA_01','Every warehouse entity has a graph node','Completeness','graph.node',
 'Each customer, account, card and digital user in dw must appear exactly once as a graph node.',
 $q$SELECT
      (SELECT COUNT(*) FROM dw.dim_customer) + (SELECT COUNT(*) FROM dw.dim_account)
    + (SELECT COUNT(*) FROM dw.dim_card)     + (SELECT COUNT(*) FROM dw.dim_digital_user),
      (SELECT COUNT(*) FROM dw.dim_customer c WHERE NOT EXISTS
         (SELECT 1 FROM graph.node n WHERE n.node_id = 'CUSTOMER:' || c.enterprise_customer_key))
    + (SELECT COUNT(*) FROM dw.dim_account a WHERE NOT EXISTS
         (SELECT 1 FROM graph.node n WHERE n.node_id = 'ACCOUNT:' || a.core_account_id))
    + (SELECT COUNT(*) FROM dw.dim_card k WHERE NOT EXISTS
         (SELECT 1 FROM graph.node n WHERE n.node_id = 'CARD:' || k.card_id))
    + (SELECT COUNT(*) FROM dw.dim_digital_user u WHERE NOT EXISTS
         (SELECT 1 FROM graph.node n WHERE n.node_id = 'DIGITAL_USER:' || u.digital_user_id))$q$,
 'HIGH',0,'Graph validation V1 (Assignment 2 design)'),
('DQ_GRA_02','Graph fraud flags reconcile with the warehouse','Accuracy','graph.node',
 'Fraud-flagged events counted on customer nodes must equal fraud-flagged rows in the three fact tables.',
 $q$SELECT w.flags, ABS(w.flags - COALESCE(g.flags, 0))
    FROM (SELECT (SELECT COUNT(*) FROM dw.fact_core_transaction WHERE fraud_indicator)
               + (SELECT COUNT(*) FROM dw.fact_card_transaction WHERE fraud_indicator)
               + (SELECT COUNT(*) FROM dw.fact_digital_event   WHERE fraud_indicator) AS flags) w
    CROSS JOIN (SELECT SUM(fraud_event_count) AS flags
                FROM graph.node WHERE node_type = 'CUSTOMER') g$q$,
 'HIGH',0,'Graph validation V3 (Assignment 2 design)')
ON CONFLICT (rule_id) DO UPDATE
   SET rule_name = EXCLUDED.rule_name, dq_dimension = EXCLUDED.dq_dimension,
       target_object = EXCLUDED.target_object, rule_description = EXCLUDED.rule_description,
       check_sql = EXCLUDED.check_sql, severity = EXCLUDED.severity,
       tolerance_pct = EXCLUDED.tolerance_pct, rule_source = EXCLUDED.rule_source;


-- 5. Access: the graph holds customer names (node display_name), so it
--    follows the same policy as dw.dim_customer: data stewards may read
--    it; fraud analysts and auditors get no direct access.
REVOKE ALL ON SCHEMA graph FROM PUBLIC;
GRANT USAGE  ON SCHEMA graph TO data_steward;
GRANT SELECT ON ALL TABLES IN SCHEMA graph TO data_steward;

-- Next: run Shubham's 07_run_governance.sql, then his 08 report.
