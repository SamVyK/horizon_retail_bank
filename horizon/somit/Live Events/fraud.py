import json
import asyncio
import psycopg2
from datetime import datetime
from aiokafka import AIOKafkaConsumer

# --- Config ---
KAFKA_BROKER = "localhost:9092"
TOPICS = [
    "horizon.staging.card_transactions",
    "horizon.staging.digital_events",
    "horizon.staging.core_transactions",
]

PG = {
    "host": "localhost",
    "port": 5432,
    "dbname": "lab",
    "user": "student",
    "password": "student",   # <-- change this
}

# --- In-memory state ---
# Each rule gets its own dict so shapes never collide.
overseas_velocity     = {}   # {card_id: [{"epoch","amount","country"}]}
burst_velocity        = {}   # {card_id: [{"epoch","amount"}]}
device_users          = {}   # {device_id: set(digital_user_id)}
beneficiary_senders   = {}   # {beneficiary_reference: set(digital_user_id)}


def get_connection():
    return psycopg2.connect(**PG)


def write_fraud_event(event_type, customer_key, source_id, severity, details):
    """Insert a fraud alert into staging.fraud_events."""
    conn = None
    try:
        conn = get_connection()
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO staging.fraud_events
                (event_type, customer_key, source_id, severity, details)
                VALUES (%s, %s, %s, %s, %s)
                """,
                (event_type, customer_key, source_id, severity,
                 json.dumps(details, default=str)),
            )
        conn.commit()
        print(f"   ✅ Wrote alert: {event_type} / {severity}")
    except Exception as e:
        print(f"   ❌ Failed to write alert: {e}")
    finally:
        if conn:
            conn.close()


def _parse_ts(ts):
    """Return a POSIX timestamp from an ISO-8601 string, or None."""
    if not ts:
        return None
    try:
        return datetime.fromisoformat(str(ts).replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError, AttributeError):
        return None


# ---------------------------------------------------------------------------
# Rule 1 — Card Fraud: 3+ overseas, card-not-present transactions in 60 min
# ---------------------------------------------------------------------------
def check_card_fraud(after):
    if not isinstance(after, dict):
        return

    card_id = after.get("card_id")
    if not card_id:
        return

    ts        = after.get("transaction_timestamp")
    country   = after.get("transaction_country")
    amount    = after.get("transaction_amount")
    intl      = after.get("domestic_international")
    present   = after.get("card_present_flag")

    print(f"   check_card_fraud: card={card_id} intl={intl} present={present} ts={ts}")

    if intl != "International" or present == "TRUE":
        return

    ts_epoch = _parse_ts(ts)
    if ts_epoch is None:
        print(f"   check_card_fraud: could not parse ts={ts!r}")
        return

    overseas_velocity.setdefault(card_id, []).append({
        "epoch": ts_epoch, "amount": amount, "country": country,
    })

    cutoff = ts_epoch - 3600
    overseas_velocity[card_id] = [
        t for t in overseas_velocity[card_id] if t["epoch"] > cutoff
    ]

    count = len(overseas_velocity[card_id])
    print(f"   overseas tx in last 60 min for {card_id}: {count}")

    if count >= 3:
        write_fraud_event(
            event_type="CARD_FRAUD_OVERSEAS_CLUSTER",
            customer_key=card_id,
            source_id=after.get("card_transaction_id"),
            severity="HIGH",
            details={
                "card_id": card_id,
                "tx_count_60min": count,
                "countries": list({
                    t["country"] for t in overseas_velocity[card_id]
                    if t.get("country")
                }),
            },
        )


# ---------------------------------------------------------------------------
# Rule 2 — Rapid Burst: 5+ approved transactions in 10 min on the same card
# ---------------------------------------------------------------------------
def check_rapid_burst(after):
    if not isinstance(after, dict):
        return

    card_id = after.get("card_id")
    status  = after.get("transaction_status")
    if not card_id or status != "APPROVED":
        return

    ts       = after.get("transaction_timestamp")
    ts_epoch = _parse_ts(ts)
    if ts_epoch is None:
        return

    burst_velocity.setdefault(card_id, []).append({
        "epoch": ts_epoch, "amount": after.get("transaction_amount"),
    })

    cutoff = ts_epoch - 600
    recent = [t for t in burst_velocity[card_id] if t["epoch"] > cutoff]

    print(f"   burst check: card={card_id} approved tx in last 10 min: {len(recent)}")

    if len(recent) >= 5:
        write_fraud_event(
            event_type="RAPID_TRANSACTION_BURST",
            customer_key=card_id,
            source_id=after.get("card_transaction_id"),
            severity="HIGH",
            details={
                "card_id": card_id,
                "tx_count_10min": len(recent),
                "total_amount": sum(
                    float(t["amount"] or 0) for t in recent
                ),
            },
        )


# ---------------------------------------------------------------------------
# Rule 3 — Shared Device Ring: same device_id, >2 distinct digital_user_id
# ---------------------------------------------------------------------------
def check_shared_device(after):
    if not isinstance(after, dict):
        return

    device_id    = after.get("device_id")
    digital_user = after.get("digital_user_id")
    if not device_id or not digital_user:
        return

    device_users.setdefault(device_id, set()).add(digital_user)
    count = len(device_users[device_id])

    print(f"   shared device check: device={device_id} distinct_users={count}")

    if count > 2:
        write_fraud_event(
            event_type="SHARED_DEVICE_RING",
            customer_key=digital_user,
            source_id=device_id,
            severity="HIGH",
            details={
                "device_id": device_id,
                "distinct_users": count,
                "users": list(device_users[device_id]),
            },
        )


# ---------------------------------------------------------------------------
# Rule 4 — Suspicious Beneficiary: >5 distinct senders to the same beneficiary
# ---------------------------------------------------------------------------
def check_suspicious_beneficiary(after):
    if not isinstance(after, dict):
        return

    beneficiary  = after.get("beneficiary_reference")
    digital_user = after.get("digital_user_id")
    event_type   = after.get("event_type")

    if not beneficiary or not digital_user:
        return

    # Only count transfer-style events
    if event_type and event_type.lower() not in ("transfer", "beneficiaryadd", "payment"):
        return

    beneficiary_senders.setdefault(beneficiary, set()).add(digital_user)
    count = len(beneficiary_senders[beneficiary])

    print(f"   beneficiary check: ben={beneficiary} distinct_senders={count}")

    if count > 5:
        write_fraud_event(
            event_type="SUSPICIOUS_BENEFICIARY",
            customer_key=digital_user,
            source_id=beneficiary,
            severity="HIGH",
            details={
                "beneficiary_reference": beneficiary,
                "distinct_senders": count,
                "senders": sorted(beneficiary_senders[beneficiary]),
            },
        )


# ---------------------------------------------------------------------------
# Consumer loop
# ---------------------------------------------------------------------------
async def consume():
    consumer = AIOKafkaConsumer(
        *TOPICS,
        bootstrap_servers=KAFKA_BROKER,
        group_id="fraud-detector",
        auto_offset_reset="latest",
        value_deserializer=lambda v: json.loads(v.decode("utf-8")) if v else None,
    )
    await consumer.start()

    print(f"[{datetime.now():%H:%M:%S}] Consumer started. Subscribed to:")
    for t in TOPICS:
        print(f"   - {t}")
    print("Waiting for events... (Ctrl+C to stop)\n")

    try:
        async for msg in consumer:
            topic = msg.topic
            event = msg.value

            if event is None:
                continue

            print(f"[{datetime.now():%H:%M:%S}] ← {topic}")

            payload = event.get("payload", event) if isinstance(event, dict) else {}
            after   = payload.get("after") if isinstance(payload, dict) else None
            op      = payload.get("op") if isinstance(payload, dict) else None

            print(f"   op={op}  after={'populated' if after else 'null'}")

            if after is None:
                continue

            try:
                if "card_transactions" in topic:
                    check_card_fraud(after)
                    check_rapid_burst(after)
                elif "digital_events" in topic:
                    check_shared_device(after)
                    check_suspicious_beneficiary(after)
                elif "core_transactions" in topic:
                    pass
            except Exception as e:
                print(f"   ⚠ rule error on {topic}: {type(e).__name__}: {e}")

            print()

    except asyncio.CancelledError:
        print("\nConsumer cancelled.")
    finally:
        await consumer.stop()
        print("Consumer stopped.")


if __name__ == "__main__":
    try:
        asyncio.run(consume())
    except KeyboardInterrupt:
        print("\n[Ctrl+C] Consumer stopped by user.")