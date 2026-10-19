"""
Horizon Retail Bank - Data Fabric (Governance Layer)
run_governance.py : runs scripts 06, 07 and 08 from the lab Python container
Owner : Shubham Bhardwaj (25755442)

WHY THIS FILE EXISTS
CloudBeaver can run the SQL scripts directly. This runner is a second,
repeatable way to run them, the same way Workshop 6 runs its pipeline:

    docker compose exec python python /workspace/governance/run_governance.py

It connects to the Postgres container, runs the three governance scripts
in order, and prints every Report 3 result as a table, plus the access
test messages. Use --report-only to skip setup and just re-run the
governance cycle and the report.

CONNECTION
Defaults match the Lab Environment docker-compose.yml (host "postgres",
user/password "student"). Override with environment variables if your
setup differs: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD.
"""

import os
import sys

import psycopg2

HERE = os.path.dirname(os.path.abspath(__file__))

CONNECTION = {
    "host": os.getenv("PGHOST", "postgres"),
    "port": int(os.getenv("PGPORT", "5432")),
    "dbname": os.getenv("PGDATABASE", "horizon_dw"),
    "user": os.getenv("PGUSER", "student"),
    "password": os.getenv("PGPASSWORD", "student"),
}


def read_sql(name):
    """Return the text of a SQL file stored next to this script."""
    with open(os.path.join(HERE, name), encoding="utf-8") as handle:
        return handle.read()


def print_table(title, cursor):
    """Print the current result set as a plain-text table."""
    rows = cursor.fetchall()
    headers = [col.name for col in cursor.description]
    cells = [[("" if v is None else str(v)) for v in row] for row in rows]
    widths = [max([len(h)] + [len(r[i]) for r in cells]) for i, h in enumerate(headers)]
    widths = [min(w, 60) for w in widths]          # keep long text readable

    def fmt(values):
        return " | ".join(str(v)[:w].ljust(w) for v, w in zip(values, widths))

    print(f"\n=== {title} ({len(rows)} rows)")
    print(fmt(headers))
    print("-+-".join("-" * w for w in widths))
    for row in cells:
        print(fmt(row))


def print_notices(connection):
    """Print and clear PostgreSQL NOTICE messages (used by the access test)."""
    for notice in connection.notices:
        print("  " + notice.strip().replace("NOTICE:  ", ""))
    connection.notices.clear()


def run_script(connection, name):
    """Execute a whole SQL file in one call (setup scripts)."""
    with connection.cursor() as cursor:
        cursor.execute(read_sql(name))
    connection.commit()
    connection.notices.clear()                     # drop 'does not exist, skipping'
    print(f"[OK] {name}")


def run_report(connection):
    """Run script 08: Part A (views) as one block, then each R3.x query
    separately so every result set can be printed."""
    sql = read_sql("08_report3_lineage_quality.sql")
    part_a, part_b = sql.split("PART B - Report 3 queries", 1)
    part_a = part_a.rsplit("/*", 1)[0]             # cut the PART B banner start

    with connection.cursor() as cursor:
        cursor.execute(part_a)
    connection.commit()
    print("[OK] 08 Part A: report views created")

    # Each query starts with a comment line "-- R3.n ..."
    blocks = part_b.split("\n-- R3.")[1:]
    for block in blocks:
        title = "R3." + block.splitlines()[0].strip()
        body = "\n".join(block.splitlines()[1:]).split("-- End of Report 3")[0]
        with connection.cursor() as cursor:
            cursor.execute(body)
            if cursor.description:                 # a SELECT returned rows
                print_table(title, cursor)
            else:                                  # the DO block (access test)
                print(f"\n=== {title}")
                print_notices(connection)
        connection.commit()


def main():
    report_only = "--report-only" in sys.argv
    print(f"Connecting to {CONNECTION['user']}@{CONNECTION['host']}:"
          f"{CONNECTION['port']}/{CONNECTION['dbname']}")
    connection = psycopg2.connect(**CONNECTION)
    try:
        if not report_only:
            run_script(connection, "06_governance_setup.sql")
        with connection.cursor() as cursor:
            cursor.execute("SELECT governance.refresh_catalog()")
            print(f"[OK] catalog refreshed: {cursor.fetchone()[0]} objects")
            cursor.execute("SELECT governance.run_quality_checks()")
            print(f"[OK] quality run complete: run_id {cursor.fetchone()[0]}")
        connection.commit()
        run_report(connection)
        print("\nGovernance cycle and Report 3 completed successfully.")
    except psycopg2.Error as error:
        connection.rollback()
        print(f"\n[ERROR] {error.pgerror or error}")
        sys.exit(1)
    finally:
        connection.close()


if __name__ == "__main__":
    main()
