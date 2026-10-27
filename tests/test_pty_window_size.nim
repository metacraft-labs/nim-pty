## test_pty_window_size.nim — L1 mandatory test.
##
## setWindowSize(p, 100, 40) triggers SIGWINCH in child; child's `stty size`
## reports `40 100`. We use `stty size` as the introspection helper because
## it's universally available and prints "<rows> <cols>".

import std/[monotimes, strutils, unittest]
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
    # No mock: a real shell/stty and actual PTY stdin establish ordering.
    # Disable real terminal echo so only the two exact geometry lines appear.
    let shellBin = requireBin("sh")
    let deadline = getMonoTime() + initDuration(seconds = 2)
    var sess = spawnPty(shellBin,
      ["-c", "stty -echo; stty size; IFS= read -r marker; [ \"$marker\" = resized ] || exit 7; exec stty size"],
      inheritedEnv(), SpawnOptions(cols: 80, rows: 24))
    try:
      var pending = ""
      proc nextLine(): string =
        while '\n' notin pending:
          doAssert getMonoTime() < deadline, "PTY resize transaction exceeded its original two-second budget"
          let remaining = deadline - getMonoTime()
          let slice = min(remaining, initDuration(milliseconds = 50))
          let chunk = readBytes(sess, 4096, slice)
          pending.add(cast[string](chunk))
        let ending = pending.find('\n')
        result = pending[0 ..< ending]
        result.removeSuffix('\r')
        pending = pending[ending + 1 .. ^1]
      doAssert nextLine() == "24 80", "initial PTY geometry must precede resize"
      setWindowSize(sess, 132, 50)
      write(sess, cast[seq[byte]]("resized\n"))
      let observedResize = nextLine()
      doAssert observedResize == "50 132", "child must observe the exact live resize; observed=" & repr(observedResize)
      while isAlive(sess):
        doAssert getMonoTime() < deadline, "child did not exit within the resize transaction"
        let remaining = deadline - getMonoTime()
        let chunk = readBytes(sess, 4096, min(remaining, initDuration(milliseconds = 50)))
        pending.add(cast[string](chunk))
      doAssert pending.len == 0, "unexpected output after the geometry protocol"
      check waitExitCode(sess) == 0
    finally:
      try:
        terminate(sess)
      finally:
        close(sess)
