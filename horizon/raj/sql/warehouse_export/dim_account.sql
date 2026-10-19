-- Raj: read-only input adapter. Maedeh owns creation and population of dw.dim_account.
-- Names/keys follow the warehouse diagram in the updated team report.
SELECT * FROM dw.dim_account ORDER BY account_key;
