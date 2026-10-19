-- Alerts table
CREATE TABLE staging.fraud_events (
    event_id     bigserial PRIMARY KEY,
    event_type   text,
    customer_key text,
    source_id    text,
    severity     text,
    details      jsonb,
    detected_at  timestamptz DEFAULT now()
);
CREATE INDEX idx_fraud_events_detected_at
    ON staging.fraud_events(detected_at DESC);