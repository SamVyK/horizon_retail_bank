# Live notifications, lab version (Somit's workstream)

These files make fraud alerts appear **live in the presentation dashboard**. They need only the lab containers and Python 3. They don't need Debezium, Redpanda or any pip install.

| File | What it does |
|---|---|
| `01_live_setup.sql` | Adds AFTER triggers to `staging.card_transactions`, `staging.digital_events`, `staging.core_transactions` and `staging.digital_users`. Every change is logged in `staging.live_event_log`. Somit's 4 fraud rules are checked with the same thresholds as `Live Events/fraud.py`, and alerts are written to `staging.fraud_events` and announced with `pg_notify('horizon_live')`. |
| `02_clean_tests.sql` | Removes test rows, alerts and the event log so a demo starts from zero. |
| `live_server.py` | Installs the triggers, serves the dashboard at http://localhost:8765, and gives the dashboard the latest events and alerts every second. It also runs Somit's own test scripts when a button is pressed. |
| `dashboard.html` | The presentation. Chapter G switches to **Live** when the server is running. Alert pop-ups appear on every chapter. |

## Where it goes
```
<lab folder>/workspace/horizon/somit/live_lab/   ← this folder
<lab folder>/workspace/horizon/somit/Live Events/ ← Somit's tests (already there)
```

## Run
```bash
cd ~/Documents/advanced-database-lab
bash workspace/horizon/run_all_mac.sh                     # build the data (once)
python3 workspace/horizon/somit/live_lab/live_server.py    # leave it running
```
Open **http://localhost:8765**, go to chapter **G**, and press **Test 1 – Test 4**.
Inserting the same rows from CloudBeaver or Terminal shows up in the same way.

The four rules (from Somit's fraud.py):
- Overseas cluster: 3 or more international card-not-present payments on one card within 60 minutes.
- Rapid burst: 5 or more APPROVED payments on one card within 10 minutes.
- Shared device: one device used by more than 2 users.
- Suspicious beneficiary: one payee receiving transfers from more than 5 senders.

The full streaming version (Debezium → Redpanda → fraud.py → Streamlit) in `Live Events/` is unchanged.
