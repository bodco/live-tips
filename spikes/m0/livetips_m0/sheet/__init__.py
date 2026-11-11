"""Pacenote 0.10.0 (Meeting Sheet): the sidecar of the module that prepares every call except Transcript.

One artifact per call, <project>/live/<base>.sheet.json (schema pacenote.sheet/1), shared by every AI route.
Phase 1 (core): schema.py (validator), presets.py (rules/meeting-sheet.yaml and the user's presets),
readiness.py (ready / almost / not ready, gaps, the automatic budget question), merge.py (manual edits survive).
CLI: python -m livetips_m0.sheet <command> --request <request.json> | --sheet <sheet.json>
"""
SCHEMA = "pacenote.sheet/1"
