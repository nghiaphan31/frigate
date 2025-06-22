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
from datetime import datetime
import sys


def human_readable_log(event, header=False):
    """
    Returns a fixed-width formatted string for the event.
    If header=True, returns the header instead.
    """
    columns = [
        ('Time',         19, 'time'),          # fixed: YYYY-MM-DD HH:MM:SS
        ('Type',          8, 'type'),
        ('Camera',       10, 'camera'),
        ('Label',         8, 'label'),
        ('ActiveZ',      12, 'current_zones'),
        ('EnteredZ',     12, 'entered_zones'),
        ('Score',         7, 'score'),
        ('Sev',           5, 'max_severity'),
        ('Loiter',        7, 'pending_loitering'),
        ('Act',           5, 'active'),
        ('Stat',          5, 'stationary'),
        ('FP',            5, 'false_positive'),
        ('PosChg',        7, 'position_changes'),
        ('EventID',      13, 'id'),
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
        if field in ('score',):
            try:
                return f"{float(val):.2f}" if val is not None else "-"
            except Exception:
                return "-"
        if field in ('pending_loitering', 'active', 'stationary', 'false_positive'):
            return "Y" if val else "N"
        if field == 'time':
            ts = after.get('frame_time') or after.get('start_time')
            if ts is not None:
                try:
                    from datetime import datetime
                    return datetime.fromtimestamp(float(ts)).strftime('%Y-%m-%d %H:%M:%S')
                except Exception:
                    return "-"
            return "-"
        if field == 'position_changes':
            return str(val) if val is not None else "0"
        return str(val) if val is not None else "-"

    if header:
        # Print header line
        return " | ".join(f"{title:<{width}}" for (title, width, _) in columns)

    after = event.get('after', {})
    line = []
    for title, width, field in columns:
        val = extract_value(field, after, event)
        if len(val) > width:
            val = val[:width-2] + ".."
        line.append(f"{val:<{width}}")
    return " | ".join(line)
    
def parse_events_file(filename):
    with open(filename, 'r') as f:
        lines = [line.strip() for line in f if line.strip()]
    events = []
    try:
        # Try JSON Lines (one event per line)
        for line in lines:
            events.append(json.loads(line))
    except json.JSONDecodeError:
        # Fallback: try treating entire file as a single JSON object
        with open(filename, 'r') as f2:
            events = [json.load(f2)]
    print(human_readable_log({}, header=True))
    for event in events:
        print(human_readable_log(event))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Assumption: you have subsscribed to the frigate events and have pipe it out to a jsonl")
        print("Example: mosquitto_sub -h 192.168.1.24 -u mosquito -P mosquito -t 'frigate/events' > frigate_event_dump.jsonl")
        print("Usage: python3 frigate_event_log_parser.py <events.jsonl>")
        sys.exit(1)
    parse_events_file(sys.argv[1])
