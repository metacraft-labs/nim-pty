## nim_pty — cross-platform pseudo-terminal allocation and management.
##
## This is the public entry point. It re-exports the platform-appropriate
## backend so callers write `import nim_pty` and get a single, value-typed
## API regardless of OS.
##
## Quick example:
##
## ```nim
## import std/[times, options]
## import nim_pty
##
## var sess = spawnPty("/bin/echo", ["hello, world"], [], SpawnOptions(cols: 80, rows: 24))
## var buf = newSeq[byte](256)
## let n = read(sess, buf, initDuration(seconds = 1))
## if n > 0:
##   echo "child wrote: ", cast[string](buf[0 ..< n])
## let exit = waitExitCode(sess)
## doAssert exit == 0
## # `sess` is destroyed here — child reaped, master FD closed.
## ```
##
## The full design rationale, including the no-`ref` and no-`ptr` invariants
## and the testing-rigor charter, lives in
## `Front-Ends/IsoNim/isonim-tui.milestones.org` (sections "Memory-safety +
## testing-rigor charter" and "L1: nim-pty") in the codetracer-specs repo.

when defined(windows):
  import nim_pty/windows
  export windows
else:
  import nim_pty/posix
  export posix
