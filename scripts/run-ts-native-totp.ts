import { spawnSync } from "child_process";
import { createHash } from "crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync } from "fs";
import { dirname, resolve } from "path";

type Platform = "android" | "macos";
type AndroidAbi = "arm64-v8a" | "armeabi-v7a";
type AndroidVariant = "debug" | "release";

const TS_NATIVE_ROOT = resolve(import.meta.dir, "..");
const PROJECT_ROOT = TS_NATIVE_ROOT;
const COMPILER_ROOT = resolve(
  process.env.NATIVE_TS_COMPILER_ROOT?.trim() ||
    resolve(TS_NATIVE_ROOT, "../native-ts-compiler"),
);
const ANDROID_ROOT = resolve(TS_NATIVE_ROOT, "android");
const MACOS_ROOT = resolve(TS_NATIVE_ROOT, "macos");
const MACOS_BUILD_DIR = resolve(MACOS_ROOT, "build");
const MACOS_APP = resolve(MACOS_BUILD_DIR, "Debug/TotpTsNativeMacApp.app");
const MACOS_APP_TARGET = "TotpTsNativeMacApp";
const MACOS_GENERATED_DYLIB = resolve(MACOS_BUILD_DIR, "generated/libntui_ts_app.dylib");
const MACOS_BUNDLED_DYLIB = resolve(MACOS_APP, "Contents/Frameworks/libntui_ts_app.dylib");
const MACOS_PROCESS_NAME = "TotpTsNativeMacApp";
const ANDROID_ACTIVITY = "dev.meedwire.totp.tsnative/.MainActivity";
const ANDROID_PACKAGE = "dev.meedwire.totp.tsnative";
const ANDROID_DIAGNOSTIC_PROPERTIES = [
  "debug.ntui.memory_logs",
  "debug.ntui.render_logs",
  "debug.ntui.snapshot_logs",
  "debug.ntui.scroll_logs",
  "debug.ntui.scroll_probe",
  "debug.ntui.frame_phases",
  "debug.ntui.gc_collect",
] as const;

const platform = readPlatform();

if (platform === "android") {
  runAndroid();
} else {
  runMacos();
}

function runAndroid(): void {
  const device = resolveAndroidDevice();
  const variant = readAndroidVariant();
  const abi = resolveAndroidAbi(device);
  const variantTask = variant === "release" ? "Release" : "Debug";
  const apk = resolve(
    ANDROID_ROOT,
    `app/build/outputs/apk/${variant}/app-${variant}.apk`,
  );
  console.log(`[totp-ts-native] Android device: ${device} abi=${abi} variant=${variant}`);
  run(
    "./gradlew",
    [
      "--no-daemon",
      `-PntuiAbi=${abi}`,
      "--rerun-tasks",
      `:app:assemble${variantTask}`,
    ],
    ANDROID_ROOT,
    {
      ANDROID_SERIAL: device,
      NATIVE_TS_COMPILER_ROOT: COMPILER_ROOT,
    },
  );
  if (!existsSync(apk)) {
    throw new Error(`Android APK not found: ${apk}`);
  }
  run("adb", ["-s", device, "install", "-r", apk], PROJECT_ROOT);
  if (variant === "release") disableAndroidDiagnostics(device);
  run("adb", ["-s", device, "shell", "am", "force-stop", ANDROID_PACKAGE], PROJECT_ROOT);
  run(
    "adb",
    ["-s", device, "shell", "am", "start", "-W", "-n", ANDROID_ACTIVITY],
    PROJECT_ROOT,
  );
  console.log("[totp-ts-native] Android app launched");
}

function runMacos(): void {
  run("cmake", ["-G", "Xcode", "-S", MACOS_ROOT, "-B", MACOS_BUILD_DIR], PROJECT_ROOT, {
    NATIVE_TS_COMPILER_ROOT: COMPILER_ROOT,
  });
  rebuildMacosRuntimeDylib();
  stopRunningMacosApp();
  buildMacosTarget(MACOS_APP_TARGET);
  if (!existsSync(MACOS_APP)) {
    throw new Error(`macOS app bundle not found: ${MACOS_APP}`);
  }
  copyMacosRuntimeDylib();
  run("open", [MACOS_APP], PROJECT_ROOT);
  console.log(`[totp-ts-native] macOS app launched: ${MACOS_APP}`);
}

function buildMacosTarget(target: string): void {
  run("cmake", ["--build", MACOS_BUILD_DIR, "--config", "Debug", "--target", target], PROJECT_ROOT, {
    NATIVE_TS_COMPILER_ROOT: COMPILER_ROOT,
  });
}

function rebuildMacosRuntimeDylib(): void {
  rmSync(MACOS_GENERATED_DYLIB, { force: true });
  buildMacosTarget("ntui_ts_runtime");
  if (!existsSync(MACOS_GENERATED_DYLIB)) {
    throw new Error(`macOS generated dylib not found after build: ${MACOS_GENERATED_DYLIB}`);
  }
}

function copyMacosRuntimeDylib(): void {
  if (!existsSync(MACOS_GENERATED_DYLIB)) {
    throw new Error(`macOS generated dylib not found: ${MACOS_GENERATED_DYLIB}`);
  }

  mkdirSync(dirname(MACOS_BUNDLED_DYLIB), { recursive: true });
  copyFileSync(MACOS_GENERATED_DYLIB, MACOS_BUNDLED_DYLIB);

  const generatedChecksum = sha256File(MACOS_GENERATED_DYLIB);
  const bundledChecksum = sha256File(MACOS_BUNDLED_DYLIB);
  if (generatedChecksum !== bundledChecksum) {
    throw new Error(
      `macOS dylib copy verification failed: generated ${generatedChecksum}, bundled ${bundledChecksum}`,
    );
  }
  console.log(
    `[totp-ts-native] macOS dylib copied and verified: ${MACOS_BUNDLED_DYLIB} sha256=${bundledChecksum}`,
  );
}

function sha256File(path: string): string {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function stopRunningMacosApp(): void {
  spawnSync("osascript", ["-e", 'tell application "TOTP Authenticator" to quit'], {
    cwd: PROJECT_ROOT,
    stdio: "ignore",
  });
  spawnSync("pkill", ["-x", MACOS_PROCESS_NAME], {
    cwd: PROJECT_ROOT,
    stdio: "ignore",
  });
}

function resolveAndroidDevice(): string {
  const envSerial = process.env.ANDROID_SERIAL?.trim();
  if (envSerial) return envSerial;

  const devices = spawnSync("adb", ["devices"], {
    cwd: PROJECT_ROOT,
    encoding: "utf8",
  });
  if (devices.status !== 0 || devices.error) {
    throw new Error(`failed to list Android devices\n${devices.stderr}${devices.error?.message ?? ""}`);
  }

  const connected = devices.stdout
    .split("\n")
    .map((line) => line.trim().split(/\s+/))
    .filter(([serial, state]) => Boolean(serial) && state === "device")
    .map(([serial]) => serial!);

  if (connected.length === 0) {
    throw new Error("no Android device available; start an emulator or connect a device");
  }
  const physical = connected.filter(
    (serial) => adbCapture(serial, ["shell", "getprop", "ro.kernel.qemu"]) !== "1",
  );
  if (physical.length === 1) return physical[0]!;
  if (physical.length > 1) {
    throw new Error(
      `multiple physical Android devices available (${physical.join(", ")}); set ANDROID_SERIAL`,
    );
  }
  if (connected.length === 1) return connected[0]!;
  throw new Error(
    `multiple Android emulators available (${connected.join(", ")}); set ANDROID_SERIAL`,
  );
}

function resolveAndroidAbi(device: string): AndroidAbi {
  const requested = readArg("--abi", "auto");
  if (requested !== "auto" && requested !== "arm64-v8a" && requested !== "armeabi-v7a") {
    throw new Error("--abi must be auto, arm64-v8a or armeabi-v7a");
  }
  const abiList =
    adbCapture(device, ["shell", "getprop", "ro.product.cpu.abilist"]) ||
    adbCapture(device, ["shell", "getprop", "ro.product.cpu.abi"]);
  const supported = abiList.split(",").map((abi) => abi.trim());
  if (requested !== "auto") {
    if (!supported.includes(requested)) {
      throw new Error(`device ${device} does not support ${requested}; reported ABIs: ${abiList}`);
    }
    return requested;
  }
  if (supported.includes("arm64-v8a")) return "arm64-v8a";
  if (supported.includes("armeabi-v7a")) return "armeabi-v7a";
  throw new Error(`device ${device} has no supported ARM ABI; reported ABIs: ${abiList || "<empty>"}`);
}

function readAndroidVariant(): AndroidVariant {
  const raw = readArg("--variant", "debug");
  if (raw === "debug" || raw === "release") return raw;
  throw new Error("--variant must be debug or release");
}

function disableAndroidDiagnostics(device: string): void {
  for (const property of ANDROID_DIAGNOSTIC_PROPERTIES) {
    run("adb", ["-s", device, "shell", "setprop", property, "0"], PROJECT_ROOT);
  }
}

function adbCapture(device: string, args: string[]): string {
  const result = spawnSync("adb", ["-s", device, ...args], {
    cwd: PROJECT_ROOT,
    encoding: "utf8",
  });
  if (result.status !== 0 || result.error) {
    throw new Error(
      `adb failed for ${device}: ${args.join(" ")}\n${result.stderr}${result.error?.message ?? ""}`,
    );
  }
  return result.stdout.trim();
}

function readPlatform(): Platform {
  const raw = readArg("--platform", "");
  if (raw === "android" || raw === "macos") return raw;
  throw new Error(
    "usage: bun run scripts/run-ts-native-totp.ts --platform=android|macos " +
      "[--variant=debug|release] [--abi=auto|arm64-v8a|armeabi-v7a]",
  );
}

function readArg(name: string, fallback: string): string {
  const prefix = `${name}=`;
  const index = process.argv.findIndex((value) => value === name || value.startsWith(prefix));
  if (index < 0) return fallback;
  const current = process.argv[index] as string;
  if (current.startsWith(prefix)) return current.slice(prefix.length);
  const value = process.argv[index + 1];
  return value && !value.startsWith("--") ? value : fallback;
}

function run(
  command: string,
  args: string[],
  cwd: string,
  env?: Record<string, string>,
): void {
  const result = spawnSync(command, args, {
    cwd,
    env: { ...process.env, ...env },
    stdio: "inherit",
  });
  if (result.status !== 0 || result.error) {
    throw new Error(
      `command failed: ${[command, ...args].join(" ")}${result.error ? `\n${result.error.message}` : ""}`,
    );
  }
}
