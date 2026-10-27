## Source-owned compiler preparation graph only. No product/test execution.
## The canonical supplier/floor is identical to the owning parent gcc>=12.
import repro_project_dsl
import repro_dsl_stdlib/packages/gcc

package nim_pty_compiler_acquisition:
  defaultToolProvisioning "tarball"
  uses:
    "gcc >=12"
  build:
    let profile = buildAction(
      id = "nim_pty_compiler_acquisition.gcc_version",
      call = inlineExecCall(@["gcc", "--version"]),
      toolIdentityRefs = @["gcc"])
    discard collect("profile", @[profile])
