-- which customers are connected to each other through shared devices,
-- shared IP addresses, or payees/terminals used for fraud, and which of
-- those connected groups need investigating these groups are candidate
-- fraud rings, mule networks or victims of the same attacker

--   requires 06_graph_layer.sql check V6 also requires 06b
--   part A creates the report views (run once; re-run after re-running 06)
--   part B is the report itself: run each query separately and
--   screenshot the result grid for the report/demo
--   part C checks that the graph is correct and complete

-- A1. every customer-to-customer link, with names and the shared entity
CREATE OR REPLACE VIEW graph.v_customer_link_detail AS
SELECT l.customer_a,
       na.display_name           AS customer_a_name,
       l.customer_b,
       nb.display_name           AS customer_b_name,
       l.link_type,
       l.shared_node_id,
       ns.linked_customer_count  AS customers_sharing_entity,
       ns.fraud_customer_count   AS fraud_customers_on_entity
FROM graph.customer_link l
JOIN graph.node na ON na.node_id = l.customer_a
JOIN graph.node nb ON nb.node_id = l.customer_b
JOIN graph.node ns ON ns.node_id = l.shared_node_id;


-- A2. 1 row per connected group of 2+ customers, prioritised for review
-- review_priority:
--   HIGH   2+ members have fraud-flagged activity (coordinated fraud or
--          several victims of the same attacker)
--   MEDIUM exactly 1 member has fraud-flagged activity (the others may be
--          unflagged victims or accomplices)
--   LOW    no fraud-flagged activity (e.g. a family sharing a tablet)
CREATE OR REPLACE VIEW graph.v_cluster_summary AS
WITH members AS (
    SELECT cc.cluster_id, cc.customer_node_id, n.fraud_event_count,
           c.risk_category
    FROM graph.customer_cluster cc
    JOIN graph.node n ON n.node_id = cc.customer_node_id
    JOIN dw.dim_customer c ON c.customer_key = n.customer_key
),
member_stats AS (
    SELECT cluster_id,
           COUNT(*)                                        AS customer_count,
           COUNT(*) FILTER (WHERE fraud_event_count > 0)   AS customers_with_fraud,
           SUM(fraud_event_count)                          AS fraud_events,
           COUNT(*) FILTER (WHERE risk_category = 'HIGH')  AS high_risk_customers,
           STRING_AGG(SUBSTRING(customer_node_id FROM 10), ', '
                      ORDER BY customer_node_id)           AS members
    FROM members GROUP BY cluster_id
),
link_stats AS (
    SELECT cc.cluster_id,
           COUNT(*) FILTER (WHERE l.link_type = 'SHARED_DEVICE')         AS device_links,
           COUNT(*) FILTER (WHERE l.link_type = 'SHARED_IP')             AS ip_links,
           COUNT(*) FILTER (WHERE l.link_type = 'SHARED_FRAUD_PAYEE')    AS fraud_payee_links,
           COUNT(*) FILTER (WHERE l.link_type = 'SHARED_FRAUD_TERMINAL') AS fraud_terminal_links,
           STRING_AGG(DISTINCT l.shared_node_id, ', ')                   AS shared_entities
    FROM graph.customer_link l
    JOIN graph.customer_cluster cc ON cc.customer_node_id = l.customer_a
    GROUP BY cc.cluster_id
)
SELECT m.cluster_id,
       CASE WHEN m.customers_with_fraud >= 2 THEN 'HIGH'
            WHEN m.customers_with_fraud = 1  THEN 'MEDIUM'
            ELSE 'LOW' END                      AS review_priority,
       m.customer_count,
       m.customers_with_fraud,
       m.fraud_events,
       m.high_risk_customers,
       l.device_links, l.ip_links, l.fraud_payee_links, l.fraud_terminal_links,
       m.members,
       l.shared_entities
FROM member_stats m
JOIN link_stats l ON l.cluster_id = m.cluster_id
WHERE m.customer_count > 1;


-- A3. shared entities: anything reached by 2+ customers, with how many
-- of them were fraud-flagged. Includes supernodes so an analyst can see
-- what was excluded from linking and why
CREATE OR REPLACE VIEW graph.v_shared_entities AS
SELECT n.node_id,
       n.node_type,
       n.business_key,
       n.linked_customer_count,
       n.fraud_customer_count,
       n.fraud_event_count,
       n.is_supernode,
       CASE WHEN n.is_supernode THEN NULL
            ELSE (SELECT STRING_AGG(DISTINCT SUBSTRING(ce.customer_node_id FROM 10), ', ')
                  FROM graph.customer_entity ce
                  WHERE ce.entity_node_id = n.node_id)
       END AS customers
FROM graph.node n
WHERE n.linked_customer_count >= 2;


-- A4. collection points: payees, external accounts and card terminals
-- that received fraud-flagged activity from 2+ different customers
-- many victims paying one destination in a short time is the signature
-- of a mule account or a scripted card attack supernodes (big billers
-- such as Origin Energy) are excluded: a few fraud-flagged bill payments
-- among hundreds of normal ones do not make the biller a collection point
CREATE OR REPLACE VIEW graph.v_collection_points AS
SELECT n.node_type,
       n.business_key,
       n.fraud_customer_count,
       n.linked_customer_count,
       n.fraud_event_count,
       SUM(e.total_amount) FILTER (WHERE e.fraud_event_count > 0)  AS fraud_amount,
       MIN(e.first_seen)   FILTER (WHERE e.fraud_event_count > 0)  AS first_fraud,
       MAX(e.last_seen)    FILTER (WHERE e.fraud_event_count > 0)  AS last_fraud,
       ROUND(EXTRACT(EPOCH FROM
             MAX(e.last_seen)  FILTER (WHERE e.fraud_event_count > 0)
           - MIN(e.first_seen) FILTER (WHERE e.fraud_event_count > 0)) / 3600.0, 1)
                                                                    AS hours_span
FROM graph.node n
JOIN graph.edge e ON e.dst_node_id = n.node_id
WHERE n.node_type IN ('BENEFICIARY', 'EXTERNAL_ACCOUNT', 'TERMINAL')
  AND n.fraud_customer_count >= 2
  AND NOT n.is_supernode
GROUP BY n.node_id, n.node_type, n.business_key, n.fraud_customer_count,
         n.linked_customer_count, n.fraud_event_count;


-- PART B: REPORT 2 OUTPUT (run each query on its own)

-- R2.1 graph overview: what the graph contains
SELECT 'node' AS object, node_type AS type, COUNT(*) AS row_count
FROM graph.node GROUP BY node_type
UNION ALL
SELECT 'edge', edge_type, COUNT(*) FROM graph.edge GROUP BY edge_type
UNION ALL
SELECT 'customer link', link_type, COUNT(*) FROM graph.customer_link GROUP BY link_type
ORDER BY object DESC, type;

-- R2.2 summary: how many connected groups at each priority.
SELECT review_priority,
       COUNT(*)                  AS groups,
       SUM(customer_count)       AS customers,
       SUM(customers_with_fraud) AS customers_with_fraud
FROM graph.v_cluster_summary
GROUP BY review_priority
ORDER BY CASE review_priority WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;

-- R2.3 connected groups for investigation, highest priority first
SELECT review_priority, customer_count, customers_with_fraud, fraud_events,
       device_links, ip_links, fraud_payee_links, fraud_terminal_links,
       members, shared_entities
FROM graph.v_cluster_summary
ORDER BY CASE review_priority WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
         customers_with_fraud DESC, customer_count DESC
LIMIT 20;

-- R2.4 collection points: where fraud-flagged money and card attacks
-- from several customers converged
SELECT node_type, business_key, fraud_customer_count, fraud_event_count,
       fraud_amount, first_fraud, last_fraud, hours_span
FROM graph.v_collection_points
ORDER BY fraud_customer_count DESC, fraud_amount DESC;

-- R2.5 devices and IP addresses shared by several customers
SELECT node_type, business_key, linked_customer_count,
       fraud_customer_count, customers
FROM graph.v_shared_entities
WHERE node_type IN ('DEVICE', 'IP_ADDRESS')
  AND NOT is_supernode
ORDER BY fraud_customer_count DESC, linked_customer_count DESC
LIMIT 20;

-- R2.6 drill-down: fraud-touched nodes within 4 hops of one ring member
-- shows HOW customers are connected (example path for each node), here
-- across digital banking (device, IP) and core banking (payee, account)
-- change the customer to explore another group; remove the
-- fraud_event_count filter to see the full neighbourhood
SELECT node_type, node_id, hops, fraud_event_count, example_path
FROM graph.fn_neighbourhood('CUSTOMER:ENT_C000021', 4)
WHERE fraud_event_count > 0
ORDER BY hops, node_type, node_id;

-- R2.7 supernodes excluded from linking, and the threshold used
SELECT (SELECT setting_value FROM graph.config
        WHERE setting_name = 'max_customers_per_entity') AS threshold,
       node_type, business_key, linked_customer_count, fraud_customer_count
FROM graph.node
WHERE is_supernode
ORDER BY linked_customer_count DESC;

-- R2.8 how widely entities are shared (justifies the threshold)
SELECT node_type,
       CASE WHEN linked_customer_count = 1  THEN '1'
            WHEN linked_customer_count <= 3  THEN '2-3'
            WHEN linked_customer_count <= 10 THEN '4-10'
            WHEN linked_customer_count <= 50 THEN '11-50'
            ELSE '50+' END AS customers_sharing,
       COUNT(*) AS entities
FROM graph.node
WHERE linked_customer_count > 0
GROUP BY 1, 2
ORDER BY 1, MIN(linked_customer_count);


-- PART C: VALIDATION (expected results in the comments)

-- V1. every warehouse customer, account, card and digital user has
--     exactly one node. Expected: the two counts match on every row
SELECT 'CUSTOMER' AS node_type,
       (SELECT COUNT(*) FROM dw.dim_customer) AS warehouse_rows,
       (SELECT COUNT(*) FROM graph.node WHERE node_type = 'CUSTOMER') AS graph_nodes
UNION ALL
SELECT 'ACCOUNT', (SELECT COUNT(*) FROM dw.dim_account),
       (SELECT COUNT(*) FROM graph.node WHERE node_type = 'ACCOUNT')
UNION ALL
SELECT 'CARD', (SELECT COUNT(*) FROM dw.dim_card),
       (SELECT COUNT(*) FROM graph.node WHERE node_type = 'CARD')
UNION ALL
SELECT 'DIGITAL_USER', (SELECT COUNT(*) FROM dw.dim_digital_user),
       (SELECT COUNT(*) FROM graph.node WHERE node_type = 'DIGITAL_USER');

-- V2. activity edges account for every source event edges aggregate
--     events, so the sum of event_count must equal the fact row count
--     expected: the two counts match on every row
SELECT 'digital events with a device' AS check_name,
       (SELECT COUNT(*) FROM dw.fact_digital_event
        WHERE NULLIF(device_id, '') IS NOT NULL) AS source_rows,
       (SELECT SUM(event_count) FROM graph.edge WHERE edge_type = 'USED_DEVICE') AS graph_events
UNION ALL
SELECT 'digital events with an IP',
       (SELECT COUNT(*) FROM dw.fact_digital_event
        WHERE NULLIF(ip_address_synthetic, '') IS NOT NULL),
       (SELECT SUM(event_count) FROM graph.edge WHERE edge_type = 'LOGGED_IN_FROM')
UNION ALL
SELECT 'payments with a beneficiary (core + digital)',
       (SELECT COUNT(*) FROM dw.fact_core_transaction
        WHERE NULLIF(beneficiary_reference, '') IS NOT NULL)
     + (SELECT COUNT(*) FROM dw.fact_digital_event
        WHERE NULLIF(beneficiary_reference, '') IS NOT NULL),
       (SELECT SUM(event_count) FROM graph.edge WHERE edge_type = 'PAID')
UNION ALL
SELECT 'core transactions with a counterparty',
       (SELECT COUNT(*) FROM dw.fact_core_transaction
        WHERE NULLIF(counterparty_reference, '') IS NOT NULL),
       (SELECT SUM(event_count) FROM graph.edge WHERE edge_type = 'SENT_TO')
UNION ALL
SELECT 'card transactions with a terminal',
       (SELECT COUNT(*) FROM dw.fact_card_transaction
        WHERE NULLIF(device_reference, '') IS NOT NULL),
       (SELECT SUM(event_count) FROM graph.edge WHERE edge_type = 'USED_TERMINAL');

-- V3. fraud flags carried into the graph match the warehouse.
--     expected: the two numbers are equal (338 with the Horizon dataset)
SELECT (SELECT COUNT(*) FROM dw.fact_core_transaction WHERE fraud_indicator)
     + (SELECT COUNT(*) FROM dw.fact_card_transaction WHERE fraud_indicator)
     + (SELECT COUNT(*) FROM dw.fact_digital_event WHERE fraud_indicator)
           AS warehouse_fraud_flags,
       (SELECT SUM(fraud_event_count) FROM graph.node WHERE node_type = 'CUSTOMER')
           AS graph_customer_fraud_flags;

-- V4. no customer link is based on a supernode or a merchant, and no
--     payee/terminal link lacks the required fraud evidence
--     expected: 0
SELECT COUNT(*) AS bad_links
FROM graph.customer_link l
JOIN graph.node n ON n.node_id = l.shared_node_id
WHERE n.is_supernode
   OR n.node_type = 'MERCHANT'
   OR (n.node_type IN ('BENEFICIARY', 'EXTERNAL_ACCOUNT', 'TERMINAL')
       AND n.fraud_customer_count <
           (SELECT setting_value FROM graph.config
            WHERE setting_name = 'min_fraud_customers_for_weak_link'));

-- V5. clusters are consistent: every customer has one cluster, and no
--     link joins two different clusters expected: 0 and 0
SELECT (SELECT COUNT(*) FROM graph.node n
        WHERE n.node_type = 'CUSTOMER'
          AND NOT EXISTS (SELECT 1 FROM graph.customer_cluster cc
                          WHERE cc.customer_node_id = n.node_id))
           AS customers_without_cluster,
       (SELECT COUNT(*) FROM graph.customer_link l
        JOIN graph.customer_cluster a ON a.customer_node_id = l.customer_a
        JOIN graph.customer_cluster b ON b.customer_node_id = l.customer_b
        WHERE a.cluster_id <> b.cluster_id)
           AS links_crossing_clusters;

-- V6. does the graph find the planted scenarios? (needs 06b)
--     the graph was built without looking at the answer key for each
--     scenario type: how many of its customers ended up in a connected
--     group, in how many different groups, and at what priority.
--     expected with the horizon dataset:
--     shared device ring, suspicious beneficiary, account takeover,
--     rapid transaction burst -> all customers in ONE group, HIGH
--     benign shared device -> one group, LOW (correctly not escalated)
--     false positive Auth -> their shared office IP is a supernode, so
--     they are not grouped by it. (one of these customers, ENT_C000037,
--     is also a shared device ring member, so shows as HIGH here; two
--     others fall into LOW groups through unrelated IP overlaps.)
--     card fraud, geographic anomaly, false positive travel, legitimate
--     high-value -> single-customer patterns; the graph is not the right
--     tool for these (they belong to rule-based alerting)
WITH scen AS (
    SELECT DISTINCT scenario_type, 'CUSTOMER:' || enterprise_customer_key AS customer_node_id
    FROM staging.fraud_scenario_reference
),
grp AS (
    SELECT cc.customer_node_id, cc.cluster_id, s.review_priority
    FROM graph.customer_cluster cc
    LEFT JOIN graph.v_cluster_summary s ON s.cluster_id = cc.cluster_id
)
SELECT sc.scenario_type,
       COUNT(*)                                             AS scenario_customers,
       COUNT(*) FILTER (WHERE g.review_priority IS NOT NULL) AS customers_in_a_group,
       COUNT(DISTINCT g.cluster_id) FILTER (WHERE g.review_priority IS NOT NULL)
                                                            AS distinct_groups,
       STRING_AGG(DISTINCT g.review_priority, ', ')         AS priorities
FROM scen sc
JOIN grp g ON g.customer_node_id = sc.customer_node_id
GROUP BY sc.scenario_type
ORDER BY sc.scenario_type;
