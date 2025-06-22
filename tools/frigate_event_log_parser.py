"""
Frigate Event Log Parser
-----------------------

Assumption: You have subscribed to the Frigate events topic and piped them to a JSONL file.
Example:
    mosquitto_sub -h 192.168.1.24 -u mosquito -P mosquito -t 'frigate/events' > frigate_event_dump.jsonl

Usage:
    python3 frigate_event_log_parser.py <events.jsonl>

Example (with filtering):
    python3 frigate_event_log_parser.py frigate_event_dump.jsonl | grep allee

Description:
    - Reads a Frigate MQTT events JSONL file and prints each event as a readable, fixed-width table row.
    - Useful for log review, filtering, and searching event data in terminal.
    - Exits with error if you do not specify an input file.
"""

import json
from datetime import datetime, timedelta
import sys
import os


def human_readable_log(event, header=False, full=False):
    """
    Returns a fixed-width formatted string for the event.
    If header=True, returns the header instead.
    If full=True, prints full value on a new line if truncated.
    """
    columns = [
        ('Time',         19, 'time'),          # fixed: YYYY-MM-DD HH:MM:SS
        ('Type',          8, 'type'),
        ('EventID',       7, 'id'),           # Only last 6 chars
        ('Camera',       18, 'camera'),
        ('Label',         8, 'label'),
        ('ActiveZ',      8, 'current_zones'),
        ('EnteredZ',     8, 'entered_zones'),
        ('Score',         7, 'score'),
        ('TopScore',      8, 'top_score'),
        ('Sev',           10, 'max_severity'),
        ('Loiter',        6, 'pending_loitering'),
        ('Act',           3, 'active'),
        ('Stat',          4, 'stationary'),
        ('NoMo',          4, 'motionless_count'),
        ('PosChg',        6, 'position_changes'),
        ('FP',            2, 'false_positive'),
        ('Clip',          4, 'has_clip'),
        ('Snap',          4, 'has_snapshot'),
    ]

    # Map Frigate JSON keys to the right places (after block and event block)
    def extract_value(field, after, event):
        # event-block fields
        if field == 'type':
            return (event.get('type', '') or '').upper()
        # after-block fields
        val = after.get(field)
        if field in ('current_zones', 'entered_zones'):
            return ",".join(val) if val else "-"
        if field in ('score', 'top_score'):
            try:
                return f"{float(val):.2f}" if val is not None else "-"
            except Exception:
                return "-"
        if field in ('pending_loitering', 'active', 'stationary', 'false_positive', 'has_clip', 'has_snapshot'):
            return "Y" if val else "N"
        if field == 'motionless_count':
            return str(val) if val is not None else "0"
        if field == 'position_changes':
            return str(val) if val is not None else "0"
        if field == 'time':
            ts = after.get('frame_time') or after.get('start_time')
            if ts is not None:
                try:
                    from datetime import datetime
                    return datetime.fromtimestamp(float(ts)).strftime('%Y-%m-%d %H:%M:%S')
                except Exception:
                    return "-"
            return "-"
        if field == 'id':
            # Only last 6 chars for event id
            if val and isinstance(val, str) and len(val) >= 6:
                return val[-6:]
            return str(val) if val is not None else "-"
        return str(val) if val is not None else "-"

    if header:
        # Print header line
        return " | ".join(f"{title:<{width}}" for (title, width, _) in columns)

    after = event.get('after', {})
    line = []
    full_lines = []
    for idx, (title, width, field) in enumerate(columns):
        val = extract_value(field, after, event)
        truncated = False
        if len(val) > width:
            truncated = True
            val_trunc = val[:width-2] + ".."
        else:
            val_trunc = val
        line.append(f"{val_trunc:<{width}}")
        if full and truncated:
            # Print full value on a new line, with column name
            full_lines.append(f"    [Full {title}]: {val}")
    row = " | ".join(line)
    if full and full_lines:
        return row + "\n" + "\n".join(full_lines)
    return row
    
def write_and_prune_raw_log(raw_event_line, event):
    """
    Append the raw event JSON line to frigate_event_raw.log and keep only last 30 days of events.
    Uses event['after']['frame_time'] or event['after']['start_time'] as the timestamp.
    """
    RAW_LOG_FILE = "frigate_event_raw.log"
    now = datetime.now()
    cutoff = now - timedelta(days=30)
    # Append the new event
    with open(RAW_LOG_FILE, "a") as f:
        f.write(raw_event_line + "\n")
    # Prune old events
    if not os.path.exists(RAW_LOG_FILE):
        return
    with open(RAW_LOG_FILE, 'r') as f:
        lines = [line.strip() for line in f if line.strip()]
    kept_lines = []
    for line in lines:
        try:
            evt = json.loads(line)
            after = evt.get('after', {})
            ts = after.get('frame_time') or after.get('start_time')
            if ts is not None:
                evt_time = datetime.fromtimestamp(float(ts))
                if evt_time >= cutoff:
                    kept_lines.append(line)
            else:
                # If no timestamp, keep the line to avoid data loss
                kept_lines.append(line)
        except Exception:
            # Malformed line, keep it
            kept_lines.append(line)
    with open(RAW_LOG_FILE, 'w') as f:
        for l in kept_lines:
            f.write(l + "\n")

def parse_events_file(filename, full=False):
    with open(filename, 'r') as f:
        lines = [line.strip() for line in f if line.strip()]
    events = []
    try:
        # Try JSON Lines (one event per line)
        for line in lines:
            events.append(json.loads(line))
            # Write raw event and prune log
            try:
                write_and_prune_raw_log(line, events[-1])
            except Exception:
                pass
    except json.JSONDecodeError:
        # Fallback: try treating entire file as a single JSON object
        with open(filename, 'r') as f2:
            events = [json.load(f2)]
            # Write raw event and prune log
            try:
                write_and_prune_raw_log(json.dumps(events[0]), events[0])
            except Exception:
                pass
    print(human_readable_log({}, header=True))
    for event in events:
        print(human_readable_log(event, full=full))

if __name__ == "__main__":
    full = False
    if '--full' in sys.argv:
        full = True
        sys.argv.remove('--full')
    if len(sys.argv) < 2:
        print("Assumption: you have subsscribed to the frigate events and have pipe it out to a jsonl")
        print("Example: mosquitto_sub -h 192.168.1.24 -u mosquito -P mosquito -t 'frigate/events' > frigate_event_dump.jsonl")
        print("Usage: python3 frigate_event_log_parser.py <events.jsonl> [--full]")
        sys.exit(1)
    parse_events_file(sys.argv[1], full=full)
