import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { join } from "node:path";

// Candidates for Lua binary
const candidatePaths = [
  "lua",
  "C:\\Users\\thoma\\.antigravity-ide\\extensions\\actboy168.lua-debug-2.3.0-win32-x64\\runtime\\win32-x64\\lua51\\lua.exe",
  "C:\\Users\\thoma\\.antigravity-ide\\extensions\\actboy168.lua-debug-2.3.0-win32-x64\\runtime\\win32-x64\\luajit\\lua.exe"
];

let luaPath = null;
for (const p of candidatePaths) {
  if (p === "lua") {
    const res = spawnSync("lua", ["-v"], { stdio: "pipe", shell: true });
    if (res.status === 0) {
      luaPath = "lua";
      break;
    }
  } else if (existsSync(p)) {
    luaPath = p;
    break;
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
