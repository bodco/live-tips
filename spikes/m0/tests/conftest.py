import sys
from pathlib import Path

HERE = Path(__file__).absolute()   # not resolve(): mutation testing links the tree and must import its own copy
sys.path.insert(0, str(HERE.parents[1]))          # spikes/m0
APP = HERE.parents[3]                             # tools/live-tips-app
FIX = APP / "Fixtures"
