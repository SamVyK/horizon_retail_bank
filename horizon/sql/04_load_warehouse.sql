-- Load all warehouse dimensions and facts from staging.
-- ON CONFLICT DO NOTHING skips existing business IDs;
-- existing records are not updated.
--
-- Standardise Australian phone numbers to +61 format.
-- Preserve other formats after whitespace removal.
-- NULL or whitespace-only phones return NULL.
-- Raw staging data remains unchanged.
--
-- All loads run in one transaction.
-- If execution fails, run ROLLBACK; in the same session,
-- fix the error, then rerun the entire file.

BEGIN;


CREATE OR REPLACE FUNCTION dw.normalise_phone(raw_phone TEXT)
RETURNS TEXT
LANGUAGE SQL IMMUTABLE STRICT
AS $$
    WITH cleaned AS (
        SELECT NULLIF(
            REGEXP_REPLACE(raw_phone, '[[:space:]]', '', 'g'),
            ''
        ) AS phone
    )
    SELECT CASE
        WHEN phone ~ '^0[2-478][0-9]{8}$'
            THEN '+61' || SUBSTRING(phone FROM 2)
        WHEN phone ~ '^61[2-478][0-9]{8}$'
            THEN '+' || phone
        ELSE phone
    END
    FROM cleaned;
$$;

-- Load the customer dimension from core data and supplied mapping.
INSERT INTO dw.dim_customer (
    enterprise_customer_key, core_customer_id,
    first_name, last_name, date_of_birth, gender,
    email, phone, address_line, suburb, city, state,
    postcode, country, customer_since_date,
    occupation_category, employment_status, annual_income,
    customer_segment, kyc_status, risk_category,
    card_customer_id, digital_user_id
)
SELECT
    TRIM(m.enterprise_customer_key),
    TRIM(c.core_customer_id),
    TRIM(c.first_name),
    TRIM(c.last_name),
    NULLIF(TRIM(c.date_of_birth), '')::DATE,
    UPPER(TRIM(c.gender)),
    LOWER(TRIM(c.email)),
    dw.normalise_phone(c.phone),
    TRIM(c.address_line),
    TRIM(c.suburb),
    TRIM(c.city),
    UPPER(TRIM(c.state)),
    TRIM(c.postcode),
    TRIM(c.country),
    NULLIF(TRIM(c.customer_since_date), '')::DATE,
    TRIM(c.occupation_category),
    TRIM(c.employment_status),
    NULLIF(TRIM(c.annual_income), '')::NUMERIC(12,2),
    TRIM(c.customer_segment),
    UPPER(TRIM(c.kyc_status)),
    UPPER(TRIM(c.risk_category)),
    NULLIF(TRIM(m.card_customer_id), ''),
    NULLIF(TRIM(m.digital_user_id), '')
FROM staging.core_customers AS c
JOIN staging.entity_mapping_reference AS m
    ON TRIM(c.core_customer_id) = TRIM(m.core_customer_id)
ON CONFLICT (enterprise_customer_key) DO NOTHING;


-- Load accounts and link each account to its warehouse customer.
INSERT INTO dw.dim_account (
    core_account_id, customer_key,
    account_type, product_code, account_status,
    open_date, close_date, currency,
    current_balance, available_balance,
    overdraft_limit, interest_rate, branch_code
)
SELECT
    TRIM(a.core_account_id),
    c.customer_key,
    TRIM(a.account_type),
    TRIM(a.product_code),
    UPPER(TRIM(a.account_status)),
    NULLIF(TRIM(a.open_date), '')::DATE,
    NULLIF(TRIM(a.close_date), '')::DATE,
    UPPER(TRIM(a.currency)),
    NULLIF(TRIM(a.current_balance), '')::NUMERIC(15,2),
    NULLIF(TRIM(a.available_balance), '')::NUMERIC(15,2),
    NULLIF(TRIM(a.overdraft_limit), '')::NUMERIC(12,2),
    NULLIF(TRIM(a.interest_rate), '')::NUMERIC(5,2),
    TRIM(a.branch_code)
FROM staging.core_accounts AS a
JOIN dw.dim_customer AS c
    ON TRIM(a.core_customer_id) = c.core_customer_id
ON CONFLICT (core_account_id) DO NOTHING;

-- Load cards and link them to customers using the supplied mapping.
INSERT INTO dw.dim_card (
    card_id, customer_key, card_customer_id,
    card_account_reference, customer_name, billing_postcode,
    card_type, card_network, card_status,
    issue_date, expiry_date, credit_limit,
    contactless_enabled, international_enabled, card_risk_band
)
SELECT
    TRIM(s.card_id),
    c.customer_key,
    TRIM(s.card_customer_id),
    TRIM(s.card_account_reference),
    TRIM(s.customer_name),
    TRIM(s.billing_postcode),
    TRIM(s.card_type),
    UPPER(TRIM(s.card_network)),
    UPPER(TRIM(s.card_status)),
    NULLIF(TRIM(s.issue_date), '')::DATE,
    NULLIF(TRIM(s.expiry_date), '')::DATE,
    NULLIF(TRIM(s.credit_limit), '')::NUMERIC(12,2),
    NULLIF(TRIM(s.contactless_enabled), '')::BOOLEAN,
    NULLIF(TRIM(s.international_enabled), '')::BOOLEAN,
    UPPER(TRIM(s.card_risk_band))
FROM staging.cards AS s
JOIN staging.entity_mapping_reference AS m
    ON TRIM(s.card_customer_id) = TRIM(m.card_customer_id)
JOIN dw.dim_customer AS c
    ON TRIM(m.enterprise_customer_key) = c.enterprise_customer_key
ON CONFLICT (card_id) DO NOTHING;


-- Load digital users and connect them to enterprise customers.
INSERT INTO dw.dim_digital_user (
    digital_user_id, customer_key,
    digital_account_reference, customer_name,
    registered_email, registered_phone,
    registration_date, digital_status, preferred_platform,
    biometric_enabled, mfa_enabled, notification_enabled,
    last_login_timestamp, digital_risk_band
)
SELECT
    TRIM(u.digital_user_id),
    c.customer_key,
    TRIM(u.digital_account_reference),
    TRIM(u.customer_name),
    LOWER(TRIM(u.registered_email)),
    dw.normalise_phone(u.registered_phone),
    NULLIF(TRIM(u.registration_date), '')::DATE,
    UPPER(TRIM(u.digital_status)),
    TRIM(u.preferred_platform),
    NULLIF(TRIM(u.biometric_enabled), '')::BOOLEAN,
    NULLIF(TRIM(u.mfa_enabled), '')::BOOLEAN,
    NULLIF(TRIM(u.notification_enabled), '')::BOOLEAN,
    NULLIF(TRIM(u.last_login_timestamp), '')::TIMESTAMP,
    UPPER(TRIM(u.digital_risk_band))
FROM staging.digital_users AS u
JOIN staging.entity_mapping_reference AS m
    ON TRIM(u.digital_user_id) = TRIM(m.digital_user_id)
JOIN dw.dim_customer AS c
    ON TRIM(m.enterprise_customer_key) = c.enterprise_customer_key
ON CONFLICT (digital_user_id) DO NOTHING;


-- Load core transactions and link each to its warehouse account.
INSERT INTO dw.fact_core_transaction (
    core_transaction_id, account_key,
    transaction_timestamp, transaction_type, transaction_amount,
    debit_credit_indicator, transaction_channel, transaction_status,
    currency, balance_after_transaction,
    counterparty_reference, beneficiary_reference,
    transaction_city, transaction_state, transaction_country,
    transaction_description, fraud_risk_score, fraud_indicator
)
SELECT
    TRIM(t.core_transaction_id),
    a.account_key,
    NULLIF(TRIM(t.transaction_timestamp), '')::TIMESTAMP,
    TRIM(t.transaction_type),
    NULLIF(TRIM(t.transaction_amount), '')::NUMERIC(15,2),
    UPPER(TRIM(t.debit_credit_indicator)),
    NULLIF(TRIM(t.transaction_channel), ''),
    UPPER(TRIM(t.transaction_status)),
    UPPER(TRIM(t.currency)),
    NULLIF(TRIM(t.balance_after_transaction), '')::NUMERIC(15,2),
    NULLIF(TRIM(t.counterparty_reference), ''),
    NULLIF(TRIM(t.beneficiary_reference), ''),
    TRIM(t.transaction_city),
    UPPER(TRIM(t.transaction_state)),
    TRIM(t.transaction_country),
    TRIM(t.transaction_description),
    NULLIF(TRIM(t.fraud_risk_score), '')::INTEGER,
    NULLIF(TRIM(t.fraud_indicator), '')::BOOLEAN
FROM staging.core_transactions AS t
JOIN dw.dim_account AS a
    ON TRIM(t.core_account_id) = a.core_account_id
ON CONFLICT (core_transaction_id) DO NOTHING;


-- Load card transactions and link each to its warehouse card.
INSERT INTO dw.fact_card_transaction (
    card_transaction_id, card_key,
    transaction_timestamp, transaction_amount, currency,
    merchant_name, merchant_category, merchant_category_code,
    transaction_type, transaction_status, payment_method,
    card_present_flag, domestic_international,
    transaction_city, transaction_country, device_reference,
    authorization_code, fraud_risk_score, fraud_indicator
)
SELECT
    TRIM(t.card_transaction_id),
    c.card_key,
    NULLIF(TRIM(t.transaction_timestamp), '')::TIMESTAMP,
    NULLIF(TRIM(t.transaction_amount), '')::NUMERIC(15,2),
    UPPER(TRIM(t.currency)),
    TRIM(t.merchant_name),
    TRIM(t.merchant_category),
    TRIM(t.merchant_category_code),
    TRIM(t.transaction_type),
    UPPER(TRIM(t.transaction_status)),
    TRIM(t.payment_method),
    NULLIF(TRIM(t.card_present_flag), '')::BOOLEAN,
    TRIM(t.domestic_international),
    TRIM(t.transaction_city),
    TRIM(t.transaction_country),
    NULLIF(TRIM(t.device_reference), ''),
    TRIM(t.authorization_code),
    NULLIF(TRIM(t.fraud_risk_score), '')::INTEGER,
    NULLIF(TRIM(t.fraud_indicator), '')::BOOLEAN
FROM staging.card_transactions AS t
JOIN dw.dim_card AS c
    ON TRIM(t.card_id) = c.card_id
ON CONFLICT (card_transaction_id) DO NOTHING;


-- Load digital events and link each to its warehouse user.
INSERT INTO dw.fact_digital_event (
    digital_event_id, digital_user_key,
    event_timestamp, event_type, channel,
    device_id, device_fingerprint, device_type, operating_system,
    trusted_device_flag, authentication_method, login_status,
    failed_login_attempts, ip_address_synthetic, ip_region,
    event_city, event_country, digital_account_reference,
    beneficiary_reference, transaction_amount, transaction_status,
    event_risk_score, fraud_indicator
)
SELECT
    TRIM(e.digital_event_id),
    u.digital_user_key,
    NULLIF(TRIM(e.event_timestamp), '')::TIMESTAMP,
    TRIM(e.event_type),
    TRIM(e.channel),
    TRIM(e.device_id),
    TRIM(e.device_fingerprint),
    TRIM(e.device_type),
    TRIM(e.operating_system),
    NULLIF(TRIM(e.trusted_device_flag), '')::BOOLEAN,
    TRIM(e.authentication_method),
    UPPER(TRIM(e.login_status)),
    NULLIF(TRIM(e.failed_login_attempts), '')::INTEGER,
    TRIM(e.ip_address_synthetic),
    TRIM(e.ip_region),
    TRIM(e.event_city),
    TRIM(e.event_country),
    TRIM(e.digital_account_reference),
    NULLIF(TRIM(e.beneficiary_reference), ''),
    NULLIF(TRIM(e.transaction_amount), '')::NUMERIC(15,2),
    UPPER(TRIM(e.transaction_status)),
    NULLIF(TRIM(e.event_risk_score), '')::INTEGER,
    NULLIF(TRIM(e.fraud_indicator), '')::BOOLEAN
FROM staging.digital_events AS e
JOIN dw.dim_digital_user AS u
    ON TRIM(e.digital_user_id) = u.digital_user_id
ON CONFLICT (digital_event_id) DO NOTHING;


COMMIT;

