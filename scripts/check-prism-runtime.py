#!/usr/bin/env python3
# © 2026 aiaiaiai · aiaiaiai.org
"""Summarize private Docker observations without echoing raw logs or arguments."""
import datetime as dt
import json
import re
import sys
from pathlib import Path

def summarize(processes, logs, now):
    checks = {}
    for name in ("signal-scheduler", "delivery-worker"):
        checks[name] = any(re.search(r"(?:^|\s)(?:\S*/)?prism-hub-" + name + r"(?:\s|$)", line) for line in processes.splitlines())
    passes = []
    failed_passes = []
    for line in logs.splitlines():
        try:
            timestamp = dt.datetime.fromisoformat(line.split(" ", 1)[0].replace("Z", "+00:00"))
            age = (now - timestamp).total_seconds()
        except (ValueError, IndexError):
            continue
        if not 0 <= age <= 600:
            continue
        match = re.search(r"\bsignal_pass read=(\d+) failed_sources=(\d+) alerts=(\d+) retractions=(\d+) skipped=(\d+)\s*$", line)
        if match:
            passes.append((timestamp, int(match[2])))
        elif re.search(r"\bsignal_pass_failed\b", line):
            failed_passes.append(timestamp)
    latest = max(passes, default=None)
    checks["recent_signal_pass"] = latest is not None
    checks["latest_pass_sources_ok"] = latest is not None and latest[1] == 0
    checks["no_newer_failed_pass"] = latest is not None and not any(t >= latest[0] for t in failed_passes)
    return {"checks": checks, "observed_passes_10m": len(passes),
            "last_pass_utc": latest[0].isoformat() if latest else None,
            "latest_failed_sources": latest[1] if latest else None,
            "worker_activity": "process observed only; correlated delivery still required",
            "ok": all(checks.values())}

if __name__ == "__main__":
    result = summarize(Path(sys.argv[1]).read_text(), Path(sys.argv[2]).read_text(),
                       dt.datetime.now(dt.timezone.utc))
    print(json.dumps(result, sort_keys=True))
    sys.exit(0 if result["ok"] else 1)
