"""Bronze preserves seven warehouse tables; silver validates joins; gold serves analytics."""
from collections import Counter
from datetime import datetime
from decimal import Decimal,InvalidOperation
import pyarrow as pa
from deltalake import DeltaTable,write_deltalake
from .common import read_input,dump,fingerprint,utcnow

ACTIVITY_SCHEMA=pa.schema([
 ('activity_id',pa.string()),('source_system',pa.string()),('source_record_id',pa.string()),
 ('enterprise_customer_key',pa.string()),('source_entity_id',pa.string()),
 ('event_timestamp',pa.timestamp('us')),('activity_type',pa.string()),('activity_status',pa.string()),
 ('amount',pa.decimal128(18,2)),('currency',pa.string()),('direction',pa.string()),
 ('synthetic_fraud_label',pa.bool_()),('outside_reporting_window',pa.bool_())])

def index(rows,key):
 if not rows: raise ValueError('Empty dimension '+key)
 values=[r.get(key,'') for r in rows]
 if '' in values or len(set(values))!=len(values): raise ValueError('Blank/duplicate dimension key '+key)
 return {r[key]:r for r in rows}

def normalise(tables):
 customers=index(tables['dim_customer'],'customer_key')
 index(tables['dim_customer'],'enterprise_customer_key')
 indexes={};issues=[];accepted=[]
 for name,key,natural in [('dim_account','account_key','core_account_id'),('dim_card','card_key','card_id'),('dim_digital_user','digital_user_key','digital_user_id')]:
  indexes[name]=index(tables[name],key);index(tables[name],natural)
  if any(r['customer_key'] not in customers for r in tables[name]): raise ValueError(name+' has unknown customer_key')
 specs=[('CORE','fact_core_transaction','dim_account','account_key','core_account_id','core_transaction_id','transaction_timestamp'),
        ('CARD','fact_card_transaction','dim_card','card_key','card_id','card_transaction_id','transaction_timestamp'),
        ('DIGITAL','fact_digital_event','dim_digital_user','digital_user_key','digital_user_id','digital_event_id','event_timestamp')]
 for system,table,dim,fk,natural,pk,time_col in specs:
  rows=tables[table];duplicates=Counter(r.get(pk,'') for r in rows)
  for r in rows:
   rid=r.get(pk,'');reasons=[]
   if not rid or duplicates[rid]>1: reasons.append('missing_or_duplicate_source_id')
   entity=indexes[dim].get(r.get(fk,''))
   if entity is None: reasons.append('unmatched_dimension_key')
   try:
    stamp=datetime.fromisoformat(r[time_col].replace('Z','+00:00'))
    if stamp.tzinfo: raise ValueError('Timezone differs from unzoned team-dataset contract')
   except (ValueError,KeyError): reasons.append('invalid_or_zoned_timestamp');stamp=None
   text=r.get('transaction_amount','')
   try:
    amount=Decimal(text) if text else None
    if amount is None and system!='DIGITAL': raise ValueError()
    if amount is not None and (not amount.is_finite() or amount<0 or amount!=amount.quantize(Decimal('.01')) or amount>=Decimal('10000000000000000')): raise ValueError()
   except (InvalidOperation,ValueError): reasons.append('invalid_amount');amount=None
   label=r.get('fraud_indicator','').upper()
   if label not in ['TRUE','FALSE','T','F']: reasons.append('invalid_fraud_label')
   kind=r.get('event_type' if system=='DIGITAL' else 'transaction_type','')
   if not kind: reasons.append('missing_activity_type')
   currency=r.get('currency','') if system!='DIGITAL' else ('UNSPECIFIED' if amount is not None else None)
   if system!='DIGITAL' and (len(currency)!=3 or not currency.isalpha() or currency!=currency.upper()): reasons.append('invalid_currency')
   status=r.get('login_status','') if system=='DIGITAL' and kind=='Login' else r.get('transaction_status','')
   if not status: reasons.append('missing_status')
   if system=='DIGITAL' and kind in ['Fund Transfer','BPAY Payment'] and amount is None: reasons.append('missing_digital_payment_amount')
   if reasons:
    issues.append({'severity':'REJECT','source_system':system,'source_record_id':rid,'reason':';'.join(reasons)});continue
   customer=customers[entity['customer_key']]
   outside=not ('2024-01-01'<=stamp.date().isoformat()<='2026-09-30')
   if outside: issues.append({'severity':'WARNING','source_system':system,'source_record_id':rid,'reason':'outside_default_reporting_window; retained'})
   if system=='DIGITAL' and amount is not None: issues.append({'severity':'WARNING','source_system':system,'source_record_id':rid,'reason':'digital_currency_not_supplied; no currency inferred'})
   accepted.append({'activity_id':system+':'+rid,'source_system':system,'source_record_id':rid,
    'enterprise_customer_key':customer['enterprise_customer_key'],'source_entity_id':entity[natural],
    'event_timestamp':stamp,'activity_type':kind,'activity_status':status,'amount':amount,'currency':currency,
    'direction':r.get('debit_credit_indicator') or None,'synthetic_fraud_label':label in ['TRUE','T'],
    'outside_reporting_window':outside})
 return accepted,issues

def build(mode):
 tables,meta,folder,out=read_input(mode);lake=out/'lakehouse';versions={}
 def write(name,table):
  path=lake/name;write_deltalake(str(path),table,mode='overwrite')
  versions[name]={'version':DeltaTable(str(path)).version(),'rows':table.num_rows}
 # Validate all required relationships before changing the successful published manifest.
 activity,issues=normalise(tables)
 for name,rows in tables.items():
  if not rows: raise ValueError('Empty warehouse table '+name)
  schema=pa.schema([(k,pa.string()) for k in rows[0]])
  write('bronze/'+name,pa.Table.from_pylist(rows,schema=schema))
 for name,key,natural in [('dim_customer','customer_key','enterprise_customer_key'),('dim_account','account_key','core_account_id'),('dim_card','card_key','card_id'),('dim_digital_user','digital_user_key','digital_user_id')]:
  fields=[key,natural]+([] if name=='dim_customer' else ['customer_key'])
  write('silver/'+name,pa.Table.from_pylist([{k:r[k] for k in fields} for r in tables[name]],schema=pa.schema([(k,pa.string()) for k in fields])))
 table=pa.Table.from_pylist(activity,schema=ACTIVITY_SCHEMA)
 write('silver/activity_event',table)
 write('gold/fact_activity',table)
 fields=['enterprise_customer_key','customer_segment','risk_category','state']
 write('gold/dim_customer',pa.Table.from_pylist([{k:r[k] for k in fields} for r in tables['dim_customer']],schema=pa.schema([(k,pa.string()) for k in fields])))
 issue_schema=pa.schema([(k,pa.string()) for k in ['severity','source_system','source_record_id','reason']])
 write('audit/quality_issues',pa.Table.from_pylist(issues,schema=issue_schema))
 profile={'source_fact_rows':sum(len(tables[n]) for n in ['fact_core_transaction','fact_card_transaction','fact_digital_event']),
  'accepted':len(activity),'rejected':sum(r['severity']=='REJECT' for r in issues),
  'warnings':dict(Counter(r['reason'] for r in issues if r['severity']=='WARNING')),
  'by_source':dict(Counter(r['source_system'] for r in activity))}
 dump(out/'build_summary.json',profile)
 dump(lake/'manifest.json',{'mode':mode,'input_hash':fingerprint(folder),'created_at':utcnow(),'origin':meta['origin'],'tables':versions,'timestamp_policy':'Source wall-clock timestamps preserved. No timezone supplied; no UTC claim.'})
 print(profile)
