"""Retain bounded numeric resource evidence, without environment or path data.

These snapshots describe the calling cgroup. Event changes alone cannot prove
which process caused an OOM or who killed the acquisition process.
"""

import json
import os
from pathlib import Path, PurePosixPath
import re
import sys
import time


def read_bounded(path, limit):
    with open(path, "rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("oversize")
    return data.decode("ascii")


def mount_path(value):
    # mountinfo escapes whitespace and backslashes with these octal forms.
    if re.search(r"\\(?!040|011|012|134)", value):
        raise ValueError("mount_escape")
    return re.sub(r"\\(040|011|012|134)",
                  lambda match: chr(int(match[1], 8)), value)


def absolute_parts(value):
    if not value.startswith("/") or ".." in value.split("/"):
        raise ValueError("membership_path")
    return PurePosixPath(value)


def calling_cgroup():
    members = [line[3:] for line in read_bounded("/proc/self/cgroup", 4096).splitlines()
               if line.startswith("0::")]
    if len(members) != 1:
        raise ValueError("membership_count")
    member = absolute_parts(members[0])
    candidates = []
    for line in read_bounded("/proc/self/mountinfo", 65536).splitlines():
        left, separator, right = line.partition(" - ")
        if not separator or right.split()[0] != "cgroup2":
            continue
        fields = left.split()
        root = absolute_parts(mount_path(fields[3]))
        mount = absolute_parts(mount_path(fields[4]))
        if member.is_relative_to(root):
            candidate = Path(str(mount / member.relative_to(root)))
            # Refuse redirected cgroup directories rather than reading another
            # cgroup. Counter files themselves are supplied by cgroupfs.
            if candidate.resolve(strict=True) != candidate:
                raise ValueError("redirected_cgroup")
            candidates.append(candidate)
    if len(candidates) != 1:
        raise ValueError("mount_count")
    return candidates[0]


def error_kind(error):
    if isinstance(error, PermissionError):
        return "permission"
    if isinstance(error, FileNotFoundError):
        return "missing"
    return "invalid_or_unavailable"


def snapshot():
    result = {"schema": 1, "timeUnixNs": time.time_ns(), "memoryKiB": {},
              "cgroup": {"values": {}, "unlimited": [], "events": {}}, "errors": {}}
    try:
        for line in read_bounded("/proc/meminfo", 16384).splitlines():
            fields = line.split()
            if fields[0].rstrip(":") in {"MemTotal", "MemAvailable", "SwapTotal", "SwapFree"}:
                if len(fields) != 3 or fields[2] != "kB" or not fields[1].isdigit():
                    raise ValueError("memory_value")
                result["memoryKiB"][fields[0][:-1]] = int(fields[1])
    except (OSError, ValueError, UnicodeError, IndexError) as error:
        result["errors"]["meminfo"] = error_kind(error)
    for name in ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree"):
        if name not in result["memoryKiB"]:
            result["errors"][name] = "missing"
    try:
        cgroup = calling_cgroup()
    except (OSError, ValueError, UnicodeError, IndexError) as error:
        result["errors"]["cgroup"] = error_kind(error)
        return result
    for name in ("memory.max", "memory.current", "memory.peak", "memory.swap.max", "memory.swap.current"):
        try:
            value = read_bounded(cgroup / name, 128).strip()
            if value == "max" and name.endswith(".max"):
                result["cgroup"]["values"][name] = None
                result["cgroup"]["unlimited"].append(name)
            elif value.isdigit():
                result["cgroup"]["values"][name] = int(value)
            else:
                raise ValueError("counter_value")
        except (OSError, ValueError, UnicodeError) as error:
            result["errors"][name] = error_kind(error)
    try:
        for line in read_bounded(cgroup / "memory.events", 4096).splitlines():
            fields = line.split()
            if fields[0] in {"low", "high", "max", "oom", "oom_kill", "oom_group_kill"}:
                if len(fields) != 2 or not fields[1].isdigit():
                    raise ValueError("event_value")
                result["cgroup"]["events"][fields[0]] = int(fields[1])
    except (OSError, ValueError, UnicodeError, IndexError) as error:
        result["errors"]["memory.events"] = error_kind(error)
    return result


if __name__ == "__main__":
    data = (json.dumps(snapshot(), sort_keys=True) + "\n").encode("ascii")
    if len(data) > 16384:
        raise ValueError("snapshot exceeds fixed artifact bound")
    descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)
