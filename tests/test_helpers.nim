## test_helpers.nim — shared utilities for nim-pty integration tests.
##
## Every test in this repo uses real ptys + real subprocesses (per the no-mocks
## charter). This module collects the bits every test needs:
##
##   * `findBin(name)` — locate a binary via $PATH WITHOUT resolving its
##     symlink, so multiplexers like NixOS's `coreutils` dispatch on argv[0].
##   * `readUntil` — drain a session until a substring appears or a timeout
##     elapses; useful for waiting on shell prompts and child output.
##   * `inheritedEnv` — copy the parent's environment into the
##     `openArray[(string, string)]` shape `spawnPty` accepts. Tests almost
##     always want PATH at minimum.
##   * `RssReader` / `FdReader` — process self-introspection used by the
##     leak-budget tests.

import std/[monotimes, os, strutils, times]
import nim_pty

proc findBin*(name: string): string =
  ## Return the first $PATH entry containing an executable named `name`,
  ## without resolving symlinks. Falls back to `/bin/<name>` and
  ## `/usr/bin/<name>` for portability.
  let pathEnv = getEnv("PATH")
  for dir in pathEnv.split(':'):
    if dir.len == 0: continue
    let candidate = dir / name
    if fileExists(candidate):
      return candidate
  for fallback in ["/bin/" & name, "/usr/bin/" & name]:
    if fileExists(fallback):
      return fallback
  return ""

proc requireBin*(name: string): string =
  let p = findBin(name)
  if p.len == 0:
    raise newException(IOError, "required test binary not found in PATH: " & name)
  return p

proc inheritedEnv*(): seq[(string, string)] =
  result = @[]
  for k, v in envPairs():
    result.add((k, v))

proc readUntil*(s: var PtySession;
                needle: string;
                timeout: Duration): string =
  ## Keep reading until `needle` appears in the accumulated output or the
  ## timeout elapses. Returns whatever has been received so far.
  let deadline = getMonoTime() + timeout
  var acc = ""
  while getMonoTime() < deadline:
    let remaining = deadline - getMonoTime()
    let chunk = readBytes(s, 4096, remaining)
    if chunk.len == 0:
      # EOF or timeout window
      if not isAlive(s):
        return acc
      continue
    acc.add(cast[string](chunk))
    if acc.contains(needle):
      return acc
  return acc

proc readAllAvailable*(s: var PtySession;
                       timeout: Duration): string =
  ## Read until EOF or the timeout elapses, returning the concatenated
  ## output. Useful for short-lived child processes.
  let deadline = getMonoTime() + timeout
  result = ""
  while getMonoTime() < deadline:
    let remaining = deadline - getMonoTime()
    let chunk = readBytes(s, 4096, remaining)
    if chunk.len == 0:
      if not isAlive(s):
        return result
      continue
    result.add(cast[string](chunk))

# ---------------------------------------------------------------------------
# Process introspection — used by the leak-budget tests.
# ---------------------------------------------------------------------------

proc readRssBytes*(): int =
  ## Resident-set-size of the current process in bytes. Linux-only; returns
  ## 0 if /proc isn't available (macOS / non-Linux). Tests that depend on
  ## this skip themselves on platforms where it returns 0.
  when defined(linux):
    let path = "/proc/self/status"
    if not fileExists(path):
      return 0
    for line in lines(path):
      if line.startsWith("VmRSS:"):
        let parts = line.splitWhitespace()
        if parts.len >= 3:
          # Format: "VmRSS:  12345 kB"
          try:
            return parseInt(parts[1]) * 1024
          except CatchableError:
            return 0
    return 0
  else:
    return 0

proc countOpenFds*(): int =
  ## Number of file descriptors currently open by this process. Linux-only
  ## (counts /proc/self/fd entries). On macOS we'd need lsof or
  ## proc_pidinfo; tests requiring this skip on non-Linux.
  when defined(linux):
    let dir = "/proc/self/fd"
    if not dirExists(dir):
      return -1
    var n = 0
    for kind, _ in walkDir(dir):
      if kind in {pcFile, pcLinkToFile, pcDir, pcLinkToDir}:
        inc n
    return n
  else:
    return -1

proc countThreads*(): int =
  ## Number of threads in this process. Linux-only.
  when defined(linux):
    let dir = "/proc/self/task"
    if not dirExists(dir):
      return -1
    var n = 0
    for _, _ in walkDir(dir):
      inc n
    return n
  else:
    return -1
