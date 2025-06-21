# mosquitto_sub -h 192.168.1.24 -u mosquito -P mosquito -t 'frigate/events' > frigate_event_dump.jsonl
# this script is to parse this type of jsonl logs

import json
from datetime import datetime
import sys


def human_readable_log(event):
    try:
        after = event.get('after', {})
        event_type = event.get('type', 'N/A').upper()
        camera = after.get('camera', 'N/A')
        label = after.get('label', 'N/A')
        current_zones = after.get('current_zones', [])
        entered_zones = after.get('entered_zones', [])
        score = after.get('score', None)
        severity = after.get('max_severity', 'N/A')
        event_id = after.get('id', 'N/A')
        # Prefer start_time, fall back to frame_time or now
        timestamp = after.get('start_time') or after.get('frame_time') or None
        if timestamp is not None:
            dt = datetime.fromtimestamp(float(timestamp))
            timestr = dt.strftime('%Y-%m-%d %H:%M:%S')
        else:
            timestr = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        log_line = (
            f"{timestr} | {event_type:7} | Camera: {camera} | Object: {label} "
            f"| Active zones: {current_zones} | Entered zones: {entered_zones} "
            f"| Score: {score:.2f} | Severity: {severity} | Event ID: {event_id}"
        )
        return log_line
    except Exception as e:
        return f"Error parsing event: {e}"


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
    for event in events:
        print(human_readable_log(event))

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Assumption: you have subsscribed to the frigate events and have pipe it out to a jsonl")
        print("Example: mosquitto_sub -h 192.168.1.24 -u mosquito -P mosquito -t 'frigate/events' > frigate_event_dump.jsonl")
        print("Usage: python frigate_event_log_parser.py <events.jsonl>")
        sys.exit(1)
    parse_events_file(sys.argv[1])
