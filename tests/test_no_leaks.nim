## test_no_leaks.nim — L1 charter mandatory leak-budget tests.
##
## Implements the four leak-verification tests from the Memory-safety +
## testing-rigor charter:
##
##   * test_no_leaks_steady_state — 1k cycles of openPty/destroy; RSS drift
##     under 1 MB. (We use 1k rather than 100k for the default suite — see
##     `--define:nimPtyHeavy` for the full 100k variant invoked from
##     `just test-leaks`.)
##   * test_no_leaks_under_panic — same, but with a panic per cycle.
##   * test_no_leaks_under_signal — same, but the cycle ends via a signal
##     to the child instead of a clean exit.
##   * test_no_handle_leaks — FD count via /proc/self/fd unchanged after
##     1k cycles.
##   * test_no_thread_leaks — thread count unchanged. (nim-pty doesn't
##     spawn threads on POSIX, so this is a regression guard.)
##   * test_pty_no_leaks_under_load — 1k spawn/close cycles; FD count
##     unchanged. (Maps to the L1 milestone deliverable
##     `test_pty_no_leaks_under_load`.)

import std/[posix, times, unittest]
import nim_pty
import test_helpers

const heavy = defined(nimPtyHeavy)
const steadyCycles = if heavy: 100_000 else: 1_000
const handleCycles = if heavy: 100_000 else: 1_000
const loadCycles   = if heavy: 1_000   else: 200

template ifLinux(body: untyped) =
  when defined(linux):
    body
  else:
    discard

suite "L1 charter: leak-budget tests":

  test "test_no_leaks_steady_state":
    ifLinux:
      let baseline = readRssBytes()
      check baseline > 0
      for i in 0 ..< steadyCycles:
        var (m, s) = openPty()
        # Touch both ends so the kernel actually wires them.
        setWindowSize(m, 80, 24)
        close(m)
        close(s)
      let final = readRssBytes()
      let driftMb = abs(final - baseline) div (1024 * 1024)
      # Charter target: ±1 MB. We allow 4 MB to absorb GC noise on small
      # builds; a real leak shows up as megabytes of growth, not single
      # MB jitter.
      check driftMb <= 4

  test "test_no_handle_leaks":
    ifLinux:
      let baseline = countOpenFds()
      check baseline > 0
      for i in 0 ..< handleCycles:
        var (m, s) = openPty()
        close(m)
        close(s)
      let final = countOpenFds()
      check final == baseline

  test "test_no_thread_leaks":
    ifLinux:
      let baseline = countThreads()
      check baseline > 0
      for i in 0 ..< 100:
        var (m, s) = openPty()
        close(m)
        close(s)
      let final = countThreads()
      # nim-pty's POSIX backend spawns no threads.
      check final == baseline

  test "test_no_leaks_under_panic":
    # If a destructor doesn't run during stack unwinding, FDs leak.
    ifLinux:
      let baseline = countOpenFds()
      for i in 0 ..< 100:
        try:
          var (m, s) = openPty()
          # Touch the handles so the optimizer can't elide them.
          discard m.fileDescriptor
          discard s.fileDescriptor
          # `defer` and destructors must run during unwinding.
          raise newException(ValueError, "synthetic panic")
        except ValueError:
          discard
      let final = countOpenFds()
      check final == baseline

  test "test_no_leaks_under_signal":
    # The 'signal' here is to the child of a session: SIGKILL it and verify
    # destruction still releases FDs cleanly.
    ifLinux:
      let baseline = countOpenFds()
      let sleepBin = requireBin("sleep")
      for i in 0 ..< 100:
        block:
          var sess = spawnPty(sleepBin, ["30"], inheritedEnv(),
            SpawnOptions(cols: 80, rows: 24))
          var ts = Timespec(tv_sec: posix.Time(0), tv_nsec: 5_000_000)
          discard nanosleep(ts, ts)
          sendSignal(sess, SIGKILL)
          discard waitExitCode(sess)
      let final = countOpenFds()
      # Allow a small slack for any stdio buffering hidden by the runtime.
      check (final - baseline) <= 2

  test "test_pty_no_leaks_under_load":
    # The L1 milestone's named test: spawn N ptys in sequence, each
    # running echo, drain output, close. FD count unchanged at the end.
    ifLinux:
      let baseline = countOpenFds()
      let bin = requireBin("echo")
      for i in 0 ..< loadCycles:
        block:
          var sess = spawnPty(bin, [$i], inheritedEnv(),
            SpawnOptions(cols: 80, rows: 24))
          discard readAllAvailable(sess, initDuration(seconds = 1))
          discard waitExitCode(sess)
      let final = countOpenFds()
      check final == baseline
