import html,json
from datetime import date,datetime
from decimal import Decimal
from collections import defaultdict
import duckdb
from deltalake import DeltaTable,write_deltalake
from .common import ROOT,location,load,dump,write_csv,fingerprint

def table_html(rows,limit=100):
 if not rows:return '<p>No records</p>'
 cols=list(rows[0]);head='<tr>'+''.join('<th>'+html.escape(k.replace('_',' '))+'</th>' for k in cols)+'</tr>'
 return '<div class="scroll"><table><thead>'+head+'</thead><tbody>'+''.join('<tr>'+''.join('<td>'+html.escape('' if r[k] is None else str(r[k]))+'</td>' for k in cols)+'</tr>' for r in rows[:limit])+'</tbody></table></div>'

def chart(monthly,start,end):
 # Zero-fill calendar months, including months with no rows, for an honest time axis.
 start_date=date.fromisoformat(start);end_date=date.fromisoformat(end)
 months=[];y,m=start_date.year,start_date.month
 while (y,m)<=(end_date.year,end_date.month):
  months.append(f'{y:04}-{m:02}');m+=1
  if m==13:y+=1;m=1
 values=defaultdict(int)
 for r in monthly:values[(r['activity_month'],r['source_system'])]+=r['event_count']
 maxv=max([values[(mo,s)] for mo in months for s in ['CORE','CARD','DIGITAL']]+[1])
 w,h=1100,360;left,top,bottom=65,48,65;plot_h=h-top-bottom
 parts=[f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="Monthly recorded activity counts">']
 for i in range(5):
  value=round(maxv*i/4); yy=top+plot_h*(1-i/4)
  parts.append(f'<line x1="{left}" x2="1080" y1="{yy}" y2="{yy}" stroke="#dedbd2"/><text x="{left-10}" y="{yy+4}" text-anchor="end" font-family="Arial,sans-serif" fill="#53616a" font-size="12">{value:,}</text>')
 colors={'CORE':'#19374a','CARD':'#337b78','DIGITAL':'#b56c3e'}
 for j,(system,color) in enumerate(colors.items()):
  pts=[]
  for i,mo in enumerate(months):
   x=left+i*(1015/max(1,len(months)-1));yy=top+plot_h*(1-values[(mo,system)]/maxv);pts.append(f'{x:.2f},{yy:.2f}')
  parts.append(f'<polyline points="{" ".join(pts)}" fill="none" stroke="{color}" stroke-width="3" stroke-linejoin="round"/>')
  parts.append(f'<line x1="{left+j*165}" x2="{left+j*165+22}" y1="20" y2="20" stroke="{color}" stroke-width="3"/><text x="{left+j*165+30}" y="24" fill="#19374a" font-family="Arial,sans-serif" font-size="13">{system}</text>')
 for i,mo in enumerate(months):
  if i%3==0 or i==len(months)-1:
   x=left+i*(1015/max(1,len(months)-1));parts.append(f'<text x="{x}" y="{h-35}" text-anchor="middle" font-family="Arial,sans-serif" fill="#53616a" font-size="12">{mo}</text>')
 return ''.join(parts)+'</svg>'

def render_page(mode,start,end,customer,all_rows,included,summary,svg,outputs,profile,filtered):
 """Build the activity brief from the selected period and the computed SQL outputs."""
 source_counts=defaultdict(int);month_counts=defaultdict(int);year_source=defaultdict(int)
 for row in filtered:
  count=int(row['event_count']);source=row['source_system'];month=row['activity_month']
  source_counts[source]+=count;month_counts[month]+=count;year_source[(month[:4],source)]+=count
 peak=max(month_counts.items(),key=lambda item:item[1]) if month_counts else None
 outside=all_rows-included
 status_counts=defaultdict(int)
 for row in outputs['03_status_breakdown']:
  status_counts[(row['source_system'],row['activity_status'])]+=int(row['record_count'])
 status_rows=[{'source':source,'status':status,'records':f'{count:,}'}
              for (source,status),count in sorted(status_counts.items())]
 years=sorted({year for year,_ in year_source})
 year_rows=[{'year':year,**{source:f'{year_source[(year,source)]:,}' for source in ('CORE','CARD','DIGITAL')},
             'total':f'{sum(year_source[(year,source)] for source in ("CORE","CARD","DIGITAL")):,}'}
            for year in years]
 origin='Original dataset preview' if mode=='dataset-preview' else 'Integrated warehouse export'
 pct=lambda count:100*count/included if included else 0
 portions=''.join(f'<span class="segment {source.lower()}" style="width:{pct(source_counts[source]):.4f}%" title="{source}: {source_counts[source]:,} records"></span>' for source in ('CORE','CARD','DIGITAL'))
 source_legend=''.join(f'<li><i class="swatch {source.lower()}"></i><span>{source.title()}</span><strong>{source_counts[source]:,}</strong><em>{pct(source_counts[source]):.1f}%</em></li>' for source in ('CORE','CARD','DIGITAL'))
 warning_rows=[{'issue':key.replace('_',' ').replace(';','; '),'affected_rows':f'{value:,}'} for key,value in summary['warnings'].items()]
 first_card=next((str(r['first_event'])[:10] for r in profile if r['source_system']=='CARD'),'not available')
 peak_text=(f'{peak[0]} with {peak[1]:,} recorded events' if peak else 'No events in this period')
 page='''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Report 1 · Activity brief | Horizon Retail Bank</title><style>
 :root{--navy:#102d3a;--teal:#338c87;--orange:#df8b55;--cream:#f6f2e9;--ink:#213641;--muted:#60717a;--rule:#d8dfdf}*{box-sizing:border-box}body{margin:0;background:#e8eeed;color:var(--ink);font:14px/1.52 Arial,Helvetica,sans-serif}.shell{max-width:1160px;margin:24px auto;background:#fff;box-shadow:0 12px 42px #102d3a18}.topline{height:6px;background:linear-gradient(90deg,var(--navy) 0 48%,var(--teal) 48% 77%,var(--orange) 77%)}header{background:var(--navy);color:#fff;padding:31px 47px 39px}.headrow{display:flex;justify-content:space-between;gap:20px;align-items:center;border-bottom:1px solid #ffffff45;padding-bottom:15px;text-transform:uppercase;font-size:10px;letter-spacing:.17em}.headrow b{font-size:15px;letter-spacing:.2em}.headrow span{color:#b8cdcf}.hero{display:grid;grid-template-columns:minmax(0,1fr) 190px;gap:32px;align-items:end;padding-top:30px}.overline,.label{font-size:10px;letter-spacing:.16em;text-transform:uppercase;font-weight:700}.overline{color:#8bd0c9;margin:0 0 12px}h1{font:normal 49px/1.05 Georgia,'Times New Roman',serif;letter-spacing:-.025em;margin:0 0 14px;max-width:700px}.hero p:not(.overline){color:#c2d1d1;font-size:15px;max-width:640px;margin:0}.issue{border-left:1px solid #ffffff55;padding-left:22px;text-align:left}.issue strong{display:block;font:normal 70px/.9 Georgia,serif;color:#8bd0c9}.issue span{display:block;letter-spacing:.13em;font-size:10px;text-transform:uppercase;margin-top:10px}.meta{display:flex;gap:12px 34px;flex-wrap:wrap;background:#e7f0ef;border-bottom:1px solid var(--rule);padding:13px 47px;font-size:12px}.meta b{font-size:10px;letter-spacing:.08em;text-transform:uppercase;margin-right:6px;color:#536771}.body{padding:0 47px 44px}.opening{display:grid;grid-template-columns:minmax(0,1.3fr) minmax(290px,1fr);gap:42px;padding:42px 0 38px}.label{color:#ad6339;margin:0 0 14px}.opening h2{font:normal 29px/1.16 Georgia,serif;margin:0 0 16px}.opening p{max-width:565px;margin:10px 0}.readout{border-top:3px solid var(--teal);padding-top:18px}.readout ul{padding-left:18px;margin:12px 0 0}.readout li{margin:10px 0}.ledger{background:#f2f5f3;border-top:3px solid var(--navy);padding:19px 22px 22px}.ledger h2{font:normal 22px Georgia,serif;margin:0 0 18px}.metric{display:flex;justify-content:space-between;gap:12px;border-bottom:1px solid #cfdbd9;padding:9px 0}.metric span{font-size:12px;color:#536771}.metric strong{font-size:19px;font-variant-numeric:tabular-nums}.mix{display:flex;overflow:hidden;height:16px;margin-top:22px}.segment{display:block;height:100%}.core,.swatch.core{background:var(--navy)}.card,.swatch.card{background:var(--teal)}.digital,.swatch.digital{background:var(--orange)}.legend{list-style:none;padding:0;margin:13px 0 0}.legend li{display:grid;grid-template-columns:12px 1fr 70px 52px;gap:10px;align-items:center;margin:6px 0;font-size:12px}.legend strong,.legend em{text-align:right;font-style:normal;font-variant-numeric:tabular-nums}.legend em{color:var(--muted)}.swatch{width:9px;height:9px}.section{border-top:1px solid var(--rule);padding:34px 0 25px}.sectionhead{display:grid;grid-template-columns:54px minmax(0,1fr);gap:19px;align-items:start;margin-bottom:22px}.number{font:normal 30px/1 Georgia,serif;color:var(--teal)}.sectionhead h2{font:normal 30px/1.1 Georgia,serif;margin:0 0 7px}.sectionhead p{margin:0;color:var(--muted);font-size:13px}.figure{background:#f7f9f7;padding:17px 14px 3px;border-top:1px solid #b9c9c7;border-bottom:1px solid #b9c9c7}.figure svg{display:block;width:100%;height:auto}.two{display:grid;grid-template-columns:1fr 1fr;gap:28px;margin-top:27px}.subhead{font-size:10px;letter-spacing:.13em;text-transform:uppercase;color:#ad6339;font-weight:700;margin:0 0 10px}.note{color:var(--muted);font-size:12px;margin:11px 0 0}.callout{border-left:3px solid var(--orange);background:#fff8f0;padding:16px 19px}.callout strong{display:block;font:normal 21px Georgia,serif;margin-bottom:5px}.callout p{margin:0;font-size:13px}.scroll{overflow:auto;max-height:480px;border-top:2px solid var(--navy)}table{width:100%;border-collapse:collapse;font-size:12px;font-variant-numeric:tabular-nums}th,td{text-align:left;white-space:nowrap;padding:9px 11px;border-bottom:1px solid var(--rule)}th{font-size:10px;text-transform:uppercase;letter-spacing:.08em;background:#eff4f2;color:#4c626c}tbody tr:nth-child(even){background:#f8faf9}.method{background:#f2f5f3;padding:22px 25px;margin-top:23px}.method p{margin:0 0 10px}footer{background:var(--navy);color:#b8ccca;padding:18px 47px;font-size:11px;letter-spacing:.02em}@media(max-width:780px){.shell{margin:0}.body{padding:0 20px 30px}header{padding:23px 20px}.meta{padding:12px 20px}.hero,.opening,.two{grid-template-columns:1fr}.issue{display:none}h1{font-size:39px}.sectionhead{grid-template-columns:38px 1fr;gap:10px}.sectionhead h2{font-size:25px}footer{padding:18px 20px}}@media print{body{background:white}.shell{box-shadow:none;margin:0}.scroll{max-height:none}.section{break-inside:avoid}.figure svg{max-height:240px}header,footer,.ledger,.method,.callout{print-color-adjust:exact;-webkit-print-color-adjust:exact}}
 </style></head><body><div class="shell"><div class="topline"></div><header><div class="headrow"><b>Horizon Retail Bank</b><span>Data systems / analytical series</span></div><div class="hero"><div><p class="overline">Integrated activity · Report 01</p><h1>What happened across the bank?</h1><p>Core banking, card processing and digital activity in one traceable view.</p></div><div class="issue"><strong>01</strong><span>Activity trends<br>Research prototype</span></div></div></header>'''
 page+=f'<div class="meta"><span><b>Input</b> {html.escape(origin)}</span><span><b>Period</b> {html.escape(start)} to {html.escape(end)} inclusive</span><span><b>Basis</b> Source records, all statuses</span></div>'
 page+='<div class="body"><div class="opening"><div class="readout"><p class="label">The readout</p><h2>One analytical window. Three different source histories.</h2><ul>'
 page+=f'<li><b>{included:,}</b> records fall inside the selected period; <b>{all_rows:,}</b> remain in the gold activity table.</li>'
 page+=f'<li><b>{outside:,}</b> records fall outside this period. The card source begins on <b>{html.escape(first_card)}</b>; older events are retained rather than deleted.</li>'
 page+=f'<li>The busiest month in the selected period is <b>{html.escape(peak_text)}</b>. This counts interactions and statuses, not distinct payments.</li>'
 page+='</ul></div><aside class="ledger"><p class="label">Coverage ledger</p><h2>Selected period</h2>'
 page+=''.join(f'<div class="metric"><span>{label}</span><strong>{value:,}</strong></div>' for label,value in [('In period',included),('Outside period',outside),('Rejected by checks',summary['rejected'])])
 page+=f'<div class="mix" role="img" aria-label="Source mix: core {source_counts["CORE"]:,}, card {source_counts["CARD"]:,}, digital {source_counts["DIGITAL"]:,}">{portions}</div><ul class="legend">{source_legend}</ul></aside></div>'
 page+='<section class="section"><div class="sectionhead"><span class="number">01</span><div><h2>Activity through time</h2><p>Monthly source-record counts within the selected period. Empty months are plotted at zero.</p></div></div><div class="figure">'+svg+'</div><div class="two"><div><p class="subhead">Year by source</p>'+table_html(year_rows)+'<p class="note">First and last years may cover only part of a calendar year.</p></div><div class="callout"><strong>Reading the trend</strong><p>Each line describes when a source recorded activity. The card history starts earlier than the selected window. A digital interaction and a core posting may reflect the same operation, so lines should not be added into a count of unique payments.</p></div></div></section>'
 page+='<section class="section"><div class="sectionhead"><span class="number">02</span><div><h2>Recorded value</h2><p>Successful monetary activity in the selected period, separated by source and currency.</p></div></div>'+table_html(outputs['02_successful_values'])+'<div class="method"><p><b>Measure:</b> gross recorded value for COMPLETED core and APPROVED card records. These are not net balances, fraud losses or a cross-system banking total.</p><p>Digital monetary events have no supplied currency, so their values are excluded from this comparison. Do not assume AUD.</p></div></section>'
 page+='<section class="section"><div class="sectionhead"><span class="number">03</span><div><h2>Outcomes and activity types</h2><p>Failures, reversals and pending records remain visible in the activity history.</p></div></div><div class="two"><div><p class="subhead">Outcome summary</p>'+table_html(status_rows)+'</div><div><p class="subhead">Activity and status detail</p>'+table_html(outputs['03_status_breakdown'])+'</div></div></section>'
 page+='<section class="section"><div class="sectionhead"><span class="number">04</span><div><h2>Follow one customer</h2><p>Illustrative timeline for '+html.escape(customer)+' across all retained history.</p></div></div>'+table_html(outputs['04_customer_timeline'])+'<p class="note">The page shows at most 100 timeline rows. The accompanying CSV retains every matching row.</p></section>'
 page+='<section class="section"><div class="sectionhead"><span class="number">05</span><div><h2>Coverage and caveats</h2><p>Source span, missing context and the checks applied during the lakehouse build.</p></div></div><div class="two"><div><p class="subhead">Source coverage</p>'+table_html(profile)+'</div><div><p class="subhead">Build warnings</p>'+table_html(warning_rows)+'</div></div><div class="method"><p><b>Interpretation:</b> zero rejected rows means the implemented validation rules accepted the supplied records. It does not establish that the data is complete or error-free.</p><p>Digital monetary currency is unspecified. Timestamps preserve source wall-clock values without a declared timezone. Synthetic fraud indicators are source labels rather than confirmed cases or model predictions.</p></div></section></div>'
 page+='<footer>Report 01 · Derived from lakehouse gold activity and SQL outputs · CSV exports, verification and Delta history accompany this page.</footer></div></body></html>'
 return page

def report(mode,start,end,customer):
 if date.fromisoformat(start)>date.fromisoformat(end): raise ValueError('start must be <= end')
 folder,out=location(mode);lake=out/'lakehouse';manifest=load(lake/'manifest.json')
 if manifest['input_hash']!=fingerprint(folder):raise ValueError('Warehouse export changed; rerun lakehouse build first')
 activity=DeltaTable(str(lake/'gold/fact_activity')).to_pyarrow_table()
 with duckdb.connect() as db:
  db.register('activity',activity)
  monthly_table=db.execute((ROOT/'sql/report_1/01_monthly_activity.sql').read_text()).fetch_arrow_table()
  write_deltalake(str(lake/'gold/monthly_activity'),monthly_table,mode='overwrite')
  monthly=monthly_table.to_pylist()
  # Apply exact date filtering before regrouping so custom partial months are handled correctly.
  filtered=db.execute("SELECT strftime(event_timestamp,'%Y-%m') AS activity_month,source_system,count(*) AS event_count FROM activity WHERE event_timestamp>=CAST(? AS TIMESTAMP) AND event_timestamp<CAST(? AS TIMESTAMP)+INTERVAL 1 DAY GROUP BY ALL ORDER BY 1,2",[start,end]).fetch_arrow_table().to_pylist()
  outputs={}
  for filename,params in [('02_successful_values',[start,end]),('03_status_breakdown',[start,end]),('04_customer_timeline',[customer])]:
   result=db.execute((ROOT/'sql/report_1'/(filename+'.sql')).read_text(),params).fetch_arrow_table()
   outputs[filename]=result.to_pylist();write_csv(out/'reports'/(filename+'.csv'),outputs[filename],result.column_names)
  profile=db.execute('SELECT source_system,count(*) AS records,count(amount) AS amount_records,min(event_timestamp) AS first_event,max(event_timestamp) AS last_event FROM activity GROUP BY source_system ORDER BY source_system').fetch_arrow_table().to_pylist()
 write_csv(out/'reports/01_monthly_activity_all_history.csv',monthly,monthly_table.column_names)
 write_csv(out/'reports/01_monthly_counts_selected_window.csv',filtered,['activity_month','source_system','event_count'])
 svg=chart(filtered,start,end);(out/'reports/monthly_activity.svg').write_text(svg,encoding='utf-8')
 included=sum(r['event_count'] for r in filtered);summary=load(out/'build_summary.json')
 metrics={'mode':mode,'window_start':start,'window_end':end,'all_history_records':activity.num_rows,'window_records':included,'outside_selected_window':activity.num_rows-included,'rejected':summary['rejected'],'source_profiles':profile}
 dump(out/'reports/report_1_metrics.json',metrics)
 page=render_page(mode,start,end,customer,activity.num_rows,included,summary,svg,outputs,profile,filtered)
 (out/'reports/Report_1_Activity_Trends.html').write_text(page,encoding='utf-8')
 (out/'reports/Report_1_Activity_Brief.html').write_text(page,encoding='utf-8')
 manifest['tables']['gold/monthly_activity']={'version':DeltaTable(str(lake/'gold/monthly_activity')).version(),'rows':monthly_table.num_rows}
 dump(lake/'manifest.json',manifest)
 print(metrics)
