/* =====================================================================
   Horizon Retail Bank - Data Fabric (Governance Layer)
   Script 08: Report 3 - Data Lineage and Quality
   Owner     : Shubham Bhardwaj (25755442)
   Database  : horizon_dw
   Run after : 07_run_governance.sql (at least one quality run needed)
   ---------------------------------------------------------------------
   USE CASE
   Before a fraud analyst acts on a warehouse figure, the bank must be
   able to answer: Where did this data come from? Can it be trusted?
   Who is allowed to see it? This report answers those three questions
   from the governance metadata.

   PART A creates reusable report views (re-runnable: CREATE OR REPLACE).
   PART B runs the report queries. Each query is numbered R3.x so it can
   be referenced from the written report and shown in the demo video.
   ===================================================================== */


/* =====================================================================
   PART A - Report views
   ===================================================================== */

-- A1. Data trust summary: one row of headline figures (dashboard tiles).
CREATE OR REPLACE VIEW governance.v_data_trust_summary AS
WITH last_run AS (
    SELECT MAX(run_id) AS run_id FROM governance.dq_run
),
ctrl AS (
    SELECT r.*
    FROM governance.dq_result AS r
    JOIN governance.dq_rule   AS q ON q.rule_id = r.rule_id
    WHERE r.run_id = (SELECT run_id FROM last_run)
      AND q.check_type = 'CONTROL'
)
SELECT
    (SELECT COUNT(*) FROM governance.data_catalog)                      AS objects_catalogued,
    (SELECT COUNT(*) FROM governance.column_catalog)                    AS columns_catalogued,
    (SELECT COUNT(*) FROM governance.column_catalog
      WHERE sensitivity IN ('PII_DIRECT','PII_QUASI','DEVICE_NETWORK')) AS sensitive_columns,
    (SELECT COUNT(*) FROM governance.lineage)                           AS lineage_flows,
    (SELECT COUNT(*) FROM ctrl)                                         AS control_rules_run,
    (SELECT COUNT(*) FROM ctrl WHERE status = 'PASS')                   AS control_rules_passed,
    ROUND(100.0 * (SELECT COUNT(*) FROM ctrl WHERE status = 'PASS')
          / NULLIF((SELECT COUNT(*) FROM ctrl), 0), 1)                  AS rule_pass_rate_pct,
    ROUND(100.0 * (1 - (SELECT SUM(rows_failed) FROM ctrl)::NUMERIC
          / NULLIF((SELECT SUM(rows_checked) FROM ctrl), 0)), 2)         AS row_pass_rate_pct,
    (SELECT run_id FROM last_run)                                       AS latest_run_id,
    (SELECT finished_at FROM governance.dq_run
      WHERE run_id = (SELECT run_id FROM last_run))                     AS latest_run_at;


-- A2. Latest result for every rule, with the business owner of the
--     table it tests, so each failure has someone accountable.
CREATE OR REPLACE VIEW governance.v_dq_scorecard AS
SELECT r.run_id,
       q.rule_id,
       q.rule_name,
       q.dq_dimension,
       q.target_object,
       COALESCE(c.business_owner, 'Multiple owners') AS accountable_owner,
       q.severity,
       q.check_type,
       r.rows_checked,
       r.rows_failed,
       r.failure_pct,
       q.tolerance_pct,
       r.status
FROM governance.dq_result AS r
JOIN governance.dq_rule   AS q ON q.rule_id = r.rule_id
LEFT JOIN governance.data_catalog AS c
       ON c.schema_name || '.' || c.table_name = q.target_object
WHERE r.run_id = (SELECT MAX(run_id) FROM governance.dq_run);


-- A3. Quality by dimension (control rules only).
CREATE OR REPLACE VIEW governance.v_dq_by_dimension AS
SELECT dq_dimension,
       COUNT(*)                                      AS rules,
       COUNT(*) FILTER (WHERE status = 'PASS')       AS passed,
       COUNT(*) FILTER (WHERE status = 'FAIL')       AS failed,
       SUM(rows_checked)                             AS rows_checked,
       SUM(rows_failed)                              AS rows_failed,
       ROUND(100.0 * (1 - SUM(rows_failed)::NUMERIC / NULLIF(SUM(rows_checked), 0)), 2)
                                                     AS row_pass_rate_pct
FROM governance.v_dq_scorecard
WHERE check_type = 'CONTROL'
GROUP BY dq_dimension;


-- A4. Quality by table: which datasets are safe to use today.
--     trust_level: TRUSTED (no failures), CAUTION (only MEDIUM/LOW
--     failures), AT RISK (any CRITICAL or HIGH failure).
CREATE OR REPLACE VIEW governance.v_dq_by_table AS
SELECT target_object,
       accountable_owner,
       COUNT(*)                                          AS rules,
       COUNT(*) FILTER (WHERE status = 'FAIL')           AS rules_failed,
       SUM(rows_failed)                                  AS rows_failed,
       CASE
           WHEN COUNT(*) FILTER (WHERE status = 'FAIL'
                                   AND severity IN ('CRITICAL','HIGH')) > 0 THEN 'AT RISK'
           WHEN COUNT(*) FILTER (WHERE status = 'FAIL') > 0              THEN 'CAUTION'
           ELSE 'TRUSTED'
       END                                               AS trust_level
FROM governance.v_dq_scorecard
WHERE check_type = 'CONTROL'
GROUP BY target_object, accountable_owner;


-- A5. Quality trend across runs (one row per run).
CREATE OR REPLACE VIEW governance.v_dq_trend AS
SELECT d.run_id,
       d.started_at,
       d.rules_run,
       d.rules_passed,
       d.rules_failed,
       ROUND(100.0 * d.rules_passed / NULLIF(d.rules_run - d.rules_info, 0), 1)
                                                     AS rule_pass_rate_pct
FROM governance.dq_run AS d
WHERE d.finished_at IS NOT NULL;


-- A6. Layer reconciliation: staging rows vs warehouse rows for each
--     entity, taken from the catalog snapshot.
CREATE OR REPLACE VIEW governance.v_layer_reconciliation AS
WITH pairs (entity, staging_table, warehouse_table) AS (
    VALUES ('Customers',           'core_customers',    'dim_customer'),
           ('Accounts',            'core_accounts',     'dim_account'),
           ('Cards',               'cards',             'dim_card'),
           ('Digital users',       'digital_users',     'dim_digital_user'),
           ('Core transactions',   'core_transactions', 'fact_core_transaction'),
           ('Card transactions',   'card_transactions', 'fact_card_transaction'),
           ('Digital events',      'digital_events',    'fact_digital_event')
)
SELECT p.entity,
       'staging.' || p.staging_table  AS staging_object,
       s.row_count                    AS staging_rows,
       'dw.' || p.warehouse_table     AS warehouse_object,
       w.row_count                    AS warehouse_rows,
       s.row_count - w.row_count      AS difference,
       CASE WHEN s.row_count = w.row_count THEN 'RECONCILED' ELSE 'CHECK' END AS status
FROM pairs AS p
LEFT JOIN governance.data_catalog AS s
       ON s.schema_name = 'staging' AND s.table_name = p.staging_table
LEFT JOIN governance.data_catalog AS w
       ON w.schema_name = 'dw' AND w.table_name = p.warehouse_table;


-- A7. Sensitive data inventory: where personal data lives.
CREATE OR REPLACE VIEW governance.v_sensitive_data_inventory AS
SELECT c.schema_name || '.' || c.table_name               AS object_name,
       d.layer,
       COUNT(*) FILTER (WHERE c.sensitivity = 'PII_DIRECT')     AS pii_direct,
       COUNT(*) FILTER (WHERE c.sensitivity = 'PII_QUASI')      AS pii_quasi,
       COUNT(*) FILTER (WHERE c.sensitivity = 'DEVICE_NETWORK') AS device_network,
       COUNT(*) FILTER (WHERE c.sensitivity = 'FINANCIAL')      AS financial,
       string_agg(c.column_name, ', ' ORDER BY c.ordinal_position)
           FILTER (WHERE c.sensitivity = 'PII_DIRECT')          AS direct_identifier_columns
FROM governance.column_catalog AS c
JOIN governance.data_catalog   AS d
  ON d.schema_name = c.schema_name AND d.table_name = c.table_name
WHERE c.schema_name IN ('staging','dw','secure')
GROUP BY c.schema_name, c.table_name, d.layer;


-- A8. Access matrix: documented policy vs privileges PostgreSQL actually
--     enforces (has_table_privilege). Any MISMATCH is a governance gap.
CREATE OR REPLACE VIEW governance.v_access_matrix AS
WITH roles (role_name) AS (
    VALUES ('fraud_analyst'), ('data_steward'), ('compliance_auditor')
),
objects (object_name) AS (
    VALUES ('dw.dim_customer'), ('dw.fact_card_transaction'),
           ('secure.v_customer_masked'), ('staging.core_customers'),
           ('governance.dq_result'), ('governance.dq_rule')
)
SELECT r.role_name,
       o.object_name,
       CASE WHEN has_table_privilege(r.role_name, o.object_name, 'SELECT')
            THEN 'YES' ELSE 'no' END                      AS can_read,
       CASE WHEN has_table_privilege(r.role_name, o.object_name, 'INSERT')
            THEN 'YES' ELSE 'no' END                      AS can_write,
       p.access_level                                     AS documented_policy,
       CASE
           WHEN p.access_level IS NULL THEN 'not documented'
           WHEN p.access_level = 'NONE'
                AND has_table_privilege(r.role_name, o.object_name, 'SELECT') THEN 'MISMATCH'
           WHEN p.access_level IN ('READ','READ_WRITE')
                AND NOT has_table_privilege(r.role_name, o.object_name, 'SELECT') THEN 'MISMATCH'
           WHEN p.access_level = 'READ'
                AND has_table_privilege(r.role_name, o.object_name, 'INSERT') THEN 'MISMATCH'
           WHEN p.access_level = 'READ_WRITE'
                AND NOT has_table_privilege(r.role_name, o.object_name, 'INSERT') THEN 'MISMATCH'
           ELSE 'OK'
       END                                                AS policy_check
FROM roles AS r
CROSS JOIN objects AS o
LEFT JOIN governance.access_policy AS p
       ON p.role_name = r.role_name AND p.object_name = o.object_name;


-- Report views are governance metadata: auditors and stewards may read them.
GRANT SELECT ON ALL TABLES IN SCHEMA governance TO compliance_auditor, data_steward;


/* =====================================================================
   PART B - Report 3 queries
   ===================================================================== */

-- R3.1 Data trust summary (headline figures).
SELECT * FROM governance.v_data_trust_summary;

-- R3.2 Catalog: every governed object, its layer, owner and size.
SELECT layer, schema_name, table_name, object_type, source_system,
       business_owner, technical_owner, column_count, row_count,
       sensitive_column_count
FROM governance.data_catalog
WHERE schema_name IN ('staging','dw','secure')
ORDER BY CASE layer WHEN 'STAGING' THEN 1 WHEN 'WAREHOUSE' THEN 2 ELSE 3 END,
         table_name;

-- R3.3 Lineage: full upstream trace of the card transaction fact table,
--      back to its source files.
SELECT * FROM governance.trace_upstream('dw.fact_card_transaction');

-- R3.4 Lineage: trace of a masked analyst view back to its sources.
SELECT * FROM governance.trace_upstream('secure.v_customer_masked');

-- R3.5 Layer reconciliation: nothing lost from staging to warehouse.
SELECT * FROM governance.v_layer_reconciliation;

-- R3.6 Quality scorecard: latest result of every rule, failures first.
SELECT rule_id, rule_name, dq_dimension, target_object, accountable_owner,
       severity, rows_checked, rows_failed, failure_pct, status
FROM governance.v_dq_scorecard
ORDER BY CASE status WHEN 'FAIL' THEN 1 WHEN 'INFO' THEN 2 ELSE 3 END,
         CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2
                       WHEN 'MEDIUM' THEN 3 ELSE 4 END,
         rule_id;

-- R3.7 Quality by dimension.
SELECT * FROM governance.v_dq_by_dimension ORDER BY row_pass_rate_pct;

-- R3.8 Quality by table with trust level.
SELECT * FROM governance.v_dq_by_table
ORDER BY CASE trust_level WHEN 'AT RISK' THEN 1 WHEN 'CAUTION' THEN 2 ELSE 3 END,
         target_object;

-- R3.9 Effect of ETL cleansing: the same phone rule on raw source data
--      (DQ_VAL_05) and on the warehouse (DQ_VAL_04).
SELECT rule_id, target_object, rows_checked, rows_failed, failure_pct, status
FROM governance.v_dq_scorecard
WHERE rule_id IN ('DQ_VAL_05','DQ_VAL_04')
ORDER BY rule_id DESC;

-- R3.10 Drill-down example: the 10 cards with the oldest expiry that are
--       still marked ACTIVE (rule DQ_TIM_01), shown through the masked view.
SELECT card_id, card_holder_masked, card_type, card_status, expiry_date,
       (CURRENT_DATE - expiry_date) AS days_past_expiry
FROM secure.v_card_masked
WHERE card_status = 'ACTIVE'
  AND expiry_date < CURRENT_DATE
ORDER BY expiry_date
LIMIT 10;

-- R3.11 Sensitive data inventory: where personal data is stored.
SELECT * FROM governance.v_sensitive_data_inventory
ORDER BY pii_direct DESC, object_name;

-- R3.12 Access control: documented policy vs enforced privileges.
SELECT * FROM governance.v_access_matrix ORDER BY role_name, object_name;

-- R3.13 Masking in action: what a fraud analyst sees for one customer.
SELECT customer_key, enterprise_customer_key, first_initial, last_name_masked,
       birth_year, email_masked, phone_masked, state, risk_category
FROM secure.v_customer_masked
WHERE enterprise_customer_key = 'ENT_C000001';

-- R3.14 Quality trend across runs (run script 07 again to add history).
SELECT * FROM governance.v_dq_trend ORDER BY run_id;

-- R3.15 Live access test: switch into each role and try to read the
--       full customer table and the masked view. Results appear as
--       NOTICE messages (CloudBeaver: Output/Log panel). SET LOCAL ROLE
--       only lasts for this block, so the session is unchanged afterwards.
DO $$
DECLARE
    v_role   TEXT;
    v_object TEXT;
    v_rows   BIGINT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['fraud_analyst','compliance_auditor','data_steward'] LOOP
        FOREACH v_object IN ARRAY ARRAY['dw.dim_customer','secure.v_customer_masked'] LOOP
            BEGIN
                EXECUTE format('SET LOCAL ROLE %I', v_role);
                EXECUTE format('SELECT COUNT(*) FROM %s', v_object) INTO v_rows;
                RAISE NOTICE '% reading % : ALLOWED (% rows)', v_role, v_object, v_rows;
            EXCEPTION WHEN insufficient_privilege THEN
                RAISE NOTICE '% reading % : DENIED by PostgreSQL', v_role, v_object;
            END;
            RESET ROLE;
        END LOOP;
    END LOOP;
END;
$$;

-- End of Report 3.
