-- Raj. Currency- and source-separated gross values, not net balances or fraud losses.
-- Digital amounts have no supplied currency and are intentionally excluded here.
-- Do not sum the returned rows across currencies or across source systems.
SELECT source_system, currency, count(*) AS record_count, sum(amount) AS gross_recorded_amount
FROM activity
WHERE event_timestamp >= CAST(? AS TIMESTAMP)
  AND event_timestamp < CAST(? AS TIMESTAMP) + INTERVAL 1 DAY
  AND ((source_system='CORE' AND activity_status='COMPLETED')
    OR (source_system='CARD' AND activity_status='APPROVED'))
GROUP BY source_system,currency
ORDER BY source_system,currency;
