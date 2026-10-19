/* =====================================================================
   Horizon Retail Bank - Live notifications, lab version
   Somit's workstream (live events) | 32113 Advanced Database | A2
   File: somit/live_lab/01_live_setup.sql

   PURPOSE
   Runs Somit's four streaming fraud rules (from Live Events/fraud.py)
   inside PostgreSQL, so live alerts work in the lab without Debezium
   and Redpanda. Every new row in the three activity tables, and every
   change to staging.digital_users, is:
     1. logged in staging.live_event_log (the live event feed),
     2. checked against the four rules,
     3. written to staging.fraud_events when a rule fires
        (same table and columns as Somit's V2), and
     4. announced with pg_notify('horizon_live', ...).
   live_server.py reads these tables and pushes them to the dashboard.

   RULES (same thresholds as fraud.py)
     CARD_FRAUD_OVERSEAS_CLUSTER  3+ international, card-not-present
                                  transactions on one card in 60 min
     RAPID_TRANSACTION_BURST      5+ APPROVED transactions on one card
                                  in 10 min
     SHARED_DEVICE_RING           one device used by more than 2
                                  digital users
     SUSPICIOUS_BENEFICIARY       one beneficiary receiving transfers
                                  from more than 5 digital users

   SAFE TO RE-RUN. A rule error is caught and logged, so the trigger
   never blocks an insert. Run it again after run_all (the reset drops
   staging); live_server.py does this automatically when it starts.
   ===================================================================== */

CREATE TABLE IF NOT EXISTS staging.fraud_events (
    event_id     bigserial PRIMARY KEY,
    event_type   text,
    customer_key text,
    source_id    text,
    severity     text,
    details      jsonb,
    detected_at  timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_fraud_events_detected_at
    ON staging.fraud_events(detected_at DESC);

CREATE TABLE IF NOT EXISTS staging.live_event_log (
    log_id      bigserial PRIMARY KEY,
    table_name  text NOT NULL,
    operation   text NOT NULL,
    row_id      text,
    summary     jsonb,
    logged_at   timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- Text timestamps in staging are cast safely; a bad value becomes NULL.
CREATE OR REPLACE FUNCTION staging.try_ts(p text) RETURNS timestamptz
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    RETURN p::timestamptz;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

-- Write one alert and announce it.
CREATE OR REPLACE FUNCTION staging.live_raise_alert(
    p_type text, p_customer text, p_source text, p_details jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_id bigint;
BEGIN
    INSERT INTO staging.fraud_events (event_type, customer_key, source_id, severity, details)
    VALUES (p_type, p_customer, p_source, 'HIGH', p_details)
    RETURNING event_id INTO v_id;
    PERFORM pg_notify('horizon_live',
        json_build_object('kind','alert','event_id',v_id,'type',p_type,'source',p_source)::text);
END;
$$;

/* ---------------- card_transactions: rules 1 and 2 ---------------- */
CREATE OR REPLACE FUNCTION staging.live_card_tx() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_ts  timestamptz := staging.try_ts(NEW.transaction_timestamp);
    v_n   int;
    v_amt numeric;
BEGIN
    INSERT INTO staging.live_event_log (table_name, operation, row_id, summary)
    VALUES ('card_transactions', TG_OP, NEW.card_transaction_id,
            jsonb_build_object('card', NEW.card_id, 'merchant', NEW.merchant_name,
                               'amount', NEW.transaction_amount, 'currency', NEW.currency,
                               'status', NEW.transaction_status,
                               'scope', NEW.domestic_international,
                               'present', NEW.card_present_flag,
                               'country', NEW.transaction_country));
    PERFORM pg_notify('horizon_live', json_build_object('kind','event','table','card_transactions')::text);

    BEGIN
        -- Rule 1: overseas, card-not-present cluster (3+ in 60 min)
        IF NEW.domestic_international = 'International'
           AND coalesce(NEW.card_present_flag,'') <> 'TRUE' AND v_ts IS NOT NULL THEN
            SELECT count(*) INTO v_n
            FROM staging.card_transactions t
            WHERE t.card_id = NEW.card_id
              AND t.domestic_international = 'International'
              AND coalesce(t.card_present_flag,'') <> 'TRUE'
              AND (staging.try_ts(t.transaction_timestamp), t.card_transaction_id)
                  <= (v_ts, NEW.card_transaction_id)
              AND staging.try_ts(t.transaction_timestamp) > v_ts - interval '60 minutes';
            IF v_n >= 3 THEN
                PERFORM staging.live_raise_alert('CARD_FRAUD_OVERSEAS_CLUSTER', NEW.card_id,
                    NEW.card_transaction_id,
                    jsonb_build_object('card_id', NEW.card_id, 'tx_count_60min', v_n,
                        'countries', (SELECT jsonb_agg(DISTINCT t.transaction_country)
                                      FROM staging.card_transactions t
                                      WHERE t.card_id = NEW.card_id
                                        AND t.domestic_international = 'International'
                                        AND staging.try_ts(t.transaction_timestamp)
                                            BETWEEN v_ts - interval '60 minutes' AND v_ts)));
            END IF;
        END IF;

        -- Rule 2: rapid burst (5+ APPROVED in 10 min)
        IF NEW.transaction_status = 'APPROVED' AND v_ts IS NOT NULL THEN
            SELECT count(*), sum(NULLIF(t.transaction_amount,'')::numeric) INTO v_n, v_amt
            FROM staging.card_transactions t
            WHERE t.card_id = NEW.card_id
              AND t.transaction_status = 'APPROVED'
              AND (staging.try_ts(t.transaction_timestamp), t.card_transaction_id)
                  <= (v_ts, NEW.card_transaction_id)
              AND staging.try_ts(t.transaction_timestamp) > v_ts - interval '10 minutes';
            IF v_n >= 5 THEN
                PERFORM staging.live_raise_alert('RAPID_TRANSACTION_BURST', NEW.card_id,
                    NEW.card_transaction_id,
                    jsonb_build_object('card_id', NEW.card_id, 'tx_count_10min', v_n,
                                       'total_amount', v_amt));
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO staging.live_event_log (table_name, operation, row_id, summary)
        VALUES ('card_transactions', 'RULE_ERROR', NEW.card_transaction_id,
                jsonb_build_object('error', SQLERRM));
    END;
    RETURN NEW;
END;
$$;

/* ---------------- digital_events: rules 3 and 4 ---------------- */
CREATE OR REPLACE FUNCTION staging.live_digital_event() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_ts timestamptz := coalesce(staging.try_ts(NEW.event_timestamp), '-infinity'::timestamptz);
    v_n  int;
    v_users jsonb;
BEGIN
    INSERT INTO staging.live_event_log (table_name, operation, row_id, summary)
    VALUES ('digital_events', TG_OP, NEW.digital_event_id,
            jsonb_build_object('user', NEW.digital_user_id, 'event', NEW.event_type,
                               'device', NEW.device_id, 'ip', NEW.ip_address_synthetic,
                               'beneficiary', NEW.beneficiary_reference,
                               'amount', NEW.transaction_amount));
    PERFORM pg_notify('horizon_live', json_build_object('kind','event','table','digital_events')::text);

    BEGIN
        -- Rule 3: shared device ring (more than 2 distinct users)
        IF NEW.device_id IS NOT NULL AND NEW.digital_user_id IS NOT NULL THEN
            SELECT count(DISTINCT e.digital_user_id), jsonb_agg(DISTINCT e.digital_user_id)
              INTO v_n, v_users
            FROM staging.digital_events e
            WHERE e.device_id = NEW.device_id
              AND (coalesce(staging.try_ts(e.event_timestamp), '-infinity'::timestamptz), e.digital_event_id)
                  <= (v_ts, NEW.digital_event_id);
            IF v_n > 2 THEN
                PERFORM staging.live_raise_alert('SHARED_DEVICE_RING', NEW.digital_user_id,
                    NEW.device_id,
                    jsonb_build_object('device_id', NEW.device_id, 'distinct_users', v_n,
                                       'users', v_users));
            END IF;
        END IF;

        -- Rule 4: suspicious beneficiary (more than 5 distinct senders)
        IF NEW.beneficiary_reference IS NOT NULL AND NEW.digital_user_id IS NOT NULL
           AND (NEW.event_type IS NULL
                OR lower(NEW.event_type) IN ('transfer','beneficiaryadd','payment')) THEN
            SELECT count(DISTINCT e.digital_user_id), jsonb_agg(DISTINCT e.digital_user_id)
              INTO v_n, v_users
            FROM staging.digital_events e
            WHERE e.beneficiary_reference = NEW.beneficiary_reference
              AND (e.event_type IS NULL
                   OR lower(e.event_type) IN ('transfer','beneficiaryadd','payment'))
              AND (coalesce(staging.try_ts(e.event_timestamp), '-infinity'::timestamptz), e.digital_event_id)
                  <= (v_ts, NEW.digital_event_id);
            IF v_n > 5 THEN
                PERFORM staging.live_raise_alert('SUSPICIOUS_BENEFICIARY', NEW.digital_user_id,
                    NEW.beneficiary_reference,
                    jsonb_build_object('beneficiary_reference', NEW.beneficiary_reference,
                                       'distinct_senders', v_n, 'senders', v_users));
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        INSERT INTO staging.live_event_log (table_name, operation, row_id, summary)
        VALUES ('digital_events', 'RULE_ERROR', NEW.digital_event_id,
                jsonb_build_object('error', SQLERRM));
    END;
    RETURN NEW;
END;
$$;

/* ---------------- core_transactions: logged (no rule, as in fraud.py) ---------------- */
CREATE OR REPLACE FUNCTION staging.live_core_tx() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO staging.live_event_log (table_name, operation, row_id, summary)
    VALUES ('core_transactions', TG_OP, NEW.core_transaction_id,
            jsonb_build_object('account', NEW.core_account_id, 'type', NEW.transaction_type,
                               'amount', NEW.transaction_amount,
                               'beneficiary', NEW.beneficiary_reference));
    PERFORM pg_notify('horizon_live', json_build_object('kind','event','table','core_transactions')::text);
    RETURN NEW;
END;
$$;

/* ---------------- digital_users: Somit V1 changes (insert/update/delete) ---------------- */
CREATE OR REPLACE FUNCTION staging.live_digital_user() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE r record;
BEGIN
    IF TG_OP = 'DELETE' THEN r := OLD; ELSE r := NEW; END IF;
    INSERT INTO staging.live_event_log (table_name, operation, row_id, summary)
    VALUES ('digital_users', TG_OP, r.digital_user_id,
            jsonb_build_object('name', r.customer_name, 'status', r.digital_status,
                               'platform', r.preferred_platform, 'risk', r.digital_risk_band));
    PERFORM pg_notify('horizon_live', json_build_object('kind','event','table','digital_users')::text);
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_live_card_tx      ON staging.card_transactions;
DROP TRIGGER IF EXISTS trg_live_digital_event ON staging.digital_events;
DROP TRIGGER IF EXISTS trg_live_core_tx      ON staging.core_transactions;
DROP TRIGGER IF EXISTS trg_live_digital_user ON staging.digital_users;

CREATE TRIGGER trg_live_card_tx AFTER INSERT ON staging.card_transactions
    FOR EACH ROW EXECUTE FUNCTION staging.live_card_tx();
CREATE TRIGGER trg_live_digital_event AFTER INSERT ON staging.digital_events
    FOR EACH ROW EXECUTE FUNCTION staging.live_digital_event();
CREATE TRIGGER trg_live_core_tx AFTER INSERT ON staging.core_transactions
    FOR EACH ROW EXECUTE FUNCTION staging.live_core_tx();
CREATE TRIGGER trg_live_digital_user AFTER INSERT OR UPDATE OR DELETE ON staging.digital_users
    FOR EACH ROW EXECUTE FUNCTION staging.live_digital_user();

SELECT 'live notifications ready' AS status;
