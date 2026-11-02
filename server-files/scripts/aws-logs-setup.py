#!/usr/bin/env python3
# Shim: the canonical copy lives in the scaffold (scaffold/scripts/server/).
# Do not edit here; see scaffold/docs/14-server-tooling.md.
import os
import runpy
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("SERVER_ROOT", root)
sys.argv[0] = os.path.join(root, "scaffold", "scripts", "server", "aws-logs-setup.py")
runpy.run_path(sys.argv[0], run_name="__main__")
