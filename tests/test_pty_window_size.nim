## test_pty_window_size.nim — L1 mandatory test.
##
## setWindowSize(p, 100, 40) triggers SIGWINCH in child; child's `stty size`
## reports `40 100`. We use `stty size` as the introspection helper because
## it's universally available and prints "<rows> <cols>".

import std/[strutils, unittest]
import nim_pty
import test_helpers
# `initDuration` from std/times is re-exported by nim_pty.

suite "L1: window size round trip":

  test "stty size reports configured dimensions":
    let bin = requireBin("stty")
    var sess = spawnPty(bin, ["size"], inheritedEnv(),
      SpawnOptions(cols: 100, rows: 40))
    let output = readAllAvailable(sess, initDuration(seconds = 5))
    let exit = waitExitCode(sess)
    check exit == 0
    var clean = output
    clean.removeSuffix({'\r', '\n', ' '})
    # `stty size` prints "<rows> <cols>"
    let parts = clean.splitWhitespace()
    check parts.len == 2
    check parts[0] == "40"
    check parts[1] == "100"

  test "default 80x24":
    let bin = requireBin("stty")
    var sess = spawnPty(bin, ["size"], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    let output = readAllAvailable(sess, initDuration(seconds = 5))
    discard waitExitCode(sess)
    var clean = output
    clean.removeSuffix({'\r', '\n', ' '})
    check clean.contains("24")
    check clean.contains("80")

  test "setWindowSize on a running session updates the live size":
    # Spawn a long-running shell; query stty before and after a resize.
    let shellBin = findBin("sh")
    if shellBin.len == 0:
      skip()
    else:
      var sess = spawnPty(shellBin,
        ["-c", "stty size; sleep 0.2; stty size"],
        inheritedEnv(), SpawnOptions(cols: 80, rows: 24))
      # Wait briefly for the first stty size to print, then resize.
      var early = ""
      while early.splitLines().len < 2:
        let chunk = readBytes(sess, 4096, initDuration(milliseconds = 50))
        if chunk.len > 0:
          early.add(cast[string](chunk))
        else:
          break
      setWindowSize(sess, 132, 50)
      let rest = readAllAvailable(sess, initDuration(seconds = 2))
      discard waitExitCode(sess)
      let total = early & rest
      let lines = total.splitLines()
      var sizes: seq[string] = @[]
      for l in lines:
        let stripped = l.strip()
        if stripped.len > 0 and stripped.splitWhitespace().len == 2:
          sizes.add(stripped)
      check sizes.len >= 2
      if sizes.len >= 2:
        # First measurement: 24 80
        check sizes[0].contains("80")
        check sizes[0].contains("24")
        # Last measurement: 50 132
        check sizes[^1].contains("132")
        check sizes[^1].contains("50")
