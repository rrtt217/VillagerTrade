# VillagerTrade
This Cuberite Plugin adds "sort of" working villager trade to Cuberite. Unlike Vanilla, the villager has no professions/types due to the Lua API limit, instead the trade list may refresh, and the trade list itself is divided into several "professions". 

## v2 变更
- **村民唯一标识符**：每个村民分配 `职业+随机字符` 的标识符（存储在 CustomName，会持久化）。
- **持久化存储按村民**：经验和职业列表改按村民唯一标识符存储（`villager_data.txt`）。
- **v1→v2 迁移**：将 v1 的玩家经验分配给第一个新分配的对应职业村民（分配后清 0）；`player_trades.txt` 未记录职业，不做迁移。
- **交易刷新基于 Age**：村民交易在 Age 增长超过阈值时刷新，持久化保存上次刷新 Age。
- **阻止命名**：阻止玩家用命名牌给村民命名（保护标识符）。
- **村民刷怪蛋**：可配置开关的合成配方（绿宝石+鸡蛋）及交易（放在 vtGeneric 职业）。

# Features/ TODOs
- [x] Right click a Villager to open trade screen
- [x] Sync inventory in trade screen with actual trade screen
- [x] Fully-functional trade slots 
- [x] data-driven trade definition
- [x] trade experience and unlock level
- [x] save/load villager trade xp and trade list (v2: 按村民)
- [x] shift-left click in trade screen
- [x] 村民唯一标识符（CustomName）
- [x] v1→v2 数据迁移
- [x] 交易刷新基于 Age
- [x] 阻止玩家给村民命名
- [x] 村民刷怪蛋合成配方与交易
- [ ] shift-right click in trade screen
- [ ] several bug fixes
- [ ] remove Herobrine
