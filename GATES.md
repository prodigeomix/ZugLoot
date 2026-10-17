# Gates: ZugLoot Deep Audit and Runtime Invariant Enforcement

OWNS: tests/**, Comm.lua, MasterLootUI.lua, LootWindow.lua, SRImport.lua, Timer.lua

Scope: Deep reliability, security, network MTU, C-API invariant, and memory churn audit of ZugLoot for WoW 1.12.1.

- [x] G1: Detect undeclared globals, leaking locals, and verify Lua 5.0 compatibility across all files
  CHECK: node tests/run.mjs tests/test_global_guard.lua
  EXPECT: global pollution trap passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=927bcc93a3fb33b58aead75b7aa69ac6f614f4ebaf3074e7465ecb91e5b27db2; exit=0; EXPECT=matched; output-sha256=8d46a634c2a062923b020714ff71600ce94807bf28adbde61c28c14b6f9050d5; output-bytes=30; shell=C:\WINDOWS\system32\cmd.exe; cwd=C:\Games\Interface\AddOns\ZugLoot; path=8086073e8118/21 entries

- [x] G2: Verify SendAddonMessage hard MTU cap of 254 bytes with multi-part chunking and ChatThrottleLib routing
  CHECK: node tests/run.mjs tests/test_network_mtu_throttle.lua
  EXPECT: network mtu and throttle discipline passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=38f54c83161a0d406e811d2a69ef3e4246d4d4c21d4ad55d67fb2d023e7f4fa6; exit=0; EXPECT=matched; output-sha256=117bdfdba707ef1b2449cd5a283f3d7e2831dac2eee0db8dff9639a5480087e6; output-bytes=44; shell=C:\WINDOWS\system32\cmd.exe; cwd=C:\Games\Interface\AddOns\ZugLoot; path=8086073e8118/21 entries

- [x] G3: Verify corpse slot collapse reconciliation and dynamic candidate re-verification at award time
  CHECK: node tests/run.mjs tests/test_corpse_slot_shift.lua
  EXPECT: corpse slot shift and candidate invariants passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=36ee4fd214330cc96267e1bf7e5f0d6a25e89cdbdb6176c30b08ce6c519e3714; exit=0; EXPECT=matched; output-sha256=7676899a1304a4c83150a91a94083a56f3071466937f157f870c763cf0eb3e47; output-bytes=51; shell=C:\WINDOWS\system32\cmd.exe; cwd=C:\Games\Interface\AddOns\ZugLoot; path=8086073e8118/21 entries

- [x] G4: Fuzz deserialization parsers against malformed base64, escape corruption, and ReDoS without unhandled exceptions
  CHECK: node tests/run.mjs tests/test_fuzz_deserialization.lua
  EXPECT: deserialization fuzzing and injection defense passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=7fb851ee2c6a10374d64834972d2a69eb95fad3d65ee033783a62dfbd27c7db7; exit=0; EXPECT=matched; output-sha256=d956c2107e335269b0c41cac584abace24e59784344da350925d24a40ee6e815; output-bytes=54; shell=C:\WINDOWS\system32\cmd.exe; cwd=C:\Games\Interface\AddOns\ZugLoot; path=8086073e8118/21 entries

- [x] G5: Eliminate idle Timer churn and enforce SavedVariables ring buffer bounds on history tables
  CHECK: node tests/run.mjs tests/test_memory_churn_bounds.lua
  EXPECT: memory churn and savedvariables bounds passed
  EVIDENCE: automatic-evidence=v1; definition-sha256=9b134bd4af69a8f935240a32d55b5728236fc2dbcbc4312f5015797666064246; exit=0; EXPECT=matched; output-sha256=ff9eac37746a69d1aa459abd091fadede7b7df789f48fb6a194b91275dfd2619; output-bytes=47; shell=C:\WINDOWS\system32\cmd.exe; cwd=C:\Games\Interface\AddOns\ZugLoot; path=8086073e8118/21 entries

- [x] G6: Verify full regression test suite passes with zero failures
  CHECK: node tests/run.mjs tests/run_tests.lua
  EXPECT: All tests passed.
  EVIDENCE: automatic-evidence=v1; definition-sha256=2b9811cd4160da91e3a94bf65f98fb6c4ff2d18d173a74a40ad419f21b576800; exit=0; EXPECT=matched; output-sha256=c66b0802773bba65eda050c14eb65c5e9d86b5b4f8ef3bf6d469acc0127da968; output-bytes=2646; shell=C:\WINDOWS\system32\cmd.exe; cwd=C:\Games\Interface\AddOns\ZugLoot; path=8086073e8118/21 entries
