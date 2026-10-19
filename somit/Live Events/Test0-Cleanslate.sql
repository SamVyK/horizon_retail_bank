-- Delete source test rows
DELETE FROM staging.card_transactions
WHERE card_transaction_id LIKE 'CTX_TEST_%'
   OR card_transaction_id LIKE 'CTX_LIVE_%';

DELETE FROM staging.digital_events
WHERE digital_event_id LIKE 'EV_TEST_%';

-- Delete the alerts those rules generated
DELETE FROM staging.fraud_events
WHERE source_id LIKE 'CTX_TEST_%'
   OR source_id LIKE 'CTX_LIVE_%'
   OR source_id LIKE 'DEV_TEST_%'
   OR source_id LIKE 'BEN_MULE_%'
   OR source_id LIKE 'CARD_TEST_%'
   OR customer_key LIKE 'DU_TEST_%'
   OR customer_key LIKE 'CARD_TEST_%';