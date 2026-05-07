# nim-pty

Cross-platform pseudo-terminal allocation and management for Nim.

## What this library does

`nim-pty` lets a Nim program allocate a pseudo-terminal (pty) and spawn a
child process inside it, then exchange bytes with the child the way a
terminal emulator would. Use cases:

- Running a TUI app under test (the IsoNim-TUI test harness depends on this)
- Embedding a shell or REPL inside a Nim application
- Building a terminal multiplexer, recorder, or proxy

The library deliberately exposes raw bytes in both directions; it does NOT
parse ANSI/VT control sequences. Layer the L2 library (`nim-libvterm`) on
top of this for parsed `Screen` access.

## Commands

```sh
just build           # compile every test as a smoke check
just test            # run the default matrix point (orc + release + threads:on)
just lint            # nim check + nixfmt --check
just format          # nimpretty + nixfmt
```

Charter matrix recipes (CI runs each as a separate matrix cell):

```sh
just test-arc        # arc memory manager, all three modes
just test-orc        # orc memory manager, all three modes
just test-refc       # refc memory manager, all three modes
just test-threads-off
just test-asan       # AddressSanitizer (Linux/clang)
just test-ubsan      # UndefinedBehaviorSanitizer
just test-tsan       # ThreadSanitizer
just test-lsan       # LeakSanitizer
just test-valgrind   # secondary leak verification
just test-leaks-heavy  # 100k-cycle leak budgets (slow; CI only)
just test-all        # everything that runs on a Linux runner
```

## Project structure

```
src/
  nim_pty.nim                # public top-level — re-exports the platform backend
  nim_pty/posix.nim          # POSIX backend (load-bearing path on Linux + macOS)
  nim_pty/windows.nim        # Windows ConPTY backend (currently a stub; see TODO)
tests/
  test_pty_spawn_echo.nim    # L1 spec test
  test_pty_signals.nim       # L1 spec test (sendSignal)
  test_pty_window_size.nim   # L1 spec test (TIOCSWINSZ + SIGWINCH)
  test_no_leaks.nim          # charter leak-budget suite
  test_utf8_split.nim        # L1 spec test (UTF-8 byte integrity)
  test_pty_cross_platform.nim# L1 spec test
  test_api_invariants.nim    # charter §1 API rules (no ref/ptr, RAII)
  test_helpers.nim           # shared utilities (no test_ prefix → not run on its own)
.github/workflows/ci.yml     # full charter matrix on every PR
flake.nix                    # nix devShell + checks
Justfile                     # all build/test/lint recipes
nim_pty.nimble               # single-source-of-truth version
```

## Architectural decisions

- **Value-typed handles, RAII-everywhere.** `PtyHandle` and `PtySession`
  are value `object`s; `=copy` is disabled and `=destroy` releases the FD
  and reaps the child. There is no "you must remember to call close()"
  footgun.

- **`fd > 2` guard in destructors.** A default-initialised handle has
  `fd == 0, closed == false`. Without the guard, the destructor on the
  implicit `result` slot would close stdin the first time `spawnPty`
  assigns to `result`. See the long comment on `=destroy(PtyHandle)` in
  `src/nim_pty/posix.nim`.

- **Hand-rolled fork + execve, not `forkpty(3)`.** We need to install a
  custom window size before exec and want a clean Nim signature for
  `spawnPty`. The implementation follows APUE §19.4.

- **EIO on read = EOF.** When the slave end is fully closed on Linux,
  reading the master returns EIO; we translate this to a clean EOF (0
  bytes) so callers don't have to special-case the platform.

- **Windows ConPTY is a documented stub.** The L1 milestone explicitly
  permits this. See `src/nim_pty/windows.nim` for the TODO list.

## Coding conventions

- `--styleCheck:usages --styleCheck:error` is enforced — use `camelCase`
  identifiers. The Justfile bakes this into every nim invocation.
- Public types are value `object`s. `ref object` is forbidden in the
  public API (charter §1).
- Public APIs never expose raw `ptr`. Use `openArray[T]`, `seq[byte]`,
  `string`, or typed handles.
- `cast` is forbidden in the public API; use sparingly internally and
  justify each use in a comment (currently only at the FFI boundary).
- Every test is a real-stack integration test — no mocks.
- Every test that depends on `/proc` must skip itself on non-Linux via
  `when defined(linux)` rather than failing.

## Specs

The authoritative specifications for this library live in the
`codetracer-specs` repo:

- `Front-Ends/IsoNim/isonim-tui.milestones.org` — see "L1: nim-pty" and
  the "Memory-safety + testing-rigor charter".

When user requests change the public API, update the spec in the same
change set.
