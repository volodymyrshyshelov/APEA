#!/usr/bin/env python3
"""
Convert a simple cron expression to Azure Automation schedule hints.

Supported patterns (minute hour day month day_of_week):
 - "0 6 * * *"  -> Daily at 06:00 UTC
 - "0 */6 * * *" -> Every 6 hours
 - "0 0 * * 1" -> Weekly (Mon) at 00:00 UTC

Note: Azure Automation schedules require explicit start time and frequency/interval.
This tool prints recommended frequency/interval and next start-time (UTC rounded +10min).
"""
import sys
from datetime import datetime, timedelta

def usage():
    print("Usage: cron_to_schedule.py '<cron expression>' [timezone=UTC]")
    sys.exit(1)

if len(sys.argv) < 2:
    usage()

cron = sys.argv[1].strip()
tz = sys.argv[2] if len(sys.argv) > 2 else 'UTC'

fields = cron.split()
if len(fields) != 5:
    print("Error: cron must have 5 fields: m h dom mon dow")
    sys.exit(2)

m, h, dom, mon, dow = fields
now = datetime.utcnow()
start = now + timedelta(minutes=10)
start = start.replace(second=0, microsecond=0)
hint = {"frequency": None, "interval": None, "time": None, "timezone": tz}

if dom == "*" and mon == "*" and dow == "*" and m.isdigit() and h.isdigit():
    hint["frequency"] = "Day"
    hint["interval"] = 1
    hint["time"] = f"{int(h):02d}:{int(m):02d}"
elif dom == "*" and mon == "*" and dow == "*" and m == "0" and h.startswith("*/") and h[2:].isdigit():
    hint["frequency"] = "Hour"
    hint["interval"] = int(h[2:])
    hint["time"] = None
elif dom == "*" and mon == "*" and m.isdigit() and h.isdigit() and dow.isdigit():
    hint["frequency"] = "Week"
    hint["interval"] = 1
    hint["time"] = f"{int(h):02d}:{int(m):02d}"
else:
    print("Unsupported/complex cron; map manually to Azure schedule.")
    sys.exit(3)

print("Azure Automation schedule suggestion:")
print(f"  frequency = {hint['frequency']}")
print(f"  interval  = {hint['interval']}")
if hint["time"]:
    print(f"  time      = {hint['time']} (UTC)")
print(f"  timezone  = {hint['timezone']}")
print(f"  start     = {start.isoformat()}Z  (>= 5 min in the future)")
