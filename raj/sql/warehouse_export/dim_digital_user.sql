-- Raj: read-only input adapter. Maedeh owns creation and population of dw.dim_digital_user.
-- Names/keys follow the warehouse diagram in the updated team report.
SELECT * FROM dw.dim_digital_user ORDER BY digital_user_key;
