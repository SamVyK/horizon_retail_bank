import streamlit as st
import pandas as pd
import psycopg2
from datetime import datetime

st.set_page_config(page_title="Fraud Monitor", page_icon="🚨", layout="wide")

@st.cache_resource
def get_connection():
    return psycopg2.connect(
        host="localhost",
        port=5432,
        dbname="lab",
        user="student",
        password="student",   # <-- change this
    )

st.title("🚨 Live Fraud Monitor")

@st.fragment(run_every=2)
def live_feed():
    try:
        conn = get_connection()
        df = pd.read_sql("""
            SELECT detected_at, event_type, severity, customer_key, source_id
            FROM staging.fraud_events
            ORDER BY detected_at DESC
            LIMIT 50;
        """, conn)
    except Exception as e:
        st.error(f"Query failed: {e}")
        return

    if df.empty:
        st.info("Waiting for fraud events...")
        return

    st.caption(f"Updated {datetime.now():%H:%M:%S} · {len(df)} alerts")
    st.dataframe(df, use_container_width=True, height=600)

live_feed()