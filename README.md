# nim-pty

Cross-platform pseudo-terminal allocation and management for Nim.

`nim-pty` lets a Nim program spawn a child process inside a pseudo-terminal
and exchange bytes with it the same way a terminal emulator would. It's the
load-bearing FFI layer used by IsoNim-TUI's test harness and production
drivers, but it has no IsoNim dependency and is usable on its own.

## Status

Public, MIT-licensed, **L1 milestone**. POSIX (Linux + macOS) is the
load-bearing path and passes the full Memory-safety + testing-rigor charter
matrix. Windows ConPTY support is a documented stub (see `src/nim_pty/windows.nim`)
and is tracked for a follow-up milestone.

The authoritative specification is in
`codetracer-specs/Front-Ends/IsoNim/isonim-tui.milestones.org` — see the
"L1: nim-pty" heading and the "Memory-safety + testing-rigor charter"
gating requirement.

## Quick start

```nim
import std/[options, os, times]
import nim_pty

# Spawn `echo` in a fresh pty.
var sess = spawnPty(
  findExe("echo", followSymlinks = false),
  ["hello, pty"],
  toSeq(envPairs()),
  SpawnOptions(cols: 80, rows: 24)
)

# Read whatever the child writes.
var buf = newSeq[byte](256)
let n = readSession(sess, buf, initDuration(seconds = 1))
if n > 0:
  echo "child wrote: ", cast[string](buf[0 ..< n])

# Wait for it to exit.
let exitCode = waitExitCode(sess)
doAssert exitCode == 0

# `sess` is destroyed at end of scope — child reaped, master FD closed.
```

The full public API surface is documented in `src/nim_pty/posix.nim` (each
proc has a doc-comment).

## Building

This repo follows the standard Metacraft Labs layout: `flake.nix`,
`.envrc`, `Justfile`, AGENTS.md.

```sh
direnv allow .          # if direnv is installed
just build              # compile all test files as a smoke check
just test               # default matrix cell (orc + release + threads:on)
just lint               # nim check (with style checks) + nixfmt --check
```

The full charter matrix lives under `just test-all` and the per-axis
recipes (`test-arc`, `test-asan`, etc.). See `AGENTS.md` for the full
recipe list.

## Testing-rigor commitment

This library participates in the IsoNim TUI charter's testing matrix:

| Library | Memory managers | Sanitizers | Leak budgets | Cross-platform parity |
|---------|-----------------|-----------|--------------|----------------------|
| **nim-pty** | arc + orc + refc | ASan + UBSan + TSan + LSan + Valgrind | 5 explicit budget tests | Cell-by-cell on 3 platforms (POSIX shipping; Windows in progress) |

No mocks in integration tests — every test exercises real ptys and real
subprocesses (`/bin/echo`, `/bin/cat`, `sleep`, `stty`, etc.).

## License

MIT — see [LICENSE](./LICENSE).
