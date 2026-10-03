#!/usr/bin/env python3
"""Sample one macOS process using Python's standard library and /bin/ps."""

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import tempfile
import time


def positive_number(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError("must be a finite number greater than zero")
    return number


def positive_pid(value):
    pid = int(value)
    if pid <= 0:
        raise argparse.ArgumentTypeError("must be a PID greater than zero")
    return pid


def cpu_seconds(value):
    """Decode ps time: [[days-]hours:]minutes:seconds[.fraction]."""
    days = 0
    if "-" in value:
        day_value, value = value.split("-", 1)
        days = int(day_value)
    parts = value.split(":")
    if len(parts) not in (2, 3):
        raise ValueError("unexpected ps CPU time")
    seconds = float(parts[-1]) + int(parts[-2]) * 60 + days * 86400
    if len(parts) == 3:
        seconds += int(parts[0]) * 3600
    return seconds


def read_process(pid):
    environment = dict(os.environ, LC_ALL="C")
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "pid=", "-o", "pcpu=",
         "-o", "rss=", "-o", "time=", "-o", "lstart=", "-o", "comm="],
        capture_output=True, text=True, env=environment, timeout=2,
        check=False,
    )
    if result.returncode == 1 and not result.stdout.strip():
        return None
    if result.returncode != 0:
        raise RuntimeError("ps failed: " + result.stderr.strip())
    fields = result.stdout.strip().split(maxsplit=9)
    if len(fields) != 10 or int(fields[0]) != pid:
        raise ValueError("unexpected ps output")
    return {
        "pid": pid,
        "ps_cpu_percent": float(fields[1]),
        "rss_bytes": int(fields[2]) * 1024,
        "cpu_time_seconds": cpu_seconds(fields[3]),
        "process_started_at": " ".join(fields[4:9]),
        "executable": fields[9],
    }


def summarize(samples):
    if not samples:
        return {"sample_count": 0}
    rss = [sample["rss_bytes"] for sample in samples]
    span = samples[-1]["elapsed_seconds"] - samples[0]["elapsed_seconds"]
    used_cpu = samples[-1]["cpu_time_seconds"] - samples[0]["cpu_time_seconds"]
    intervals = [sample["interval_cpu_percent"] for sample in samples
                 if sample["interval_cpu_percent"] is not None]
    return {
        "sample_count": len(samples),
        "sample_span_seconds": round(span, 6),
        "cpu_time_delta_seconds": round(used_cpu, 6),
        "interval_cpu_mean_percent": round(used_cpu / span * 100, 3) if span > 0 else None,
        "interval_cpu_peak_percent": max(intervals) if intervals else None,
        "ps_cpu_sample_mean_percent": round(statistics.fmean(
            sample["ps_cpu_percent"] for sample in samples), 3),
        "rss_first_bytes": rss[0],
        "rss_last_bytes": rss[-1],
        "rss_mean_bytes": round(statistics.fmean(rss)),
        "rss_peak_bytes": max(rss),
    }


def publish(report, destination):
    report["summary"] = summarize(report["samples"])
    if destination is None:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8",
                                         dir=destination.parent, delete=False) as temporary:
            temporary_name = temporary.name
            json.dump(report, temporary, ensure_ascii=False, indent=2, allow_nan=False)
            temporary.write("\n")
        os.replace(temporary_name, destination)
    finally:
        if temporary_name and os.path.exists(temporary_name):
            os.unlink(temporary_name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=positive_pid, required=True)
    parser.add_argument("--duration", type=positive_number, default=10.0, help="seconds (default: 10)")
    parser.add_argument("--interval", type=positive_number, default=0.5, help="seconds (default: 0.5)")
    parser.add_argument("--output", type=Path, help="atomically updated JSON file; final JSON also goes to stdout")
    args = parser.parse_args()
    report = {
        "schema_version": 1,
        "status": "sampling",
        "stop_reason": None,
        "started_at_utc": datetime.now(timezone.utc).isoformat(),
        "pid": args.pid,
        "duration_requested_seconds": args.duration,
        "interval_requested_seconds": args.interval,
        "platform": platform.platform(),
        "process": None,
        "samples": [],
    }
    start = time.monotonic()
    exit_code = 0
    try:
        if sys.platform != "darwin":
            raise RuntimeError("this tool requires macOS")
        while True:
            process = read_process(args.pid)
            elapsed = time.monotonic() - start
            if process is None:
                report["stop_reason"] = "process_exited" if report["samples"] else "process_not_found"
                exit_code = 0 if report["samples"] else 1
                break
            identity = {key: process[key] for key in ("pid", "process_started_at", "executable")}
            if report["process"] is None:
                report["process"] = identity
            elif identity != report["process"]:
                report["stop_reason"] = "process_identity_changed"
                break
            sample = {key: process[key] for key in ("ps_cpu_percent", "rss_bytes", "cpu_time_seconds")}
            sample["elapsed_seconds"] = round(elapsed, 6)
            sample["interval_cpu_percent"] = None
            if report["samples"]:
                previous = report["samples"][-1]
                delta_time = sample["elapsed_seconds"] - previous["elapsed_seconds"]
                delta_cpu = sample["cpu_time_seconds"] - previous["cpu_time_seconds"]
                if delta_cpu < 0:
                    raise ValueError("process CPU time decreased")
                if delta_time > 0:
                    sample["interval_cpu_percent"] = round(delta_cpu / delta_time * 100, 3)
            report["samples"].append(sample)
            publish(report, args.output)
            if elapsed >= args.duration:
                report["stop_reason"] = "duration_completed"
                break
            next_due = min(start + len(report["samples"]) * args.interval, start + args.duration)
            time.sleep(max(0, next_due - time.monotonic()))
    except KeyboardInterrupt:
        report["stop_reason"] = "interrupted"
        exit_code = 130
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["stop_reason"] = "measurement_error"
        report["error"] = str(error)
        exit_code = 1
    report["status"] = "error" if exit_code == 1 else "complete"
    report["elapsed_seconds"] = round(time.monotonic() - start, 6)
    report["finished_at_utc"] = datetime.now(timezone.utc).isoformat()
    try:
        publish(report, args.output)
    except OSError as error:
        report["status"] = "error"
        report["stop_reason"] = "output_error"
        report["error"] = str(error)
        exit_code = 1
    print(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
