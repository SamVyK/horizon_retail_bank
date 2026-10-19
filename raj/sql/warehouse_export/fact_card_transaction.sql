-- Raj: read-only input adapter. Maedeh owns creation and population of dw.fact_card_transaction.
-- Names/keys follow the warehouse diagram in the updated team report.
SELECT * FROM dw.fact_card_transaction ORDER BY card_transaction_key;
