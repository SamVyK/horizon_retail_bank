INSERT INTO staging.digital_users (
    digital_user_id, digital_account_reference, customer_name,
    registered_email, registered_phone, registration_date,
    digital_status, preferred_platform, biometric_enabled,
    mfa_enabled, notification_enabled, last_login_timestamp,
    digital_risk_band
) VALUES
    ('DU9001', 'ACC90001', 'Priya Sharma',
     'priya.sharma@example.com', '+61412340001', '2024-03-12',
     'ACTIVE', 'iOS', 'TRUE', 'TRUE', 'TRUE', '2024-09-28 08:15:00', 'LOW'),

    ('DU9002', 'ACC90002', 'Liam O''Connor',
     'liam.oconnor@example.com', '+61412340002', '2024-04-05',
     'ACTIVE', 'Android', 'FALSE', 'TRUE', 'TRUE', '2024-09-29 19:42:00', 'MEDIUM'),

    ('DU9003', 'ACC90003', 'Mei Lin',
     'mei.lin@example.com', '+61412340003', '2024-05-20',
     'PENDING', 'Web', 'FALSE', 'FALSE', 'TRUE', '2024-09-15 11:30:00', 'LOW'),

    ('DU9004', 'ACC90004', 'Ahmed Hassan',
     'ahmed.hassan@example.com', NULL, '2024-06-11',
     'SUSPENDED', 'Android', 'TRUE', 'TRUE', 'FALSE', '2024-08-01 07:00:00', 'HIGH'),

    ('DU9005', 'ACC90005', 'Sarah Williams',
     'sarah.williams@example.com', '+61412340005', '2024-07-02',
     'ACTIVE', 'iOS', 'TRUE', 'FALSE', 'TRUE', '2024-10-01 14:22:00', 'LOW'),

    ('DU9006', 'ACC90006', 'Tom Nguyen',
     'tom.nguyen@example.com', '+61412340006', '2024-08-18',
     'BLOCKED', 'Web', 'FALSE', 'FALSE', 'FALSE', NULL, 'HIGH');