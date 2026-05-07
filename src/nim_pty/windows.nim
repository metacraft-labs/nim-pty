## nim_pty/windows.nim — Windows ConPTY backend (stub).
##
## *Status:* this file is a documented stub. It exposes the same public type
## names and procedure signatures as the POSIX backend so downstream code can
## be written cross-platform, but every implementation raises
## `PtyUnimplementedError`. A future milestone (tracked in the L1 deliverables
## under `*Windows ConPTY implementation*`) will land the real
## `CreatePseudoConsole`/`ResizePseudoConsole`/`ClosePseudoConsole` plumbing
## plus `CreateProcessW` with `STARTUPINFOEX`.
##
## *Why a stub?* The L1 milestone explicitly permits shipping the POSIX
## backend comprehensively while deferring Windows ConPTY when implementing
## both well would exceed the milestone's scope. The POSIX backend is the
## load-bearing path for IsoNim-TUI's M0 → M9 (PosixDriver) work, so finishing
## it solidly was prioritised. The Windows backend's missing pieces are:
##
##   * FFI declarations for `CreatePseudoConsole`, `ResizePseudoConsole`,
##     `ClosePseudoConsole` (kernel32.dll, available on Windows 10 1809+).
##   * Pipe creation via `CreatePipe` + assignment to the pseudo-console.
##   * `CreateProcessW` with `STARTUPINFOEX` and `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`.
##   * Capability detection (`isConPtySupported()`) returning `false` on
##     legacy `cmd.exe`.
##   * Async I/O on the read pipe via `ReadFile` with `OVERLAPPED` (or a
##     dedicated reader thread) to honor the `timeout` parameter on `read`.
##   * Translation of `SIGINT`/`SIGTERM`-style operations to
##     `GenerateConsoleCtrlEvent(CTRL_C_EVENT, ...)` /
##     `TerminateProcess`.
##
## TODO(L1-windows): land the real implementation. Tracked alongside the
## downstream Windows driver work (M10) in the IsoNim-TUI plan.
##
## Why no `ref object` here either: even in the stub, the API contract from
## the charter is that `PtyHandle` and `PtySession` are value types managed
## by `=destroy`. The stub's types preserve that contract so consumers don't
## see different types on different platforms.

import std/[options, times]

type
  PtyError* = object of CatchableError
  PtyUnimplementedError* = object of PtyError

  PtyHandle* = object
    ## Placeholder; mirrors POSIX `PtyHandle` shape.
    handle*: int  # HANDLE on Windows. Stored as `int` here only because
                  # the stub never actually opens one.
    closed*: bool

  ExitState* = enum
    esRunning, esExited, esReaped

  PtySession* = object
    master*: PtyHandle
    pid*: int  # ProcessId on Windows
    state*: ExitState
    code*: int

  SpawnOptions* = object
    cols*: int
    rows*: int
    cwd*: string

proc `=copy`*(dest: var PtyHandle; src: PtyHandle) {.error.}
proc `=copy`*(dest: var PtySession; src: PtySession) {.error.}

when defined(gcDestructors):
  proc `=destroy`*(h: PtyHandle) =
    discard

  proc `=destroy`*(s: PtySession) =
    discard
else:
  proc `=destroy`*(h: var PtyHandle) =
    discard

  proc `=destroy`*(s: var PtySession) =
    discard

proc raiseStub() {.noreturn.} =
  raise newException(PtyUnimplementedError,
    "nim-pty Windows ConPTY backend is not yet implemented; see " &
    "src/nim_pty/windows.nim TODO. The POSIX backend is the supported " &
    "path on Linux and macOS.")

proc isOpen*(h: PtyHandle): bool {.inline.} = not h.closed

proc fileDescriptor*(h: PtyHandle): int {.inline.} = h.handle

proc close*(h: var PtyHandle) =
  h.closed = true

proc setNonblock*(h: var PtyHandle) = discard

proc setWindowSize*(h: var PtyHandle; cols, rows: int) = raiseStub()
proc getWindowSize*(h: PtyHandle): tuple[cols, rows: int] = raiseStub()

proc openPty*(): tuple[master, slave: PtyHandle] = raiseStub()

proc spawnPty*(cmd: string;
               args: openArray[string];
               env: openArray[(string, string)];
               opts: SpawnOptions = SpawnOptions(cols: 80, rows: 24)):
              PtySession = raiseStub()

proc read*(s: var PtySession;
           buf: var openArray[byte];
           timeout: Duration): int = raiseStub()

proc write*(s: var PtySession; data: openArray[byte]) = raiseStub()

proc sendSignal*(s: var PtySession; sig: cint) = raiseStub()

proc terminate*(s: var PtySession) = raiseStub()

proc isAlive*(s: var PtySession): bool = false

proc exitCode*(s: var PtySession): Option[int] =
  if s.state == esReaped: some(s.code) else: none(int)

proc waitExitCode*(s: var PtySession): int = raiseStub()

proc setWindowSize*(s: var PtySession; cols, rows: int) = raiseStub()

proc getWindowSize*(s: PtySession): tuple[cols, rows: int] = raiseStub()

proc fileDescriptor*(s: PtySession): int {.inline.} = s.master.handle

proc close*(s: var PtySession) =
  s.master.closed = true

proc readBytes*(s: var PtySession;
                maxBytes: int;
                timeout: Duration): seq[byte] = raiseStub()

proc isConPtySupported*(): bool =
  ## Capability probe; always `false` while the backend is a stub.
  false

export options, times
