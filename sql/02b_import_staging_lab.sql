-- LAB VERSION of Maedeh's 02b_import_staging.sql.
-- Only change: CSV paths point to /tmp/horizon_data/ inside the student-postgres
-- container (copied there with docker cp). Run the whole file with Execute script
-- in CloudBeaver, connected to the lab database.
-- Order: 01 -> 02 -> 02b -> 03 -> 04 -> 05.
-- Server-side COPY: files must be on the PostgreSQL server machine and readable
-- by its service account. Use postgres or a role permitted server-file access.
-- If file permissions block COPY, use pgAdmin Import/Export instead:
-- CSV, Header Yes, delimiter comma, quote and escape double quote.
-- No existing data is deleted. Populated staging tables block this import.
-- All eight imports commit together. After any error, run ROLLBACK; before retry.

BEGIN;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM staging.core_customers)
       OR EXISTS (SELECT 1 FROM staging.core_accounts)
       OR EXISTS (SELECT 1 FROM staging.core_transactions)
       OR EXISTS (SELECT 1 FROM staging.cards)
       OR EXISTS (SELECT 1 FROM staging.card_transactions)
       OR EXISTS (SELECT 1 FROM staging.digital_users)
       OR EXISTS (SELECT 1 FROM staging.digital_events)
       OR EXISTS (SELECT 1 FROM staging.entity_mapping_reference) THEN
        RAISE EXCEPTION 'Staging already contains data. Initial import cancelled.';
    END IF;
END;
$$;

COPY staging.core_customers
FROM '/tmp/horizon_data/core_customers.csv'
WITH (FORMAT CSV, HEADER TRUE, DELIMITER ',', ENCODING 'UTF8');

COPY staging.core_accounts
FROM '/tmp/horizon_data/core_accounts.csv'
WITH (FORMAT CSV, HEADER TRUE, DELIMITER ',', ENCODING 'UTF8');

COPY staging.core_transactions
FROM '/tmp/horizon_data/core_transactions.csv'
WITH (FORMAT CSV, HEADER TRUE, DELIMITER ',', ENCODING 'UTF8');

COPY staging.cards
FROM '/tmp/horizon_data/cards.csv'
WITH (FORMAT CSV, HEADER TRUE, DELIMITER ',', ENCODING 'UTF8');

COPY staging.card_transactions
FROM '/tmp/horizon_data/card_transactions.csv'
WITH (FORMAT CSV, HEADER TRUE, DELIMITER ',', ENCODING 'UTF8');

COPY staging.digital_users
FROM '/tmp/horizon_data/digital_users.csv'
WITH (FORMAT CSV, HEADER TRUE, DELIMITER ',', ENCODING 'UTF8');

COPY staging.digital_events
FROM '/tmp/horizon_data/digital_events.csv'
WITH (FORMAT CSV, HEADER TRUE, DELIMITER ',', ENCODING 'UTF8');

COPY staging.entity_mapping_reference
FROM '/tmp/horizon_data/entity_mapping_reference.csv'
WITH (FORMAT CSV, HEADER TRUE, DELIMITER ',', ENCODING 'UTF8');

COMMIT;

-- Expected counts: customers 5000, accounts 7500, core transactions 9500,
-- cards 5000, card transactions 9500, digital users 4000, digital events 9500,
-- mapping 5000.
SELECT 'core_customers' AS table_name, COUNT(*) AS row_count FROM staging.core_customers
UNION ALL
SELECT 'core_accounts' AS table_name, COUNT(*) AS row_count FROM staging.core_accounts
UNION ALL
SELECT 'core_transactions' AS table_name, COUNT(*) AS row_count FROM staging.core_transactions
UNION ALL
SELECT 'cards' AS table_name, COUNT(*) AS row_count FROM staging.cards
UNION ALL
SELECT 'card_transactions' AS table_name, COUNT(*) AS row_count FROM staging.card_transactions
UNION ALL
SELECT 'digital_users' AS table_name, COUNT(*) AS row_count FROM staging.digital_users
UNION ALL
SELECT 'digital_events' AS table_name, COUNT(*) AS row_count FROM staging.digital_events
UNION ALL
SELECT 'entity_mapping_reference' AS table_name, COUNT(*) AS row_count FROM staging.entity_mapping_reference;

