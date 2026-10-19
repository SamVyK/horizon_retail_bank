#!/bin/bash
# =====================================================================
# run_all_mac.sh  -  Mac version of run_all.ps1 (PostgreSQL parts)
# Horizon Retail Bank | 32113 Advanced Database | Assignment 2
#
# Builds, in the agreed team order, inside the lab's PostgreSQL container:
#   Maedeh warehouse -> Samnang graph + Report 2 -> Shubham 06 ->
#   Samnang graph registration -> Shubham 07 -> Shubham 08 (Report 3)
#   -> Somit change-notification trigger
# Raj's lakehouse and the Neo4j copy are not run here (Python steps).
#
# HOW TO RUN (Terminal, inside this horizon folder):
#   bash run_all_mac.sh
# =====================================================================

DB="${1:-lab}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="$HERE/run_log_mac_$(date +%Y%m%d_%H%M%S).txt"
SQL=/tmp/horizon_sql
DATA=/tmp/horizon_data

log() { echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOG"; }

# Find the PostgreSQL container automatically (student-postgres or postgres-1)
PG=$(docker ps --format '{{.Names}}' | grep -i postgres | head -1)
if [ -z "$PG" ]; then
  log "FAILED no PostgreSQL container is running. Run: docker compose start (in the lab folder)"
  exit 1
fi
log "Using container $PG, database $DB. Log: $LOG"

for f in core_customers core_accounts core_transactions cards card_transactions \
         digital_users digital_events entity_mapping_reference fraud_scenario_reference; do
  if [ ! -f "$HERE/data/$f.csv" ]; then
    log "FAILED missing data/$f.csv"; exit 1
  fi
done
log "OK     pre-flight checks"

# Copy CSVs and SQL into the container
docker exec -u root "$PG" rm -rf "$DATA" "$SQL"
docker exec -u root "$PG" mkdir -p "$SQL"
docker cp "$HERE/data" "$PG:$DATA"                    || { log "FAILED copy CSV files"; exit 1; }
docker cp "$HERE/00_reset_all.sql" "$PG:$SQL/00_reset_all.sql"
for owner in maedeh samnang shubham somit; do
  docker cp "$HERE/$owner" "$PG:$SQL/$owner"          || { log "FAILED copy $owner"; exit 1; }
done
docker exec -u root "$PG" chmod -R a+rX "$DATA" "$SQL"
log "OK     files copied into $PG"

run_sql() {   # $1 = label, $2 = file
  log "START  $1"
  if docker exec "$PG" psql -U student -d "$DB" -v ON_ERROR_STOP=1 -P pager=off -f "$SQL/$2" >>"$LOG" 2>&1; then
    log "OK     $1"
  else
    log "FAILED $1  (details in $LOG)"; exit 1
  fi
}

run_sql 'Reset Horizon schemas'                  '00_reset_all.sql'
run_sql 'Maedeh 01 create schemas'               'maedeh/01_create_schemas_lab.sql'
run_sql 'Maedeh 02 create staging tables'        'maedeh/02_create_staging_tables.sql'
run_sql 'Maedeh 02b import CSVs to staging'      'maedeh/02b_import_staging_lab.sql'
run_sql 'Maedeh 03 create warehouse tables'      'maedeh/03_create_warehouse_tables.sql'
run_sql 'Maedeh 04 load warehouse'               'maedeh/04_load_warehouse.sql'
run_sql 'Maedeh 05 validation checks'            'maedeh/05_validation_checks.sql'
run_sql 'Samnang 06 graph layer'                 'samnang/06_graph_layer.sql'
run_sql 'Samnang 06b fraud scenario answer key'  'samnang/06b_import_fraud_scenarios.sql'
run_sql 'Samnang 07 Report 2'                    'samnang/07_report2_connected_entities.sql'
run_sql 'Shubham 06 governance setup'            'shubham/06_governance_setup.sql'
run_sql 'Samnang register graph in governance'   'samnang/register_graph_in_governance.sql'
run_sql 'Shubham 07 run governance cycle'        'shubham/07_run_governance.sql'
run_sql 'Shubham 08 Report 3'                    'shubham/08_report3_lineage_quality.sql'
run_sql 'Somit 1 create tcn extension'           'somit/1._create_extension_tcn.sql'
run_sql 'Somit 2 add primary key'                'somit/2._add_pk.sql'
run_sql 'Somit 3 create notification trigger'    'somit/3._create_trigger.sql'
if [ -f "$HERE/somit/live_lab/01_live_setup.sql" ]; then
  run_sql 'Somit live alerts: triggers + 4 fraud rules' 'somit/live_lab/01_live_setup.sql'
fi

# Presentation dashboard generated from the database (host python3, or the lab Python container)
if [ -f "$HERE/generate_dashboard.py" ] && [ -f "$HERE/somit/live_lab/dashboard.html" ]; then
  log "START  Generate Horizon_Dashboard.html"
  if command -v python3 >/dev/null 2>&1 && python3 "$HERE/generate_dashboard.py" --database "$DB" >>"$LOG" 2>&1; then
    log "OK     Generate Horizon_Dashboard.html"
  else
    PY=$(docker ps --format '{{.Names}}' | grep -i python | head -1)
    if [ -n "$PY" ] && docker exec -e PGHOST=postgres -e PGDATABASE="$DB" "$PY" python /workspace/horizon/generate_dashboard.py >>"$LOG" 2>&1; then
      log "OK     Generate Horizon_Dashboard.html (Python container)"
    else
      log "SKIP   dashboard could not be generated (details in $LOG)"
    fi
  fi
fi

log 'ALL STEPS COMPLETED'
[ -f "$HERE/Horizon_Dashboard.html" ] && log "Dashboard: $HERE/Horizon_Dashboard.html"
[ -f "$HERE/somit/live_lab/live_server.py" ] && log "Live alerts: python3 workspace/horizon/somit/live_lab/live_server.py  then open http://localhost:8765"
log "Report 3 access test: docker exec $PG psql -U student -d $DB -f $SQL/shubham/08_report3_lineage_quality.sql"
