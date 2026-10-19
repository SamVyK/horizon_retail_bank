-- Publication
CREATE PUBLICATION dbz_publication
FOR TABLE staging.card_transactions, staging.digital_events, staging.core_transactions;