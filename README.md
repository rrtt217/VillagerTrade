# VillagerTrade

**English** · [中文](README.zh-CN.md) · [Changelog](CHANGELOG.md)

A Cuberite plugin that adds "sort of working" villager trading. Cuberite's Lua API does not
expose the real villager profession, so the plugin gives every villager its own virtual
profession, a persistent identifier and a trade list that is refreshed over time.

## Features

- **Right-click a villager** to open the trade window (the vanilla villager window: two input
  slots, one result slot, plus your inventory).
- **Sneak + right-click** a villager to list its trades in chat instead of opening the window.
- **Per-villager identity**: each villager gets a `vt-<profession>-<random>` id stored in its
  CustomName (persisted in the world) and its own XP / last-refresh age in `villager_data.txt`.
- **Virtual professions** `vtFarmer` … `vtGeneric` (see `trades.txt`); a villager only offers
  trades of its own profession.
- **XP levels**: trading grants the villager XP and drops experience orbs for the player; levels
  1–3 at 100 / 300 / 600 XP unlock more trades.
- **Trade refresh**: a villager's trade list is regenerated after 5 minutes of world time.
- **Name-tag protection**: name tags cannot rename a plugin-managed villager.
- **Villager spawn eggs**: craft 1 emerald + 1 egg, or buy one from a `vtGeneric` villager
  (the crafting recipe has a switch in `settings.ini`).

## Install

Copy the `VillagerTrade` folder into `<server>/Plugins/` and restart the server (or reload
plugins). Developed and tested against Cuberite's 1.12.2 protocol; the trade window layout
matches the vanilla villager window.

## Configuration — `settings.ini`

```ini
[Features]
EnableVillagerSpawnEggCrafting=1
```

- Write keys **without spaces around `=`**. Cuberite counts those spaces as part of the key name,
  the lookup fails, and the option silently falls back to its default.
- Reload the plugin after editing (`/reload` or the console `reload`).

## Using the trade window

| Action | Effect |
|---|---|
| Put items into slot 0 / 1 | Trade inputs (slot 1 is only used by two-input trades) |
| Left-click the result slot (2) | Perform **one** trade |
| Shift + left-click the result slot | Perform **as many trades as fit**; the output is placed into your inventory (existing stacks are filled first, then empty slots) |
| Right-click the result slot | **Cycle** through every trade that currently matches the inputs |
| Shift + right-click on slots 0–2 | Disabled |
| Close the window | Unused inputs are dropped at your feet; the result preview is discarded |

The result slot is owned by the plugin: it never accepts items, and a preview that was not paid
for disappears as soon as the inputs stop matching — it cannot be looted.

### Switching between trades with identical inputs

Several entries in `trades.txt` can match the same inputs (for example `1 emerald` matches every
`emerald -> …` entry whose `(min,max)` range allows one). The result slot always shows the
**currently selected** entry, and **right-clicking the result slot cycles to the next match**.
While more than one entry matches, the plugin reports the selection in chat:

```
[VillagerTrade] 交易 2/4：2x emerald -> 1x whitewool
```

The selection resets to the first match whenever the set of matching trades changes (for example
after you add or remove an input), so you always start from a predictable state. If two entries
look identical, cycling is still meaningful for randomly generated outputs: each entry rolls its
own counts and enchantments when the list is generated.

## `trades.txt` format

```
<Input1>, (<min>,<max>) [; <Input2>, (<min>,<max>)] = <Output>, (<min>,<max>) | <Weight> | <Profession> | <UnlockLevel> | <TradeXp>
```

- Item names use Cuberite's spelling (`lapislazuli`, `chainmain_leggings` — the official typo) or
  a numeric item id.
- `^damage` sets the item damage (e.g. `spawn_egg^120`); `-"<Enchantments>"` sets enchantments
  (`"id=lvl;…"` or `"ByXpLevels(min,max)"`).
- `Weight` is the probability (0–1) that the entry is included when a trade list is generated.
- `Profession`: 0 = vtFarmer, 1 = vtLibrarian, 2 = vtPriest, 3 = vtBlacksmith, 4 = vtButcher,
  5 = vtGeneric. `UnlockLevel` is 0–3.
- Unknown item names are logged to the console instead of silently producing an empty trade.

## Data storage

`villager_data.txt`, one line per villager:

```
<villagerID> = <profession> | <xp1> | … | <xp6> | <lastRefreshWorldAge>
```

Written when a player leaves, every 5 minutes, and when the plugin unloads or the server stops.
`-1` in the last field means "never refreshed".

## Known limitations

- Shift + right-click has no behaviour (blocked on purpose).
- Cuberite's default click handling can leave zero-count "ghost" items behind after a pick-up;
  the plugin treats such slots as empty.
- Villager professions are virtual — the Lua API cannot read the real villager profession.
- Trade lists live in memory and are regenerated on demand; only the refresh age is persisted.
- `player_trades.txt` / `player_trade_experience.txt` are v1 files kept only for migration.
