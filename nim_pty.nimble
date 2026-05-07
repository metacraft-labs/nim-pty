version       = "0.1.0"
author        = "Metacraft Labs"
description   = "Cross-platform pseudo-terminal allocation and management for Nim"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

when defined(linux):
  # Linux's libc separates openpty/forkpty into libutil; Glibc 2.34+ folded
  # them into libc but linking -lutil is still safe and required on older
  # systems that may participate in the test matrix.
  passL: "-lutil"
