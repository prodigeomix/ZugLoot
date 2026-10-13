-- ZugLoot/Constants.lua
-- Shared constants: version, comm prefix, roll caps, colors.
ZugLoot = ZugLoot or {}
ZugLoot.VERSION = "0.1.0"
ZugLoot.PREFIX = "ZugLoot"

ZugLoot.Caps = {
  SR = 100,
  MS = 100,
  OS = 99,
  TMOG = 98,
}

ZugLoot.RollType = {
  SR = "SR",
  MS = "MS",
  OS = "OS",
  TMOG = "TMOG",
}

-- LootBlare-parity roll list colors (hex w/o alpha edge cases handled by callers).
ZugLoot.Colors = {
  SR = "ffe5302d",
  MS = "FFFFFF00",
  OS = "FF00FF00",
  TM = "FF00FFFF",
  GOLD = "FFFFD700",
  GREY = "FF888888",
  GREEN = "FF00FF00",
  YELLOW = "FFFFFF00",
  RED = "FFFF0000",
}

ZugLoot.Limits = {
  DROP_LOG_MAX = 500,
  ROLL_TIMEOUT_DEFAULT = 15,
}
