-- Raj. Status semantics differ across systems; keep each source and activity type separate.
SELECT source_system, activity_type, activity_status, count(*) AS record_count
FROM activity
WHERE event_timestamp >= CAST(? AS TIMESTAMP)
  AND event_timestamp < CAST(? AS TIMESTAMP) + INTERVAL 1 DAY
GROUP BY ALL
ORDER BY source_system, activity_type, activity_status;
