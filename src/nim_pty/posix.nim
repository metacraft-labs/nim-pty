## nim_pty/posix.nim — POSIX backend for nim-pty.
##
## This module wraps the platform's pseudo-terminal primitives: openpty(3),
## forkpty(3), termios manipulation, TIOCSWINSZ, and child-process control via
## kill(2)/waitpid(2). It exposes a small set of value-typed handles whose
## destructors release every OS resource they own — there is no "remember to
## call close()" footgun.
##
## Public-API rules (charter §1):
##   * Public types are value `object`, never `ref object`.
##   * `=copy` is disabled on every owning handle so that ownership is unique.
##     Callers move handles via `=sink` or pass them by `var`.
##   * `=destroy` is the single resource-release path; explicit `close*` procs
##     are convenience wrappers that just invoke the destructor logic.
##   * No raw `ptr` is exposed. FFI internals use `ptr cchar`/`cint` at the C
##     boundary and translate to `string`/`seq[byte]` for Nim callers.
##
## All FFI declarations live at the top of the module so the rest of the file
## reads as ordinary Nim. The module is `{.push raises: [].}`-clean inside —
## OS errors are translated into `OSError` exceptions at the public seam only.

{.push hint[XDeclaredButNotUsed]: off.}

import std/[options, posix, times]
import std/oserrors

# ---------------------------------------------------------------------------
# FFI declarations
# ---------------------------------------------------------------------------
#
# `openpty`, `forkpty`, `login_tty`, and `cfmakeraw` live in <pty.h> (Linux
# glibc) and <util.h> (BSD/macOS). The Nim importc block selects the right
# header at compile time.

when defined(linux):
  const ptyHeader = "<pty.h>"
elif defined(macosx) or defined(bsd):
  const ptyHeader = "<util.h>"
else:
  const ptyHeader = "<pty.h>"

type
  WinsizeC {.importc: "struct winsize", header: "<sys/ioctl.h>",
             pure, final.} = object
    ws_row: cushort
    ws_col: cushort
    ws_xpixel: cushort
    ws_ypixel: cushort

var
  TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong
  TIOCGWINSZ {.importc, header: "<sys/ioctl.h>".}: culong

proc cOpenpty(amaster, aslave: ptr cint;
              name: ptr cchar;
              termp, winp: pointer): cint
  {.importc: "openpty", header: ptyHeader.}

# `forkpty(3)` exists in pty.h but we don't call it — see the comment block
# above `spawnPty` for why we hand-roll the fork-and-exec sequence. Leave
# it documented here as a reference.
#
# proc cForkpty(amaster: ptr cint; name: ptr cchar; termp, winp: pointer): Pid
#   {.importc: "forkpty", header: ptyHeader.}

proc cIoctl(fd: cint; request: culong): cint
  {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

proc cFcntl(fd: cint; cmd: cint): cint
  {.importc: "fcntl", header: "<fcntl.h>", varargs.}

proc cExecve(path: cstring;
             argv: cstringArray;
             envp: cstringArray): cint
  {.importc: "execve", header: "<unistd.h>".}

proc cExit(status: cint) {.importc: "_exit", header: "<unistd.h>".}

var
  F_GETFD {.importc, header: "<fcntl.h>".}: cint
  F_SETFD {.importc, header: "<fcntl.h>".}: cint
  FD_CLOEXEC {.importc, header: "<fcntl.h>".}: cint
  EAGAIN {.importc, header: "<errno.h>".}: cint

# ---------------------------------------------------------------------------
# Errors and small helpers
# ---------------------------------------------------------------------------

type
  PtyError* = object of CatchableError
    ## Raised for any pty-related failure that surfaces to user code.

proc raiseOSError(ctx: string) {.noreturn.} =
  let e = osLastError()
  raise newException(PtyError,
    ctx & ": " & osErrorMsg(e) & " (errno=" & $int(e) & ")")

proc closeFdQuiet(fd: var cint) =
  ## Best-effort close. Used in destructors where exceptions must not escape.
  if fd >= 0:
    discard close(fd)
    fd = -1

# ---------------------------------------------------------------------------
# PtyHandle — owning wrapper for a single pty file descriptor
# ---------------------------------------------------------------------------

type
  PtyHandle* = object
    ## Owns a single pty FD (master or slave). Released by `=destroy`.
    ##
    ## NB: a *default-initialised* `PtyHandle` (e.g. inside a freshly
    ## allocated `result` slot) must NOT look like it owns FD 0 — otherwise
    ## the destructor would close stdin when the slot is overwritten. We
    ## therefore keep `fd` defaulting to 0 and rely on the `closed` flag
    ## (which IS `false` by default but the destructor also checks `fd > 0`,
    ## see `=destroy`). In practice every `PtyHandle` is either constructed
    ## via `openPty` (fd > 2 always) or received from a `=sink`/`=move`,
    ## so fd 0 ends up reserved for "uninitialised".
    fd*: cint
    closed*: bool

proc `=copy`*(dest: var PtyHandle; src: PtyHandle) {.error.}
  ## Pty FDs have unique ownership. Use `move` / `sink` parameters to transfer.

when defined(gcDestructors):
  proc `=destroy`*(h: PtyHandle) =
    ## Close the FD if it is still open. Safe to call on a moved-from handle.
    ##
    ## NB: we deliberately use `h.fd > 2` as the lower bound, NOT `>= 0`. This
    ## prevents a default-initialised handle (fd == 0, closed == false) from
    ## closing stdin/stdout/stderr when a destructor runs against the implicit
    ## `result` slot before its first real assignment. nim-pty never owns the
    ## standard FDs — every real pty FD is well above 2.
    if not h.closed and h.fd > 2:
      discard close(h.fd)
else:
  # Legacy signature for refc — required because Nim 2.2's =destroy hooks
  # were redefined to take `T` rather than `var T` only when gcDestructors
  # is active (arc/orc). Under refc the older `var T` signature is enforced.
  proc `=destroy`*(h: var PtyHandle) =
    if not h.closed and h.fd > 2:
      discard close(h.fd)

proc isOpen*(h: PtyHandle): bool {.inline.} =
  not h.closed and h.fd >= 0

proc fileDescriptor*(h: PtyHandle): cint {.inline.} =
  ## Read-only access to the underlying FD for advanced callers (e.g.
  ## select/poll integration). Do NOT close this FD yourself — let the
  ## handle's destructor do it.
  h.fd

proc close*(h: var PtyHandle) =
  ## Explicitly release the FD. Idempotent; the destructor will not
  ## double-close. Refuses to close FDs 0/1/2 — see `=destroy` for rationale.
  if not h.closed:
    if h.fd > 2:
      closeFdQuiet(h.fd)
    h.closed = true

proc setCloexec(fd: cint) =
  ## Mark the FD close-on-exec so child processes don't inherit the master.
  let flags = cFcntl(fd, F_GETFD)
  if flags == -1:
    raiseOSError("fcntl(F_GETFD)")
  if cFcntl(fd, F_SETFD, flags or FD_CLOEXEC) == -1:
    raiseOSError("fcntl(F_SETFD, FD_CLOEXEC)")

proc setNonblock*(h: var PtyHandle) =
  ## Switch the FD to non-blocking mode. Only the master side ever needs
  ## this; the slave belongs to the child process.
  let flags = cFcntl(h.fd, F_GETFL)
  if flags == -1:
    raiseOSError("fcntl(F_GETFL)")
  if cFcntl(h.fd, F_SETFL, flags or O_NONBLOCK) == -1:
    raiseOSError("fcntl(F_SETFL, O_NONBLOCK)")

proc setWindowSize*(h: var PtyHandle; cols, rows: int) =
  ## TIOCSWINSZ on the master sends SIGWINCH to the foreground process group
  ## of the slave. Both `cols` and `rows` must fit in `cushort` (the kernel
  ## structure is 16-bit per dimension); validate and translate.
  if cols < 0 or cols > int(high(cushort)):
    raise newException(PtyError, "cols out of range: " & $cols)
  if rows < 0 or rows > int(high(cushort)):
    raise newException(PtyError, "rows out of range: " & $rows)
  var ws = WinsizeC(
    ws_row: cushort(rows),
    ws_col: cushort(cols),
    ws_xpixel: 0,
    ws_ypixel: 0)
  if cIoctl(h.fd, TIOCSWINSZ, addr ws) == -1:
    raiseOSError("ioctl(TIOCSWINSZ)")

proc getWindowSize*(h: PtyHandle): tuple[cols, rows: int] =
  var ws = WinsizeC()
  if cIoctl(h.fd, TIOCGWINSZ, addr ws) == -1:
    raiseOSError("ioctl(TIOCGWINSZ)")
  (cols: int(ws.ws_col), rows: int(ws.ws_row))

# ---------------------------------------------------------------------------
# openPty — pure pty allocation (no fork)
# ---------------------------------------------------------------------------

proc openPty*(): tuple[master, slave: PtyHandle] =
  ## Allocate a master/slave pty pair via `openpty(3)`. Both FDs are marked
  ## close-on-exec; callers that hand the slave to a child must dup it onto
  ## stdin/stdout/stderr (the kernel clears CLOEXEC on dup) or use the
  ## higher-level `spawnPty`.
  var m, s: cint = -1
  if cOpenpty(addr m, addr s, nil, nil, nil) == -1:
    raiseOSError("openpty")
  try:
    setCloexec(m)
    setCloexec(s)
  except CatchableError:
    discard close(m)
    discard close(s)
    raise
  result = (master: PtyHandle(fd: m, closed: false),
            slave:  PtyHandle(fd: s, closed: false))

# ---------------------------------------------------------------------------
# spawnPty — fork + exec inside a fresh pty
# ---------------------------------------------------------------------------
#
# We deliberately reimplement forkpty's logic in Nim rather than calling
# `forkpty(3)` because:
#   1. We want to install our own initial window size before exec.
#   2. We want the parent to retain a non-CLOEXEC master while the child's
#      slave becomes its controlling terminal.
#   3. forkpty's name-buffer parameter is awkward in safe Nim.
#
# Implementation outline (per APUE §19.4 and OpenSSH's ptyfork.c):
#   - openpty()
#   - fork()
#   - child: setsid(); ioctl(slave, TIOCSCTTY); dup slave→0/1/2; close master;
#            execve(argv, envp); _exit(127) on failure.
#   - parent: close slave; remember master + child PID.
#
# `setsid` + `TIOCSCTTY` are essential — without them job control inside the
# pty is broken.

var
  TIOCSCTTY {.importc, header: "<sys/ioctl.h>".}: culong

type
  ExitState* = enum
    ## Tracks whether `waitpid` has reaped the child. Plain `Option[int]`
    ## isn't enough — we need to remember "alive" vs "exited" vs "reaped".
    esRunning, esExited, esReaped

  PtySession* = object
    ## Owns the master FD of a spawned child plus the child's PID.
    ## `=destroy` reaps the child (sending SIGKILL if still alive) and
    ## releases the FD.
    master*: PtyHandle
    pid*: Pid
    state*: ExitState
    code*: int  ## Exit status (filled in once `state == esReaped`).

  SpawnOptions* = object
    ## Optional spawn-time configuration. Defaults are sensible for "run a
    ## program inside a fresh pty and capture its output".
    cols*: int
    rows*: int
    cwd*: string  ## Empty string means "inherit parent CWD".

proc `=copy`*(dest: var PtySession; src: PtySession) {.error.}

proc reapNonblocking(s: var PtySession) =
  ## Try waitpid(WNOHANG); if the child has exited, capture its status.
  if s.state != esRunning:
    return
  var status: cint
  let r = waitpid(s.pid, status, WNOHANG)
  if r == 0:
    return
  if r == -1:
    let e = osLastError()
    # ECHILD means we already reaped or the child never existed.
    if cint(e) == ECHILD:
      s.state = esReaped
      return
    return
  # r == s.pid → child has changed state and we've reaped it.
  s.state = esReaped
  if WIFEXITED(status):
    s.code = int(WEXITSTATUS(status))
  elif WIFSIGNALED(status):
    s.code = -int(WTERMSIG(status))
  else:
    s.code = -1

proc reapBlocking(s: var PtySession) =
  if s.state != esRunning:
    return
  var status: cint
  while true:
    let r = waitpid(s.pid, status, cint(0))
    if r == s.pid:
      s.state = esReaped
      if WIFEXITED(status):
        s.code = int(WEXITSTATUS(status))
      elif WIFSIGNALED(status):
        s.code = -int(WTERMSIG(status))
      else:
        s.code = -1
      return
    if r == -1:
      let e = osLastError()
      if cint(e) == EINTR:
        continue
      if cint(e) == ECHILD:
        s.state = esReaped
        return
      return

template ptySessionDestroyBody(s: untyped) =
  ## Shared body for the two destructor signatures (gcDestructors vs refc).
  ##
  ## Destructor strategy:
  ##   1. If the child is still running, send SIGHUP — most well-behaved
  ##      programs (shells, editors, REPLs) exit cleanly on SIGHUP.
  ##   2. Try a non-blocking waitpid for ~250ms.
  ##   3. If the child still hasn't exited, send SIGKILL and block on
  ##      waitpid. SIGKILL cannot be ignored.
  ##   4. Close the master FD.
  ##
  ## Defensive check: a default-initialised PtySession has pid==0,
  ## state==esRunning. Treat pid <= 0 as "no child" to avoid sending signals
  ## to ourselves or the whole process group when destructing a zero-init
  ## slot.
  if s.state == esRunning and s.pid > 0:
    # Send SIGHUP first.
    discard kill(s.pid, SIGHUP)
    var status: cint
    var waited = 0
    var reaped = false
    while waited < 25:  # 25 * 10ms = 250ms
      let r = waitpid(s.pid, status, WNOHANG)
      if r == s.pid or r == -1:
        reaped = true
        break
      # Sleep 10ms.
      var ts = Timespec(tv_sec: posix.Time(0), tv_nsec: 10_000_000)
      discard nanosleep(ts, ts)
      inc waited
    if not reaped:
      discard kill(s.pid, SIGKILL)
      while true:
        let r = waitpid(s.pid, status, cint(0))
        if r == s.pid or r == -1:
          break
  if not s.master.closed and s.master.fd > 2:
    discard close(s.master.fd)

when defined(gcDestructors):
  proc `=destroy`*(s: PtySession) =
    ptySessionDestroyBody(s)
else:
  proc `=destroy`*(s: var PtySession) =
    ptySessionDestroyBody(s)

proc spawnPty*(cmd: string;
               args: openArray[string];
               env: openArray[(string, string)];
               opts: SpawnOptions = SpawnOptions(cols: 80, rows: 24)):
              PtySession =
  ## Fork a child running `cmd` with `args`, attach it to a fresh pty whose
  ## master is owned by the returned `PtySession`. The slave side is dup'd
  ## onto the child's stdin/stdout/stderr.
  ##
  ## `env` is passed as an `openArray[(string, string)]` so callers don't
  ## need to allocate a `Table`. The child sees ONLY these variables — if
  ## you want to inherit the parent environment, pass `os.envPairs()`.
  var pair = openPty()
  let masterFd = pair.master.fd
  let slaveFd = pair.slave.fd
  # The child will own the slave; the parent only ever needs the master.
  # We mark the slave as inheritable below by simply not setting CLOEXEC
  # before fork. We already set CLOEXEC in openPty; clear it on the slave
  # and rely on dup() to clear it on the duplicated FDs anyway.
  block:
    let flags = cFcntl(slaveFd, F_GETFD)
    if flags >= 0:
      discard cFcntl(slaveFd, F_SETFD, flags and (not FD_CLOEXEC))

  # Build argv/envp before forking (after fork(), only async-signal-safe
  # functions are allowed and Nim's GC isn't safe to use).
  var argvBuf: seq[string] = @[cmd]
  for a in args: argvBuf.add(a)
  var envBuf: seq[string] = @[]
  for kv in env:
    envBuf.add(kv[0] & "=" & kv[1])

  # Marshal to C string arrays. `cstringArray` allocates on the Nim heap and
  # must be released with `deallocCStringArray` — but only in the parent;
  # the child replaces its address space with execve so its leak is moot.
  var argv = allocCStringArray(argvBuf)
  var envp = allocCStringArray(envBuf)

  let cmdC = cstring(cmd)

  # fork()
  let pid = fork()
  if pid == -1:
    deallocCStringArray(argv)
    deallocCStringArray(envp)
    raiseOSError("fork")

  if pid == 0:
    # ----- child -----
    # Be conservative: only call async-signal-safe functions until execve.
    # Close the master copy; the child must not retain it.
    discard close(masterFd)
    # Become session leader and acquire the slave as the controlling tty.
    if setsid() == -1:
      cExit(127)
    if cIoctl(slaveFd, TIOCSCTTY, cint(0)) == -1:
      # Some kernels (older Darwin) require argument 0; the importc varargs
      # signature handles either form. If TIOCSCTTY fails we still try to
      # exec — the program will run, just without job control.
      discard
    # Wire stdio.
    if dup2(slaveFd, 0) == -1: cExit(127)
    if dup2(slaveFd, 1) == -1: cExit(127)
    if dup2(slaveFd, 2) == -1: cExit(127)
    if slaveFd > 2:
      discard close(slaveFd)
    # cwd
    if opts.cwd.len > 0:
      if chdir(cstring(opts.cwd)) != 0:
        cExit(127)
    # exec — argv is null-terminated by allocCStringArray.
    discard cExecve(cmdC, argv, envp)
    cExit(127)
    # unreachable

  # ----- parent -----
  deallocCStringArray(argv)
  deallocCStringArray(envp)
  # Parent doesn't need the slave end.
  discard close(slaveFd)
  pair.slave.fd = -1
  pair.slave.closed = true
  # Initial window size.
  try:
    setWindowSize(pair.master, opts.cols, opts.rows)
  except CatchableError:
    # Window size is best-effort; many child programs don't care.
    discard
  result = PtySession(
    master: PtyHandle(fd: pair.master.fd, closed: false),
    pid: pid,
    state: esRunning,
    code: 0)
  pair.master.fd = -1
  pair.master.closed = true

# ---------------------------------------------------------------------------
# I/O on a session
# ---------------------------------------------------------------------------

proc read*(s: var PtySession;
           buf: var openArray[byte];
           timeout: Duration): int =
  ## Read up to `buf.len` bytes from the master FD. Blocks for up to
  ## `timeout`. Returns:
  ##   * `>0`  — number of bytes read
  ##   * `0`   — EOF (child closed all references to the slave)
  ##   * `-1`  — timeout elapsed with no data available
  ##
  ## Implementation uses `select(2)`. We avoid `poll` to maximize portability
  ## across legacy POSIX systems that participate in the test matrix.
  if buf.len == 0:
    return 0
  let fd = s.master.fd
  if fd < 0:
    raise newException(PtyError, "session master is closed")

  # Build timeval. negative timeout means wait forever; zero means poll.
  var tv: Timeval
  let useTimeout = timeout.inMilliseconds >= 0
  if useTimeout:
    tv.tv_sec = posix.Time(timeout.inSeconds)
    let ms = timeout.inMilliseconds - timeout.inSeconds * 1000
    tv.tv_usec = clong(ms * 1000)

  var rs: TFdSet
  FD_ZERO(rs)
  FD_SET(fd, rs)
  let n = if useTimeout: select(fd + 1, addr rs, nil, nil, addr tv)
          else:          select(fd + 1, addr rs, nil, nil, nil)
  if n == 0:
    # Maybe the child died exactly now — try to reap.
    reapNonblocking(s)
    return -1
  if n == -1:
    let e = osLastError()
    if cint(e) == EINTR:
      return -1
    raiseOSError("select")
  # Data is ready (or EOF).
  let got = read(fd, addr buf[0], buf.len)
  if got == -1:
    let e = osLastError()
    if cint(e) == EAGAIN or cint(e) == EINTR:
      return -1
    # On Linux, when the slave end has been fully closed (child exited and
    # all references dropped), `read` on the master returns EIO. Treat that
    # as a clean EOF — the child's output stream is over.
    if cint(e) == EIO:
      reapNonblocking(s)
      return 0
    raiseOSError("read")
  if got == 0:
    reapNonblocking(s)
  return got

proc write*(s: var PtySession; data: openArray[byte]) =
  ## Write all of `data` to the master FD, retrying on partial writes. Raises
  ## `PtyError` if the child has closed its end (EIO on Linux, EBADF on
  ## macOS) or any other write error occurs.
  if data.len == 0:
    return
  if s.master.fd < 0:
    raise newException(PtyError, "session master is closed")
  var written = 0
  while written < data.len:
    # cast: reinterpret the openArray's base address as an indexable byte
    # buffer so we can offset by `written` for the partial-write retry path.
    # The libc `write(2)` FFI takes a raw `pointer`, and openArray itself
    # has no pointer-arithmetic operator.
    let n = write(s.master.fd,
                  addr cast[ptr UncheckedArray[byte]](addr data[0])[written],
                  data.len - written)
    if n == -1:
      let e = osLastError()
      if cint(e) == EINTR:
        continue
      raiseOSError("write")
    written += n

proc sendSignal*(s: var PtySession; sig: cint) =
  ## Send a POSIX signal to the child process. No-op if the child has
  ## already been reaped.
  if s.state != esRunning:
    return
  if kill(s.pid, sig) == -1:
    let e = osLastError()
    if cint(e) == ESRCH:
      # Already gone; reap.
      reapNonblocking(s)
      return
    raiseOSError("kill")

proc terminate*(s: var PtySession) =
  ## Cross-platform "make it stop". On POSIX we send SIGTERM, then SIGKILL
  ## if the child doesn't exit within ~250ms.
  if s.state != esRunning:
    return
  discard kill(s.pid, SIGTERM)
  var waited = 0
  while waited < 25:
    reapNonblocking(s)
    if s.state == esReaped:
      return
    var ts = Timespec(tv_sec: posix.Time(0), tv_nsec: 10_000_000)
    discard nanosleep(ts, ts)
    inc waited
  discard kill(s.pid, SIGKILL)
  reapBlocking(s)

proc isAlive*(s: var PtySession): bool =
  reapNonblocking(s)
  s.state == esRunning

proc exitCode*(s: var PtySession): Option[int] =
  ## Return the child's exit code if it has terminated; otherwise `none`.
  ## Does NOT block. Use `waitExitCode` for the blocking flavor.
  reapNonblocking(s)
  if s.state == esReaped:
    return some(s.code)
  return none(int)

proc waitExitCode*(s: var PtySession): int =
  reapBlocking(s)
  s.code

proc setWindowSize*(s: var PtySession; cols, rows: int) =
  setWindowSize(s.master, cols, rows)

proc getWindowSize*(s: PtySession): tuple[cols, rows: int] =
  getWindowSize(s.master)

proc fileDescriptor*(s: PtySession): cint {.inline.} =
  s.master.fd

proc close*(s: var PtySession) =
  ## Reap the child if necessary and close the master FD. Idempotent.
  if s.state == esRunning and s.pid > 0:
    discard kill(s.pid, SIGHUP)
    reapBlocking(s)
  if not s.master.closed and s.master.fd > 2:
    closeFdQuiet(s.master.fd)
    s.master.closed = true

# ---------------------------------------------------------------------------
# Convenience: read into a seq[byte]
# ---------------------------------------------------------------------------

proc readBytes*(s: var PtySession;
                maxBytes: int;
                timeout: Duration): seq[byte] =
  ## Convenience wrapper that allocates a `seq[byte]` of the right length.
  ## Returns `@[]` on timeout/EOF.
  if maxBytes <= 0:
    return @[]
  result = newSeq[byte](maxBytes)
  let n = read(s, result, timeout)
  if n <= 0:
    result.setLen(0)
  else:
    result.setLen(n)

# Re-export a few symbols that tests want to reference without re-deriving.
export options, times
{.pop.}
