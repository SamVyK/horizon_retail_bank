"""Offline source-CSV preview and read-only export of the actual dw schema are separate routes."""
import csv,io,os,tempfile
from zipfile import ZipFile
from collections import Counter
from .common import ROOT,TABLES,SOURCE_FILES,location,dump,write_csv,utcnow,fingerprint

def unique(rows,key):
 values=[r[key] for r in rows]
 if '' in values or len(values)!=len(set(values)): raise ValueError('Invalid or duplicate '+key)
 return {r[key]:r for r in rows}

def preview(zip_path):
 with ZipFile(zip_path) as z:
  raw={k:list(csv.DictReader(io.StringIO(z.read('Dataset/'+v).decode('utf-8-sig')))) for k,v in SOURCE_FILES.items()}
 # This explicit mapping reference is supplied ground truth. It does NOT demonstrate entity resolution.
 core_map=unique(raw['mapping'],'core_customer_id')
 for key in ['enterprise_customer_key','card_customer_id','digital_user_id']:
  values=[r[key] for r in raw['mapping'] if r[key]]
  if len(values)!=len(set(values)): raise ValueError('Ambiguous mapping '+key)
 customer_key={r['core_customer_id']:str(i+1) for i,r in enumerate(raw['core_customers'])}
 card_map={r['card_customer_id']:customer_key[r['core_customer_id']] for r in raw['mapping'] if r['card_customer_id']}
 digital_map={r['digital_user_id']:customer_key[r['core_customer_id']] for r in raw['mapping'] if r['digital_user_id']}
 tables={}
 tables['dim_customer']=[{**r,**{k:v for k,v in core_map[r['core_customer_id']].items() if k!='primary_core_account_id'},'customer_key':customer_key[r['core_customer_id']]} for r in raw['core_customers']]
 tables['dim_account']=[{**r,'account_key':str(i+1),'customer_key':customer_key[r['core_customer_id']]} for i,r in enumerate(raw['core_accounts'])]
 tables['dim_card']=[{**r,'card_key':str(i+1),'customer_key':card_map[r['card_customer_id']]} for i,r in enumerate(raw['cards'])]
 tables['dim_digital_user']=[{**r,'digital_user_key':str(i+1),'customer_key':digital_map[r['digital_user_id']]} for i,r in enumerate(raw['digital_users'])]
 for fact,source,dim,natural,fk,pk in [
  ('fact_core_transaction','core_transactions','dim_account','core_account_id','account_key','core_transaction_key'),
  ('fact_card_transaction','card_transactions','dim_card','card_id','card_key','card_transaction_key'),
  ('fact_digital_event','digital_events','dim_digital_user','digital_user_id','digital_user_key','digital_event_key')]:
  index=unique(tables[dim],natural)
  tables[fact]=[{**r,fk:index[r[natural]][fk],pk:str(i+1)} for i,r in enumerate(raw[source])]
 folder,out=location('dataset-preview');folder.mkdir(parents=True,exist_ok=True)
 for name,rows in tables.items(): write_csv(folder/(name+'.csv'),rows,list(rows[0]))
 profile={name:{'rows':len(rows),'columns':list(rows[0])} for name,rows in raw.items()}
 dump(out/'dataset_profile.json',profile)
 dump(folder/'handoff.json',{'mode':'dataset-preview','created_at':utcnow(),'origin':str(zip_path),'identity_method':'supplied entity_mapping_reference.csv; surrogate keys assigned only for offline preview','warning':'This is not an export of Maedeh\'s running warehouse.'})
 print('Prepared DATASET PREVIEW; source rows preserved; no warehouse database was created.')

def export():
 import psycopg
 dsn=os.environ.get('WAREHOUSE_DSN')
 if not dsn: raise ValueError('Set WAREHOUSE_DSN, or get the seven warehouse CSV exports from Maedeh.')
 folder,out=location('warehouse');folder.parent.mkdir(parents=True,exist_ok=True)
 with tempfile.TemporaryDirectory(dir=folder.parent) as tmp:
  from pathlib import Path
  with psycopg.connect(dsn) as db:
   db.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY')
   actual_db=db.execute('SELECT current_database()').fetchone()[0]
   missing=[name for name in TABLES if db.execute('SELECT to_regclass(%s)',(f'dw.{name}',)).fetchone()[0] is None]
   if missing: raise ValueError(f'Database {actual_db!r} is missing required dw tables: {", ".join(missing)}. No tables exported.')
   for name in TABLES:
    query=(ROOT/'sql/warehouse_export'/(name+'.sql')).read_text()
    cur=db.execute(query);cols=[c.name for c in cur.description]
    write_csv(Path(tmp)/(name+'.csv'),[dict(zip(cols,r)) for r in cur],cols)
  folder.mkdir(parents=True,exist_ok=True)
  for name in TABLES: (Path(tmp)/(name+'.csv')).replace(folder/(name+'.csv'))
 dump(folder/'handoff.json',{'mode':'warehouse','created_at':utcnow(),'database':actual_db,'origin':f'PostgreSQL {actual_db} dw schema via read-only repeatable-read export'})
 print(f'Exported seven dw tables from {actual_db}; the source database was not modified.')

def register_csv():
 folder,out=location('warehouse')
 for name in TABLES:
  if not (folder/(name+'.csv')).exists(): raise ValueError('Missing export: '+name+'.csv')
 dump(folder/'handoff.json',{'mode':'warehouse','created_at':utcnow(),'origin':'User-supplied CSV export of the seven dw tables; exporter must confirm common snapshot'})
 print('CSV handoff registered. Build validates keys and relationships next.')
