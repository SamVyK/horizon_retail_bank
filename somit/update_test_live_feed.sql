-- Update one user's status and last login
UPDATE staging.digital_users
SET digital_status = 'ACTIVE',
    last_login_timestamp = '2024-10-05 09:00:00'
WHERE digital_user_id = 'DU9003';

-- Update multiple rows in one statement
UPDATE staging.digital_users
SET preferred_platform = 'iOS'
WHERE digital_user_id IN ('DU9005', 'DU9006');