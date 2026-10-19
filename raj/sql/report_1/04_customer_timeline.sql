-- Raj. Parameterised enterprise identity demonstrates integrated cross-system activity.
-- Events remain separate observations; no payment-level cross-system deduplication is claimed.
SELECT event_timestamp,source_system,source_record_id,activity_type,activity_status,amount,currency
FROM activity WHERE enterprise_customer_key=?
ORDER BY event_timestamp,source_system,source_record_id;
