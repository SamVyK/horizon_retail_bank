<#
=====================================================================
 run_all.ps1
 Horizon Retail Bank | 32113 Advanced Database | Assignment 2
 Team integration: builds the whole prototype in the Lab Environment,
 end to end, in the agreed order, and writes a dated run log.

   1. Maedeh   staging + integrated warehouse (dw)      PostgreSQL
   2. Samnang  graph layer + Report 2                    PostgreSQL
   3. Shubham  data fabric (governance) + Report 3       PostgreSQL
      (with the graph registered in the governance catalog)
   4. Raj      Delta lakehouse + Report 1                Python, DuckDB
   5. Samnang  graph copied into Neo4j for Report 2 visuals
   6. Somit    live change notifications on digital users  PostgreSQL
               + live fraud alerts (somit/live_lab: 4 rules in triggers)
   7. Dashboard Horizon_Dashboard.html generated from the database
               (generate_dashboard.py); live alerts via live_server.py

 REQUIREMENTS
   - Lab containers running (docker compose up -d in the lab folder).
   - This folder at <lab folder>\workspace\horizon, with docker-compose.yml in <lab folder>
   - The 9 CSV files in <lab folder>\workspace\horizon\data
   - Internet access the first time (installs Raj's 4 Python libraries
     into the lab's Python container).
   - Lab Compose service names: postgres and python. Container names may vary.

 HOW TO RUN (PowerShell, in the lab folder, e.g. C:\advanced-database-lab)
   powershell -NoProfile -ExecutionPolicy Bypass -File .\workspace\horizon\run_all.ps1

 OPTIONS
   -SkipRaj      do not run the lakehouse steps
   -SkipNeo4j    do not copy the graph into Neo4j
   -SkipStreaming do not set up Somit's change notifications
   -SkipDashboard do not generate Horizon_Dashboard.html
   -Database x   use database x instead of "lab"

 IMPORTANT
   The run starts with 00_reset_all.sql, which drops and rebuilds the
   five Horizon schemas (staging, dw, graph, governance, secure) from the
   CSV files. Other work in the lab database is not touched.
   The script stops at the first failing step and says which one.
=====================================================================
#>
param(
    [switch]$SkipRaj,
    [switch]$SkipNeo4j,
    [switch]$SkipStreaming,
    [switch]$SkipDashboard,
    [string]$Database = 'lab'
)

# Native tools (docker, psql) print notices on stderr; that is not an
# error. Failures are detected from each command's exit code instead.
$ErrorActionPreference = 'Continue'

$Here    = $PSScriptRoot
$Stamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$Log     = Join-Path $Here "run_log_$Stamp.txt"
# Resolve containers from the lab Compose project, not their machine-specific names.
# This script lives under <lab>/workspace/horizon.
$LabCompose = Join-Path (Split-Path (Split-Path $Here -Parent) -Parent) 'docker-compose.yml'
if (-not (Test-Path -LiteralPath $LabCompose)) {
    Write-Error "Lab Compose file missing: $LabCompose. Put the project under <lab>/workspace/horizon."
    exit 1
}
$Pg = ([string](& docker compose -f $LabCompose ps -q postgres 2>$null | Select-Object -First 1)).Trim()
$Py = ([string](& docker compose -f $LabCompose ps -q python 2>$null | Select-Object -First 1)).Trim()
if (-not $Pg -or -not $Py) {
    Write-Error "Lab PostgreSQL or Python service is not running. Start them with: docker compose -f '$LabCompose' up -d"
    exit 1
}
$SqlDir  = '/tmp/horizon_sql'           # paths inside the lab PostgreSQL container
$DataDir = '/tmp/horizon_data'
$Csvs    = @('core_customers.csv','core_accounts.csv','core_transactions.csv',
             'cards.csv','card_transactions.csv','digital_users.csv',
             'digital_events.csv','entity_mapping_reference.csv',
             'fraud_scenario_reference.csv')


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

# Print a timestamped line and append it to the run log.
function Write-Log([string]$Text) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $Log -Value $line
}

# Run one command, keep its output in the log, stop on a non-zero exit.
function Invoke-Step([string]$Name, [string[]]$Command) {
    Write-Log "START  $Name"
    $exe  = $Command[0]
    $rest = $Command[1..($Command.Length - 1)]
    $output = & $exe @rest 2>&1 | ForEach-Object { "$_" } | Out-String
    $code = $LASTEXITCODE
    if ($output.Trim()) {
        Write-Host $output
        Add-Content -Path $Log -Value $output
    }
    if ($code -ne 0) {
        Write-Log "FAILED $Name (exit code $code). Details are in $Log"
        exit 1
    }
    Write-Log "OK     $Name"
}

# Run one SQL file with psql inside the PostgreSQL container.
# ON_ERROR_STOP makes psql exit with an error code on the first error.
function Invoke-Sql([string]$Name, [string]$File) {
    Invoke-Step $Name @('docker','exec',$Pg,'psql','-U','student','-d',$Database,
                        '-v','ON_ERROR_STOP=1','-P','pager=off','-f',"$SqlDir/$File")
}


# ---------------------------------------------------------------------
# 0. Pre-flight checks
# ---------------------------------------------------------------------
Write-Log "Horizon prototype run started. Database: $Database. Log: $Log"

foreach ($c in @($Pg, $Py)) {
    $running = docker inspect --format '{{.State.Running}}' $c 2>$null
    if ($LASTEXITCODE -ne 0 -or $running -ne 'true') {
        Write-Log "FAILED lab container $c is not running. Run docker compose up -d in the lab folder."
        exit 1
    }
}

foreach ($f in $Csvs) {
    if (-not (Test-Path (Join-Path $Here "data\$f"))) {
        Write-Log "FAILED missing data\$f (put all 9 CSV files in $Here\data)"
        exit 1
    }
}

# The Python container sees the lab's workspace folder as /workspace.
docker exec $Py test -f /workspace/horizon/run_all.ps1 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Log "FAILED this folder must be <lab folder>\workspace\horizon so the Python container can see it."
    exit 1
}
Write-Log "OK     pre-flight checks"


# ---------------------------------------------------------------------
# 1. Copy CSVs and SQL into the PostgreSQL container
#    (PostgreSQL reads the CSVs with server-side COPY)
# ---------------------------------------------------------------------
Invoke-Step 'clear old copies'  @('docker','exec','-u','root',$Pg,'rm','-rf',$DataDir,$SqlDir)
Invoke-Step 'create SQL folder' @('docker','exec','-u','root',$Pg,'mkdir','-p',$SqlDir)
Invoke-Step 'copy CSV files'    @('docker','cp',(Join-Path $Here 'data'),"${Pg}:$DataDir")
Invoke-Step 'copy reset script' @('docker','cp',(Join-Path $Here '00_reset_all.sql'),"${Pg}:$SqlDir/00_reset_all.sql")
foreach ($owner in @('maedeh','samnang','shubham','somit')) {
    Invoke-Step "copy $owner SQL" @('docker','cp',(Join-Path $Here $owner),"${Pg}:$SqlDir/$owner")
}
Invoke-Step 'make files readable' @('docker','exec','-u','root',$Pg,'chmod','-R','a+rX',$DataDir,$SqlDir)


# ---------------------------------------------------------------------
# 2. PostgreSQL: warehouse, graph, governance (order matters)
# ---------------------------------------------------------------------
Invoke-Sql 'Reset Horizon schemas'                 '00_reset_all.sql'

Invoke-Sql 'Maedeh 01 create schemas'              'maedeh/01_create_schemas_lab.sql'
Invoke-Sql 'Maedeh 02 create staging tables'       'maedeh/02_create_staging_tables.sql'
Invoke-Sql 'Maedeh 02b import CSVs to staging'     'maedeh/02b_import_staging_lab.sql'
Invoke-Sql 'Maedeh 03 create warehouse tables'     'maedeh/03_create_warehouse_tables.sql'
Invoke-Sql 'Maedeh 04 load warehouse'              'maedeh/04_load_warehouse.sql'
Invoke-Sql 'Maedeh 05 validation checks'           'maedeh/05_validation_checks.sql'

Invoke-Sql 'Samnang 06 graph layer'                'samnang/06_graph_layer.sql'
Invoke-Sql 'Samnang 06b fraud scenario answer key' 'samnang/06b_import_fraud_scenarios.sql'
Invoke-Sql 'Samnang 07 Report 2 connected entities' 'samnang/07_report2_connected_entities.sql'

# Shubham's setup resets governance, so the graph is registered after it
# and before his governance cycle (which catalogs and checks it).
Invoke-Sql 'Shubham 06 governance setup'           'shubham/06_governance_setup.sql'
Invoke-Sql 'Samnang register graph in governance'  'samnang/register_graph_in_governance.sql'
Invoke-Sql 'Shubham 07 run governance cycle'       'shubham/07_run_governance.sql'
Invoke-Sql 'Shubham 08 Report 3 lineage and quality' 'shubham/08_report3_lineage_quality.sql'

# Somit: change notifications on staging.digital_users (tcn extension and
# trigger). His scripts run unchanged; they succeed every time because the
# reset above recreates staging without the key and trigger.
if (-not $SkipStreaming) {
    Invoke-Sql 'Somit 1 create tcn extension'       'somit/1._create_extension_tcn.sql'
    Invoke-Sql 'Somit 2 add primary key'            'somit/2._add_pk.sql'
    Invoke-Sql 'Somit 3 create notification trigger' 'somit/3._create_trigger.sql'
    # Live fraud alerts (lab version of Somit's Live Events rules). Optional:
    # runs only when somit\live_lab has been added to the project.
    if (Test-Path (Join-Path $Here 'somit\live_lab\01_live_setup.sql')) {
        Invoke-Sql 'Somit live alerts: triggers + 4 fraud rules' 'somit/live_lab/01_live_setup.sql'
    } else {
        Write-Log 'SKIP   Somit live alerts (somit\live_lab not found)'
    }
}


# ---------------------------------------------------------------------
# 3. Raj: Delta lakehouse and Report 1 (in the lab's Python container)
# ---------------------------------------------------------------------
if (-not $SkipRaj) {
    # Install Raj's pinned libraries only if they are missing.
    docker exec $Py python -c "import deltalake, pyarrow, duckdb, psycopg" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Step 'Raj install libraries' @('docker','exec',$Py,'pip','install','--quiet',
            'deltalake==1.2.1','pyarrow==21.0.0','duckdb==1.4.1','psycopg[binary]==3.2.10')
    }
    $RajScripts = '/workspace/horizon/raj/scripts'
    Invoke-Step 'Raj 02 export warehouse (read-only)' @('docker','exec','-e',
        "WAREHOUSE_DSN=postgresql://student:student@postgres:5432/$Database",
        $Py,'python',"$RajScripts/02_export_maedeh_warehouse.py")
    Invoke-Step 'Raj 03 build lakehouse'   @('docker','exec',$Py,'python',"$RajScripts/03_build_lakehouse.py",'--mode','warehouse')
    Invoke-Step 'Raj 04 Report 1'          @('docker','exec',$Py,'python',"$RajScripts/04_report_activity_trends.py",'--mode','warehouse')
    Invoke-Step 'Raj 05 verify results'    @('docker','exec',$Py,'python',"$RajScripts/05_verify_results.py",'--mode','warehouse')
    Invoke-Step 'Raj 06 Delta history'     @('docker','exec',$Py,'python',"$RajScripts/06_delta_history.py",'--mode','warehouse')
}


# ---------------------------------------------------------------------
# 4. Samnang: copy the graph into Neo4j
# ---------------------------------------------------------------------
if (-not $SkipNeo4j) {
    Invoke-Step 'Samnang 08 load graph into Neo4j' @('docker','exec','-e',"PG_DBNAME=$Database",
        $Py,'python','/workspace/horizon/samnang/08_load_graph_to_neo4j.py')
}


# ---------------------------------------------------------------------
# 5. Presentation dashboard, generated from the database
#    Runs in the lab Python container (psycopg was installed for Raj).
#    If the database cannot be read, the dashboard keeps the team-run figures.
# ---------------------------------------------------------------------
if (-not $SkipDashboard) {
    if ((Test-Path (Join-Path $Here 'generate_dashboard.py')) -and
        (Test-Path (Join-Path $Here 'somit\live_lab\dashboard.html'))) {
        Invoke-Step 'Generate Horizon_Dashboard.html' @('docker','exec','-e',"PGDATABASE=$Database",'-e','PGHOST=postgres',
            $Py,'python','/workspace/horizon/generate_dashboard.py')
    } else {
        Write-Log 'SKIP   dashboard (generate_dashboard.py or somit\live_lab\dashboard.html not found)'
    }
}


# ---------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------
Write-Log 'ALL STEPS COMPLETED (streaming trigger installed; live listener/feed run separately)'
Write-Log "Report 1 (Raj):    $Here\raj\output\warehouse\reports\Report_1_Activity_Brief.html"
Write-Log 'Report 2 (Samnang): CloudBeaver graph schema views; Neo4j Browser http://localhost:7474 (queries in samnang\09_report2_neo4j.cypher)'
Write-Log 'Report 3 (Shubham): CloudBeaver governance schema views (queries R3.1-R3.15 in shubham\08_report3_lineage_quality.sql)'
if (-not $SkipDashboard -and (Test-Path (Join-Path $Here 'Horizon_Dashboard.html'))) {
    Write-Log "Dashboard: $Here\Horizon_Dashboard.html"
    Write-Log "Live fraud alerts in the dashboard: python $Here\somit\live_lab\live_server.py   then open http://localhost:8765"
}
if (-not $SkipStreaming) {
    Write-Log "Live notifications (Somit): window 1: docker exec -it $Py python /workspace/horizon/somit/listen_lab.py"
    Write-Log "  window 2: docker exec $Pg psql -U student -d $Database -f /tmp/horizon_sql/somit/insert_test_live_feed.sql (then update_..., then delete_...)"
}
Write-Log "Full output of every step: $Log"
