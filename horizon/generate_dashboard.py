#!/usr/bin/env python3
"""Generate Horizon's interactive presentation dashboard from the lab database.

Place this file in the Horizon project root (beside raj/, samnang/, shubham/, somit/).
After run_all.ps1 (or run_all_mac.sh) succeeds, run:

    python generate_dashboard.py          (Windows)
    python3 generate_dashboard.py         (Mac)

run_all.ps1 also runs it for you inside the lab's Python container.

What it does
  1. Reads the latest figures from PostgreSQL: warehouse counts, monthly
     activity (Report 1), graph priorities (Report 2), the data-trust
     summary and every quality rule result (Report 3).
  2. Injects them into the dashboard template
     somit/live_lab/dashboard.html as window.HZ_SNAPSHOT.
  3. Writes Horizon_Dashboard.html in the project root.

Open it directly for the presentation, or start the live server to add
real-time fraud alerts (chapter G):

    python3 somit/live_lab/live_server.py   ->  http://localhost:8765

Database access, tried in this order:
  docker exec psql (on the host) -> psycopg / psycopg2 (inside student-python)
If neither works, the dashboard is still written with the team-run figures
and a note saying so. The script only reads; it never changes the database.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

TZ = os.environ.get("HZ_TZ", "Australia/Sydney").replace("'", "")

SECTIONS = {
    "warehouse": """
        SELECT json_build_object(
          'records', (SELECT count(*) FROM dw.fact_core_transaction)
                   + (SELECT count(*) FROM dw.fact_card_transaction)
                   + (SELECT count(*) FROM dw.fact_digital_event),
          'customers', (SELECT count(*) FROM dw.dim_customer),
          'labels', (SELECT count(*) FROM dw.fact_core_transaction WHERE fraud_indicator)
                  + (SELECT count(*) FROM dw.fact_card_transaction WHERE fraud_indicator)
                  + (SELECT count(*) FROM dw.fact_digital_event WHERE fraud_indicator),
          'database', current_database(),
          'generated', to_char(now() AT TIME ZONE '{tz}', 'DD Mon YYYY HH24:MI'))
    """,
    "monthly": """
        WITH a AS (
          SELECT 'core' AS s, transaction_timestamp AS t FROM dw.fact_core_transaction
          UNION ALL SELECT 'card', transaction_timestamp FROM dw.fact_card_transaction
          UNION ALL SELECT 'digital', event_timestamp FROM dw.fact_digital_event),
        w AS (SELECT * FROM a WHERE t >= '2024-01-01' AND t < '2026-10-01'),
        m AS (SELECT to_char(d, 'YYYY-MM') AS month
              FROM generate_series('2024-01-01'::date, '2026-09-01'::date, interval '1 month') d),
        c AS (SELECT to_char(date_trunc('month', t), 'YYYY-MM') AS month, s, count(*) AS n FROM w GROUP BY 1, 2)
        SELECT json_build_object(
          'window', (SELECT count(*) FROM w),
          'monthly', json_build_object(
             'months',  (SELECT json_agg(month ORDER BY month) FROM m),
             'core',    (SELECT json_agg(coalesce(c.n,0) ORDER BY m.month) FROM m LEFT JOIN c ON c.month=m.month AND c.s='core'),
             'card',    (SELECT json_agg(coalesce(c.n,0) ORDER BY m.month) FROM m LEFT JOIN c ON c.month=m.month AND c.s='card'),
             'digital', (SELECT json_agg(coalesce(c.n,0) ORDER BY m.month) FROM m LEFT JOIN c ON c.month=m.month AND c.s='digital')))
    """,
    "graph": """
        SELECT json_build_object(
          'nodes', (SELECT count(*) FROM graph.node),
          'edges', (SELECT count(*) FROM graph.edge),
          'links', (SELECT count(*) FROM graph.customer_link),
          'groups', (SELECT count(*) FROM graph.v_cluster_summary),
          'prio', (SELECT json_object_agg(review_priority, json_build_array(g, c)) FROM (
                     SELECT review_priority, count(*) AS g, sum(customer_count) AS c
                     FROM graph.v_cluster_summary GROUP BY 1) p))
    """,
    "governance": """
        SELECT json_build_object(
          'objects', t.objects_catalogued, 'columns', t.columns_catalogued,
          'sensitive', t.sensitive_columns, 'flows', t.lineage_flows,
          'controlRun', t.control_rules_run, 'ruleRate', t.rule_pass_rate_pct,
          'rowRate', t.row_pass_rate_pct, 'run', t.latest_run_id,
          'schemas', (SELECT count(*) FROM governance.managed_schema),
          'pass', r.rules_passed, 'fail', r.rules_failed, 'info', r.rules_info,
          'rules', (SELECT json_agg(json_build_object('rule_id', x.rule_id, 'rows_checked', x.rows_checked,
                                                      'rows_failed', x.rows_failed, 'status', x.status))
                    FROM governance.dq_result x WHERE x.run_id = r.run_id))
        FROM governance.v_data_trust_summary t
        JOIN governance.dq_run r ON r.run_id = t.latest_run_id
    """,
}


def lab_compose(root: Path) -> Path:
    return root.parent.parent / "docker-compose.yml"


def find_container(root: Path) -> str | None:
    if os.environ.get("HZ_CONTAINER"):
        return os.environ["HZ_CONTAINER"]
    compose = lab_compose(root)
    if compose.is_file():
        try:
            out = subprocess.run(["docker", "compose", "-f", str(compose), "ps", "-q", "postgres"],
                                 capture_output=True, text=True, timeout=20).stdout.strip()
            if out:
                return out.splitlines()[0].strip()
        except (OSError, subprocess.SubprocessError):
            pass
    try:
        out = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                             capture_output=True, text=True, timeout=20).stdout
        for name in out.splitlines():
            if "postgres" in name.lower():
                return name.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def make_docker_runner(container: str, database: str):
    def run(sql: str) -> dict:
        p = subprocess.run(["docker", "exec", container, "psql", "-U", "student", "-d", database,
                            "-X", "-At", "-v", "ON_ERROR_STOP=1", "-c", sql],
                           capture_output=True, text=True, encoding="utf-8", timeout=60)
        if p.returncode:
            raise RuntimeError(p.stderr.strip().splitlines()[-1] if p.stderr.strip() else "psql failed")
        return json.loads(p.stdout.strip())
    return run


def make_psycopg_runner(database: str):
    try:
        import psycopg as driver  # psycopg 3 (installed by Raj's step)
    except ImportError:
        try:
            import psycopg2 as driver  # psycopg 2
        except ImportError as exc:
            raise RuntimeError("neither psycopg nor psycopg2 is installed") from exc
    conn = driver.connect(host=os.environ.get("PGHOST", "postgres"), port=os.environ.get("PGPORT", "5432"),
                          dbname=database, user=os.environ.get("PGUSER", "student"),
                          password=os.environ.get("PGPASSWORD", "student"), connect_timeout=8)
    conn.autocommit = True

    def run(sql: str) -> dict:
        with conn.cursor() as cur:
            cur.execute(sql)
            value = cur.fetchone()[0]
        return value if isinstance(value, dict) else json.loads(value)
    return run


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=Path(__file__).resolve().parent)
    ap.add_argument("--database", default=os.environ.get("PGDATABASE", "lab"))
    ap.add_argument("--output", type=Path, help="default: ROOT/Horizon_Dashboard.html")
    ap.add_argument("--no-db", action="store_true", help="write the dashboard with the team-run figures")
    args = ap.parse_args()
    root = args.root.resolve()
    template = root / "somit" / "live_lab" / "dashboard.html"
    if not template.is_file():
        print(f"Dashboard template missing: {template}\nUnzip live_lab into somit/ first.", file=sys.stderr)
        return 2

    runner, method = None, "none"
    if not args.no_db:
        if shutil.which("docker"):
            container = find_container(root)
            if container:
                runner, method = make_docker_runner(container, args.database), f"docker exec {container[:12]}"
        if runner is None:
            try:
                runner, method = make_psycopg_runner(args.database), "psycopg"
            except Exception as exc:  # no driver or no connection
                print(f"Database not reachable ({exc}); using the team-run figures.")

    snapshot: dict = {}
    if runner:
        for name, sql in SECTIONS.items():
            try:
                part = runner(sql.format(tz=TZ))
                snapshot.update({k: v for k, v in part.items() if v is not None})
                print(f"  {name:<11} read from PostgreSQL")
            except Exception as exc:
                print(f"  {name:<11} skipped ({str(exc)[:120]})")

    page = template.read_text(encoding="utf-8")
    inject = ("<script>window.HZ_SNAPSHOT=" + json.dumps(snapshot, default=str).replace("</", "<\\/")
              + ";</script>\n") if snapshot else ""
    marker = "<script>\n(() => {"
    if inject:
        if marker not in page:
            print("Template format not recognised; the dashboard keeps its default figures.", file=sys.stderr)
        page = page.replace(marker, inject + marker, 1)
    out = (args.output or root / "Horizon_Dashboard.html").resolve()
    out.write_text(page, encoding="utf-8")
    print(f"Dashboard created: {out}  (data: {method if snapshot else 'team-run figures'})")
    print("Live alerts: python3 somit/live_lab/live_server.py, then open http://localhost:8765")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
