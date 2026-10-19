INSERT INTO staging.digital_events (
    digital_event_id, digital_user_id, event_timestamp, event_type,
    device_id, login_status
) VALUES
('EV_TEST_RING_01', 'DU_TEST_A', now(),                   'Login', 'DEV_TEST_RING', 'SUCCESS'),
('EV_TEST_RING_02', 'DU_TEST_B', now() + interval '10 s', 'Login', 'DEV_TEST_RING', 'SUCCESS'),
('EV_TEST_RING_03', 'DU_TEST_C', now() + interval '20 s', 'Login', 'DEV_TEST_RING', 'SUCCESS');