## test_pty_inherited_fds.nim — the child of `spawnPty` inherits no descriptor
## of the parent's beyond its stdio.
##
## The defect it guards: a pipe the parent opened WITHOUT `CLOEXEC` (as Nim's
## osproc opens a child's stdout) was inherited by the pty's child. A parent
## that closes its own write end and reads the pipe to EOF then waited for the
## pty's child to exit, since that child held the write end too — in CodeTracer
## a GPUI window reading `git status` hung for as long as its Shell pane's shell
## lived. No mock: a real pipe, a real pty, a real child (`sleep`).

import std/[monotimes, posix, times, unittest]
import nim_pty
import test_helpers

suite "the pty's child holds none of the parent's descriptors":

  test "a pipe opened without CLOEXEC reaches EOF while the child runs":
    var fds: array[2, cint]
    check pipe(fds) == 0
    let bin = requireBin("sleep")
    # The child lives well past the budget below: with the write end
    # inherited, the read would wait for it.
    var sess = spawnPty(bin, ["5"], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    check fds[1] >= 3
    discard close(fds[1])
    var pfd = TPollfd(fd: fds[0], events: POLLIN)
    let started = getMonoTime()
    let ready = poll(addr pfd, 1, 2000)
    var buf: array[16, char]
    let n = (if ready == 1: read(fds[0], addr buf[0], buf.len) else: -1)
    check ready == 1                       # readable: EOF, not a timeout
    check n == 0                           # and it is EOF, not data
    check getMonoTime() - started < initDuration(milliseconds = 1500)
    discard close(fds[0])
    sess.terminate()
    discard waitExitCode(sess)
