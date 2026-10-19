"""
08_load_graph_to_neo4j.py
Horizon Retail Bank | 32113 Advanced Database | Assignment 2
Workstream: Graph database (relationship analysis)

PURPOSE
Copies the graph built in PostgreSQL (06_graph_layer.sql, schema "graph")
into the lab's Neo4j graph database, so fraud rings can be explored and
shown visually in Neo4j Browser with Cypher (see 09_report2_neo4j.cypher).

  PostgreSQL graph.node          -> Neo4j nodes (:Node plus a type label)
  PostgreSQL graph.edge          -> Neo4j relationships (OWNS, USED_DEVICE, ...)
  PostgreSQL graph.customer_link -> Neo4j (:Customer)-[:LINKED_TO]->(:Customer)
  PostgreSQL graph.customer_cluster -> cluster_id / review_priority on customers

Follows the same pattern as the workshop's graph_db_architecture.py:
constraints first, then UNWIND + MERGE in write transactions.

RUN (from the lab folder, with docker compose running)
  1. Put this file in the lab's workspace folder, e.g. workspace/horizon/
  2. Make sure 06_graph_layer.sql has been run in PostgreSQL.
  3. docker exec -it student-python python /workspace/horizon/08_load_graph_to_neo4j.py
  4. Open http://localhost:7474 (user neo4j / password password) and run
     the queries in 09_report2_neo4j.cypher.

RE-RUNNING
  Safe to re-run: it deletes the previous Horizon graph in Neo4j (only
  nodes labelled :Node) and loads it again from PostgreSQL.
"""

import os
from decimal import Decimal

import psycopg2
from neo4j import GraphDatabase


# --------------------------------------------------
# Connections (container names from docker-compose.yml)
# --------------------------------------------------
# PG_DBNAME defaults to "lab". If the warehouse was built in another
# database (e.g. horizon_dw), run with:  -e PG_DBNAME=horizon_dw
PG_SETTINGS = {
    "dbname": os.environ.get("PG_DBNAME", "lab"),
    "user": "student",
    "password": "student",
    "host": "postgres",
    "port": 5432,
}

NEO4J_URI = "bolt://neo4j:7687"
NEO4J_AUTH = ("neo4j", "password")

# Rows sent to Neo4j per transaction. Large enough to be fast, small
# enough to stay well inside Neo4j's default memory.
BATCH_SIZE = 5000


# --------------------------------------------------
# Allowed labels and relationship types
# --------------------------------------------------
# Cypher cannot take a label or relationship type as a parameter, so they
# are inserted into the query text. Only names from these fixed lists are
# ever used, so nothing from the data can change the query itself.
NODE_LABELS = {
    "CUSTOMER": "Customer",
    "ACCOUNT": "Account",
    "CARD": "Card",
    "DIGITAL_USER": "DigitalUser",
    "DEVICE": "Device",
    "IP_ADDRESS": "IpAddress",
    "BENEFICIARY": "Beneficiary",
    "EXTERNAL_ACCOUNT": "ExternalAccount",
    "TERMINAL": "Terminal",
    "MERCHANT": "Merchant",
}

RELATIONSHIP_TYPES = {
    "OWNS", "HOLDS", "HAS_LOGIN", "USED_DEVICE", "LOGGED_IN_FROM",
    "PAID", "SENT_TO", "USED_TERMINAL", "PURCHASED_AT",
}


# --------------------------------------------------
# Read from PostgreSQL
# --------------------------------------------------

def read_rows(pg_conn, sql):
    """Run a query and return a list of dicts.
    NUMERIC values come back as Decimal, which the Neo4j driver cannot
    store, so they are converted to float."""
    with pg_conn.cursor() as cur:
        cur.execute(sql)
        columns = [c[0] for c in cur.description]
        rows = []
        for record in cur.fetchall():
            row = {}
            for col, value in zip(columns, record):
                row[col] = float(value) if isinstance(value, Decimal) else value
            rows.append(row)
    return rows


# Nodes, with each customer's cluster and review priority added.
# Priority uses the same rule as Report 2 (07): HIGH = 2+ customers in
# the group have fraud-flagged activity, MEDIUM = 1, LOW = none.
NODES_SQL = """
WITH cluster_stats AS (
    SELECT cc.cluster_id,
           COUNT(*) AS cluster_size,
           COUNT(*) FILTER (WHERE n.fraud_event_count > 0) AS fraud_customers
    FROM graph.customer_cluster cc
    JOIN graph.node n ON n.node_id = cc.customer_node_id
    GROUP BY cc.cluster_id
)
SELECT n.node_id, n.node_type, n.business_key, n.display_name,
       n.fraud_event_count, n.linked_customer_count, n.fraud_customer_count,
       n.is_supernode,
       cc.cluster_id,
       cs.cluster_size,
       CASE WHEN cs.cluster_size IS NULL OR cs.cluster_size < 2 THEN NULL
            WHEN cs.fraud_customers >= 2 THEN 'HIGH'
            WHEN cs.fraud_customers = 1  THEN 'MEDIUM'
            ELSE 'LOW' END AS review_priority
FROM graph.node n
LEFT JOIN graph.customer_cluster cc ON cc.customer_node_id = n.node_id
LEFT JOIN cluster_stats cs ON cs.cluster_id = cc.cluster_id
ORDER BY n.node_type, n.node_id
"""

EDGES_SQL = """
SELECT src_node_id AS src, dst_node_id AS dst, edge_type,
       event_count, total_amount, fraud_event_count,
       first_seen, last_seen, source_table
FROM graph.edge
ORDER BY edge_type, edge_id
"""

LINKS_SQL = """
SELECT customer_a AS src, customer_b AS dst, shared_node_id, link_type
FROM graph.customer_link
ORDER BY customer_a, customer_b, shared_node_id
"""


# --------------------------------------------------
# Write to Neo4j
# --------------------------------------------------

def batches(rows, size=BATCH_SIZE):
    for start in range(0, len(rows), size):
        yield rows[start:start + size]


def delete_previous_graph(tx):
    """Delete up to 10,000 Horizon nodes (and their relationships).
    Called repeatedly until nothing is left, so no single transaction
    gets too big. Only :Node is touched; other lab data is left alone."""
    result = tx.run("""
        MATCH (n:Node)
        WITH n LIMIT 10000
        DETACH DELETE n
        RETURN count(*) AS deleted
    """)
    return result.single()["deleted"]


def create_constraints(tx):
    # Every Horizon node has a unique node_id, like a primary key.
    # The constraint also creates the index used by MATCH below.
    tx.run("""
        CREATE CONSTRAINT horizon_node_id_unique
        IF NOT EXISTS
        FOR (n:Node)
        REQUIRE n.node_id IS UNIQUE
    """)


def load_nodes(tx, label, rows):
    # Every node gets the shared :Node label plus its own type label,
    # e.g. (:Node:Customer). Properties mirror the PostgreSQL columns.
    tx.run(f"""
        UNWIND $rows AS row
        MERGE (n:Node {{node_id: row.node_id}})
        SET n:{label},
            n.node_type             = row.node_type,
            n.business_key          = row.business_key,
            n.display_name          = row.display_name,
            n.fraud_event_count     = row.fraud_event_count,
            n.linked_customer_count = row.linked_customer_count,
            n.fraud_customer_count  = row.fraud_customer_count,
            n.is_supernode          = row.is_supernode,
            n.cluster_id            = row.cluster_id,
            n.cluster_size          = row.cluster_size,
            n.review_priority       = row.review_priority
    """, rows=rows)


def load_edges(tx, rel_type, rows):
    # Aggregated activity between two nodes, e.g.
    # (:DigitalUser)-[:USED_DEVICE {event_count: 2}]->(:Device)
    tx.run(f"""
        UNWIND $rows AS row
        MATCH (a:Node {{node_id: row.src}})
        MATCH (b:Node {{node_id: row.dst}})
        MERGE (a)-[r:{rel_type}]->(b)
        SET r.event_count       = row.event_count,
            r.total_amount      = row.total_amount,
            r.fraud_event_count = row.fraud_event_count,
            r.first_seen        = row.first_seen,
            r.last_seen         = row.last_seen,
            r.source_table      = row.source_table
    """, rows=rows)


def load_customer_links(tx, rows):
    # Direct customer-to-customer links, one per shared entity, so the
    # rings can be drawn with customers only.
    tx.run("""
        UNWIND $rows AS row
        MATCH (a:Customer {node_id: row.src})
        MATCH (b:Customer {node_id: row.dst})
        MERGE (a)-[r:LINKED_TO {shared_node_id: row.shared_node_id}]->(b)
        SET r.link_type = row.link_type
    """, rows=rows)


def count_in_neo4j(tx):
    nodes = tx.run("MATCH (n:Node) RETURN count(n) AS c").single()["c"]
    rels = tx.run("""
        MATCH (:Node)-[r]->(:Node)
        WHERE type(r) <> 'LINKED_TO'
        RETURN count(r) AS c
    """).single()["c"]
    links = tx.run("MATCH (:Customer)-[r:LINKED_TO]->(:Customer) RETURN count(r) AS c").single()["c"]
    return nodes, rels, links


# --------------------------------------------------
# Main Program
# --------------------------------------------------

def main():
    print("Reading graph from PostgreSQL database:", PG_SETTINGS["dbname"])
    pg_conn = psycopg2.connect(**PG_SETTINGS)
    try:
        nodes = read_rows(pg_conn, NODES_SQL)
        edges = read_rows(pg_conn, EDGES_SQL)
        links = read_rows(pg_conn, LINKS_SQL)
    finally:
        pg_conn.close()
    print(f"  {len(nodes)} nodes, {len(edges)} edges, {len(links)} customer links")

    if not nodes:
        raise SystemExit("graph.node is empty: run 06_graph_layer.sql first.")

    # Stop early if the data contains a type this script does not know.
    unknown = ({r["node_type"] for r in nodes} - NODE_LABELS.keys()) | \
              ({r["edge_type"] for r in edges} - RELATIONSHIP_TYPES)
    if unknown:
        raise SystemExit(f"Unknown node/edge types: {sorted(unknown)}")

    driver = GraphDatabase.driver(NEO4J_URI, auth=NEO4J_AUTH)
    try:
        driver.verify_connectivity()
        with driver.session() as session:
            print("Connected to Neo4j")

            print("Removing previous Horizon graph...")
            while session.execute_write(delete_previous_graph) > 0:
                pass

            print("Creating constraints...")
            session.execute_write(create_constraints)

            for node_type, label in NODE_LABELS.items():
                rows = [r for r in nodes if r["node_type"] == node_type]
                for batch in batches(rows):
                    session.execute_write(load_nodes, label, batch)
                print(f"Loaded {len(rows):>6} {label} nodes")

            for rel_type in sorted(RELATIONSHIP_TYPES):
                rows = [r for r in edges if r["edge_type"] == rel_type]
                for batch in batches(rows):
                    session.execute_write(load_edges, rel_type, batch)
                print(f"Loaded {len(rows):>6} {rel_type} relationships")

            for batch in batches(links):
                session.execute_write(load_customer_links, batch)
            print(f"Loaded {len(links):>6} LINKED_TO customer links")

            # Check: Neo4j holds exactly what PostgreSQL holds.
            n_nodes, n_rels, n_links = session.execute_read(count_in_neo4j)
            print("\nCheck (PostgreSQL -> Neo4j):")
            print(f"  nodes          {len(nodes):>6} -> {n_nodes:>6}")
            print(f"  relationships  {len(edges):>6} -> {n_rels:>6}")
            print(f"  customer links {len(links):>6} -> {n_links:>6}")
            ok = (n_nodes, n_rels, n_links) == (len(nodes), len(edges), len(links))
            print("  RESULT:", "MATCH" if ok else "MISMATCH - investigate before using")
    finally:
        driver.close()
        print("Connection closed.")


if __name__ == "__main__":
    main()
