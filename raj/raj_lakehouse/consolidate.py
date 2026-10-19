import hashlib,json
from .common import ROOT,dump

def consolidate():
 entries=[]
 for root,owner in [(ROOT/'sql','Raj'),(ROOT/'team_sql','Owner to be confirmed in team_sql/order.json')]:
  for path in sorted(root.rglob('*')):
   if path.suffix.lower() not in ['.sql','.cypher'] or not path.is_file():continue
   txt=path.read_text(encoding='utf-8')
   actual_owner='Maedeh' if path.is_relative_to(ROOT/'team_sql/Maedeh') else owner
   engine='Neo4j Cypher' if path.suffix=='.cypher' else 'PostgreSQL' if actual_owner=='Maedeh' or 'warehouse_export' in str(path) else 'DuckDB' if 'report_1' in str(path) else 'Confirm with script owner'
   entries.append({'file':str(path.relative_to(ROOT)),'owner':actual_owner,'engine':engine,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'execution_status':'Reported passing by Maedeh on her local PostgreSQL; not independently executed here' if actual_owner=='Maedeh' else 'Not asserted by consolidation; retain actual run evidence separately'})
 out=ROOT/'consolidated';out.mkdir(exist_ok=True)
 order=json.loads((ROOT/'team_sql/order.json').read_text(encoding='utf-8'))
 dump(out/'script_inventory.json',{'entries':entries,'warehouse_execution_order':order,'pending':['Divaakar: source DDL and synthetic data loading','Samnang: graph import and Report 2 queries','Shubham: fabric and Report 3 scripts','Somit: streaming, tests and Report 4 scripts','Raj: capture live warehouse handoff and downstream verification'],'note':'Inventory preserves separate engines and copied authorship. Maedeh reported a passing local run; this inventory is not independent run evidence.'})
 # Only homogeneous read-only queries are bundled together; report SQL has different parameters.
 exports=sorted((ROOT/'sql/warehouse_export').glob('*.sql'))
 (out/'warehouse_export_queries.sql').write_text('\n\n'.join('-- '+p.name+'\n'+p.read_text() for p in exports),encoding='utf-8')
 print('Consolidated inventory, Maedeh run order and PostgreSQL export query bundle created. Other team SQL remains required.')
