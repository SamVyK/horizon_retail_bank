#!/usr/bin/env python3
"""
Horizon Retail Bank - live notification server (lab version)
Somit's workstream (live events) | 32113 Advanced Database | Assignment 2
File: somit/live_lab/live_server.py

WHAT IT DOES
  1. Installs the live triggers (01_live_setup.sql) in the lab database.
     They run Somit's four fraud rules inside PostgreSQL and write alerts
     to staging.fraud_events, and log every change in
     staging.live_event_log.
  2. Serves the presentation dashboard at http://localhost:8765
  3. Answers /api/state, which the dashboard polls every second, so new
     events and fraud alerts appear on screen as they happen.
  4. Lets the dashboard run Somit's own test scripts (Test1-Test4, the
     V1 digital-user insert/update/delete) with one click.

Uses only the Python standard library. It talks to PostgreSQL through
`docker exec <postgres container> psql`, so nothing needs installing.

RUN (Terminal, in the lab folder):
    python3 workspace/horizon/somit/live_lab/live_server.py
Then open http://localhost:8765 and go to chapter G (Live events).
Stop with Ctrl+C.

OPTIONS (environment variables)
    HZ_DB=lab            database name
    HZ_PORT=8765         web port
    HZ_CONTAINER=...     PostgreSQL container (auto-detected)
    HZ_TZ=Australia/Sydney   time zone for displayed times
    HZ_LOCAL=1           use a local psql on localhost instead of docker
"""
import json
import os
import shutil
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
SOMIT = os.path.dirname(HERE)
DB = os.getenv("HZ_DB", "lab")
PORT = int(os.getenv("HZ_PORT", "8765"))
TZ = os.getenv("HZ_TZ", "Australia/Sydney").replace("'", "")

# One-click demo actions -> SQL files (all Somit's own tests, unchanged)
ACTIONS = {
    "test1":    os.path.join(SOMIT, "Live Events", "Test1-Internationalcluster.sql"),
    "test2":    os.path.join(SOMIT, "Live Events", "Test2-Rapidtransactions.sql"),
    "test3":    os.path.join(SOMIT, "Live Events", "Test3-Shareddevicering.sql"),
    "test4":    os.path.join(SOMIT, "Live Events", "Test4-SuspiciousBeneficiary.sql"),
    "v1insert": os.path.join(SOMIT, "insert_test_live_feed.sql"),
    "v1update": os.path.join(SOMIT, "update_test_live_feed.sql"),
    "v1delete": os.path.join(SOMIT, "delete_test_live.sql"),
    "clean":    os.path.join(HERE, "02_clean_tests.sql"),
    "setup":    os.path.join(HERE, "01_live_setup.sql"),
}


def find_container():
    name = os.getenv("HZ_CONTAINER")
    if name:
        return name
    # 1) the lab's Compose service "postgres" (<lab>/docker-compose.yml)
    compose = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(SOMIT))), "docker-compose.yml")
    if os.path.exists(compose):
        try:
            cid = subprocess.run(["docker", "compose", "-f", compose, "ps", "-q", "postgres"],
                                 capture_output=True, text=True, timeout=20).stdout.strip()
            if cid:
                return cid.splitlines()[0].strip()
        except (OSError, subprocess.SubprocessError):
            pass
    # 2) any running container with "postgres" in its name
    try:
        out = subprocess.run(["docker", "ps", "--format", "{{.Names}}"],
                             capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    for line in out.splitlines():
        if "postgres" in line.lower():
            return line.strip()
    return None


LOCAL = os.getenv("HZ_LOCAL") == "1"
CONTAINER = None if LOCAL else find_container()


def psql_cmd():
    base = ["psql", "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1", "-U", "student", "-d", DB]
    if LOCAL:
        return base[:1] + ["-h", "localhost"] + base[1:]
    return ["docker", "exec", "-i", CONTAINER] + base


def run_sql(sql=None, file_path=None):
    """Run SQL text or a SQL file. Returns (ok, stdout, stderr)."""
    cmd = psql_cmd()
    env = dict(os.environ, PGPASSWORD="student")
    if file_path:
        with open(file_path, "rb") as fh:
            data = fh.read()
        cmd = cmd + ["-f", "-"]
    else:
        data = None
        cmd = cmd + ["-c", sql]
    try:
        p = subprocess.run(cmd, input=data, capture_output=True, timeout=60, env=env)
    except (OSError, subprocess.SubprocessError) as exc:
        return False, "", str(exc)
    return p.returncode == 0, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")


STATE_SQL = """
SELECT json_build_object(
  'events', (SELECT coalesce(json_agg(x ORDER BY x.log_id), '[]'::json) FROM (
      SELECT log_id, table_name, operation, row_id, summary,
             to_char(logged_at AT TIME ZONE '{tz}', 'HH24:MI:SS') AS t
      FROM staging.live_event_log WHERE log_id > {e}
      ORDER BY log_id DESC LIMIT 60) x),
  'alerts', (SELECT coalesce(json_agg(y ORDER BY y.event_id), '[]'::json) FROM (
      SELECT event_id, event_type, customer_key, source_id, severity, details,
             to_char(detected_at AT TIME ZONE '{tz}', 'HH24:MI:SS') AS t
      FROM staging.fraud_events WHERE event_id > {a}
      ORDER BY event_id DESC LIMIT 50) y),
  'counts', (SELECT coalesce(json_object_agg(event_type, n), '{{}}'::json)
             FROM (SELECT event_type, count(*) AS n FROM staging.fraud_events GROUP BY 1) c),
  'total_alerts', (SELECT count(*) FROM staging.fraud_events),
  'total_events', (SELECT count(*) FROM staging.live_event_log),
  'database', current_database())
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "HorizonLive/1.0"

    def log_message(self, fmt, *args):  # keep the terminal quiet except actions
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def do_GET(self):
        url = urlparse(self.path)
        if url.path in ("/", "/index.html", "/dashboard.html"):
            # Prefer the dashboard generated from the database (generate_dashboard.py);
            # fall back to the template in this folder.
            generated = os.path.join(os.path.dirname(SOMIT), "Horizon_Dashboard.html")
            page = generated if os.path.exists(generated) else os.path.join(HERE, "dashboard.html")
            with open(page, "rb") as fh:
                return self._send(200, fh.read(), "text/html")
        if url.path == "/api/state":
            q = parse_qs(url.query)
            try:
                e = max(0, int(q.get("e", ["0"])[0]))
                a = max(0, int(q.get("a", ["0"])[0]))
            except ValueError:
                return self._send(400, json.dumps({"ok": False, "error": "bad cursor"}))
            ok, out, err = run_sql(STATE_SQL.format(e=e, a=a, tz=TZ))
            if not ok and "does not exist" in err:
                # The warehouse was rebuilt (run_all resets staging): reinstall the triggers.
                if run_sql(file_path=ACTIONS["setup"])[0]:
                    print("Live triggers reinstalled after a rebuild")
                    ok, out, err = run_sql(STATE_SQL.format(e=e, a=a, tz=TZ))
            if not ok:
                return self._send(500, json.dumps({"ok": False, "error": err.strip()[-400:]}))
            state = json.loads(out.strip() or "{}")
            state["ok"] = True
            return self._send(200, json.dumps(state))
        return self._send(404, json.dumps({"ok": False, "error": "not found"}))

    def do_POST(self):
        url = urlparse(self.path)
        if url.path.startswith("/api/run/"):
            name = url.path.rsplit("/", 1)[-1]
            path = ACTIONS.get(name)
            if not path or not os.path.exists(path):
                return self._send(404, json.dumps({"ok": False, "error": "unknown action " + name}))
            ok, out, err = run_sql(file_path=path)
            print(("OK    " if ok else "ERROR ") + name + ("" if ok else "  " + err.strip()[-200:]))
            return self._send(200 if ok else 500,
                              json.dumps({"ok": ok, "action": name, "error": err.strip()[-400:]}))
        return self._send(404, json.dumps({"ok": False, "error": "not found"}))


def main():
    if not LOCAL:
        if not shutil.which("docker"):
            sys.exit("Docker CLI not found. Open Docker Desktop first.")
        if not CONTAINER:
            sys.exit("No PostgreSQL container is running. Run: docker compose up -d")
        print(f"Using container {CONTAINER}, database {DB}")
    ok, out, err = run_sql(file_path=ACTIONS["setup"])
    if not ok:
        print(err.strip()[-600:])
        sys.exit("Could not install the live triggers. Build the warehouse first "
                 "(run_all_mac.sh), then start this server again.")
    print("Live triggers installed: 4 fraud rules on staging card/digital/core tables")
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Dashboard: http://localhost:{PORT}   (chapter G = Live events)")
    print("Insert rows from CloudBeaver, Terminal or the dashboard buttons; alerts appear live.")
    print("Ctrl+C to stop.")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
