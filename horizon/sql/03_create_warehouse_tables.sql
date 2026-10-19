-- Customer dimension: one row per enterprise customer.
CREATE TABLE dw.dim_customer (
    customer_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    enterprise_customer_key TEXT NOT NULL UNIQUE,
    core_customer_id TEXT NOT NULL UNIQUE,

    first_name TEXT,
    last_name TEXT,
    date_of_birth DATE,
    gender TEXT,
    email TEXT,
    phone TEXT,
    address_line TEXT,
    suburb TEXT,
    city TEXT,
    state TEXT,
    postcode TEXT,
    country TEXT,
    customer_since_date DATE,
    occupation_category TEXT,
    employment_status TEXT,
    annual_income NUMERIC(12,2),
    customer_segment TEXT,
    kyc_status TEXT,
    risk_category TEXT,

    card_customer_id TEXT,
    digital_user_id TEXT,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Account dimension: one row per core banking account.
CREATE TABLE dw.dim_account (
    account_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    core_account_id TEXT NOT NULL UNIQUE,
    customer_key BIGINT NOT NULL
        REFERENCES dw.dim_customer(customer_key),

    account_type TEXT,
    product_code TEXT,
    account_status TEXT,
    open_date DATE,
    close_date DATE,
    currency TEXT,
    current_balance NUMERIC(15,2),
    available_balance NUMERIC(15,2),
    overdraft_limit NUMERIC(12,2),
    interest_rate NUMERIC(5,2),
    branch_code TEXT,

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Supports joins between customers and their accounts.
CREATE INDEX idx_dim_account_customer
    ON dw.dim_account(customer_key);

-- Card dimension: one row per card.
-- Customer ownership is resolved through the supplied mapping.
CREATE TABLE dw.dim_card (
    card_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    card_id TEXT NOT NULL UNIQUE,
    customer_key BIGINT NOT NULL
        REFERENCES dw.dim_customer(customer_key),

    card_customer_id TEXT,
    card_account_reference TEXT,
    customer_name TEXT,
    billing_postcode TEXT,
    card_type TEXT,
    card_network TEXT,
    card_status TEXT,
    issue_date DATE,
    expiry_date DATE,
    credit_limit NUMERIC(12,2),
    contactless_enabled BOOLEAN,
    international_enabled BOOLEAN,
    card_risk_band TEXT,

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_dim_card_customer
    ON dw.dim_card(customer_key);


-- Digital user dimension: one row per digital banking user.
CREATE TABLE dw.dim_digital_user (
    digital_user_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    digital_user_id TEXT NOT NULL UNIQUE,
    customer_key BIGINT NOT NULL
        REFERENCES dw.dim_customer(customer_key),

    digital_account_reference TEXT,
    customer_name TEXT,
    registered_email TEXT,
    registered_phone TEXT,
    registration_date DATE,
    digital_status TEXT,
    preferred_platform TEXT,
    biometric_enabled BOOLEAN,
    mfa_enabled BOOLEAN,
    notification_enabled BOOLEAN,
    last_login_timestamp TIMESTAMP,
    digital_risk_band TEXT,

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_dim_digital_user_customer
    ON dw.dim_digital_user(customer_key);


-- One row per core banking transaction.
CREATE TABLE dw.fact_core_transaction (
    core_transaction_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    core_transaction_id TEXT NOT NULL UNIQUE,
    account_key BIGINT NOT NULL
        REFERENCES dw.dim_account(account_key),

    transaction_timestamp TIMESTAMP NOT NULL,
    transaction_type TEXT,
    transaction_amount NUMERIC(15,2),
    debit_credit_indicator TEXT,
    transaction_channel TEXT,
    transaction_status TEXT,
    currency TEXT,
    balance_after_transaction NUMERIC(15,2),
    counterparty_reference TEXT,
    beneficiary_reference TEXT,
    transaction_city TEXT,
    transaction_state TEXT,
    transaction_country TEXT,
    transaction_description TEXT,
    fraud_risk_score INTEGER,
    fraud_indicator BOOLEAN,

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Supports account activity queries over a time period.
CREATE INDEX idx_fact_core_account_time
    ON dw.fact_core_transaction(account_key, transaction_timestamp);


-- One row per card transaction.
CREATE TABLE dw.fact_card_transaction (
    card_transaction_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    card_transaction_id TEXT NOT NULL UNIQUE,
    card_key BIGINT NOT NULL
        REFERENCES dw.dim_card(card_key),

    transaction_timestamp TIMESTAMP NOT NULL,
    transaction_amount NUMERIC(15,2),
    currency TEXT,
    merchant_name TEXT,
    merchant_category TEXT,
    merchant_category_code TEXT,
    transaction_type TEXT,
    transaction_status TEXT,
    payment_method TEXT,
    card_present_flag BOOLEAN,
    domestic_international TEXT,
    transaction_city TEXT,
    transaction_country TEXT,
    device_reference TEXT,
    authorization_code TEXT,
    fraud_risk_score INTEGER,
    fraud_indicator BOOLEAN,

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Supports card activity queries over a time period.
CREATE INDEX idx_fact_card_time
    ON dw.fact_card_transaction(card_key, transaction_timestamp);


-- One row per digital banking event.
CREATE TABLE dw.fact_digital_event (
    digital_event_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    digital_event_id TEXT NOT NULL UNIQUE,
    digital_user_key BIGINT NOT NULL
        REFERENCES dw.dim_digital_user(digital_user_key),

    event_timestamp TIMESTAMP NOT NULL,
    event_type TEXT,
    channel TEXT,
    device_id TEXT,
    device_fingerprint TEXT,
    device_type TEXT,
    operating_system TEXT,
    trusted_device_flag BOOLEAN,
    authentication_method TEXT,
    login_status TEXT,
    failed_login_attempts INTEGER,
    ip_address_synthetic TEXT,
    ip_region TEXT,
    event_city TEXT,
    event_country TEXT,
    digital_account_reference TEXT,
    beneficiary_reference TEXT,
    transaction_amount NUMERIC(15,2),
    transaction_status TEXT,
    event_risk_score INTEGER,
    fraud_indicator BOOLEAN,

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Supports digital user activity queries over time.
CREATE INDEX idx_fact_digital_user_time
    ON dw.fact_digital_event(digital_user_key, event_timestamp);

-- Supports analysis of devices shared across users.
CREATE INDEX idx_fact_digital_device
    ON dw.fact_digital_event(device_id);

