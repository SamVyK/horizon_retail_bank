"""Contract edge cases and mathematical invariants; runs on the prepared supplied dataset."""
import unittest
from copy import deepcopy
from datetime import datetime
from decimal import Decimal
from raj_lakehouse.common import read_input
from raj_lakehouse.build import normalise

class LakehouseTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.tables=read_input('dataset-preview')[0]
 def test_complete_dataset_and_semantics(self):
  rows,issues=normalise(self.tables)
  self.assertEqual(len(rows),28500)
  self.assertEqual(sum(r['outside_reporting_window'] for r in rows),4134)
  digital=[r for r in rows if r['source_system']=='DIGITAL' and r['amount'] is not None]
  self.assertEqual(len(digital),765)
  self.assertEqual({r['currency'] for r in digital},{'UNSPECIFIED'})
  self.assertEqual(sum(r['amount'] for r in digital),Decimal('285107.09'))
 def test_bad_amount_is_quarantined_not_rounded(self):
  t=deepcopy(self.tables);t['fact_core_transaction'][0]['transaction_amount']='3.001'
  rows,issues=normalise(t)
  self.assertEqual(len(rows),28499)
  self.assertEqual(sum(r['severity']=='REJECT' for r in issues),1)
 def test_duplicate_source_ids_are_quarantined(self):
  t=deepcopy(self.tables);t['fact_card_transaction'].append(dict(t['fact_card_transaction'][0]))
  rows,issues=normalise(t)
  self.assertEqual(len(rows),28499)
  self.assertEqual(sum(r['severity']=='REJECT' for r in issues),2)
 def test_unknown_customer_stops_build(self):
  t=deepcopy(self.tables);t['dim_card'][0]['customer_key']='NO_SUCH_CUSTOMER'
  with self.assertRaises(ValueError):normalise(t)
 def test_changed_fact_reference_is_quarantined(self):
  t=deepcopy(self.tables);t['fact_digital_event'][0]['digital_user_key']='NO_SUCH_USER'
  rows,issues=normalise(t)
  self.assertEqual(len(rows),28499)
  self.assertTrue(any('unmatched_dimension_key' in r['reason'] for r in issues))

if __name__=='__main__':unittest.main()
