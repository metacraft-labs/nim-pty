"use strict";

// Use the GitHubScript-supplied Actions exec toolkit so Windows .cmd shims
// follow the same tool resolution as other JavaScript actions. Preserve the
// outer command output even when repro fails before opening its action logs.
module.exports = async function captureReproCommand({ core, exec, collection, command = "dev-exec", args = ["repro", collection] }) {
  const fs = require("node:fs");
  const path = require("node:path");
  if (!["build", "test"].includes(collection)) {
    throw new Error("Expected the original build or test collection");
  }
  const temp = process.env.RUNNER_TEMP;
  if (!temp || !path.isAbsolute(temp)) {
    throw new Error("RUNNER_TEMP must be an absolute directory");
  }
  const directory = fs.mkdtempSync(path.join(temp, `pty-repro-${collection}-`));
  fs.chmodSync(directory, 0o700);
  core.setOutput("diagnostics", directory);
  const stdout = fs.openSync(path.join(directory, "stdout.log"), "wx", 0o600);
  const stderr = fs.openSync(path.join(directory, "stderr.log"), "wx", 0o600);
  const result = {
    command: [command, ...args],
    cwd: process.cwd(),
    started: new Date().toISOString(),
  };
  let launchError;
  try {
    result.exitCode = await exec.exec(command, args, {
      ignoreReturnCode: true,
      listeners: {
        stdout: (data) => fs.writeFileSync(stdout, data),
        stderr: (data) => fs.writeFileSync(stderr, data),
      },
    });
  } catch (error) {
    launchError = error;
    result.error = String(error.stack || error);
  } finally {
    result.finished = new Date().toISOString();
    fs.closeSync(stdout);
    fs.closeSync(stderr);
    fs.writeFileSync(path.join(directory, "result.json"),
      JSON.stringify(result, null, 2) + "\n", { flag: "wx", mode: 0o600 });
  }
  if (launchError) throw launchError;
  if (result.exitCode !== 0) {
    throw new Error(`${command} ${args.join(" ")} exited with ${result.exitCode}`);
  }
};
