import csv
import hashlib
import json
from datetime import datetime,timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
TABLES=['dim_customer','dim_account','dim_card','dim_digital_user','fact_core_transaction','fact_card_transaction','fact_digital_event']
COUNTS=dict(zip(TABLES,[5000,7500,5000,4000,9500,9500,9500]))
SOURCE_FILES={
 'core_customers':'Core banking/core_customers.csv',
 'core_accounts':'Core banking/core_accounts.csv',
 'core_transactions':'Core banking/core_transactions.csv',
 'cards':'Card processing/cards.csv',
 'card_transactions':'Card processing/card_transactions.csv',
 'digital_users':'Digital banking/digital_users.csv',
 'digital_events':'Digital banking/digital_events.csv',
 'mapping':'entity_mapping_reference.csv',
 'scenarios':'fraud_scenario_reference.csv'}

def utcnow(): return datetime.now(timezone.utc).isoformat()
def dump(path,data):
 path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
 temp=path.with_suffix(path.suffix+'.tmp');temp.write_text(json.dumps(data,indent=2,default=str),encoding='utf-8');temp.replace(path)
def load(path): return json.loads(Path(path).read_text(encoding='utf-8'))
def read_csv(path):
 with Path(path).open(encoding='utf-8-sig',newline='') as f: return list(csv.DictReader(f))
def write_csv(path,rows,columns):
 path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
 with path.open('w',encoding='utf-8',newline='') as f:
  w=csv.DictWriter(f,fieldnames=columns,extrasaction='ignore');w.writeheader();w.writerows(rows)
def location(mode):
 return ROOT/'data'/mode,ROOT/'output'/mode
def fingerprint(folder):
 h=hashlib.sha256()
 for name in TABLES:
  h.update(name.encode());h.update((folder/(name+'.csv')).read_bytes())
 return h.hexdigest()
def read_input(mode):
 folder,out=location(mode)
 meta=load(folder/'handoff.json')
 if meta['mode']!=mode: raise ValueError('Input provenance does not match chosen mode')
 return {name:read_csv(folder/(name+'.csv')) for name in TABLES},meta,folder,out
