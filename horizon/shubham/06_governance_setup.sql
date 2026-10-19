/* =====================================================================
   Horizon Retail Bank - Data Fabric (Governance Layer)
   Script 06: Governance setup
   Owner     : Shubham Bhardwaj (25755442)
   Database  : horizon_dw   (connect to horizon_dw before running)
   Run after : 01 -> 02 -> 02b -> 03 -> 04 -> 05 (integrated warehouse)
   Run order : 06_governance_setup.sql -> 07_run_governance.sql
               -> 08_report3_lineage_quality.sql
   ---------------------------------------------------------------------
   PURPOSE
   Assignment 1 recommended a data fabric to provide metadata, lineage,
   data quality and access governance across Horizon's fragmented
   systems. This script implements that capability inside PostgreSQL as
   a metadata layer that sits ALONGSIDE the warehouse. It does not move
   or change any warehouse data; it describes, traces, tests and
   protects it.

   WHAT THIS SCRIPT CREATES
   1. Schemas      governance (metadata) and secure (masked views)
   2. Registry     governance.managed_schema   - which schemas the fabric
                                                 catalogs, layer, owner
                   governance.table_description - business meaning and
                                                 ownership of each table
   3. Catalog      governance.data_catalog      - one row per table/view
                   governance.column_catalog    - one row per column with
                                                 an automatic sensitivity
                                                 classification
   4. Lineage      governance.lineage           - one row per data flow
                                                 (source -> target)
   5. Quality      governance.dq_rule           - rules written as SQL
                   governance.dq_run            - one row per execution
                   governance.dq_result         - one row per rule per run
   6. Functions    refresh_catalog(), classify_column(),
                   run_quality_checks(), trace_upstream()
   7. Access       roles fraud_analyst, data_steward, compliance_auditor;
                   masked views in schema secure; GRANT/REVOKE policy

   RE-RUNNING
   This script is safe to re-run. It drops and recreates ONLY the
   governance and secure schemas (so quality-run history is reset).
   Roles are created only if they do not exist. The staging and dw
   schemas are never modified.

   COMPATIBILITY
   Uses standard PostgreSQL 15 features only (Lab Environment version).
   No extensions required. In CloudBeaver, run with "Execute script"
   (Alt+X), not "Execute statement".
   ===================================================================== */


/* ---------------------------------------------------------------------
   SECTION 0 - Pre-flight check
   Stop early with a clear message if the warehouse has not been built.
   --------------------------------------------------------------------- */
DO $$
BEGIN
    IF to_regclass('dw.dim_customer') IS NULL
       OR to_regclass('staging.core_customers') IS NULL THEN
        RAISE EXCEPTION
          'Warehouse not found. Connect to horizon_dw and run scripts 01-05 first.';
    END IF;
END;
$$;


/* ---------------------------------------------------------------------
   SECTION 1 - Schemas
   governance : all metadata tables, functions and report views
   secure     : privacy-safe (masked) views for analysts
   CASCADE removes the previous version of every object in these two
   schemas only, which makes the script re-runnable.
   --------------------------------------------------------------------- */
DROP SCHEMA IF EXISTS secure CASCADE;
DROP SCHEMA IF EXISTS governance CASCADE;

CREATE SCHEMA governance;
COMMENT ON SCHEMA governance IS
  'Data fabric metadata layer: catalog, lineage, data quality and access governance.';

CREATE SCHEMA secure;
COMMENT ON SCHEMA secure IS
  'Masked, privacy-safe views of warehouse data for analyst roles.';


/* ---------------------------------------------------------------------
   SECTION 2 - Registry of governed schemas and tables
   ---------------------------------------------------------------------
   managed_schema lists every schema the fabric catalogs. Other team
   workstreams (lakehouse, graph export, streaming) only need to INSERT
   one row here and re-run 07 to be catalogued automatically.
   --------------------------------------------------------------------- */
CREATE TABLE governance.managed_schema (
    schema_name     TEXT PRIMARY KEY,
    layer           TEXT NOT NULL
        CHECK (layer IN ('SOURCE','STAGING','WAREHOUSE','LAKEHOUSE',
                         'GRAPH','STREAMING','GOVERNANCE','PRESENTATION')),
    layer_order     INTEGER NOT NULL,          -- position in the data flow
    technical_owner TEXT NOT NULL,             -- team member responsible
    description     TEXT NOT NULL
);

INSERT INTO governance.managed_schema VALUES
 ('staging',    'STAGING',      1, 'Maedeh Mehdizadeh',
  'Raw copies of the three source systems, all columns stored as TEXT.'),
 ('dw',         'WAREHOUSE',    2, 'Maedeh Mehdizadeh',
  'Integrated dimensional warehouse: 4 dimensions and 3 fact tables.'),
 ('governance', 'GOVERNANCE',   3, 'Shubham Bhardwaj',
  'Data fabric metadata: catalog, lineage, quality rules and results.'),
 ('secure',     'PRESENTATION', 4, 'Shubham Bhardwaj',
  'Masked views that expose warehouse data without direct identifiers.');


/* table_description holds the business meaning of each table. The
   catalog refresh joins this to information_schema, so technical
   metadata (columns, types, row counts) is collected automatically and
   only the business context is maintained by hand. */
CREATE TABLE governance.table_description (
    schema_name     TEXT NOT NULL,
    table_name      TEXT NOT NULL,
    source_system   TEXT,                       -- originating system
    business_owner  TEXT NOT NULL,              -- accountable role (fictitious)
    description     TEXT NOT NULL,
    grain           TEXT,                       -- what one row represents
    PRIMARY KEY (schema_name, table_name)
);

INSERT INTO governance.table_description VALUES
 -- Staging: raw source extracts
 ('staging','core_customers','Core Banking','Head of Retail Operations',
  'Customer master records from the legacy core banking system.','One row per core customer'),
 ('staging','core_accounts','Core Banking','Head of Retail Operations',
  'Deposit, loan and business accounts held in core banking.','One row per account'),
 ('staging','core_transactions','Core Banking','Head of Payments',
  'Ledger transactions posted against core banking accounts.','One row per ledger transaction'),
 ('staging','cards','Card Processing','Head of Cards',
  'Debit and credit cards issued by the card management vendor.','One row per card'),
 ('staging','card_transactions','Card Processing','Head of Cards',
  'Card authorisations and purchases from the card processor.','One row per card transaction'),
 ('staging','digital_users','Digital Banking','Head of Digital Channels',
  'Registered internet and mobile banking users.','One row per digital user'),
 ('staging','digital_events','Digital Banking','Head of Digital Channels',
  'Login, session and payment events from the digital banking app.','One row per digital event'),
 ('staging','entity_mapping_reference','Reference Data','Chief Data Officer',
  'Cross-system customer identity mapping supplied with the synthetic dataset.','One row per enterprise customer'),
 -- Warehouse: integrated dimensional model
 ('dw','dim_customer','Integrated','Chief Data Officer',
  'Single enterprise view of each customer across all three systems.','One row per enterprise customer'),
 ('dw','dim_account','Core Banking','Head of Retail Operations',
  'Core banking accounts linked to the enterprise customer.','One row per account'),
 ('dw','dim_card','Card Processing','Head of Cards',
  'Cards linked to the enterprise customer through the identity mapping.','One row per card'),
 ('dw','dim_digital_user','Digital Banking','Head of Digital Channels',
  'Digital banking profiles linked to the enterprise customer.','One row per digital user'),
 ('dw','fact_core_transaction','Core Banking','Head of Payments',
  'Typed and cleaned core banking transactions for fraud analysis.','One row per ledger transaction'),
 ('dw','fact_card_transaction','Card Processing','Head of Cards',
  'Typed and cleaned card transactions for fraud analysis.','One row per card transaction'),
 ('dw','fact_digital_event','Digital Banking','Head of Digital Channels',
  'Typed and cleaned digital banking events for fraud analysis.','One row per digital event'),
 -- Presentation: masked views for analysts (created in section 9)
 ('secure','v_customer_masked','Integrated','Chief Data Officer',
  'Customer dimension with direct identifiers masked for analyst use.','One row per enterprise customer'),
 ('secure','v_card_masked','Card Processing','Head of Cards',
  'Card dimension with card holder name masked for analyst use.','One row per card'),
 ('secure','v_digital_user_masked','Digital Banking','Head of Digital Channels',
  'Digital user dimension with email and phone masked for analyst use.','One row per digital user');


/* ---------------------------------------------------------------------
   SECTION 3 - Catalog tables
   ---------------------------------------------------------------------
   These are filled by governance.refresh_catalog() (defined below and
   called in script 07). Storing the result as a table, rather than
   querying information_schema directly, gives a dated snapshot with
   row counts and business context that analysts can search.
   --------------------------------------------------------------------- */
CREATE TABLE governance.data_catalog (
    catalog_id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schema_name      TEXT NOT NULL REFERENCES governance.managed_schema(schema_name),
    table_name       TEXT NOT NULL,
    object_type      TEXT NOT NULL,             -- BASE TABLE or VIEW
    layer            TEXT NOT NULL,
    source_system    TEXT,
    business_owner   TEXT,
    technical_owner  TEXT,
    description      TEXT,
    grain            TEXT,
    column_count     INTEGER,
    row_count        BIGINT,
    sensitive_column_count INTEGER,
    refreshed_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (schema_name, table_name)
);

CREATE TABLE governance.column_catalog (
    schema_name      TEXT NOT NULL,
    table_name       TEXT NOT NULL,
    column_name      TEXT NOT NULL,
    ordinal_position INTEGER NOT NULL,
    data_type        TEXT NOT NULL,
    is_nullable      BOOLEAN NOT NULL,
    sensitivity      TEXT NOT NULL,             -- see classify_column()
    handling_rule    TEXT NOT NULL,             -- how the column must be treated
    refreshed_at     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (schema_name, table_name, column_name)
);


/* ---------------------------------------------------------------------
   SECTION 4 - Automatic sensitivity classification
   ---------------------------------------------------------------------
   Classifies a column from its name. This is a simple form of the
   "active metadata" idea behind a data fabric: new columns are
   classified the moment they appear, without manual tagging.
   Order matters: the first matching pattern wins.
     PII_DIRECT     identifies a person on its own (name, email, phone...)
     PII_QUASI      identifies a person when combined (postcode, suburb...)
     DEVICE_NETWORK device or network identifiers (IP, fingerprint)
     FINANCIAL      money values (balances, amounts, limits, income)
     IDENTIFIER     system keys used to join data
     GENERAL        everything else
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION governance.classify_column(p_column TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_column ~ '(^|_)(first_name|last_name|customer_name|email|registered_email|phone|registered_phone|address_line|date_of_birth)$'
            THEN 'PII_DIRECT'
        WHEN p_column ~ '(suburb|postcode|^city$|gender|occupation|employment)'
            THEN 'PII_QUASI'
        WHEN p_column ~ '(ip_address|device_fingerprint|device_id|ip_region)'
            THEN 'DEVICE_NETWORK'
        WHEN p_column ~ '(balance|amount|credit_limit|overdraft|income)'
            THEN 'FINANCIAL'
        WHEN p_column ~ '(_id|_key|_reference)$'
            THEN 'IDENTIFIER'
        ELSE 'GENERAL'
    END;
$$;

COMMENT ON FUNCTION governance.classify_column(TEXT) IS
  'Classifies a column by name into a sensitivity class used for access and masking rules.';


/* ---------------------------------------------------------------------
   SECTION 5 - Catalog refresh procedure
   ---------------------------------------------------------------------
   Rebuilds data_catalog and column_catalog from information_schema for
   every schema listed in managed_schema, then counts rows in each
   object with dynamic SQL. format('%I') quotes identifiers safely.
   Returns the number of objects catalogued.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION governance.refresh_catalog()
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    obj        RECORD;
    v_rows     BIGINT;
    v_objects  INTEGER := 0;
BEGIN
    -- 1. Column-level metadata with automatic classification
    DELETE FROM governance.column_catalog;

    INSERT INTO governance.column_catalog
          (schema_name, table_name, column_name, ordinal_position,
           data_type, is_nullable, sensitivity, handling_rule)
    SELECT c.table_schema,
           c.table_name,
           c.column_name,
           c.ordinal_position,
           c.data_type,
           (c.is_nullable = 'YES'),
           governance.classify_column(c.column_name),
           CASE governance.classify_column(c.column_name)
               WHEN 'PII_DIRECT'     THEN 'Mask for analysts; full access data_steward only'
               WHEN 'PII_QUASI'      THEN 'Allowed in aggregates; avoid combining with other quasi-identifiers'
               WHEN 'DEVICE_NETWORK' THEN 'Use for fraud investigation only; retain per AML policy'
               WHEN 'FINANCIAL'      THEN 'Confidential; internal analysis only'
               WHEN 'IDENTIFIER'     THEN 'Internal join key; do not publish externally'
               ELSE                       'No special handling'
           END
    FROM information_schema.columns AS c
    JOIN governance.managed_schema AS m
      ON m.schema_name = c.table_schema;

    -- 2. Object-level metadata (tables and views)
    DELETE FROM governance.data_catalog;

    FOR obj IN
        SELECT t.table_schema, t.table_name, t.table_type,
               m.layer, m.technical_owner,
               d.source_system, d.business_owner, d.description, d.grain
        FROM information_schema.tables AS t
        JOIN governance.managed_schema AS m
          ON m.schema_name = t.table_schema
        LEFT JOIN governance.table_description AS d
          ON d.schema_name = t.table_schema
         AND d.table_name  = t.table_name
        ORDER BY m.layer_order, t.table_name
    LOOP
        -- Live row count for each object
        EXECUTE format('SELECT COUNT(*) FROM %I.%I',
                       obj.table_schema, obj.table_name)
           INTO v_rows;

        INSERT INTO governance.data_catalog
              (schema_name, table_name, object_type, layer, source_system,
               business_owner, technical_owner, description, grain,
               column_count, row_count, sensitive_column_count)
        SELECT obj.table_schema,
               obj.table_name,
               obj.table_type,
               obj.layer,
               obj.source_system,
               COALESCE(obj.business_owner, 'Unassigned'),
               obj.technical_owner,
               COALESCE(obj.description, 'No business description recorded'),
               obj.grain,
               COUNT(*),
               v_rows,
               COUNT(*) FILTER (WHERE cc.sensitivity IN
                                ('PII_DIRECT','PII_QUASI','DEVICE_NETWORK'))
        FROM governance.column_catalog AS cc
        WHERE cc.schema_name = obj.table_schema
          AND cc.table_name  = obj.table_name;

        v_objects := v_objects + 1;
    END LOOP;

    RETURN v_objects;
END;
$$;

COMMENT ON FUNCTION governance.refresh_catalog() IS
  'Rebuilds the data and column catalogs from information_schema with live row counts.';


/* ---------------------------------------------------------------------
   SECTION 6 - Lineage
   ---------------------------------------------------------------------
   One row per data flow. Objects are written as 'schema.table'; source
   files are written as 'file:<name>.csv'. Every flow names the script
   that performs it, so any warehouse number can be traced back to a
   file and a line of code. Flows were taken directly from scripts 02b
   and 04, and from this script for the secure views.
     INGEST       file copied into staging unchanged
     TRANSFORM    cleaned, typed and loaded into the warehouse
     KEY_LOOKUP   used only to resolve a foreign/surrogate key
     DERIVED_VIEW view built on top of a table
   --------------------------------------------------------------------- */
CREATE TABLE governance.lineage (
    lineage_id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_object      TEXT NOT NULL,
    target_object      TEXT NOT NULL,
    lineage_type       TEXT NOT NULL
        CHECK (lineage_type IN ('INGEST','TRANSFORM','KEY_LOOKUP','DERIVED_VIEW')),
    transformation_script TEXT NOT NULL,
    transformation_summary TEXT NOT NULL,
    recorded_by        TEXT NOT NULL DEFAULT 'Shubham Bhardwaj',
    recorded_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (source_object, target_object)
);

INSERT INTO governance.lineage
      (source_object, target_object, lineage_type, transformation_script, transformation_summary)
VALUES
 -- Files -> staging (script 02b: COPY, no transformation)
 ('file:core_customers.csv',          'staging.core_customers',          'INGEST','02b_import_staging.sql','CSV copied as TEXT, unchanged'),
 ('file:core_accounts.csv',           'staging.core_accounts',           'INGEST','02b_import_staging.sql','CSV copied as TEXT, unchanged'),
 ('file:core_transactions.csv',       'staging.core_transactions',       'INGEST','02b_import_staging.sql','CSV copied as TEXT, unchanged'),
 ('file:cards.csv',                   'staging.cards',                   'INGEST','02b_import_staging.sql','CSV copied as TEXT, unchanged'),
 ('file:card_transactions.csv',       'staging.card_transactions',       'INGEST','02b_import_staging.sql','CSV copied as TEXT, unchanged'),
 ('file:digital_users.csv',           'staging.digital_users',           'INGEST','02b_import_staging.sql','CSV copied as TEXT, unchanged'),
 ('file:digital_events.csv',          'staging.digital_events',          'INGEST','02b_import_staging.sql','CSV copied as TEXT, unchanged'),
 ('file:entity_mapping_reference.csv','staging.entity_mapping_reference','INGEST','02b_import_staging.sql','CSV copied as TEXT, unchanged'),
 -- Staging -> warehouse dimensions (script 04)
 ('staging.core_customers',           'dw.dim_customer',   'TRANSFORM', '04_load_warehouse.sql','Trim text, lowercase email, phone to +61 format, cast dates and income'),
 ('staging.entity_mapping_reference', 'dw.dim_customer',   'TRANSFORM', '04_load_warehouse.sql','Adds enterprise key, card customer id and digital user id'),
 ('staging.core_accounts',            'dw.dim_account',    'TRANSFORM', '04_load_warehouse.sql','Trim, uppercase status and currency, cast dates and balances'),
 ('dw.dim_customer',                  'dw.dim_account',    'KEY_LOOKUP','04_load_warehouse.sql','Resolves customer_key from core_customer_id'),
 ('staging.cards',                    'dw.dim_card',       'TRANSFORM', '04_load_warehouse.sql','Trim, uppercase codes, cast dates, limits and flags'),
 ('staging.entity_mapping_reference', 'dw.dim_card',       'KEY_LOOKUP','04_load_warehouse.sql','Maps card_customer_id to enterprise customer'),
 ('dw.dim_customer',                  'dw.dim_card',       'KEY_LOOKUP','04_load_warehouse.sql','Resolves customer_key from enterprise key'),
 ('staging.digital_users',            'dw.dim_digital_user','TRANSFORM','04_load_warehouse.sql','Lowercase email, phone to +61 format, cast dates and flags'),
 ('staging.entity_mapping_reference', 'dw.dim_digital_user','KEY_LOOKUP','04_load_warehouse.sql','Maps digital_user_id to enterprise customer'),
 ('dw.dim_customer',                  'dw.dim_digital_user','KEY_LOOKUP','04_load_warehouse.sql','Resolves customer_key from enterprise key'),
 -- Staging -> warehouse facts (script 04)
 ('staging.core_transactions',        'dw.fact_core_transaction','TRANSFORM', '04_load_warehouse.sql','Cast timestamp, amount, score and fraud flag'),
 ('dw.dim_account',                   'dw.fact_core_transaction','KEY_LOOKUP','04_load_warehouse.sql','Resolves account_key from core_account_id'),
 ('staging.card_transactions',        'dw.fact_card_transaction','TRANSFORM', '04_load_warehouse.sql','Cast timestamp, amount, flags and score; currency kept as source'),
 ('dw.dim_card',                      'dw.fact_card_transaction','KEY_LOOKUP','04_load_warehouse.sql','Resolves card_key from card_id'),
 ('staging.digital_events',           'dw.fact_digital_event',   'TRANSFORM', '04_load_warehouse.sql','Cast timestamp, attempts, amount, score and flags'),
 ('dw.dim_digital_user',              'dw.fact_digital_event',   'KEY_LOOKUP','04_load_warehouse.sql','Resolves digital_user_key from digital_user_id'),
 -- Warehouse -> secure views (this script, section 9)
 ('dw.dim_customer',     'secure.v_customer_masked',     'DERIVED_VIEW','06_governance_setup.sql','Direct identifiers masked; birth date reduced to birth year'),
 ('dw.dim_card',         'secure.v_card_masked',         'DERIVED_VIEW','06_governance_setup.sql','Card holder name reduced to initial and masked surname'),
 ('dw.dim_digital_user', 'secure.v_digital_user_masked', 'DERIVED_VIEW','06_governance_setup.sql','Email and phone masked');


/* trace_upstream walks the lineage graph backwards from any object with
   a recursive query, returning every upstream object and how many hops
   away it is. Example: governance.trace_upstream('dw.fact_card_transaction')
   The depth limit of 10 protects against accidental cycles. */
CREATE OR REPLACE FUNCTION governance.trace_upstream(p_object TEXT)
RETURNS TABLE (hop INTEGER, source_object TEXT, target_object TEXT,
               lineage_type TEXT, transformation_script TEXT, path TEXT)
LANGUAGE SQL
STABLE
AS $$
    WITH RECURSIVE up AS (
        SELECT 1 AS hop, l.source_object, l.target_object, l.lineage_type,
               l.transformation_script,
               l.source_object || ' -> ' || l.target_object AS path
        FROM governance.lineage AS l
        WHERE l.target_object = p_object
        UNION ALL
        SELECT up.hop + 1, l.source_object, l.target_object, l.lineage_type,
               l.transformation_script,
               l.source_object || ' -> ' || up.path
        FROM governance.lineage AS l
        JOIN up ON l.target_object = up.source_object
        WHERE up.hop < 10
    )
    SELECT hop, source_object, target_object, lineage_type,
           transformation_script, path
    FROM up
    ORDER BY hop, source_object;
$$;

COMMENT ON FUNCTION governance.trace_upstream(TEXT) IS
  'Returns all upstream objects of a table or view by walking the lineage graph.';


/* ---------------------------------------------------------------------
   SECTION 7 - Data quality rules
   ---------------------------------------------------------------------
   Each rule is stored as data, not code: its check_sql must return ONE
   row with two numbers (rows_checked, rows_failed). Keeping rules in a
   table means new rules can be added without changing the engine, and
   the rule text is itself documented in the catalog.

   Rules come from the business rules in the source data dictionary
   (Schema.xlsx) unless marked otherwise. Dimensions follow the common
   data quality dimensions: Completeness, Validity, Consistency,
   Uniqueness, Timeliness and Accuracy.

   tolerance_pct is the share of failing rows still accepted as PASS.
   Most rules allow 0%; a rule that describes a known business pattern
   (shared family emails) allows a small tolerance.
   check_type CONTROL rules are enforced (PASS/FAIL). PROFILE rules are
   measured for information only (status INFO), e.g. raw source quality
   before cleansing, so it can be compared with the warehouse.
   --------------------------------------------------------------------- */
CREATE TABLE governance.dq_rule (
    rule_id         TEXT PRIMARY KEY,
    rule_name       TEXT NOT NULL,
    dq_dimension    TEXT NOT NULL
        CHECK (dq_dimension IN ('Completeness','Validity','Consistency',
                                'Uniqueness','Timeliness','Accuracy')),
    target_object   TEXT NOT NULL,              -- 'schema.table' tested
    rule_description TEXT NOT NULL,
    check_sql       TEXT NOT NULL,              -- returns (rows_checked, rows_failed)
    severity        TEXT NOT NULL
        CHECK (severity IN ('CRITICAL','HIGH','MEDIUM','LOW')),
    tolerance_pct   NUMERIC(5,2) NOT NULL DEFAULT 0,
    rule_source     TEXT NOT NULL,
    check_type      TEXT NOT NULL DEFAULT 'CONTROL'
        CHECK (check_type IN ('CONTROL','PROFILE')),  -- PROFILE = measured, not enforced
    is_active       BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO governance.dq_rule
      (rule_id, rule_name, dq_dimension, target_object, rule_description,
       check_sql, severity, tolerance_pct, rule_source)
VALUES
-- ---------- Completeness: nothing lost between layers ----------
('DQ_REC_01','All source transactions and events reach the warehouse','Completeness','dw.fact_*',
 'Every row in the three staging transaction/event tables must exist in its warehouse fact table.',
 $q$SELECT
      (SELECT COUNT(*) FROM staging.core_transactions)
    + (SELECT COUNT(*) FROM staging.card_transactions)
    + (SELECT COUNT(*) FROM staging.digital_events),
      (SELECT COUNT(*) FROM staging.core_transactions s
        WHERE NOT EXISTS (SELECT 1 FROM dw.fact_core_transaction w
                          WHERE w.core_transaction_id = TRIM(s.core_transaction_id)))
    + (SELECT COUNT(*) FROM staging.card_transactions s
        WHERE NOT EXISTS (SELECT 1 FROM dw.fact_card_transaction w
                          WHERE w.card_transaction_id = TRIM(s.card_transaction_id)))
    + (SELECT COUNT(*) FROM staging.digital_events s
        WHERE NOT EXISTS (SELECT 1 FROM dw.fact_digital_event w
                          WHERE w.digital_event_id = TRIM(s.digital_event_id)))$q$,
 'CRITICAL',0,'Reconciliation control (Assignment 2 design)'),
('DQ_COM_01','Transfers, BPAY and direct debits name a beneficiary','Completeness','dw.fact_core_transaction',
 'beneficiary_reference must be populated for Transfer, BPAY and Direct Debit transactions (key field for mule detection).',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE beneficiary_reference IS NULL)
    FROM dw.fact_core_transaction
    WHERE transaction_type IN ('Transfer','BPAY','Direct Debit')$q$,
 'HIGH',0,'Schema.xlsx: core_transactions.beneficiary_reference'),
('DQ_COM_02','Digital payment events carry an amount','Completeness','dw.fact_digital_event',
 'Fund Transfer and BPAY Payment events must have a transaction_amount greater than zero.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE transaction_amount IS NULL OR transaction_amount <= 0)
    FROM dw.fact_digital_event
    WHERE event_type IN ('Fund Transfer','BPAY Payment')$q$,
 'HIGH',0,'Schema.xlsx: digital_events.transaction_amount'),
-- ---------- Validity: values follow the defined format / domain ----------
('DQ_VAL_01','Customers are 18 or older at onboarding','Validity','dw.dim_customer',
 'Age at customer_since_date, in completed years, must be at least 18.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE date_part('year', age(customer_since_date, date_of_birth)) < 18)
    FROM dw.dim_customer$q$,
 'HIGH',0,'Schema.xlsx: core_customers.date_of_birth'),
('DQ_VAL_02','Customer state is a valid Australian code','Validity','dw.dim_customer',
 'state must be one of NSW, VIC, QLD, WA, SA, TAS, ACT, NT.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE state IS NULL
                            OR state NOT IN ('NSW','VIC','QLD','WA','SA','TAS','ACT','NT'))
    FROM dw.dim_customer$q$,
 'MEDIUM',0,'Schema.xlsx: core_customers.state'),
('DQ_VAL_03','Customer email has a valid structure','Validity','dw.dim_customer',
 'email must match name@domain.tld with no spaces.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE email IS NULL
                            OR email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
    FROM dw.dim_customer$q$,
 'MEDIUM',0,'Schema.xlsx: core_customers.email'),
('DQ_VAL_04','Digital phone numbers standardised (warehouse)','Validity','dw.dim_digital_user',
 'After ETL, registered_phone must be in +614XXXXXXXX format.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE registered_phone IS NULL
                            OR registered_phone !~ '^\+614[0-9]{8}$')
    FROM dw.dim_digital_user$q$,
 'MEDIUM',0,'Warehouse transformation policy (script 04)'),
('DQ_VAL_05','Digital phone numbers standardised (raw source)','Validity','staging.digital_users',
 'Same phone rule applied to raw source data, using the dictionary format 04xx xxx xxx. Compared with DQ_VAL_04 it shows the effect of the ETL cleansing.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE registered_phone !~ '^04[0-9]{2} [0-9]{3} [0-9]{3}$')
    FROM staging.digital_users$q$,
 'LOW',0,'Schema.xlsx: digital_users.registered_phone (source profiling only)'),
('DQ_VAL_06','Card credit limit matches card type','Validity','dw.dim_card',
 'Debit cards must have credit_limit = 0; credit cards must have credit_limit > 0.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE (card_type = 'Debit'  AND credit_limit <> 0)
                               OR (card_type = 'Credit' AND credit_limit <= 0))
    FROM dw.dim_card$q$,
 'MEDIUM',0,'Schema.xlsx: cards.credit_limit'),
('DQ_VAL_07','Transaction amounts are positive','Validity','dw.fact_core_transaction',
 'transaction_amount must be strictly greater than zero in core and card transactions.',
 $q$SELECT (SELECT COUNT(*) FROM dw.fact_core_transaction)
         + (SELECT COUNT(*) FROM dw.fact_card_transaction),
           (SELECT COUNT(*) FROM dw.fact_core_transaction WHERE transaction_amount IS NULL OR transaction_amount <= 0)
         + (SELECT COUNT(*) FROM dw.fact_card_transaction WHERE transaction_amount IS NULL OR transaction_amount <= 0)$q$,
 'CRITICAL',0,'Schema.xlsx: transaction_amount'),
('DQ_VAL_08','Fraud risk scores within 0-100','Validity','dw.fact_*',
 'fraud_risk_score / event_risk_score must be between 0 and 100 in all three fact tables.',
 $q$SELECT COUNT(*), COUNT(*) FILTER (WHERE score IS NULL OR score NOT BETWEEN 0 AND 100)
    FROM (SELECT fraud_risk_score AS score FROM dw.fact_core_transaction
          UNION ALL SELECT fraud_risk_score FROM dw.fact_card_transaction
          UNION ALL SELECT event_risk_score FROM dw.fact_digital_event) AS s$q$,
 'HIGH',0,'Schema.xlsx: fraud_risk_score, event_risk_score'),
-- ---------- Consistency: related values agree with each other ----------
('DQ_CON_01','Closed accounts have a valid close date','Consistency','dw.dim_account',
 'Accounts with status CLOSED must have a close_date, and close_date must not be before open_date.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE close_date IS NULL OR close_date < open_date)
    FROM dw.dim_account
    WHERE account_status = 'CLOSED'$q$,
 'MEDIUM',0,'Schema.xlsx: core_accounts.close_date'),
('DQ_CON_02','Deposit available balance = current balance + overdraft','Consistency','dw.dim_account',
 'For deposit accounts only (Everyday Transaction, Savings, Business Account). Loans and term deposits are excluded because the rule does not apply to them.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE ABS(available_balance - (current_balance + overdraft_limit)) > 0.01)
    FROM dw.dim_account
    WHERE account_type IN ('Everyday Transaction','Savings','Business Account')$q$,
 'MEDIUM',0,'Schema.xlsx: core_accounts.available_balance (refined)'),
('DQ_CON_03','Card transactions fall inside the card validity period','Consistency','dw.fact_card_transaction',
 'A card cannot transact before its issue_date or after its expiry_date.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE t.transaction_timestamp::date < k.issue_date
                               OR t.transaction_timestamp::date > k.expiry_date)
    FROM dw.fact_card_transaction AS t
    JOIN dw.dim_card AS k ON k.card_key = t.card_key$q$,
 'HIGH',0,'Schema.xlsx: card_transactions.transaction_timestamp'),
('DQ_CON_04','Domestic card transactions are in AUD','Consistency','dw.fact_card_transaction',
 'Transactions marked Domestic must use currency AUD.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE currency <> 'AUD')
    FROM dw.fact_card_transaction
    WHERE domestic_international = 'Domestic'$q$,
 'MEDIUM',0,'Schema.xlsx: card_transactions.currency'),
('DQ_CON_05','Digital events occur after user registration','Consistency','dw.fact_digital_event',
 'event_timestamp must not be earlier than the user registration_date.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE e.event_timestamp::date < u.registration_date)
    FROM dw.fact_digital_event AS e
    JOIN dw.dim_digital_user AS u ON u.digital_user_key = e.digital_user_key$q$,
 'MEDIUM',0,'Schema.xlsx: digital_events.event_timestamp'),
-- ---------- Timeliness: data reflects the current state ----------
('DQ_TIM_01','Active cards are not past expiry','Timeliness','dw.dim_card',
 'A card with status ACTIVE must have expiry_date on or after the date the check runs. Failures mean card status is not being updated in the source.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE expiry_date < CURRENT_DATE)
    FROM dw.dim_card
    WHERE card_status = 'ACTIVE'$q$,
 'HIGH',0,'Schema.xlsx: cards.card_status / expiry_date'),
('DQ_TIM_02','Card transactions within the agreed data window','Timeliness','dw.fact_card_transaction',
 'transaction_timestamp must fall between 2024-01-01 and 2026-09-30, the window defined in the data dictionary.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE transaction_timestamp <  TIMESTAMP '2024-01-01'
                               OR transaction_timestamp >= TIMESTAMP '2026-10-01')
    FROM dw.fact_card_transaction$q$,
 'MEDIUM',0,'Schema.xlsx: card_transactions.transaction_timestamp'),
-- ---------- Uniqueness ----------
('DQ_UNI_01','Customer email identifies one customer','Uniqueness','dw.dim_customer',
 'Counts customers whose email is shared with another customer. Shared emails make email-based identity matching ambiguous. A small tolerance allows genuine shared family accounts.',
 $q$SELECT COUNT(*), COUNT(*) FILTER (WHERE email_count > 1)
    FROM (SELECT COUNT(*) OVER (PARTITION BY email) AS email_count
          FROM dw.dim_customer) AS e$q$,
 'MEDIUM',2,'Entity resolution control (Assignment 2 design)'),
-- ---------- Accuracy: integrated identity is correct ----------
('DQ_ACC_01','Linked digital user email matches core customer','Accuracy','dw.dim_digital_user',
 'For each digital user linked to an enterprise customer, registered_email must equal the core customer email. Confirms the identity mapping is correct.',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE u.registered_email IS DISTINCT FROM c.email)
    FROM dw.dim_digital_user AS u
    JOIN dw.dim_customer AS c ON c.customer_key = u.customer_key$q$,
 'CRITICAL',0,'Entity resolution control (Assignment 2 design)'),
('DQ_ACC_02','Linked card holder matches core customer','Accuracy','dw.dim_card',
 'Card billing_postcode must equal the core postcode, and the card name must share the core surname and first initial (card names may be abbreviated, e.g. "B Walsh").',
 $q$SELECT COUNT(*),
           COUNT(*) FILTER (WHERE k.billing_postcode IS DISTINCT FROM c.postcode
                               OR lower(regexp_replace(k.customer_name, '^.* ', '')) <> lower(c.last_name)
                               OR upper(left(k.customer_name, 1)) <> upper(left(c.first_name, 1)))
    FROM dw.dim_card AS k
    JOIN dw.dim_customer AS c ON c.customer_key = k.customer_key$q$,
 'CRITICAL',0,'Entity resolution control (Assignment 2 design)');


-- DQ_VAL_05 measures raw source quality before cleansing; it is
-- reported for comparison with DQ_VAL_04, not enforced.
UPDATE governance.dq_rule
SET check_type = 'PROFILE'
WHERE rule_id = 'DQ_VAL_05';


/* ---------------------------------------------------------------------
   SECTION 8 - Quality run log and results
   --------------------------------------------------------------------- */
CREATE TABLE governance.dq_run (
    run_id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    finished_at   TIMESTAMPTZ,
    run_by        TEXT NOT NULL DEFAULT current_user,
    rules_run     INTEGER,
    rules_passed  INTEGER,
    rules_failed  INTEGER,
    rules_info    INTEGER,
    rules_errored INTEGER
);

CREATE TABLE governance.dq_result (
    result_id     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        BIGINT NOT NULL REFERENCES governance.dq_run(run_id),
    rule_id       TEXT NOT NULL REFERENCES governance.dq_rule(rule_id),
    rows_checked  BIGINT,
    rows_failed   BIGINT,
    failure_pct   NUMERIC(7,2),
    status        TEXT NOT NULL CHECK (status IN ('PASS','FAIL','INFO','ERROR')),
    error_message TEXT,
    checked_at    TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (run_id, rule_id)
);


/* run_quality_checks executes every active rule with EXECUTE, records
   one result row per rule, and returns the new run_id. Each rule runs
   inside its own BEGIN...EXCEPTION block, so a broken rule is logged as
   ERROR instead of stopping the whole run. */
CREATE OR REPLACE FUNCTION governance.run_quality_checks()
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_run_id   BIGINT;
    r          RECORD;
    v_checked  BIGINT;
    v_failed   BIGINT;
    v_pct      NUMERIC(7,2);
BEGIN
    INSERT INTO governance.dq_run DEFAULT VALUES
    RETURNING run_id INTO v_run_id;

    FOR r IN
        SELECT rule_id, check_sql, tolerance_pct, check_type
        FROM governance.dq_rule
        WHERE is_active
        ORDER BY rule_id
    LOOP
        BEGIN
            EXECUTE r.check_sql INTO v_checked, v_failed;

            v_pct := CASE WHEN COALESCE(v_checked, 0) = 0 THEN 0
                          ELSE ROUND(100.0 * v_failed / v_checked, 2) END;

            INSERT INTO governance.dq_result
                  (run_id, rule_id, rows_checked, rows_failed, failure_pct, status)
            VALUES (v_run_id, r.rule_id, v_checked, v_failed, v_pct,
                    CASE WHEN r.check_type = 'PROFILE'  THEN 'INFO'
                         WHEN v_pct <= r.tolerance_pct  THEN 'PASS'
                         ELSE 'FAIL' END);
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO governance.dq_result
                  (run_id, rule_id, status, error_message)
            VALUES (v_run_id, r.rule_id, 'ERROR', SQLERRM);
        END;
    END LOOP;

    UPDATE governance.dq_run AS d
    SET finished_at   = clock_timestamp(),
        rules_run     = s.total,
        rules_passed  = s.passed,
        rules_failed  = s.failed,
        rules_info    = s.info,
        rules_errored = s.errored
    FROM (SELECT COUNT(*) AS total,
                 COUNT(*) FILTER (WHERE status = 'PASS')  AS passed,
                 COUNT(*) FILTER (WHERE status = 'FAIL')  AS failed,
                 COUNT(*) FILTER (WHERE status = 'INFO')  AS info,
                 COUNT(*) FILTER (WHERE status = 'ERROR') AS errored
          FROM governance.dq_result
          WHERE run_id = v_run_id) AS s
    WHERE d.run_id = v_run_id;

    RETURN v_run_id;
END;
$$;

COMMENT ON FUNCTION governance.run_quality_checks() IS
  'Runs every active data quality rule and records the results under a new run_id.';


/* ---------------------------------------------------------------------
   SECTION 9 - Masked views (privacy by design)
   ---------------------------------------------------------------------
   Analysts need to study fraud patterns but do not need to see who the
   customer is. These views keep every analytical column but mask the
   direct identifiers. Views run with the privileges of their owner, so
   an analyst can read the view without any access to dw itself.
   --------------------------------------------------------------------- */
CREATE VIEW secure.v_customer_masked AS
SELECT
    customer_key,
    enterprise_customer_key,
    left(first_name, 1) || '.'                           AS first_initial,
    left(last_name, 1) || repeat('*', 4)                 AS last_name_masked,
    EXTRACT(YEAR FROM date_of_birth)::INTEGER            AS birth_year,
    gender,
    left(email, 2) || '***@' || split_part(email, '@', 2) AS email_masked,
    '****' || right(phone, 3)                            AS phone_masked,
    suburb, state, postcode,
    customer_since_date,
    occupation_category, employment_status, customer_segment,
    kyc_status, risk_category,
    (card_customer_id IS NOT NULL)                       AS has_card_profile,
    (digital_user_id  IS NOT NULL)                       AS has_digital_profile
FROM dw.dim_customer;

CREATE VIEW secure.v_card_masked AS
SELECT
    card_key, card_id, customer_key,
    left(customer_name, 1) || '. ' ||
        left(regexp_replace(customer_name, '^.* ', ''), 1) || '****' AS card_holder_masked,
    billing_postcode, card_type, card_network, card_status,
    issue_date, expiry_date, credit_limit,
    contactless_enabled, international_enabled, card_risk_band
FROM dw.dim_card;

CREATE VIEW secure.v_digital_user_masked AS
SELECT
    digital_user_key, digital_user_id, customer_key,
    left(registered_email, 2) || '***@' || split_part(registered_email, '@', 2) AS email_masked,
    '****' || right(registered_phone, 3)                AS phone_masked,
    registration_date, digital_status, preferred_platform,
    biometric_enabled, mfa_enabled, last_login_timestamp, digital_risk_band
FROM dw.dim_digital_user;


/* ---------------------------------------------------------------------
   SECTION 10 - Roles and access policy
   ---------------------------------------------------------------------
   Three group roles (NOLOGIN) represent job functions. Real users would
   be granted membership of a role rather than direct table rights.
     fraud_analyst      : facts + masked views, no direct identifiers
     data_steward       : full read of staging, dw and governance
     compliance_auditor : governance metadata and masked views only
   Roles are cluster-wide, so they are created only if missing.
   --------------------------------------------------------------------- */
DO $$
DECLARE
    v_role TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY['fraud_analyst','data_steward','compliance_auditor']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', v_role);
        END IF;
    END LOOP;
END;
$$;

-- Start from "no access" so the policy below is the only access path.
REVOKE ALL ON SCHEMA staging, dw, governance, secure FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA staging, dw, governance, secure FROM PUBLIC;
REVOKE ALL ON SCHEMA staging, dw, governance, secure
    FROM fraud_analyst, data_steward, compliance_auditor;
REVOKE ALL ON ALL TABLES IN SCHEMA staging, dw, governance, secure
    FROM fraud_analyst, data_steward, compliance_auditor;

-- fraud_analyst: fact tables and masked dimensions only
GRANT USAGE  ON SCHEMA dw, secure TO fraud_analyst;
GRANT SELECT ON dw.fact_core_transaction, dw.fact_card_transaction,
                dw.fact_digital_event, dw.dim_account
             TO fraud_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA secure TO fraud_analyst;

-- data_steward: full read access, maintains rules and descriptions
GRANT USAGE  ON SCHEMA staging, dw, governance, secure TO data_steward;
GRANT SELECT ON ALL TABLES IN SCHEMA staging, dw, secure TO data_steward;
GRANT SELECT ON ALL TABLES IN SCHEMA governance TO data_steward;
-- Stewards maintain rules and business metadata. Quality results and the
-- catalog snapshot are written only by the governance job, never by hand.
GRANT INSERT, UPDATE ON governance.dq_rule, governance.table_description,
                        governance.lineage, governance.managed_schema
             TO data_steward;

-- compliance_auditor: metadata and masked data, read only
GRANT USAGE  ON SCHEMA governance, secure TO compliance_auditor;
GRANT SELECT ON ALL TABLES IN SCHEMA governance, secure TO compliance_auditor;

-- Lineage tracing is available to the two governance roles
GRANT EXECUTE ON FUNCTION governance.trace_upstream(TEXT)
    TO data_steward, compliance_auditor;


/* Record the access policy itself as metadata, so the catalog can show
   who may see what. This is the documented intent; script 08 compares
   it with the privileges PostgreSQL actually enforces. */
CREATE TABLE governance.access_policy (
    role_name     TEXT NOT NULL,
    object_name   TEXT NOT NULL,
    access_level  TEXT NOT NULL CHECK (access_level IN ('READ','READ_WRITE','NONE')),
    justification TEXT NOT NULL,
    PRIMARY KEY (role_name, object_name)
);

INSERT INTO governance.access_policy VALUES
 -- fraud_analyst: analyses patterns, never sees who the customer is
 ('fraud_analyst','dw.fact_card_transaction','READ','Needed to analyse card fraud patterns'),
 ('fraud_analyst','secure.v_customer_masked','READ','Customer context without direct identifiers'),
 ('fraud_analyst','dw.dim_customer','NONE','Contains direct PII; analysts use the masked view'),
 ('fraud_analyst','staging.core_customers','NONE','Raw source data with direct PII'),
 ('fraud_analyst','governance.dq_rule','NONE','Rule maintenance is a steward task'),
 ('fraud_analyst','governance.dq_result','NONE','Quality evidence is for stewards and auditors'),
 -- data_steward: accountable for data quality, needs full records
 ('data_steward','dw.fact_card_transaction','READ','Investigates quality failures in facts'),
 ('data_steward','secure.v_customer_masked','READ','Checks masking output'),
 ('data_steward','dw.dim_customer','READ','Resolves quality issues on full customer records'),
 ('data_steward','staging.core_customers','READ','Traces issues back to raw source data'),
 ('data_steward','governance.dq_rule','READ_WRITE','Maintains quality rules'),
 ('data_steward','governance.dq_result','READ','Reviews results; results are written only by the job'),
 -- compliance_auditor: checks that governance works, sees no raw PII
 ('compliance_auditor','dw.fact_card_transaction','NONE','Audit does not require transaction detail'),
 ('compliance_auditor','secure.v_customer_masked','READ','Verifies that masking is applied'),
 ('compliance_auditor','dw.dim_customer','NONE','Audit uses metadata and masked data only'),
 ('compliance_auditor','staging.core_customers','NONE','Raw source data with direct PII'),
 ('compliance_auditor','governance.dq_rule','READ','Audits the rules in force'),
 ('compliance_auditor','governance.dq_result','READ','Audits data quality evidence');

GRANT SELECT ON governance.access_policy TO compliance_auditor, data_steward;

-- End of script 06. Next: run 07_run_governance.sql
