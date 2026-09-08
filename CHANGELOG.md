# Changelog

**English** · [中文](CHANGELOG.zh-CN.md) · [README](README.md)

## v2.1 — 2026-09-08

Fixes found by a full test pass (static checks, server runtime probes, real client clicks).

### Fixed

- **Data loss (critical)** — `villager_data.txt` was never readable: the load pattern required one
  more field than `SaveVillagerData` writes, so every load reported 0 villagers and the save that
  `Initialize` performs right after then rewrote the file from memory, destroying all stored XP.
  The round trip now works, including the `-1` placeholder for "never refreshed".
- **Infinite villager spawn eggs (critical)** — the crafting recipe only set the result and never
  declared ingredients, so materials were never consumed. `SetIngredient` and `SetResult` are now
  both set.
- **Multi-player state corruption (high)** — the trade window, villager id and trade selection were
  global, so a second player opening a window wiped the first player's state. They are now stored
  per player (UUID, falling back to the player name), and a window only clears its own state.
- **Bulk trade destroyed items (high)** — Shift+left-click deducted the same amount from *both*
  input slots, consuming items the trade did not require. Each input is now deducted by its own
  requirement.
- **Bulk trade overflow (high)** — `cItem:AddCount` takes a signed 8-bit amount, so totals above
  ±127 wrapped around: 64 emeralds could be consumed for zero output. Counts are now computed
  explicitly, capped by the space available in the inventory, and the output is distributed over
  multiple slots (existing stacks first, then empty slots). A full inventory now reports
  "背包空间不足" instead of silently consuming the inputs.
- **Result slot could be looted** — the preview item in the result slot could be taken without
  paying once the inputs no longer matched. The slot is now plugin-owned: it rejects items, an
  unpaid preview is cleared instead of dropped, and it is discarded when the window closes.
- **Window size** — the window is now the vanilla villager window (3 slots + 36 inventory slots =
  39). The previous 10×10 window sent 136 slot entries to a client whose villager container has 39
  (Cuberite's own documentation warns this can crash the client) and mirrored the inventory into
  the wrong slots.
- **`trades.txt` item names** — `lapis_lazuli` → `lapislazuli`, `chainmail_leggings` →
  `chainmain_leggings` (Cuberite's spelling). Both produced empty items, so the player paid and
  received nothing. Unknown names are now logged.
- **Hot reload** — added `Info.lua` and renamed the plugin to `VillagerTrade` so the plugin name
  matches its folder; `reload_plugin` works again (previously both spellings failed).
- **Enchantments** — `ByXpLevels-(min,max)` did not match the parser pattern and always produced
  enchantment level 0.
- **Misc** — no crash when a player has an empty UUID; villager data is saved when a player leaves
  and every 5 minutes; only non-empty input slots are dropped on close; the v1→v2 migration no
  longer runs once per world; duplicate `DEBUGLOG` definition removed; zero-count "ghost" items
  are treated as empty slots.

### Added

- `Info.lua` (plugin metadata) and `settings.ini` (`[Features] EnableVillagerSpawnEggCrafting`).
- Right-clicking the result slot cycles matching trades, with a chat line showing the selection
  (`交易 2/4：…`); the selection resets when the matching set changes.
- Console warning when `trades.txt` contains an unknown item name.

### Changed

- The trade window no longer mirrors the player inventory — the client shows the real inventory.
- Selecting among matching trades moved from the old "click slot 30" workaround to right-clicking
  the result slot.

## v2 — 2026-08-09

- Per-villager identifier `vt-<profession>-<random>` stored in CustomName (persisted in the world).
- Per-villager persistence in `villager_data.txt` (XP + last refresh age).
- v1 → v2 migration: player XP is moved to the first villager of the matching profession.
- Trade refresh based on world age instead of villager age.
- Name-tag protection for plugin-managed villagers.
- Villager spawn egg recipe (emerald + egg) and a `vtGeneric` trade.

## v1 — 2025-12-26 … 2025-12-28

- Data-driven trade definitions (`trades.txt` + parser).
- Trade window with a synced inventory and shift+left-click support.
- Trade XP, unlock levels and per-player save/load (`player_trade_experience.txt`,
  `player_trades.txt`).
