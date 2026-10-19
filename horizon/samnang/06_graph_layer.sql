-- =====================================================================
-- 06_graph_layer.sql
-- Horizon Retail Bank | 32113 Advanced Database | Assignment 2
-- Workstream: Graph database (relationship analysis)
--
-- PURPOSE
-- Builds a property graph (nodes and edges) on top of the integrated
-- warehouse (dw schema). Fraud rings rarely show up in a single
-- transaction; they show up as customers who share a device, an IP
-- address or a payee. The graph makes those relationships explicit so
-- they can be queried directly, across all three source systems.
--
-- DESIGN CHOICE
-- The graph is stored in PostgreSQL (node and edge tables plus SQL)
-- so it sits next to the warehouse it is derived from. The same node
-- and edge tables can be exported to Neo4j for visual exploration.
--
-- WHAT THIS SCRIPT CREATES (schema: graph)
--   config           tunable thresholds
--   node             one row per entity: customer, account, card, digital
--                    user, device, IP address, beneficiary (payee),
--                    external account, card terminal, merchant
--   edge             one row per relationship between two nodes,
--                    aggregated over all transactions/events
--   customer_entity  bridge: which customer reaches which entity, through
--                    which account/card/digital user, and whether that
--                    activity was fraud-flagged
--   customer_link    customer-to-customer links
--   customer_cluster connected groups of linked customers (possible rings)
--   refresh_graph()  procedure that (re)builds all of the above from dw
--   fn_neighbourhood()   everything within N hops of a node
--
-- RUN ORDER
--   01 -> 02 -> 02b -> 03 -> 04 -> 06 (this file) -> 07
--   Run the whole file (Execute script) connected to the warehouse database.
--
-- RE-RUNNING
--   Safe to re-run. The graph schema holds only derived data, so it is
--   dropped and rebuilt. Nothing in staging or dw is changed.
--   After a new warehouse load, only CALL graph.refresh_graph(); is needed.
--
-- Tested on PostgreSQL 16 with the Horizon synthetic dataset.
-- Uses only features available from PostgreSQL 13.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Start clean. The graph is fully derived from dw, so dropping it
--    loses nothing that cannot be rebuilt.
-- ---------------------------------------------------------------------
DROP SCHEMA IF EXISTS graph CASCADE;
CREATE SCHEMA graph;


-- ---------------------------------------------------------------------
-- 1. Settings
-- ---------------------------------------------------------------------
-- max_customers_per_entity
--   A "supernode" is an entity linked to so many customers that it says
--   nothing about fraud: a utility biller (Telstra, AGL), an office or
--   public Wi-Fi IP address, a popular merchant. Supernodes stay in the
--   graph but are never used to link customers or to walk through.
--
-- min_fraud_customers_for_weak_link
--   Devices and IP addresses are personal, so sharing one is a link on
--   its own. Payees, external accounts and card terminals are shared by
--   ordinary customers all the time (same biller, same shop). These only
--   link customers when at least this many different customers sent
--   fraud-flagged activity through them, e.g. a mule collection account.
CREATE TABLE graph.config (
    setting_name  TEXT PRIMARY KEY,
    setting_value INTEGER NOT NULL CHECK (setting_value > 0),
    description   TEXT NOT NULL
);

INSERT INTO graph.config (setting_name, setting_value, description) VALUES
    ('max_customers_per_entity', 10,
     'Entities linked to more customers than this are supernodes and are never used to link customers.'),
    ('min_fraud_customers_for_weak_link', 2,
     'Payees, external accounts and terminals link customers only if at least this many customers sent fraud-flagged activity through them.');


-- ---------------------------------------------------------------------
-- 2. Node table: one row per entity
-- ---------------------------------------------------------------------
-- node_id is "<TYPE>:<business key>", e.g. 'DEVICE:DEV_MULE_RING_01'.
-- Readable text IDs mean the same payee seen in two systems (core
-- banking and digital banking) becomes one node automatically.
CREATE TABLE graph.node (
    node_id               TEXT PRIMARY KEY,
    node_type             TEXT NOT NULL CHECK (node_type IN (
                              'CUSTOMER', 'ACCOUNT', 'CARD', 'DIGITAL_USER',
                              'DEVICE', 'IP_ADDRESS', 'BENEFICIARY',
                              'EXTERNAL_ACCOUNT', 'TERMINAL', 'MERCHANT')),
    business_key          TEXT NOT NULL,
    display_name          TEXT,
    -- Link back to the warehouse for customer nodes only.
    customer_key          BIGINT REFERENCES dw.dim_customer (customer_key),
    -- Fraud-flagged transactions/events touching this node.
    fraud_event_count     INTEGER NOT NULL DEFAULT 0,
    -- For shared entities: distinct customers reaching this node, and
    -- how many of them did so with fraud-flagged activity.
    linked_customer_count INTEGER NOT NULL DEFAULT 0,
    fraud_customer_count  INTEGER NOT NULL DEFAULT 0,
    is_supernode          BOOLEAN NOT NULL DEFAULT FALSE,
    -- Lineage: which warehouse table(s) this node was derived from.
    source_table          TEXT NOT NULL,
    built_at              TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (node_type, business_key)
);


-- ---------------------------------------------------------------------
-- 3. Edge table: one row per relationship (directed)
-- ---------------------------------------------------------------------
-- Many transactions between the same two nodes are aggregated into one
-- edge, with a count, total amount, fraud count and first/last seen.
--   OWNS            customer         -> account
--   HOLDS           customer         -> card
--   HAS_LOGIN       customer         -> digital user
--   USED_DEVICE     digital user     -> device
--   LOGGED_IN_FROM  digital user     -> IP address
--   PAID            account          -> beneficiary   (core banking payee)
--                   digital user     -> beneficiary   (payee added / paid in app)
--   SENT_TO         account          -> external account   (money out)
--                   external account -> account            (money in)
--   USED_TERMINAL   card             -> terminal (POS terminal or web gateway)
--   PURCHASED_AT    card             -> merchant
CREATE TABLE graph.edge (
    edge_id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    src_node_id       TEXT NOT NULL REFERENCES graph.node (node_id),
    dst_node_id       TEXT NOT NULL REFERENCES graph.node (node_id),
    edge_type         TEXT NOT NULL CHECK (edge_type IN (
                          'OWNS', 'HOLDS', 'HAS_LOGIN', 'USED_DEVICE',
                          'LOGGED_IN_FROM', 'PAID', 'SENT_TO',
                          'USED_TERMINAL', 'PURCHASED_AT')),
    event_count       INTEGER NOT NULL DEFAULT 1,
    total_amount      NUMERIC(15,2),
    fraud_event_count INTEGER NOT NULL DEFAULT 0,
    first_seen        TIMESTAMP,
    last_seen         TIMESTAMP,
    source_table      TEXT NOT NULL,
    built_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (src_node_id, dst_node_id, edge_type),
    CHECK (src_node_id <> dst_node_id)
);

-- The UNIQUE constraint already indexes lookups by source node.
-- This index supports walking edges backwards (who points at this node?).
CREATE INDEX idx_edge_dst ON graph.edge (dst_node_id, edge_type);


-- ---------------------------------------------------------------------
-- 4. Customer-to-entity bridge
-- ---------------------------------------------------------------------
-- Precomputes the two-hop path customer -> (account | card | digital
-- user) -> shared entity, so "which customers share this device?" is a
-- simple join instead of a graph walk. This is the bridge-table
-- structure proposed in Assignment 1 (BRIDGE_CUSTOMER_ACCOUNT_DEVICE).
CREATE TABLE graph.customer_entity (
    customer_node_id TEXT NOT NULL REFERENCES graph.node (node_id),
    entity_node_id   TEXT NOT NULL REFERENCES graph.node (node_id),
    via_node_id      TEXT NOT NULL REFERENCES graph.node (node_id),
    via_edge_type    TEXT NOT NULL,
    has_fraud        BOOLEAN NOT NULL,
    PRIMARY KEY (customer_node_id, entity_node_id, via_node_id)
);

CREATE INDEX idx_customer_entity_entity ON graph.customer_entity (entity_node_id);


-- ---------------------------------------------------------------------
-- 5. Customer-to-customer links
-- ---------------------------------------------------------------------
-- One row per pair of customers per shared entity. customer_a is always
-- the smaller ID so each pair is stored once.
CREATE TABLE graph.customer_link (
    customer_a     TEXT NOT NULL REFERENCES graph.node (node_id),
    customer_b     TEXT NOT NULL REFERENCES graph.node (node_id),
    shared_node_id TEXT NOT NULL REFERENCES graph.node (node_id),
    link_type      TEXT NOT NULL CHECK (link_type IN (
                       'SHARED_DEVICE', 'SHARED_IP',
                       'SHARED_FRAUD_PAYEE', 'SHARED_FRAUD_TERMINAL')),
    PRIMARY KEY (customer_a, customer_b, shared_node_id),
    CHECK (customer_a < customer_b)
);

CREATE INDEX idx_customer_link_b ON graph.customer_link (customer_b);


-- ---------------------------------------------------------------------
-- 6. Customer clusters (connected components)
-- ---------------------------------------------------------------------
-- Customers connected directly or indirectly through customer_link get
-- the same cluster_id (the smallest customer node ID in the group).
-- A customer with no links is a cluster of one.
CREATE TABLE graph.customer_cluster (
    customer_node_id TEXT PRIMARY KEY REFERENCES graph.node (node_id),
    cluster_id       TEXT NOT NULL
);

CREATE INDEX idx_customer_cluster_id ON graph.customer_cluster (cluster_id);


-- ---------------------------------------------------------------------
-- 7. Build procedure
-- ---------------------------------------------------------------------
-- Rebuilds every graph table from the current warehouse contents.
-- Runs as one unit: if any step fails, nothing is changed.
CREATE PROCEDURE graph.refresh_graph()
LANGUAGE plpgsql
AS $$
DECLARE
    v_max_customers   INTEGER;
    v_min_fraud_custs INTEGER;
    v_changed         INTEGER;
    v_rounds          INTEGER := 0;
BEGIN
    SELECT setting_value INTO v_max_customers
    FROM graph.config WHERE setting_name = 'max_customers_per_entity';

    SELECT setting_value INTO v_min_fraud_custs
    FROM graph.config WHERE setting_name = 'min_fraud_customers_for_weak_link';

    -- Clear derived data (children first because of foreign keys).
    TRUNCATE graph.customer_cluster, graph.customer_link,
             graph.customer_entity, graph.edge, graph.node
             RESTART IDENTITY;

    -- 7.1 Nodes from the warehouse dimensions ------------------------
    INSERT INTO graph.node (node_id, node_type, business_key, display_name,
                            customer_key, source_table)
    SELECT 'CUSTOMER:' || c.enterprise_customer_key, 'CUSTOMER',
           c.enterprise_customer_key,
           CONCAT_WS(' ', c.first_name, c.last_name),
           c.customer_key, 'dw.dim_customer'
    FROM dw.dim_customer c;

    INSERT INTO graph.node (node_id, node_type, business_key, display_name, source_table)
    SELECT 'ACCOUNT:' || a.core_account_id, 'ACCOUNT', a.core_account_id,
           a.account_type, 'dw.dim_account'
    FROM dw.dim_account a;

    INSERT INTO graph.node (node_id, node_type, business_key, display_name, source_table)
    SELECT 'CARD:' || k.card_id, 'CARD', k.card_id,
           CONCAT_WS(' ', k.card_network, k.card_type), 'dw.dim_card'
    FROM dw.dim_card k;

    INSERT INTO graph.node (node_id, node_type, business_key, display_name, source_table)
    SELECT 'DIGITAL_USER:' || u.digital_user_id, 'DIGITAL_USER', u.digital_user_id,
           u.preferred_platform, 'dw.dim_digital_user'
    FROM dw.dim_digital_user u;

    -- 7.2 Nodes for entities that only exist as values in fact tables -
    -- Devices: app installations from digital events.
    INSERT INTO graph.node (node_id, node_type, business_key, display_name, source_table)
    SELECT 'DEVICE:' || device_id, 'DEVICE', device_id,
           MAX(device_type), 'dw.fact_digital_event'
    FROM dw.fact_digital_event
    WHERE NULLIF(device_id, '') IS NOT NULL
    GROUP BY device_id;

    -- IP addresses used to reach digital banking.
    INSERT INTO graph.node (node_id, node_type, business_key, display_name, source_table)
    SELECT 'IP_ADDRESS:' || ip_address_synthetic, 'IP_ADDRESS', ip_address_synthetic,
           MAX(ip_region), 'dw.fact_digital_event'
    FROM dw.fact_digital_event
    WHERE NULLIF(ip_address_synthetic, '') IS NOT NULL
    GROUP BY ip_address_synthetic;

    -- Beneficiaries (payees): the same reference in core banking and in
    -- digital banking becomes one node, linking the two systems.
    INSERT INTO graph.node (node_id, node_type, business_key, display_name, source_table)
    SELECT 'BENEFICIARY:' || b.ref, 'BENEFICIARY', b.ref, 'Payee',
           STRING_AGG(DISTINCT b.src, ', ')
    FROM (
        SELECT beneficiary_reference AS ref, 'dw.fact_core_transaction' AS src
        FROM dw.fact_core_transaction
        UNION ALL
        SELECT beneficiary_reference, 'dw.fact_digital_event'
        FROM dw.fact_digital_event
    ) b
    WHERE NULLIF(b.ref, '') IS NOT NULL
    GROUP BY b.ref;

    -- External accounts: the other bank's clearing reference on a core
    -- banking transaction (where money went to, or came from).
    INSERT INTO graph.node (node_id, node_type, business_key, display_name, source_table)
    SELECT 'EXTERNAL_ACCOUNT:' || counterparty_reference, 'EXTERNAL_ACCOUNT',
           counterparty_reference, 'External account', 'dw.fact_core_transaction'
    FROM dw.fact_core_transaction
    WHERE NULLIF(counterparty_reference, '') IS NOT NULL
    GROUP BY counterparty_reference;

    -- Card terminals: device_reference on a card transaction is the
    -- merchant's POS terminal or online payment gateway, NOT the
    -- customer's own device, so it is a separate node type.
    INSERT INTO graph.node (node_id, node_type, business_key, display_name, source_table)
    SELECT 'TERMINAL:' || device_reference, 'TERMINAL', device_reference,
           MAX(payment_method), 'dw.fact_card_transaction'
    FROM dw.fact_card_transaction
    WHERE NULLIF(device_reference, '') IS NOT NULL
    GROUP BY device_reference;

    INSERT INTO graph.node (node_id, node_type, business_key, display_name, source_table)
    SELECT 'MERCHANT:' || merchant_name, 'MERCHANT', merchant_name,
           MAX(merchant_category), 'dw.fact_card_transaction'
    FROM dw.fact_card_transaction
    WHERE NULLIF(merchant_name, '') IS NOT NULL
    GROUP BY merchant_name;

    -- 7.3 Ownership edges from the dimension foreign keys --------------
    INSERT INTO graph.edge (src_node_id, dst_node_id, edge_type, source_table)
    SELECT 'CUSTOMER:' || c.enterprise_customer_key, 'ACCOUNT:' || a.core_account_id,
           'OWNS', 'dw.dim_account'
    FROM dw.dim_account a
    JOIN dw.dim_customer c ON c.customer_key = a.customer_key;

    INSERT INTO graph.edge (src_node_id, dst_node_id, edge_type, source_table)
    SELECT 'CUSTOMER:' || c.enterprise_customer_key, 'CARD:' || k.card_id,
           'HOLDS', 'dw.dim_card'
    FROM dw.dim_card k
    JOIN dw.dim_customer c ON c.customer_key = k.customer_key;

    INSERT INTO graph.edge (src_node_id, dst_node_id, edge_type, source_table)
    SELECT 'CUSTOMER:' || c.enterprise_customer_key, 'DIGITAL_USER:' || u.digital_user_id,
           'HAS_LOGIN', 'dw.dim_digital_user'
    FROM dw.dim_digital_user u
    JOIN dw.dim_customer c ON c.customer_key = u.customer_key;

    -- 7.4 Activity edges, aggregated from the fact tables ------------
    -- Digital user used a device.
    INSERT INTO graph.edge (src_node_id, dst_node_id, edge_type, event_count,
                            fraud_event_count, first_seen, last_seen, source_table)
    SELECT 'DIGITAL_USER:' || u.digital_user_id, 'DEVICE:' || e.device_id,
           'USED_DEVICE', COUNT(*),
           COUNT(*) FILTER (WHERE e.fraud_indicator),
           MIN(e.event_timestamp), MAX(e.event_timestamp), 'dw.fact_digital_event'
    FROM dw.fact_digital_event e
    JOIN dw.dim_digital_user u ON u.digital_user_key = e.digital_user_key
    WHERE NULLIF(e.device_id, '') IS NOT NULL
    GROUP BY u.digital_user_id, e.device_id;

    -- Digital user connected from an IP address.
    INSERT INTO graph.edge (src_node_id, dst_node_id, edge_type, event_count,
                            fraud_event_count, first_seen, last_seen, source_table)
    SELECT 'DIGITAL_USER:' || u.digital_user_id, 'IP_ADDRESS:' || e.ip_address_synthetic,
           'LOGGED_IN_FROM', COUNT(*),
           COUNT(*) FILTER (WHERE e.fraud_indicator),
           MIN(e.event_timestamp), MAX(e.event_timestamp), 'dw.fact_digital_event'
    FROM dw.fact_digital_event e
    JOIN dw.dim_digital_user u ON u.digital_user_key = e.digital_user_key
    WHERE NULLIF(e.ip_address_synthetic, '') IS NOT NULL
    GROUP BY u.digital_user_id, e.ip_address_synthetic;

    -- Digital user added or paid a beneficiary in the app.
    INSERT INTO graph.edge (src_node_id, dst_node_id, edge_type, event_count,
                            total_amount, fraud_event_count, first_seen, last_seen,
                            source_table)
    SELECT 'DIGITAL_USER:' || u.digital_user_id, 'BENEFICIARY:' || e.beneficiary_reference,
           'PAID', COUNT(*), SUM(e.transaction_amount),
           COUNT(*) FILTER (WHERE e.fraud_indicator),
           MIN(e.event_timestamp), MAX(e.event_timestamp), 'dw.fact_digital_event'
    FROM dw.fact_digital_event e
    JOIN dw.dim_digital_user u ON u.digital_user_key = e.digital_user_key
    WHERE NULLIF(e.beneficiary_reference, '') IS NOT NULL
    GROUP BY u.digital_user_id, e.beneficiary_reference;

    -- Core banking account paid a beneficiary (debits only carry one).
    INSERT INTO graph.edge (src_node_id, dst_node_id, edge_type, event_count,
                            total_amount, fraud_event_count, first_seen, last_seen,
                            source_table)
    SELECT 'ACCOUNT:' || a.core_account_id, 'BENEFICIARY:' || t.beneficiary_reference,
           'PAID', COUNT(*), SUM(t.transaction_amount),
           COUNT(*) FILTER (WHERE t.fraud_indicator),
           MIN(t.transaction_timestamp), MAX(t.transaction_timestamp),
           'dw.fact_core_transaction'
    FROM dw.fact_core_transaction t
    JOIN dw.dim_account a ON a.account_key = t.account_key
    WHERE NULLIF(t.beneficiary_reference, '') IS NOT NULL
    GROUP BY a.core_account_id, t.beneficiary_reference;

    -- Money moving between a Horizon account and an external account.
    -- Direction follows the money: a DEBIT goes out to the external
    -- account, a CREDIT (salary, deposit) comes in from it.
    INSERT INTO graph.edge (src_node_id, dst_node_id, edge_type, event_count,
                            total_amount, fraud_event_count, first_seen, last_seen,
                            source_table)
    SELECT x.src, x.dst, 'SENT_TO', COUNT(*), SUM(x.amount),
           COUNT(*) FILTER (WHERE x.fraud),
           MIN(x.ts), MAX(x.ts), 'dw.fact_core_transaction'
    FROM (
        SELECT CASE WHEN t.debit_credit_indicator LIKE 'C%'
                    THEN 'EXTERNAL_ACCOUNT:' || t.counterparty_reference
                    ELSE 'ACCOUNT:' || a.core_account_id END AS src,
               CASE WHEN t.debit_credit_indicator LIKE 'C%'
                    THEN 'ACCOUNT:' || a.core_account_id
                    ELSE 'EXTERNAL_ACCOUNT:' || t.counterparty_reference END AS dst,
               t.transaction_amount AS amount, t.fraud_indicator AS fraud,
               t.transaction_timestamp AS ts
        FROM dw.fact_core_transaction t
        JOIN dw.dim_account a ON a.account_key = t.account_key
        WHERE NULLIF(t.counterparty_reference, '') IS NOT NULL
    ) x
    GROUP BY x.src, x.dst;

    -- Card used at a terminal / gateway.
    INSERT INTO graph.edge (src_node_id, dst_node_id, edge_type, event_count,
                            total_amount, fraud_event_count, first_seen, last_seen,
                            source_table)
    SELECT 'CARD:' || k.card_id, 'TERMINAL:' || t.device_reference,
           'USED_TERMINAL', COUNT(*), SUM(t.transaction_amount),
           COUNT(*) FILTER (WHERE t.fraud_indicator),
           MIN(t.transaction_timestamp), MAX(t.transaction_timestamp),
           'dw.fact_card_transaction'
    FROM dw.fact_card_transaction t
    JOIN dw.dim_card k ON k.card_key = t.card_key
    WHERE NULLIF(t.device_reference, '') IS NOT NULL
    GROUP BY k.card_id, t.device_reference;

    -- Card purchases at a merchant. Amounts are in mixed currencies, so
    -- total_amount is left empty here to avoid adding AUD to EUR.
    INSERT INTO graph.edge (src_node_id, dst_node_id, edge_type, event_count,
                            fraud_event_count, first_seen, last_seen, source_table)
    SELECT 'CARD:' || k.card_id, 'MERCHANT:' || t.merchant_name,
           'PURCHASED_AT', COUNT(*),
           COUNT(*) FILTER (WHERE t.fraud_indicator),
           MIN(t.transaction_timestamp), MAX(t.transaction_timestamp),
           'dw.fact_card_transaction'
    FROM dw.fact_card_transaction t
    JOIN dw.dim_card k ON k.card_key = t.card_key
    WHERE NULLIF(t.merchant_name, '') IS NOT NULL
    GROUP BY k.card_id, t.merchant_name;

    -- 7.5 Customer -> entity bridge ----------------------------------
    -- Two hops: customer -(OWNS|HOLDS|HAS_LOGIN)-> account/card/digital
    -- user -(outgoing activity)-> shared entity. Only outgoing edges are
    -- followed, so receiving a salary from the same employer is not a link.
    INSERT INTO graph.customer_entity (customer_node_id, entity_node_id,
                                       via_node_id, via_edge_type, has_fraud)
    SELECT e1.src_node_id, e2.dst_node_id, e1.dst_node_id, e2.edge_type,
           e2.fraud_event_count > 0
    FROM graph.edge e1
    JOIN graph.edge e2 ON e2.src_node_id = e1.dst_node_id
    WHERE e1.edge_type IN ('OWNS', 'HOLDS', 'HAS_LOGIN')
      AND e2.edge_type IN ('USED_DEVICE', 'LOGGED_IN_FROM', 'PAID',
                           'SENT_TO', 'USED_TERMINAL', 'PURCHASED_AT');

    -- 7.6 Node statistics --------------------------------------------
    -- Shared entities: how many customers, how many with fraud, supernode.
    UPDATE graph.node n
    SET linked_customer_count = s.customers,
        fraud_customer_count  = s.fraud_customers,
        is_supernode          = s.customers > v_max_customers
    FROM (SELECT entity_node_id,
                 COUNT(DISTINCT customer_node_id) AS customers,
                 COUNT(DISTINCT customer_node_id) FILTER (WHERE has_fraud) AS fraud_customers
          FROM graph.customer_entity
          GROUP BY entity_node_id) s
    WHERE n.node_id = s.entity_node_id;

    -- Fraud events reaching each non-customer node (sum of incoming edges).
    UPDATE graph.node n
    SET fraud_event_count = s.fraud
    FROM (SELECT dst_node_id, SUM(fraud_event_count) AS fraud
          FROM graph.edge GROUP BY dst_node_id) s
    WHERE n.node_id = s.dst_node_id
      AND n.node_type <> 'CUSTOMER';

    -- Fraud events per customer, across all three source systems.
    UPDATE graph.node n
    SET fraud_event_count = s.fraud
    FROM (
        SELECT customer_key, SUM(fraud) AS fraud
        FROM (
            SELECT a.customer_key, COUNT(*) FILTER (WHERE t.fraud_indicator) AS fraud
            FROM dw.fact_core_transaction t
            JOIN dw.dim_account a ON a.account_key = t.account_key
            GROUP BY a.customer_key
            UNION ALL
            SELECT k.customer_key, COUNT(*) FILTER (WHERE t.fraud_indicator)
            FROM dw.fact_card_transaction t
            JOIN dw.dim_card k ON k.card_key = t.card_key
            GROUP BY k.customer_key
            UNION ALL
            SELECT u.customer_key, COUNT(*) FILTER (WHERE e.fraud_indicator)
            FROM dw.fact_digital_event e
            JOIN dw.dim_digital_user u ON u.digital_user_key = e.digital_user_key
            GROUP BY u.customer_key
        ) x
        GROUP BY customer_key
    ) s
    WHERE n.customer_key = s.customer_key;

    -- 7.7 Customer-to-customer links ---------------------------------
    -- Strong entities (device, IP): any two customers sharing one.
    -- Weak entities (payee, external account, terminal): only when enough
    -- customers sent fraud-flagged activity through the same entity.
    -- Supernodes and merchants never create links.
    INSERT INTO graph.customer_link (customer_a, customer_b, shared_node_id, link_type)
    SELECT DISTINCT a.customer_node_id, b.customer_node_id, a.entity_node_id,
           CASE n.node_type
               WHEN 'DEVICE'     THEN 'SHARED_DEVICE'
               WHEN 'IP_ADDRESS' THEN 'SHARED_IP'
               WHEN 'TERMINAL'   THEN 'SHARED_FRAUD_TERMINAL'
               ELSE 'SHARED_FRAUD_PAYEE'          -- beneficiary / external account
           END
    FROM graph.customer_entity a
    JOIN graph.customer_entity b
      ON b.entity_node_id = a.entity_node_id
     AND b.customer_node_id > a.customer_node_id
    JOIN graph.node n ON n.node_id = a.entity_node_id
    WHERE NOT n.is_supernode
      AND (   n.node_type IN ('DEVICE', 'IP_ADDRESS')
           OR (n.node_type IN ('BENEFICIARY', 'EXTERNAL_ACCOUNT', 'TERMINAL')
               AND n.fraud_customer_count >= v_min_fraud_custs));

    -- 7.8 Clusters (connected components) by label propagation --------
    -- Every customer starts with its own ID as label. Each round, a
    -- customer takes the smallest label among its linked neighbours.
    -- When no label changes, each connected group shares one label.
    INSERT INTO graph.customer_cluster (customer_node_id, cluster_id)
    SELECT node_id, node_id FROM graph.node WHERE node_type = 'CUSTOMER';

    LOOP
        UPDATE graph.customer_cluster c
        SET cluster_id = m.min_label
        FROM (
            SELECT l.me, MIN(cc.cluster_id) AS min_label
            FROM (SELECT customer_a AS me, customer_b AS other FROM graph.customer_link
                  UNION ALL
                  SELECT customer_b, customer_a FROM graph.customer_link) l
            JOIN graph.customer_cluster cc ON cc.customer_node_id = l.other
            GROUP BY l.me
        ) m
        WHERE c.customer_node_id = m.me
          AND m.min_label < c.cluster_id;

        GET DIAGNOSTICS v_changed = ROW_COUNT;
        v_rounds := v_rounds + 1;
        EXIT WHEN v_changed = 0;
    END LOOP;

    RAISE NOTICE 'Graph built: % nodes, % edges, % customer links, % multi-customer clusters (% label rounds).',
        (SELECT COUNT(*) FROM graph.node),
        (SELECT COUNT(*) FROM graph.edge),
        (SELECT COUNT(*) FROM graph.customer_link),
        (SELECT COUNT(*) FROM (SELECT cluster_id FROM graph.customer_cluster
                               GROUP BY cluster_id HAVING COUNT(*) > 1) x),
        v_rounds;
END;
$$;


-- ---------------------------------------------------------------------
-- 8. Query function: neighbourhood of a node
-- ---------------------------------------------------------------------
-- Returns every node reachable within p_max_hops of p_node_id, following
-- edges in either direction, with the shortest hop count and one example
-- path. Supernodes and merchants are never walked through, which keeps
-- results focused and the query fast.
-- Example: SELECT * FROM graph.fn_neighbourhood('CUSTOMER:ENT_C000021', 4);
-- (customer -> digital user -> device -> digital user -> customer = 4 hops)
CREATE FUNCTION graph.fn_neighbourhood(p_node_id TEXT, p_max_hops INTEGER DEFAULT 4)
RETURNS TABLE (node_id TEXT, node_type TEXT, display_name TEXT,
               fraud_event_count INTEGER, hops INTEGER, example_path TEXT)
LANGUAGE SQL STABLE
AS $$
    WITH RECURSIVE
    both_ways AS (
        SELECT src_node_id AS from_node, dst_node_id AS to_node FROM graph.edge
        UNION ALL
        SELECT dst_node_id, src_node_id FROM graph.edge
    ),
    walk (node_id, hops, path) AS (
        SELECT p_node_id, 0, ARRAY[p_node_id]
        UNION ALL
        SELECT b.to_node, w.hops + 1, w.path || b.to_node
        FROM walk w
        JOIN both_ways b ON b.from_node = w.node_id
        JOIN graph.node n ON n.node_id = b.to_node
        WHERE w.hops < p_max_hops
          AND NOT n.is_supernode
          AND n.node_type <> 'MERCHANT'
          AND NOT b.to_node = ANY (w.path)          -- no cycles
    )
    SELECT DISTINCT ON (w.node_id)
           w.node_id, n.node_type, n.display_name, n.fraud_event_count,
           w.hops, ARRAY_TO_STRING(w.path, ' -> ')
    FROM walk w
    JOIN graph.node n ON n.node_id = w.node_id
    ORDER BY w.node_id, w.hops;
$$;


-- ---------------------------------------------------------------------
-- 9. Build the graph now
-- ---------------------------------------------------------------------
CALL graph.refresh_graph();

-- Quick check: node and edge counts by type.
SELECT 'node' AS object, node_type AS type, COUNT(*) AS row_count
FROM graph.node GROUP BY node_type
UNION ALL
SELECT 'edge', edge_type, COUNT(*)
FROM graph.edge GROUP BY edge_type
ORDER BY object DESC, type;
