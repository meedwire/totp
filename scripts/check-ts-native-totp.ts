import { mkdtempSync } from "fs";
import { tmpdir } from "os";
import { join, resolve } from "path";
import { spawnSync } from "child_process";

const APP_ROOT = resolve(import.meta.dir, "..");
const COMPILER_ROOT = resolve(
  process.env.NATIVE_TS_COMPILER_ROOT ?? resolve(APP_ROOT, "../native-ts-compiler"),
);

const fixtures = [
  "totp_crypto_contract.tsx",
  "totp_account_card_scene.tsx",
  "totp_list_shell_scene.tsx",
  "totp_navigation_scene.tsx",
];

const outDir = mkdtempSync(join(tmpdir(), "ntui-totp-check-"));

for (const fixture of fixtures) {
  const input = resolve(APP_ROOT, "fixtures", fixture);
  const output = resolve(outDir, fixture.replace(/\.tsx$/, ""));
  run("bun", ["run", "cli.ts", "compile", input, "-o", output], COMPILER_ROOT);
  run(output, [], COMPILER_ROOT);
}

console.log(`[ts-native-totp] ${fixtures.length} fixtures passed`);

function run(command: string, args: string[], cwd: string): void {
  const result = spawnSync(command, args, {
    cwd,
    env: { ...process.env, NATIVE_TS_COMPILER_ROOT: COMPILER_ROOT },
    stdio: "inherit",
  });
  if (result.status !== 0 || result.error) {
    throw new Error(
      `command failed: ${[command, ...args].join(" ")}${result.error ? `\n${result.error.message}` : ""}`,
    );
  }
}
