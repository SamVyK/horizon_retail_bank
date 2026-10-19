/* =====================================================================
   Horizon Retail Bank - Data Fabric (Governance Layer)
   Script 07: Run the governance cycle
   Owner     : Shubham Bhardwaj (25755442)
   Database  : horizon_dw
   Run after : 06_governance_setup.sql
   ---------------------------------------------------------------------
   PURPOSE
   Executes one governance cycle, the way a scheduled job would after
   every warehouse load:
     1. refresh the catalog (tables, columns, row counts, sensitivity)
     2. run every active data quality rule and store the results
     3. show a short summary of the run
   This script can be run as many times as needed. Each run adds a new
   dq_run row, so repeated runs build a quality history over time.
   ===================================================================== */


-- 1. Refresh the data catalog. Returns the number of objects catalogued.
SELECT governance.refresh_catalog() AS objects_catalogued;


-- 2. Run all active quality rules. Returns the new run_id.
SELECT governance.run_quality_checks() AS new_run_id;


-- 3. Summary of the run just completed.
SELECT run_id,
       started_at,
       ROUND(EXTRACT(EPOCH FROM (finished_at - started_at)) * 1000) AS duration_ms,
       rules_run,
       rules_passed,
       rules_failed,
       rules_info,
       rules_errored
FROM governance.dq_run
ORDER BY run_id DESC
LIMIT 1;


-- 4. Results of the latest run, failures first.
SELECT r.rule_id,
       q.rule_name,
       q.dq_dimension,
       q.severity,
       r.rows_checked,
       r.rows_failed,
       r.failure_pct,
       r.status
FROM governance.dq_result AS r
JOIN governance.dq_rule   AS q ON q.rule_id = r.rule_id
WHERE r.run_id = (SELECT MAX(run_id) FROM governance.dq_run)
ORDER BY CASE r.status WHEN 'ERROR' THEN 1 WHEN 'FAIL' THEN 2
                       WHEN 'INFO' THEN 3 ELSE 4 END,
         r.rule_id;

-- End of script 07. Next: run 08_report3_lineage_quality.sql
