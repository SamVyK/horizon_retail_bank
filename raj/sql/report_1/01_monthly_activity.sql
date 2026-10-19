-- Raj, component 5 -> 9. Runs in DuckDB over Delta gold fact_activity.
-- Grain: calendar month, source, activity type, status and original currency.
-- Counts represent source records/interactions, not deduplicated banking operations.
SELECT strftime(event_timestamp, '%Y-%m') AS activity_month,
       source_system, activity_type, activity_status, currency,
       count(*) AS event_count,
       count(DISTINCT enterprise_customer_key) AS active_customers,
       count(amount) AS monetary_record_count,
       sum(amount) AS recorded_amount
FROM activity
GROUP BY ALL
ORDER BY activity_month, source_system, activity_type, activity_status, currency;
