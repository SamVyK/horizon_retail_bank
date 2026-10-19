INSERT INTO staging.card_transactions (
    card_transaction_id, card_id, transaction_timestamp, transaction_amount,
    currency, merchant_name, transaction_status, card_present_flag,
    domestic_international, transaction_city, transaction_country
) VALUES
('CTX_TEST_OVERSEAS_01', 'CARD_TEST_FRAUD', now(), 1364.83,
 'GBP', 'London Luxury', 'APPROVED', 'FALSE',
 'International', 'London', 'United Kingdom'),

('CTX_TEST_OVERSEAS_02', 'CARD_TEST_FRAUD', now() + interval '4 min', 900.00,
 'EUR', 'Paris Watches', 'APPROVED', 'FALSE',
 'International', 'Paris', 'France'),

('CTX_TEST_OVERSEAS_03', 'CARD_TEST_FRAUD', now() + interval '9 min', 1200.00,
 'USD', 'NYC Crypto', 'APPROVED', 'FALSE',
 'International', 'New York', 'United States');