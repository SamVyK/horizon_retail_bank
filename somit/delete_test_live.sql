-- Delete all test rows in one statement
DELETE FROM staging.digital_users
WHERE digital_user_id LIKE 'DU9%';