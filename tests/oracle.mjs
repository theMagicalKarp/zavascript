// Checks the conformance annotations against the real thing: tsc must report exactly the `//!`
// diagnostics (code and line), and node must print exactly the `//>` lines. A case only proves
// zavascript right if its expectations are right, and this is what keeps them honest.
//
// `ZV` codes are ours and tsc never reports them, so for a case that expects one, the oracle only
// checks that tsc reports the case's TS codes (usually none) and skips running it.
//
// Usage: node tests/oracle.mjs [filter]

import { spawn } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import { availableParallelism } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const casesDir = path.join(root, "tests", "cases");
const filter = process.argv[2];

function findCases(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return findCases(full);
    return entry.name.endsWith(".ts") && !entry.name.endsWith(".d.ts") ? [full] : [];
  });
}

/** The same annotation format `tests/runner.zig` reads. */
function parseExpectation(source) {
  const stdout = [];
  const diagnostics = [];
  source.split("\n").forEach((raw, i) => {
    const line = raw.replace(/\r$/, "");
    const out = line.indexOf("//>");
    if (out >= 0) {
      let text = line.slice(out + 3);
      if (text.startsWith(" ")) text = text.slice(1);
      stdout.push(text + "\n");
      return;
    }
    const err = line.indexOf("//!");
    if (err >= 0) {
      for (const code of line.slice(err + 3).trim().split(/\s+/).filter(Boolean)) {
        diagnostics.push(`${i + 1}:${code}`);
      }
    }
  });
  return { stdout: stdout.join(""), diagnostics: diagnostics.sort() };
}

const cases = findCases(casesDir)
  .filter((file) => !filter || path.relative(casesDir, file).includes(filter))
  .sort()
  .map((file) => ({ file, name: path.relative(casesDir, file), ...parseExpectation(readFileSync(file, "utf8")) }));

// Type check each case on its own: when a program has syntax errors, tsc skips type checking for
// every file in it, so one bad case would hide the type errors of all the others.
function runTsc(file) {
  const args = [
    "--noEmit", "--strict", "--target", "es2022", "--lib", "es2022", "--moduleDetection", "force",
    "--pretty", "false", path.join(root, "tests", "oracle", "globals.d.ts"), file,
  ];
  return run("tsc", args).then((result) => {
    if (result.error) {
      console.error(`can't run tsc: ${result.error.message} (is it installed? try \`mise install\`)`);
      process.exit(2);
    }
    const diagnostics = [];
    for (const line of result.stdout.split("\n")) {
      const match = /^(.*)\((\d+),\d+\): error (TS\d+):/.exec(line);
      if (!match) continue;
      if (path.resolve(match[1]) !== file) {
        console.error(`unexpected tsc output: ${line}`);
        process.exit(2);
      }
      diagnostics.push(`${match[2]}:${match[3]}`);
    }
    return diagnostics.sort();
  });
}

function run(command, args) {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (error) => resolve({ error }));
    child.on("close", (code) => resolve({ code, stdout, stderr }));
  });
}

const failures = [];
const pending = [...cases];
async function worker() {
  for (let c = pending.shift(); c; c = pending.shift()) {
    const expectedTs = c.diagnostics.filter((d) => /:TS\d+$/.test(d));
    const actualTs = await runTsc(c.file);
    if (expectedTs.join(" ") !== actualTs.join(" ")) {
      failures.push(`${c.name}: tsc diagnostics differ\n  expected: ${expectedTs.join(" ")}\n  tsc:      ${actualTs.join(" ")}`);
      continue;
    }
    if (c.diagnostics.length > 0) continue;
    const result = await run("node", ["--no-warnings", c.file]);
    if (result.code !== 0) {
      failures.push(`${c.name}: node exited with ${result.code}\n${result.stderr}`);
    } else if (result.stdout !== c.stdout) {
      failures.push(`${c.name}: node output differs\n--- expected\n${c.stdout}--- node\n${result.stdout}`);
    }
  }
}
await Promise.all(Array.from({ length: availableParallelism() }, worker));

for (const failure of failures) console.log(`FAIL ${failure}\n`);
console.log(`oracle: ${cases.length - failures.length} passed, ${failures.length} failed`);
process.exit(failures.length > 0 ? 1 : 0);
