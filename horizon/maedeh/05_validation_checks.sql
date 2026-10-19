-- Horizon Retail Bank: warehouse validation checks.
-- Run against the lab database.

-- 1. Confirm the database connection.
SELECT current_database();

-- 2. Check staging row counts.
SELECT 'core_customers' AS table_name, COUNT(*) AS row_count
FROM staging.core_customers
UNION ALL
SELECT 'core_accounts', COUNT(*) FROM staging.core_accounts
UNION ALL
SELECT 'core_transactions', COUNT(*) FROM staging.core_transactions
UNION ALL
SELECT 'cards', COUNT(*) FROM staging.cards
UNION ALL
SELECT 'card_transactions', COUNT(*) FROM staging.card_transactions
UNION ALL
SELECT 'digital_users', COUNT(*) FROM staging.digital_users
UNION ALL
SELECT 'digital_events', COUNT(*) FROM staging.digital_events
UNION ALL
SELECT 'entity_mapping_reference', COUNT(*)
FROM staging.entity_mapping_reference;

-- 3. Check enterprise customer keys.
-- Expected: 5000 total, 5000 unique, 0 missing.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT enterprise_customer_key) AS unique_customers,
    COUNT(*) FILTER (
        WHERE NULLIF(TRIM(enterprise_customer_key), '') IS NULL
    ) AS missing_customer_keys
FROM staging.entity_mapping_reference;

-- 4. List warehouse tables.
-- Expected: 7 tables.
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'dw'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;

-- 5. Check core customer mapping.
-- Expected: zero rows.
SELECT
    c.core_customer_id,
    COUNT(m.enterprise_customer_key) AS mapping_count
FROM staging.core_customers AS c
LEFT JOIN staging.entity_mapping_reference AS m
    ON TRIM(c.core_customer_id) = TRIM(m.core_customer_id)
GROUP BY c.core_customer_id
HAVING COUNT(m.enterprise_customer_key) <> 1;

-- 6. Check card and digital user mapping.
-- Expected: zero rows.
SELECT
    'card' AS entity_type,
    c.card_id AS source_id,
    COUNT(m.enterprise_customer_key) AS mapping_count
FROM staging.cards AS c
LEFT JOIN staging.entity_mapping_reference AS m
    ON TRIM(c.card_customer_id) = TRIM(m.card_customer_id)
GROUP BY c.card_id
HAVING COUNT(m.enterprise_customer_key) <> 1
UNION ALL
SELECT
    'digital_user',
    u.digital_user_id,
    COUNT(m.enterprise_customer_key)
FROM staging.digital_users AS u
LEFT JOIN staging.entity_mapping_reference AS m
    ON TRIM(u.digital_user_id) = TRIM(m.digital_user_id)
GROUP BY u.digital_user_id
HAVING COUNT(m.enterprise_customer_key) <> 1;

-- 7. Check warehouse row counts against expected source counts.
SELECT 'dim_customer' AS table_name,
       COUNT(*) AS actual_rows, 5000 AS expected_rows
FROM dw.dim_customer
UNION ALL
SELECT 'dim_account', COUNT(*), 7500 FROM dw.dim_account
UNION ALL
SELECT 'dim_card', COUNT(*), 5000 FROM dw.dim_card
UNION ALL
SELECT 'dim_digital_user', COUNT(*), 4000 FROM dw.dim_digital_user
UNION ALL
SELECT 'fact_core_transaction', COUNT(*), 9500
FROM dw.fact_core_transaction
UNION ALL
SELECT 'fact_card_transaction', COUNT(*), 9500
FROM dw.fact_card_transaction
UNION ALL
SELECT 'fact_digital_event', COUNT(*), 9500
FROM dw.fact_digital_event;


-- 8. Find source transactions/events missing from the warehouse.
-- Expected: zero missing records for each table.
SELECT 'core_transactions' AS source_table,
       COUNT(*) AS missing_records
FROM staging.core_transactions AS s
WHERE NOT EXISTS (
    SELECT 1
    FROM dw.fact_core_transaction AS w
    WHERE w.core_transaction_id = TRIM(s.core_transaction_id)
)
UNION ALL
SELECT 'card_transactions', COUNT(*)
FROM staging.card_transactions AS s
WHERE NOT EXISTS (
    SELECT 1
    FROM dw.fact_card_transaction AS w
    WHERE w.card_transaction_id = TRIM(s.card_transaction_id)
)
UNION ALL
SELECT 'digital_events', COUNT(*)
FROM staging.digital_events AS s
WHERE NOT EXISTS (
    SELECT 1
    FROM dw.fact_digital_event AS w
    WHERE w.digital_event_id = TRIM(s.digital_event_id)
);

-- 9. Reconcile core transaction amounts.
SELECT
    s.source_total,
    w.warehouse_total,
    s.source_total - w.warehouse_total AS difference
FROM (
    SELECT SUM(
        NULLIF(TRIM(transaction_amount), '')::NUMERIC(15,2)
    ) AS source_total
    FROM staging.core_transactions
) AS s
CROSS JOIN (
    SELECT SUM(transaction_amount) AS warehouse_total
    FROM dw.fact_core_transaction
) AS w;

-- 10. Reconcile card transaction amounts by currency.
WITH source_totals AS (
    SELECT
        UPPER(TRIM(currency)) AS currency,
        SUM(
            NULLIF(TRIM(transaction_amount), '')::NUMERIC(15,2)
        ) AS source_total
    FROM staging.card_transactions
    GROUP BY UPPER(TRIM(currency))
),
warehouse_totals AS (
    SELECT currency, SUM(transaction_amount) AS warehouse_total
    FROM dw.fact_card_transaction
    GROUP BY currency
)
SELECT
    COALESCE(s.currency, w.currency) AS currency,
    s.source_total,
    w.warehouse_total,
    COALESCE(s.source_total, 0)
        - COALESCE(w.warehouse_total, 0) AS difference
FROM source_totals AS s
FULL JOIN warehouse_totals AS w
    ON s.currency = w.currency
ORDER BY currency;

-- 11. Reconcile digital event amounts and populated amount counts.
SELECT
    s.amount_count AS source_amount_count,
    w.amount_count AS warehouse_amount_count,
    s.total AS source_total,
    w.total AS warehouse_total,
    s.total - w.total AS difference
FROM (
    SELECT
        COUNT(NULLIF(TRIM(transaction_amount), '')) AS amount_count,
        SUM(NULLIF(TRIM(transaction_amount), '')::NUMERIC(15,2)) AS total
    FROM staging.digital_events
) AS s
CROSS JOIN (
    SELECT
        COUNT(transaction_amount) AS amount_count,
        SUM(transaction_amount) AS total
    FROM dw.fact_digital_event
) AS w;

-- 12. Demonstrate customer integration across all three systems.
SELECT
    c.enterprise_customer_key,
    c.core_customer_id,
    c.card_customer_id,
    c.digital_user_id,
    (SELECT COUNT(*)
     FROM dw.dim_account AS a
     WHERE a.customer_key = c.customer_key) AS account_count,
    (SELECT COUNT(*)
     FROM dw.dim_card AS k
     WHERE k.customer_key = c.customer_key) AS card_count,
    (SELECT COUNT(*)
     FROM dw.dim_digital_user AS u
     WHERE u.customer_key = c.customer_key) AS digital_user_count
FROM dw.dim_customer AS c
WHERE c.enterprise_customer_key = 'ENT_C000001';

-- 13. Reconcile fraud labels against source records.
-- Expected TRUE counts: core 105, card 112, digital 121.
-- Expected label mismatches: 0 for all three systems.
SELECT
    'core' AS source_system,
    (SELECT COUNT(*) FROM staging.core_transactions
     WHERE NULLIF(TRIM(fraud_indicator), '')::BOOLEAN IS TRUE)
        AS source_true,
    COUNT(*) FILTER (WHERE w.fraud_indicator IS TRUE)
        AS warehouse_true,
    105 AS expected_true,
    COUNT(*) FILTER (
        WHERE w.fraud_indicator IS DISTINCT FROM
              NULLIF(TRIM(s.fraud_indicator), '')::BOOLEAN
    ) AS label_mismatches
FROM staging.core_transactions s
JOIN dw.fact_core_transaction w
    ON w.core_transaction_id = TRIM(s.core_transaction_id)
UNION ALL
SELECT
    'card',
    (SELECT COUNT(*) FROM staging.card_transactions
     WHERE NULLIF(TRIM(fraud_indicator), '')::BOOLEAN IS TRUE),
    COUNT(*) FILTER (WHERE w.fraud_indicator IS TRUE),
    112,
    COUNT(*) FILTER (
        WHERE w.fraud_indicator IS DISTINCT FROM
              NULLIF(TRIM(s.fraud_indicator), '')::BOOLEAN
    )
FROM staging.card_transactions s
JOIN dw.fact_card_transaction w
    ON w.card_transaction_id = TRIM(s.card_transaction_id)
UNION ALL
SELECT
    'digital',
    (SELECT COUNT(*) FROM staging.digital_events
     WHERE NULLIF(TRIM(fraud_indicator), '')::BOOLEAN IS TRUE),
    COUNT(*) FILTER (WHERE w.fraud_indicator IS TRUE),
    121,
    COUNT(*) FILTER (
        WHERE w.fraud_indicator IS DISTINCT FROM
              NULLIF(TRIM(s.fraud_indicator), '')::BOOLEAN
    )
FROM staging.digital_events s
JOIN dw.fact_digital_event w
    ON w.digital_event_id = TRIM(s.digital_event_id);

-- 14. Check phone and email consistency across linked customers.
-- Expected: 4000 linked users, 4000 phone matches, 4000 email matches.
SELECT
    COUNT(*) AS linked_users,
    COUNT(*) FILTER (
        WHERE NULLIF(c.phone, '') IS NOT NULL
          AND c.phone = u.registered_phone
    ) AS phone_matches,
    COUNT(*) FILTER (
        WHERE NULLIF(c.email, '') IS NOT NULL
          AND c.email = u.registered_email
    ) AS email_matches
FROM dw.dim_customer c
JOIN dw.dim_digital_user u
    ON u.customer_key = c.customer_key;