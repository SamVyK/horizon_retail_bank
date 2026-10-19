/* Horizon live notifications: remove all test rows, alerts and the event log,
   so the next demo starts from zero. Production (CSV) data is not touched. */
DELETE FROM staging.card_transactions
 WHERE card_transaction_id LIKE 'CTX_TEST_%' OR card_transaction_id LIKE 'CTX_LIVE_%';
DELETE FROM staging.digital_events
 WHERE digital_event_id LIKE 'EV_TEST_%';
DELETE FROM staging.core_transactions
 WHERE core_transaction_id LIKE 'CORE_TEST_%';
DELETE FROM staging.digital_users
 WHERE digital_user_id IN ('DU9001','DU9002','DU9003','DU9004','DU9005','DU9006');
TRUNCATE staging.fraud_events RESTART IDENTITY;
TRUNCATE staging.live_event_log RESTART IDENTITY;
SELECT 'clean slate' AS status;
