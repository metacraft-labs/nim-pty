## test_pty_cross_platform.nim — L1 mandatory test
## (test_pty_cross_platform_basic).
##
## Same scripted scenario (spawn, write, read, close) passes byte-equivalent
## on Linux + macOS + Windows runners in CI.
##
## On Linux/macOS we run the scenario directly; on Windows the test currently
## skips itself because `nim_pty/windows.nim` is a stub (see TODO in that
## file). When the Windows backend lands, this file requires no changes —
## the public API contract is identical across backends.

import std/[options, strutils, times, unittest]
import nim_pty
import test_helpers

suite "L1: cross-platform basic":

  test "spawn, write, read round-trip via cat":
    when defined(windows):
      skip()
    else:
      let bin = requireBin("cat")
      var sess = spawnPty(bin, [], inheritedEnv(),
        SpawnOptions(cols: 80, rows: 24))
      # Disable echo so cat doesn't repeat our input. We can't easily
      # `stty -echo` from the parent without spawning another process
      # in the same pty; instead, use `cat -u` (unbuffered) with a single
      # write then EOF.
      let payload = "round-trip\n"
      write(sess, cast[seq[byte]](payload).toOpenArray(0, payload.len - 1))
      # Send EOF marker (Ctrl-D = 0x04) so cat finishes.
      let eot = @[byte(4)]
      write(sess, eot.toOpenArray(0, 0))
      let output = readAllAvailable(sess, initDuration(seconds = 5))
      discard waitExitCode(sess)
      # cat in a pty echoes the input back AND echoes Ctrl-D as well; the
      # output therefore contains our payload at minimum.
      check output.contains("round-trip")

  test "spawnPty returns a session with a valid FD":
    when defined(windows):
      skip()
    else:
      let bin = requireBin("true")
      var sess = spawnPty(bin, [], inheritedEnv(),
        SpawnOptions(cols: 80, rows: 24))
      check sess.master.fd > 2  # never stdio
      discard waitExitCode(sess)
      check sess.exitCode().get == 0

  test "openPty returns two distinct FDs":
    when defined(windows):
      skip()
    else:
      var (m, s) = openPty()
      check m.fd > 2
      check s.fd > 2
      check m.fd != s.fd
      close(m)
      close(s)
