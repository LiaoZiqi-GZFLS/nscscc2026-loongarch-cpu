#!/usr/bin/env python3
"""04_capture_interact.py —— capture UART RX to a log, optionally send commands at offsets.

Usage:
    python 04_capture_interact.py COM3 115200 out.log [t1:cmd1] [t2:cmd2] ...
Sends each cmd (with \\n appended) at t seconds after start; captures everything
to out.log. Exits after the last send + grace, or 600s max.
"""
import sys
import time
import serial

PORT = sys.argv[1]
BAUD = int(sys.argv[2])
LOG = sys.argv[3]
SENDS = []
for a in sys.argv[4:]:
    t, _, cmd = a.partition(":")
    SENDS.append((float(t), cmd))

MAX_T = 600.0
end_t = max((t for t, _ in SENDS), default=0) + 90.0
end_t = min(end_t, MAX_T)

ser = serial.Serial(PORT, BAUD, timeout=0.2)
start = time.time()
sent = 0
with open(LOG, "ab") as log:
    log.write(b"\n===== capture start %s =====\n" % time.asctime().encode())
    while True:
        now = time.time() - start
        if now >= end_t:
            break
        while sent < len(SENDS) and now >= SENDS[sent][0]:
            cmd = (SENDS[sent][1] + "\n").encode()
            ser.write(cmd)
            log.write(b"\n<<< sent '%s' at t=%.1f >>>\n" % (cmd.strip(), now))
            log.flush()
            sent += 1
            time.sleep(0.3)
        data = ser.read(512)
        if data:
            log.write(data)
            log.flush()
ser.close()
print("CAPTURE_DONE", LOG, "sent", sent, "of", len(SENDS))
