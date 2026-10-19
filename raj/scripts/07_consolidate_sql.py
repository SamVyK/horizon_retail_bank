"""Raj: consolidate. See README for inputs, ownership and output paths."""
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from raj_lakehouse.cli import main
if __name__=='__main__':main('consolidate')
