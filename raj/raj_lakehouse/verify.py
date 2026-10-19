from collections import defaultdict,Counter
from decimal import Decimal
from deltalake import DeltaTable
from .common import read_input,load,dump,fingerprint

def verify(mode):
 tables,meta,folder,out=read_input(mode);lake=out/'lakehouse'
 gold=DeltaTable(str(lake/'gold/fact_activity')).to_pyarrow_table().to_pylist()
 audit=DeltaTable(str(lake/'audit/quality_issues')).to_pyarrow_table().to_pylist()
 rejected={(r['source_system'],r['source_record_id']) for r in audit if r['severity']=='REJECT'}
 checks=[];totals=[]
 def check(name,ok,detail=''):checks.append({'check':name,'passed':bool(ok),'detail':detail})
 check('Input snapshot matches completed build',load(lake/'manifest.json')['input_hash']==fingerprint(folder))
 check('Gold activity IDs are unique',len(gold)==len({r['activity_id'] for r in gold}))
 for system,table,pk in [('CORE','fact_core_transaction','core_transaction_id'),('CARD','fact_card_transaction','card_transaction_id'),('DIGITAL','fact_digital_event','digital_event_id')]:
  rows=tables[table];expected=[r for r in rows if (system,r[pk]) not in rejected];actual=[r for r in gold if r['source_system']==system]
  check(system+' accepted record IDs match',sorted(r[pk] for r in expected)==sorted(r['source_record_id'] for r in actual))
  check(system+' source rows accounted for',len(actual)+sum((system,r[pk]) in rejected for r in rows)==len(rows))
  # Independent Decimal sums directly from input; no reuse of the lakehouse normalisation function.
  source=defaultdict(lambda:Decimal('0'));target=defaultdict(lambda:Decimal('0'))
  for r in expected:
   if r.get('transaction_amount','')!='':source[r.get('currency') or 'UNSPECIFIED']+=Decimal(r['transaction_amount'])
  for r in actual:
   if r['amount'] is not None:target[r['currency']]+=r['amount']
  check(system+' monetary sums reconcile by currency',dict(source)==dict(target))
  check(system+' synthetic label count preserved',sum(r.get('fraud_indicator','').upper() in ['TRUE','T'] for r in expected)==sum(r['synthetic_fraud_label'] for r in actual))
  for currency,value in sorted(source.items()):totals.append({'source':system,'currency':currency,'input_total':str(value),'gold_total':str(target[currency]),'difference':str(value-target[currency])})
 monthly=DeltaTable(str(lake/'gold/monthly_activity')).to_pyarrow_table().to_pylist()
 check('Monthly all-history counts reconcile to gold',sum(r['event_count'] for r in monthly)==len(gold))
 check('Digital missing currency not silently assigned AUD',all(r['currency']=='UNSPECIFIED' for r in gold if r['source_system']=='DIGITAL' and r['amount'] is not None))
 result={'mode':mode,'passed':all(r['passed'] for r in checks),'checks':checks,'monetary_reconciliation':totals,'input_origin':meta['origin'],'scope':'Seven-table handoff to lakehouse and Report 1; no claim to test source-to-warehouse ETL or other workstreams.'}
 dump(out/'verification.json',result)
 for r in checks: print(('PASS ' if r['passed'] else 'FAIL ')+r['check'])
 if not result['passed']:raise SystemExit(1)

def history(mode):
 _,_,_,out=read_input(mode);path=out/'lakehouse/gold/fact_activity';t=DeltaTable(str(path));v=t.version()
 result={'mode':mode,'current_version':v,'current_rows':t.to_pyarrow_table().num_rows,'history':t.history()}
 if v>0:result['previous_version_rows']=DeltaTable(str(path),version=v-1).to_pyarrow_table().num_rows
 dump(out/'delta_history.json',result);print(result)
