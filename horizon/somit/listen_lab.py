import psycopg2
import psycopg2.extensions
import json
import select
import sys
from datetime import datetime

# --- Connection settings ---
# Use the port your postgres container is exposed on (usually 5432)
# LAB VERSION (team integration): identical to listen.py except this
# block. Inside the lab's Python container the database host is the
# container name "postgres", not "localhost". PGHOST/PGDATABASE can
# override the defaults.
import os
CONN = {
    "host": os.getenv("PGHOST", "postgres"),
    "port": int(os.getenv("PGPORT", "5432")),
    "dbname": os.getenv("PGDATABASE", "lab"),
    "user": "student",
    "password": "student",
}

# Channels to listen on
CHANNELS = ["tcn"]  # or ["users_channel", "events_channel"]

def main():
    conn = psycopg2.connect(**CONN)
    conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
    cur = conn.cursor()

    for ch in CHANNELS:
        cur.execute(f"LISTEN {ch};")
        print(f"[{datetime.now():%H:%M:%S}] Listening on channel: {ch}")

    print("Waiting for notifications... (Ctrl+C to stop)\n")

    try:
        while True:
            # Block until data is available on the socket
            if select.select([conn], [], [], 5) == ([], [], []):
                continue  # timeout, loop again

            conn.poll()
            while conn.notifies:
                notify = conn.notifies.pop(0)
                ts = datetime.now().strftime("%H:%M:%S")
                print(f"[{ts}] channel={notify.channel} pid={notify.pid}")
                print(f"         payload: {notify.payload}")

                # If the payload is JSON, pretty-print it
                try:
                    parsed = json.loads(notify.payload)
                    print("         parsed :", json.dumps(parsed, indent=2))
                except (ValueError, TypeError):
                    pass  # not JSON, skip
                print()
    except KeyboardInterrupt:
        print("\nStopping listener.")
    finally:
        cur.close()
        conn.close()

if __name__ == "__main__":
    main()