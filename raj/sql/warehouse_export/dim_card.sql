-- Raj: read-only input adapter. Maedeh owns creation and population of dw.dim_card.
-- Names/keys follow the warehouse diagram in the updated team report.
SELECT * FROM dw.dim_card ORDER BY card_key;
