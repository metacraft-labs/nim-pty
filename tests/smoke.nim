## smoke.nim — minimal sanity check; not part of the official suite.
import std/[times, options, os]
import nim_pty

proc main() =
  let echoBin = findExe("echo", followSymlinks = false)
  echo "echo at: ", echoBin
  doAssert echoBin.len > 0
  var sess = spawnPty(echoBin, ["hello"], [],
    SpawnOptions(cols: 80, rows: 24))
  var buf = newSeq[byte](256)
  let n = read(sess, buf, initDuration(seconds = 2))
  echo "read=", n
  if n > 0:
    echo "data=", cast[string](buf[0 ..< n])
  let code = waitExitCode(sess)
  echo "exit=", code

main()
