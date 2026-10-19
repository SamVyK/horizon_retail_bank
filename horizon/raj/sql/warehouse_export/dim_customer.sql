-- Raj: read-only input adapter. Maedeh owns creation and population of dw.dim_customer.
-- Names/keys follow the warehouse diagram in the updated team report.
SELECT * FROM dw.dim_customer ORDER BY customer_key;
