## test_pty_spawn_echo.nim — L1 mandatory test.
##
## spawnPty("echo", @["hello"]) writes "hello\n" to the pty; read returns
## "hello\n"; child exits 0.

import std/[unittest, options, strutils, times]
import nim_pty
import test_helpers

suite "L1: spawn + echo round trip":

  test "echo hello":
    let bin = requireBin("echo")
    var sess = spawnPty(bin, ["hello"], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    let output = readAllAvailable(sess, initDuration(seconds = 5))
    let exit = waitExitCode(sess)
    check exit == 0
    # On a pty the child sees a tty so the OS may convert \n to \r\n in the
    # output stream (ONLCR is on by default in cooked mode). Accept either.
    check (output == "hello\n" or output == "hello\r\n")

  test "echo a long line":
    # Round-trip a larger payload to exercise multi-read accumulation.
    let bin = requireBin("printf")
    let payload = "abcdefghijklmnopqrstuvwxyz0123456789" & "X".repeat(200)
    var sess = spawnPty(bin, ["%s\\n", payload], inheritedEnv(),
      SpawnOptions(cols: 200, rows: 24))
    let output = readAllAvailable(sess, initDuration(seconds = 5))
    let exit = waitExitCode(sess)
    check exit == 0
    # The pty in cooked mode line-wraps at column 200 here, but our payload
    # is exactly 236 bytes — still one logical write, possibly with
    # CRLF/LF normalization. Strip CR and trailing whitespace before
    # comparing.
    var clean = output
    clean.removeSuffix({'\r', '\n', ' '})
    let want = payload
    check clean.endsWith(want)

  test "child exit code propagates":
    # Use `false`(1) — exits with status 1 — to verify exit-code plumbing.
    let bin = requireBin("false")
    var sess = spawnPty(bin, [], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    discard readAllAvailable(sess, initDuration(milliseconds = 500))
    let exit = waitExitCode(sess)
    check exit == 1

  test "exitCode returns none while running, some when done":
    let bin = requireBin("sleep")
    var sess = spawnPty(bin, ["0.2"], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    check sess.exitCode().isNone
    discard readAllAvailable(sess, initDuration(seconds = 2))
    check sess.exitCode().isSome
    check sess.exitCode().get == 0

