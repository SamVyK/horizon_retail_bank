INSERT INTO staging.card_transactions (
    card_transaction_id, card_id, transaction_timestamp, transaction_amount,
    currency, merchant_name, transaction_status, card_present_flag,
    domestic_international, transaction_city, transaction_country
) VALUES
('CTX_TEST_BURST_01', 'CARD_TEST_BURST', now(),                    980.00,
 'AUD', 'Electronics Store', 'APPROVED', 'TRUE', 'Domestic', 'Sydney', 'Australia'),
('CTX_TEST_BURST_02', 'CARD_TEST_BURST', now() + interval '2 min', 1010.00,
 'AUD', 'Electronics Store', 'APPROVED', 'TRUE', 'Domestic', 'Sydney', 'Australia'),
('CTX_TEST_BURST_03', 'CARD_TEST_BURST', now() + interval '4 min', 990.00,
 'AUD', 'Electronics Store', 'APPROVED', 'TRUE', 'Domestic', 'Sydney', 'Australia'),
('CTX_TEST_BURST_04', 'CARD_TEST_BURST', now() + interval '6 min', 1005.00,
 'AUD', 'Electronics Store', 'APPROVED', 'TRUE', 'Domestic', 'Sydney', 'Australia'),
('CTX_TEST_BURST_05', 'CARD_TEST_BURST', now() + interval '8 min', 995.00,
 'AUD', 'Electronics Store', 'APPROVED', 'TRUE', 'Domestic', 'Sydney', 'Australia');