-- Raj: read-only input adapter. Maedeh owns creation and population of dw.fact_digital_event.
-- Names/keys follow the warehouse diagram in the updated team report.
SELECT * FROM dw.fact_digital_event ORDER BY digital_event_key;
