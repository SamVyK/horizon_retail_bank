// run after 08_load_graph_to_neo4j.py
// open Neo4j Browser at http://localhost:7474 (neo4j / password)
// paste ONE query at a time and press Run. Queries that RETURN paths
// show a network picture; switch to the Table view for the numbers
// click a label (e.g. Customer) at the top of the result and set
// its caption to business_key so node names are readable



// N1. what is in the graph (table)
MATCH (n:Node)
RETURN n.node_type AS node_type, count(*) AS nodes
ORDER BY nodes DESC;


// N2. groups to investigate (table), same rule as Report 2 in SQL
MATCH (c:Customer)
WHERE c.review_priority IS NOT NULL
RETURN c.review_priority AS priority,
       c.cluster_id      AS group_id,
       count(*)          AS customers,
       sum(c.fraud_event_count) AS fraud_events,
       collect(c.business_key)  AS members
ORDER BY CASE priority WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
         customers DESC
LIMIT 20;


// N3. all HIGH-priority rings, customers only (picture)
// each line is a LINKED_TO link; hover over it to see the link type
MATCH (a:Customer)-[r:LINKED_TO]->(b:Customer)
WHERE a.review_priority = 'HIGH'
RETURN a, r, b;


// N4. shared device ring across two systems (picture)
// 5 customers: same device and IP in digital banking, same payee in
// both digital and core banking, same external collection account
MATCH (c:Customer {cluster_id: 'CUSTOMER:ENT_C000021'})
MATCH p = (c)-[:HAS_LOGIN|OWNS]->()-[:USED_DEVICE|LOGGED_IN_FROM|PAID|SENT_TO]->(e)
WHERE e.fraud_customer_count >= 2 AND NOT e.is_supernode
RETURN p;


// N5. account takeover: one attacker, several victims (picture)
// victims' digital logins traced back to the IP addresses they share
MATCH (c:Customer {cluster_id: 'CUSTOMER:ENT_C000001'})
MATCH p = (c)-[:HAS_LOGIN]->(:DigitalUser)-[:LOGGED_IN_FROM]->(ip:IpAddress)
WHERE ip.fraud_customer_count >= 2 AND NOT ip.is_supernode
RETURN p;


// N6. mule collection hub (picture)
// 7 customers each sent about $4,900 to one external account in 30 hours
MATCH p = (c:Customer)-[:OWNS]->(:Account)-[:SENT_TO]->(x:ExternalAccount)
WHERE x.business_key = 'AU_MULE_AGGREGATE_HUB'
RETURN p;


// N7. card burst attack: 8 cards through the same 5 gateways (picture)
MATCH p = (c:Customer)-[:HOLDS]->(:Card)-[:USED_TERMINAL]->(t:Terminal)
WHERE t.fraud_customer_count >= 2 AND NOT t.is_supernode
RETURN p;


// N8. benign shared device: a family tablet, correctly LOW (picture)
MATCH p = (c:Customer)-[:HAS_LOGIN]->(:DigitalUser)-[:USED_DEVICE]->(d:Device)
WHERE d.business_key = 'DEV_FAM_TABLET_01'
RETURN p, c.review_priority;


// N9. how are two customers connected? Shortest path, ignoring
// supernodes such as big billers and shared office IPs (picture)
MATCH (a:Customer {business_key: 'ENT_C000021'}),
      (b:Customer {business_key: 'ENT_C000039'})
MATCH p = shortestPath((a)-[*..6]-(b))
WHERE none(n IN nodes(p) WHERE n.is_supernode)
RETURN p;


// N10. collection points (table): destinations receiving fraud-flagged
// activity from 2+ customers
MATCH (src:Node)-[r:PAID|SENT_TO|USED_TERMINAL]->(x:Node)
WHERE x.fraud_customer_count >= 2 AND NOT x.is_supernode
  AND r.fraud_event_count > 0
RETURN x.node_type          AS type,
       x.business_key       AS destination,
       x.fraud_customer_count AS fraud_customers,
       sum(r.total_amount)  AS fraud_amount,
       min(r.first_seen)    AS first_fraud,
       max(r.last_seen)     AS last_fraud
ORDER BY fraud_customers DESC, fraud_amount DESC;
