## Reprobuild project file for nim-pty.
##
## **Typed-Cross-Project-Deps rollout, Wave-0 leaf.** ``nim-pty`` is a
## cross-platform pseudo-terminal library — the load-bearing POSIX backend
## (``src/nim_pty/posix.nim``, ``openpty``/hand-rolled ``fork``+``execve``)
## plus a documented Windows ConPTY stub. It is a pure-Nim leaf: its only
## build inputs are its own ``src/`` tree and the system libc (``-lutil`` on
## Linux for ``openpty``/``forkpty``). It has NO in-scope sibling build
## dependency, so the ``uses:`` block is just the toolchain floor — there is
## no ``uses: "<sibling>"`` edge.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical ``runquota/repro.nim`` / ``codetracer-trace-format-nim/repro.nim``
## / ``nim-stackable-hooks/repro.nim`` recipes:
##
## * Declares the upstream tool floor via ``uses:`` so consumers that depend
##   on this repo (``uses: "nim_pty"`` — the IsoNim-TUI test harness /
##   ``nim-libvterm`` layer on top) pick up the same toolchain the nimble
##   file's ``requires "nim >= 2.0.0"`` implies.
## * Declares ``library nim_pty`` so consumers can express a workspace
##   dependency on this repo. The importable surface is the ``src/`` tree
##   (``src/nim_pty.nim`` — the umbrella that re-exports the platform
##   backend); consumers ``import nim_pty``.
## * Emits, per runnable test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>`` and
##   an EXECUTE edge (``edge.testBinary.run``) that runs it — the two-edge
##   test template from ``reprobuild-specs/Package-Model.md`` §"The test
##   template". BUILD halves collect into ``test-builds``; EXECUTE halves
##   collect into ``test`` so ``repro build test`` / ``repro test``
##   materialise the runnable closure.
##
## **Module search path + compile flags.** nim-pty ships no
## ``config.nims`` / ``nim.cfg``; its ``Justfile`` supplies
## ``--path:src --path:tests`` on every ``nim c``. Of those,
## ``--path:tests`` is redundant — every test lives in ``tests/`` and
## ``import test_helpers`` resolves from the compiled file's own directory
## (Nim's implicit search path). Only ``--path:src`` is load-bearing (for
## ``import nim_pty``), so each BUILD edge passes ``paths = @["src"]``.
## ``src`` is added to ``extraInputs`` so the whole backend tree is a
## declared input of the compile.
##
## Each BUILD edge also reproduces the repo's DEFAULT matrix point —
## ``just test`` → ``test-orc`` → ``_matrix orc release on`` →
## ``nim c … --mm:orc -d:release --threads:on``: ``--mm:orc`` via ``mm:``,
## ``-d:release`` via ``defines:``, and ``--threads:on`` via the
## wrapper's default ``threadsOn``. The ``--skipParentCfg`` /
## ``--skipUserCfg`` / ``--styleCheck`` switches from ``nim-flags`` are
## hermeticity/style toggles that don't change the produced binary and
## aren't part of the typed ``nim c`` surface, so they're omitted — the
## engine compile is already hermetic (no parent/user cfg is read from the
## engine's work root) and the corpus compiles + runs identically.
##
## **Linking.** The nimble file adds ``passL: "-lutil"`` under
## ``when defined(linux)`` (glibc splits ``openpty``/``forkpty`` into
## ``libutil``; harmless-but-required on the older systems in the test
## matrix). The DSL ``nim.c`` edge does not run the nimble file, so the
## Linux BUILD edges pass ``extraPassL = @["-lutil"]`` explicitly to
## reproduce it. The flag is gated ``when defined(linux)`` at extraction —
## macOS/Windows folded these into libc and need no ``-lutil``.
##
## **Per-test platform gating.** Every test file under ``tests/`` self-adapts
## to its target OS via ``when defined(...)`` in the file itself; the edges
## here mirror that so the corpus this host runs matches what the repo's own
## ``nim c -r`` would run. Reading each file's imports + guards:
##
##   * ``test_pty_spawn_echo`` / ``test_pty_signals`` / ``test_pty_window_size``
##     / ``test_utf8_split`` / ``test_no_leaks`` — all ``import nim_pty`` +
##     ``test_helpers`` and exercise the POSIX backend / ``/proc``. On this
##     Linux host they compile + run to exit 0. (``test_no_leaks`` guards
##     every body with ``ifLinux``; ``test_pty_signals`` imports ``std/posix``
##     — both POSIX-only, but this IS a POSIX host so they run here.)
##   * ``test_pty_cross_platform`` — ``when defined(windows): skip()`` inside
##     each ``test``; the non-Windows arm runs the real ``cat`` round-trip.
##     Runs to exit 0 on Linux/macOS.
##   * ``test_api_invariants`` — pure-API ``unittest`` with no OS gate; runs
##     everywhere ``nim_pty`` compiles. Runs on this host.
##   * ``smoke.nim`` — a runnable ``main()`` (``import nim_pty``, spawn
##     ``echo``, read, wait). Its own header says "not part of the official
##     suite"; the repo's ``Justfile`` never lists it in ``tests`` and never
##     ``nim c -r``s it except via the opt-in ``test-readme`` recipe. It is a
##     runnable smoke program rather than a suite member, so — matching the
##     repo's own test-set — it gets NO edge here.
##   * ``test_helpers.nim`` — a SHARED utility module (``findBin`` /
##     ``inheritedEnv`` / ``readUntil`` / RSS+FD introspection) imported by
##     the other tests. It defines no ``suite`` / ``when isMainModule`` and
##     is never compiled as a standalone binary (the ``Justfile`` omits it
##     from ``tests``), so it gets NO execute edge — only a transitive input
##     of the tests that ``import`` it.
##
## No test file in this repo is host-exclusive to Windows/macOS in a way that
## makes it uncompilable on Linux: every one either has no OS gate or a
## ``when defined(windows): skip() else: <real body>`` in-test guard, so all
## runnable tests are in the Linux graph. There are no ``when defined(...)``
## extraction gates needed for the test set on this host beyond the
## ``-lutil`` link flag.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on ``PATH``,
## so the weak-local PATH resolver is the right default. Without it
## ``repro build`` refuses to run with "typed tool provisioning is required
## for uses declarations".

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge and the ``edge.testBinary.run(...)``
# UFCS dispatch for the EXECUTE edges. It re-exports ``repro_project_dsl`` so
# the import order is unimportant. Like the ``nim-stackable-hooks`` leaf
# recipe, this file does NOT import ``ct_test_runner_install`` (engine-coupled,
# reprobuild-internal): the execute edges route through the engine's default
# direct-binary runner (run the binary, key on exit status), which is exactly
# the exit-0 verification this corpus needs — Nim ``unittest`` prints per-suite
# results and exits non-zero on failure.
import ct_test_nim_unittest

type
  PtyTestSpec = object
    ## One entry per runnable test file. ``source`` is the repo-relative
    ## ``.nim`` path; ``binary`` is the ``build/test-bin/<stem>`` output.
    source: string
    binary: string

const portableTestSpecs: seq[PtyTestSpec] = @[
  # Tests with no host-exclusive gate — each either has no OS ``when`` at all
  # or an in-``test`` ``when defined(windows): skip() else: <body>`` — so they
  # compile + run to exit 0 on this Linux host. On a POSIX host that includes
  # the POSIX-backend tests (``test_pty_signals`` imports ``std/posix``,
  # ``test_no_leaks`` guards its bodies with ``ifLinux``).
  PtyTestSpec(source: "tests/test_pty_spawn_echo.nim",
    binary: "build/test-bin/test_pty_spawn_echo"),
  PtyTestSpec(source: "tests/test_pty_signals.nim",
    binary: "build/test-bin/test_pty_signals"),
  PtyTestSpec(source: "tests/test_pty_window_size.nim",
    binary: "build/test-bin/test_pty_window_size"),
  PtyTestSpec(source: "tests/test_no_leaks.nim",
    binary: "build/test-bin/test_no_leaks"),
  PtyTestSpec(source: "tests/test_utf8_split.nim",
    binary: "build/test-bin/test_utf8_split"),
  PtyTestSpec(source: "tests/test_pty_cross_platform.nim",
    binary: "build/test-bin/test_pty_cross_platform"),
  PtyTestSpec(source: "tests/test_api_invariants.nim",
    binary: "build/test-bin/test_api_invariants"),
]

package nim_pty:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs. ``nim``
    # compiles every test binary (the ``buildNimUnittest.build`` edges below,
    # matching the nimble file's ``requires "nim >= 2.0.0"``); ``gcc`` is the
    # C back-end ``nim c`` shells out to and the linker that consumes the
    # ``-lutil`` ``passL`` on Linux. Sufficient for the path-mode resolver
    # under ``nix develop``.
    "nim >=2.0"
    "gcc >=12"

  # Library declaration — the ``src/`` tree the tests put on ``--path`` is
  # importable when this package is consumed via ``uses: "nim_pty"``. The
  # umbrella is ``src/nim_pty.nim`` (it re-exports the platform backend);
  # consumers ``import nim_pty``.
  library nim_pty

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile BUILD edge + one EXECUTE edge per runnable test file. BUILD
    # halves collect into ``test-builds`` (compile verification); EXECUTE
    # halves collect into ``test`` so ``repro test`` / ``repro build test``
    # materialise the runnable closure (each execute edge transitively
    # depends on its build edge).
    #
    # ``paths = @["src"]`` supplies ``--path:src`` (nim-pty has no
    # ``config.nims``; only ``import nim_pty`` needs it — ``import
    # test_helpers`` resolves from the compiled file's own ``tests/`` dir).
    # ``src`` is an ``extraInput`` so the whole backend tree is a declared
    # input of every compile.
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    # ``-lutil`` is Linux-only (glibc splits ``openpty``/``forkpty`` into
    # ``libutil``); gated at extraction so macOS/Windows compiles omit it.
    const linuxPassL =
      when defined(linux): @["-lutil"]
      else: @[]

    # Serialise the EXECUTE edges through a capacity-1 build pool. Every
    # nim-pty test allocates a real pty and forks+execs real child
    # processes (``echo`` / ``stty`` / ``sh`` / ``sleep``); several of them
    # assert on sub-100ms read windows against that child's output
    # (``test_pty_window_size``'s "running session" resize test reads the
    # first ``stty size`` within a 50ms window). Running the whole corpus
    # concurrently — especially under a saturated host during the
    # cross-repo rollout — starves those child forks of scheduler time and
    # makes the timing-sensitive reads flake. A capacity-1 pool sequences
    # the pty tests so each runs with the CPU headroom its own fork+exec
    # timing needs. This changes ONLY scheduling: no ``check`` is skipped,
    # relaxed, or removed — every test still runs in full to exit 0. The
    # BUILD (compile) edges stay unpooled and parallel.
    let ptyPool = buildPool("nim_pty.pty-serial", 1'u32)
    discard ptyPool

    proc emitTestPair(source, binary: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        defines = @["release"],
        paths = @["src"],
        mm = "orc",
        extraPassL = linuxPassL,
        extraInputs = @["src"],
        actionId = "nim_pty.test_build." & stem)
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already owns
      # the binary basename as the implicit target name; the explicit
      # ``actionId`` is the execute edge's selector (two-edge shape).
      let executeEdge = edge.testBinary.run(
        actionId = "nim_pty.test_execute." & stem,
        pool = "nim_pty.pty-serial",
        registerImplicitName = false)
      executeActions.add(executeEdge)

    for spec in portableTestSpecs:
      emitTestPair(spec.source, spec.binary,
        testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
