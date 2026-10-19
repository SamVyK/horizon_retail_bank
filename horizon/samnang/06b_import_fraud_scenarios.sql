-- =====================================================================
-- 06b_import_fraud_scenarios.sql
-- Horizon Retail Bank | 32113 Advanced Database | Assignment 2
-- Graph workstream: load the fraud scenario answer key
--
-- PURPOSE
-- fraud_scenario_reference.csv ships with the synthetic dataset and
-- lists the fraud (and deliberately legitimate) scenarios planted in the
-- data. It is NOT used to build the warehouse or the graph. It is only
-- used afterwards, in 07 Part C (check V6), to test whether the graph
-- finds the planted rings without being told about them.
--
-- RUN ORDER
--   Any time after 01 (needs the staging schema). Run once.
--   Replace /tmp/horizon_data/ with the folder that holds the CSV
--   *on the database server* (for the Lab Environment: the folder you
--   copied into the postgres container with docker cp).
--   If COPY is refused (permission denied), import the CSV with the
--   database tool's import feature, or use psql's \copy instead.
-- =====================================================================

CREATE TABLE IF NOT EXISTS staging.fraud_scenario_reference (
    fraud_scenario_id       TEXT,
    scenario_type           TEXT,
    enterprise_customer_key TEXT,
    source_system           TEXT,
    affected_record_id      TEXT,
    scenario_timestamp      TEXT,
    expected_fraud          TEXT,
    explanation             TEXT
);

-- Make the import repeatable: clear any earlier copy first.
TRUNCATE staging.fraud_scenario_reference;

COPY staging.fraud_scenario_reference
FROM '/tmp/horizon_data/fraud_scenario_reference.csv'
WITH (FORMAT CSV, HEADER TRUE, DELIMITER ',', ENCODING 'UTF8');

-- Expected: 295 rows across 10 scenario types.
SELECT scenario_type, COUNT(*) AS rows,
       COUNT(DISTINCT enterprise_customer_key) AS customers
FROM staging.fraud_scenario_reference
GROUP BY scenario_type
ORDER BY scenario_type;
