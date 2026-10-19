-- Raw customer data from the Core Banking CSV.
-- Column order matches core_customers.csv.
CREATE TABLE staging.core_customers (
    core_customer_id    TEXT,
    first_name          TEXT,
    last_name           TEXT,
    date_of_birth       TEXT,
    gender              TEXT,
    email               TEXT,
    phone               TEXT,
    address_line        TEXT,
    suburb              TEXT,
    city                TEXT,
    state               TEXT,
    postcode            TEXT,
    country             TEXT,
    customer_since_date TEXT,
    occupation_category TEXT,
    employment_status   TEXT,
    annual_income       TEXT,
    customer_segment    TEXT,
    kyc_status          TEXT,
    risk_category       TEXT
);

-- Raw account data; column order matches core_accounts.csv.
CREATE TABLE staging.core_accounts (
    core_account_id  TEXT,
    core_customer_id TEXT,
    account_type     TEXT,
    product_code     TEXT,
    account_status   TEXT,
    open_date        TEXT,
    close_date       TEXT,
    currency         TEXT,
    current_balance  TEXT,
    available_balance TEXT,
    overdraft_limit  TEXT,
    interest_rate    TEXT,
    branch_code      TEXT
);

-- Raw transactions; column order matches core_transactions.csv.
CREATE TABLE staging.core_transactions (
    core_account_id           TEXT,
    transaction_timestamp     TEXT,
    transaction_type          TEXT,
    transaction_amount        TEXT,
    debit_credit_indicator    TEXT,
    transaction_channel       TEXT,
    transaction_status        TEXT,
    currency                  TEXT,
    balance_after_transaction TEXT,
    counterparty_reference    TEXT,
    beneficiary_reference     TEXT,
    transaction_city          TEXT,
    transaction_state         TEXT,
    transaction_country       TEXT,
    transaction_description   TEXT,
    fraud_risk_score          TEXT,
    fraud_indicator           TEXT,
    core_transaction_id       TEXT
);

-- Raw card data; column order matches cards.csv.
CREATE TABLE staging.cards (
    card_id               TEXT,
    card_customer_id      TEXT,
    card_account_reference TEXT,
    customer_name         TEXT,
    billing_postcode      TEXT,
    card_type             TEXT,
    card_network          TEXT,
    card_status           TEXT,
    issue_date            TEXT,
    expiry_date           TEXT,
    credit_limit          TEXT,
    contactless_enabled   TEXT,
    international_enabled TEXT,
    card_risk_band        TEXT
);

-- Raw card transactions; column order matches card_transactions.csv.
CREATE TABLE staging.card_transactions (
    card_id                 TEXT,
    transaction_timestamp   TEXT,
    transaction_amount      TEXT,
    currency                TEXT,
    merchant_name           TEXT,
    merchant_category       TEXT,
    merchant_category_code  TEXT,
    transaction_type        TEXT,
    transaction_status      TEXT,
    payment_method          TEXT,
    card_present_flag       TEXT,
    domestic_international  TEXT,
    transaction_city        TEXT,
    transaction_country     TEXT,
    device_reference        TEXT,
    authorization_code      TEXT,
    fraud_risk_score        TEXT,
    fraud_indicator         TEXT,
    card_transaction_id     TEXT
);

-- Raw digital users; column order matches digital_users.csv.
CREATE TABLE staging.digital_users (
    digital_user_id           TEXT,
    digital_account_reference TEXT,
    customer_name             TEXT,
    registered_email          TEXT,
    registered_phone          TEXT,
    registration_date         TEXT,
    digital_status            TEXT,
    preferred_platform        TEXT,
    biometric_enabled         TEXT,
    mfa_enabled               TEXT,
    notification_enabled      TEXT,
    last_login_timestamp      TEXT,
    digital_risk_band         TEXT
);

-- Raw digital events; column order matches digital_events.csv.
CREATE TABLE staging.digital_events (
    digital_user_id           TEXT,
    event_timestamp           TEXT,
    event_type                TEXT,
    channel                   TEXT,
    device_id                 TEXT,
    device_fingerprint        TEXT,
    device_type               TEXT,
    operating_system          TEXT,
    trusted_device_flag       TEXT,
    authentication_method     TEXT,
    login_status              TEXT,
    failed_login_attempts     TEXT,
    ip_address_synthetic      TEXT,
    ip_region                 TEXT,
    event_city                TEXT,
    event_country             TEXT,
    digital_account_reference TEXT,
    beneficiary_reference     TEXT,
    transaction_amount        TEXT,
    transaction_status        TEXT,
    event_risk_score          TEXT,
    fraud_indicator           TEXT,
    digital_event_id          TEXT
);

-- Reference mapping supplied with the synthetic dataset.
-- Connects customer identifiers across the three source systems.
CREATE TABLE staging.entity_mapping_reference (
    enterprise_customer_key TEXT,
    core_customer_id        TEXT,
    card_customer_id        TEXT,
    digital_user_id         TEXT,
    primary_core_account_id TEXT
);