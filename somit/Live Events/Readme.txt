Prerequisites
Docker Desktop (with WSL2 backend on Windows)
python -m pip install psycopg2-binary aiokafka streamlit pandas

Python 3.9+ (tested on 3.14)

pgAdmin (or any PostgreSQL client)

PowerShell or Git Bash

curl.exe (bundled with Windows 10+)
Python packages
powershell
python -m pip install aiokafka psycopg2-binary streamlit pandas

Horizon/somit/Live Event
├── connector.json              # Debezium connector config
├── fraud_rules.py              # Streaming consumer + rules
├── dashboard.py                # Streamlit dashboard
├── listen.py                   # (optional) tcn listener
└── README.md

Configure docker-compose file to Write ahead log to logical which allows the debezium user to read the changes in the table.
services:
  postgres:
    image: postgres:15
    command:
      - "postgres"
      - "-c"
      - "wal_level=logical"
      - "-c"
      - "max_replication_slots=4"
      - "-c"
      - "max_wal_senders=4"
    environment:
	POSTGRES_USER: student
      POSTGRES_PASSWORD: student
      POSTGRES_DB: lab
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql

  pgadmin:
    image: dpage/pgadmin4
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@example.com
      PGADMIN_DEFAULT_PASSWORD: admin
    ports:
      - "5050:80"

  redpanda:
    image: docker.redpanda.com/redpandadata/redpanda:v26.2.4
    command:
      - redpanda start
      - --smp 1
      - --overprovisioned
      - --node-id 0
      - --kafka-addr PLAINTEXT://0.0.0.0:29092,OUTSIDE://0.0.0.0:9092
      - --advertise-kafka-addr PLAINTEXT://redpanda:29092,OUTSIDE://localhost:9092
    ports:
      - "9092:9092"

  debezium:
    image: quay.io/debezium/connect:2.7
    depends_on:
      - redpanda
      - postgres
    environment:
      BOOTSTRAP_SERVERS: redpanda:29092
      GROUP_ID: 1
      CONFIG_STORAGE_TOPIC: connect_configs
      OFFSET_STORAGE_TOPIC: connect_offsets
      STATUS_STORAGE_TOPIC: connect_statuses
    ports:
      - "8083:8083"

volumes:
  pgdata:

// Please fix the indentation issue in postgres_user above.

Start the stack docker compose up -d

Prepare SQL and run 1-4 on pgadmin cloudbeaver

Register the Debezium connector
curl.exe -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d "@connector.json"
curl.exe http://localhost:8083/connectors/horizon-digital-connector/status --verify the connection
verify topics were created 

docker compose exec redpanda rpk topic list
run python fraud.py
python -m streamlit run dashboard.py