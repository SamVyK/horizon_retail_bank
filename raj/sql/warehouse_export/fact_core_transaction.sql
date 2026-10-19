-- Raj: read-only input adapter. Maedeh owns creation and population of dw.fact_core_transaction.
-- Names/keys follow the warehouse diagram in the updated team report.
SELECT * FROM dw.fact_core_transaction ORDER BY core_transaction_key;
