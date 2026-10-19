INSERT INTO staging.digital_events (
    digital_event_id, digital_user_id, event_type,
    beneficiary_reference, transaction_amount, transaction_status
) VALUES
('EV_TEST_BEN_01', 'DU_TEST_B1', 'Transfer', 'BEN_MULE_TEST', 500.00, 'COMPLETED'),
('EV_TEST_BEN_02', 'DU_TEST_B2', 'Transfer', 'BEN_MULE_TEST', 500.00, 'COMPLETED'),
('EV_TEST_BEN_03', 'DU_TEST_B3', 'Transfer', 'BEN_MULE_TEST', 500.00, 'COMPLETED'),
('EV_TEST_BEN_04', 'DU_TEST_B4', 'Transfer', 'BEN_MULE_TEST', 500.00, 'COMPLETED'),
('EV_TEST_BEN_05', 'DU_TEST_B5', 'Transfer', 'BEN_MULE_TEST', 500.00, 'COMPLETED'),
('EV_TEST_BEN_06', 'DU_TEST_B6', 'Transfer', 'BEN_MULE_TEST', 500.00, 'COMPLETED');