## test_utf8_split.nim — L1 mandatory test (test_pty_utf8_split_across_reads).
##
## Child writes a 4-byte UTF-8 emoji; library returns the 4 bytes
## (concatenating across reads if needed) so callers can decode. read never
## returns a partial codepoint as a single read result *unless* the buffer
## is already full mid-codepoint, in which case the next read continues
## cleanly.
##
## nim-pty's `read*` procs are agnostic to UTF-8 — they return whatever
## bytes the kernel gives. We're verifying:
##
##   1. With a sufficiently large buffer, all bytes of a single UTF-8
##      emoji come back in one or more reads, totalling the original
##      payload.
##   2. With a buffer of exactly 1 byte, multiple reads concatenate to the
##      original UTF-8 payload (no bytes are dropped or duplicated).

import std/[times, unittest]
import nim_pty
import test_helpers

const
  # Snowman with variation selector: U+2603 U+FE0F → 5 bytes E2 98 83 EF B8 8F
  # Family emoji: U+1F46A → 4 bytes F0 9F 91 AA
  # Pile of poo: U+1F4A9 → 4 bytes F0 9F 92 A9
  emoji4 = "\xF0\x9F\x91\xAA"  # 4-byte family emoji
  emojiCombined = "\xE2\x98\x83\xEF\xB8\x8F"  # snowman + VS-16

suite "L1: UTF-8 byte-stream integrity":

  test "4-byte emoji round-trips intact":
    let bin = requireBin("printf")
    var sess = spawnPty(bin, ["%s", emoji4], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    let output = readAllAvailable(sess, initDuration(seconds = 5))
    discard waitExitCode(sess)
    # printf does not append a newline with %s. The pty also doesn't ONLCR
    # because there's no \n, so the bytes should arrive verbatim.
    check output == emoji4

  test "1-byte buffer reads accumulate to the full emoji":
    let bin = requireBin("printf")
    var sess = spawnPty(bin, ["%s", emoji4], inheritedEnv(),
      SpawnOptions(cols: 80, rows: 24))
    var acc: seq[byte] = @[]
    var oneByte = newSeq[byte](1)
    let deadline = epochTime() + 5.0
    while epochTime() < deadline:
      let n = read(sess, oneByte, initDuration(milliseconds = 200))
      if n == 1:
        acc.add(oneByte[0])
      elif n == 0:
        break  # EOF
      # n == -1 → timeout; loop again until deadline.
      if acc.len >= emoji4.len:
        break
    discard waitExitCode(sess)
    check acc.len == emoji4.len
    check cast[string](acc) == emoji4

  test "multi-codepoint sequence preserves byte order":
    let bin = requireBin("printf")
    let payload = emoji4 & "ascii" & emojiCombined
    var sess = spawnPty(bin, ["%s", payload], inheritedEnv(),
      SpawnOptions(cols: 200, rows: 24))
    let output = readAllAvailable(sess, initDuration(seconds = 5))
    discard waitExitCode(sess)
    check output == payload

  test "long mixed payload is not truncated":
    let bin = requireBin("printf")
    var payload = ""
    for i in 0 ..< 200:
      payload.add(emoji4)
      payload.add(" ")
    var sess = spawnPty(bin, ["%s", payload], inheritedEnv(),
      SpawnOptions(cols: 1000, rows: 24))
    let output = readAllAvailable(sess, initDuration(seconds = 5))
    discard waitExitCode(sess)
    check output.len == payload.len
    check output == payload
