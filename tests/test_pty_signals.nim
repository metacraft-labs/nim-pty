## test_pty_signals.nim — L1 mandatory test (test_pty_send_signal).
##
## Verifies that signals delivered via `sendSignal` reach the child and
## propagate through to the recorded exit code. Per POSIX convention,
## a child terminated by signal `N` reports an exit code that we encode
## as `-N` in `PtySession.code` (matching the spec in posix.nim).

import std/[options, posix, strutils, times, unittest]
import nim_pty
import test_helpers

suite "L1: signal delivery":

  test "SIGTERM terminates a sleep":
    let bin = requireBin("sleep")
    var sess = spawnPty(bin, ["10"], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    # Give the child a moment to actually start.
    var ts = Timespec(tv_sec: posix.Time(0), tv_nsec: 50_000_000)
    discard nanosleep(ts, ts)
    sendSignal(sess, SIGTERM)
    let exit = waitExitCode(sess)
    # Signal-induced exit codes are encoded as -signum.
    check exit == -int(SIGTERM)

  test "SIGINT terminates a sleep":
    let bin = requireBin("sleep")
    var sess = spawnPty(bin, ["10"], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    var ts = Timespec(tv_sec: posix.Time(0), tv_nsec: 50_000_000)
    discard nanosleep(ts, ts)
    sendSignal(sess, SIGINT)
    let exit = waitExitCode(sess)
    check exit == -int(SIGINT)

  test "SIGKILL is unblockable":
    let bin = requireBin("sleep")
    var sess = spawnPty(bin, ["10"], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    var ts = Timespec(tv_sec: posix.Time(0), tv_nsec: 50_000_000)
    discard nanosleep(ts, ts)
    sendSignal(sess, SIGKILL)
    let exit = waitExitCode(sess)
    check exit == -int(SIGKILL)

  test "terminate() reaps a stubborn child":
    # The child acknowledges the installed trap before termination begins.
    # exec keeps the stubborn process at the session's actual child PID.
    let shellBin = requireBin("sh")
    const ready = "NIM_PTY_TERM_IGNORED_READY"
    var sess = spawnPty(shellBin,
      ["-c", "trap '' TERM; printf '" & ready & "\n'; exec sleep 30"],
      inheritedEnv(), SpawnOptions(cols: 80, rows: 24))
    defer: terminate(sess)
    let output = readUntil(sess, ready, initDuration(seconds = 5))
    require output.contains(ready)
    terminate(sess)
    check sess.exitCode().isSome
    let code = sess.exitCode().get
    # The acknowledged child ignores SIGTERM, so it must die from SIGKILL.
    check code == -int(SIGKILL)

  test "isAlive reflects child state":
    let bin = requireBin("sleep")
    var sess = spawnPty(bin, ["1"], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    check isAlive(sess)
    sendSignal(sess, SIGTERM)
    discard waitExitCode(sess)
    check (not isAlive(sess))
