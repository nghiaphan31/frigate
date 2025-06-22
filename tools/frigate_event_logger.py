"""
To run this script as a systemd background service:

1. Create the systemd service file:

   sudo nano /etc/systemd/system/frigate_event_logger.service

   # Paste the following, update User if needed:

   [Unit]
   Description=Frigate MQTT Event Logger Service
   After=network.target

   [Service]
   Type=simple
   User=nghia-phan
   WorkingDirectory=/home/nghia-phan/git/nuc-docker-stack/tools
   ExecStart=/usr/bin/python3 /home/nghia-phan/git/nuc-docker-stack/tools/frigate_event_logger.py
   Restart=always
   RestartSec=5

   [Install]
   WantedBy=multi-user.target

2. Reload systemd and enable/start the service:

   sudo systemctl daemon-reload
   sudo systemctl enable frigate_event_logger.service
   sudo systemctl start frigate_event_logger.service

3. Check service status and logs:

   sudo systemctl status frigate_event_logger.service
   journalctl -u frigate_event_logger.service -f

---

1. Created an MQTT Event Logger
Language: Python
Script: nuc-docker-stack/tools/frigate_event_logger.py
Purpose: Listens to Frigate MQTT event messages (frigate/events topic) using credentials proven to work with your CLI (mosquito/mosquito on broker 192.168.1.24).
2. Integrated a Custom Log Parser
Parser file: nuc-docker-stack/tools/frigate_event_log_parser.py
How it works: Each event is parsed and formatted into a fixed-width, human-readable log line using your 
human_readable_log
 function, for easy searching and display.
Output: Logs to frigate_event.log in the same directory, with a table-like header at the top.
3. Configured as a systemd Background Service
systemd Service Unit: Created (example: /etc/systemd/system/frigate_event_logger.service)
Ensures the logger script runs in the background and starts at boot.
Handles auto-restart if it crashes and inherits the correct working directory.
Enabling/starting: Used systemctl enable --now frigate_event_logger and can view logs with journalctl.
Result:
You now have a robust, automatically-running Python logger that collects, parses, and logs all Frigate MQTT events in a human-readable format, with a persistent service managed by systemd.
"""

import paho.mqtt.client as mqtt
import logging
import json
import os
import sys

# Ensure the parser is importable
sys.path.append(os.path.dirname(__file__))
from frigate_event_log_parser import human_readable_log

BROKER = "192.168.1.24"  # MQTT broker from working CLI
MQTT_USER = "mosquito"
MQTT_PASS = "mosquito"
TOPIC = "frigate/events"
LOG_FILE = "frigate_event.log"

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format='%(message)s',  # Only log the human-readable line
)

# Write header once at log file creation
if not os.path.exists(LOG_FILE) or os.path.getsize(LOG_FILE) == 0:
    with open(LOG_FILE, "a") as f:
        f.write(human_readable_log({}, header=True) + "\n")

def on_connect(client, userdata, flags, rc):
    if rc == 0:
        print("Connected to MQTT Broker.")
        client.subscribe(TOPIC)
    else:
        print(f"Failed to connect to MQTT broker, return code {rc}")

def on_message(client, userdata, msg):
    try:
        event = msg.payload.decode('utf-8')
        try:
            parsed = json.loads(event)
            logline = human_readable_log(parsed)
            logging.info(logline)
        except Exception as e:
            logging.error(f"Parse error: {e} -- raw: {event}")
    except Exception as e:
        logging.error(f"Error processing message: {e}")

def main():
    client = mqtt.Client()
    client.username_pw_set(MQTT_USER, MQTT_PASS)
    client.on_connect = on_connect
    client.on_message = on_message

    try:
        client.connect(BROKER, 1883, 60)
        client.loop_forever()
    except Exception as e:
        print(f"Could not connect to MQTT broker: {e}")

if __name__ == "__main__":
    main()
