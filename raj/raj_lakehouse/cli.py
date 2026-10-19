import argparse
from pathlib import Path
from .common import ROOT

def main(command):
 p=argparse.ArgumentParser(description='Raj: dataset-aligned lakehouse and activity report')
 p.add_argument('--mode',choices=['dataset-preview','warehouse'],default='dataset-preview')
 p.add_argument('--zip',type=Path,default=ROOT/'input/team_dataset.zip')
 p.add_argument('--start',default='2024-01-01');p.add_argument('--end',default='2026-09-30')
 p.add_argument('--customer',default='ENT_C000001')
 a=p.parse_args()
 if command=='prepare':
  from .prepare import preview
  preview(a.zip)
 elif command=='export':
  from .prepare import export
  export()
 elif command=='register':
  from .prepare import register_csv
  register_csv()
 elif command=='build':
  from .build import build
  build(a.mode)
 elif command=='report':
  from .report import report
  report(a.mode,a.start,a.end,a.customer)
 elif command=='verify':
  from .verify import verify
  verify(a.mode)
 elif command=='history':
  from .verify import history
  history(a.mode)
 elif command=='consolidate':
  from .consolidate import consolidate
  consolidate()
