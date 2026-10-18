import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";

// Candidate Lua binaries, in order of preference. The 1.12 client runs Lua 5.0,
// so 5.1 is the closest modern interpreter; newer versions are accepted as
// fallbacks (CI installs lua5.1; dev machines may only have lua / luajit).
// LUA_BINARY env var overrides auto-detection.
const candidateBinaries = [
  "lua5.1",
  "lua5.4",
  "lua5.3",
  "lua5.2",
  "lua",
  "luajit",
];

const candidatePaths = [
  "C:\\Users\\thoma\\.antigravity-ide\\extensions\\actboy168.lua-debug-2.3.0-win32-x64\\runtime\\win32-x64\\lua51\\lua.exe",
  "C:\\Users\\thoma\\.antigravity-ide\\extensions\\actboy168.lua-debug-2.3.0-win32-x64\\runtime\\win32-x64\\luajit\\lua.exe"
];

function tryBinary(bin) {
  try {
    const res = spawnSync(bin, ["-v"], { stdio: "pipe" });
    if (res.status === 0) return true;
    // lua -v prints to stderr but still exits 0; some builds exit non-zero
    // while still emitting a version string — accept that as usable.
    const out = ((res.stderr || Buffer.alloc(0)).toString() + (res.stdout || Buffer.alloc(0)).toString()).toLowerCase();
    if (res.error == null && out.includes("lua")) return true;
  } catch {
    // binary not present — try next candidate
  }
  return false;
}

let luaPath = null;
if (process.env.LUA_BINARY && tryBinary(process.env.LUA_BINARY)) {
  luaPath = process.env.LUA_BINARY;
} else {
  for (const bin of candidateBinaries) {
    if (tryBinary(bin)) {
      luaPath = bin;
      break;
    }
  }
  if (!luaPath) {
    for (const p of candidatePaths) {
      if (existsSync(p)) {
        luaPath = p;
        break;
      }
    }
  }
}

if (!luaPath) {
  console.error("Error: Could not locate a usable Lua binary.");
  process.exit(1);
}

const args = process.argv.slice(2);
const target = args.length > 0 ? args[0] : "tests/run_tests.lua";
const extraArgs = args.slice(1);

const runRes = spawnSync(luaPath, [target, ...extraArgs], {
  stdio: "inherit",
  cwd: process.cwd()
});

process.exit(runRes.status ?? 1);
