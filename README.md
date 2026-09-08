# VillagerTrade
This Cuberite Plugin adds "sort of" working villager trade to Cuberite. Unlike Vanilla, the villager has no professions/types due to the Lua API limit, instead the trade list may refresh, and the trade list itself is divided into several "professions". 

## v2.1 修复（本次全面测试后）
- **修复村民数据无法读取（严重）**：`villager_data.txt` 的读取正则比写出的字段多一组，导致永远解析失败；随后初始化末尾的保存又用内存数据覆盖文件，村民经验会整份丢失。现已可正常往返（含 `lastRefreshAge = -1` 占位处理）。
- **修复合成配方不消耗材料（严重）**：刷怪蛋配方此前只设置产物、未声明材料，可无限复制刷怪蛋。现在 `SetIngredient` + `SetResult` 同时设置。
- **交易窗口/村民状态按玩家隔离（高）**：原实现用全局窗口对象与全局 `CurrentVillagerID`，两名玩家同时交易会互相覆盖（后开窗者清空前者的村民 ID，前者点不动）。现按玩家 UUID（无 UUID 时用名字）分表保存窗口、村民 ID 与交易选择。
- **Shift+左键「尽量交易」修正（高）**：原实现对两个输入槽都扣同一数量，会白扣另一个槽的物品；现按各输入自身需求量扣减。
- **窗口尺寸与客户端一致**：窗口改为 3 槽（3 + 玩家背包 36 = 39 槽，与客户端村民交易窗口相同）。原来的 10x10 窗口会向客户端发送 136 个槽位，而客户端村民窗口只有 39 槽（Cuberite 文档明确警告可能崩溃客户端），并且镜像背包会导致槽位错乱、物品丢失。
- **`trades.txt` 物品名修正**：`lapis_lazuli` → `lapislazuli`，`chainmail_leggings` → `chainmain_leggings`（Cuberite 官方拼写）；此前这两条交易会生成空物品（玩家付钱拿不到东西）。新增无法识别物品名时的控制台告警。
- **热重载可用**：新增 `Info.lua`，插件名统一为 `VillagerTrade`（与文件夹一致）；此前 `reload_plugin` 无论用名字还是文件夹都会失败。
- **附魔等级修复**：`ByXpLevels-(a,b)` 写法此前不匹配解析模式，附魔等级恒为 0。
- **其他**：玩家离开时保存村民数据 + 每 5 分钟自动落盘（降低崩溃丢数据风险）；UUID 为空不再报错；关窗只掉落非空输入槽；v1→v2 迁移在多世界下不再重复分配；交易选择改为「右键输出槽循环切换」（原为点击槽 30 的临时补丁）。

## v2 变更
- **村民唯一标识符**：每个村民分配 `职业+随机字符` 的标识符（存储在 CustomName，会持久化）。
- **持久化存储按村民**：经验和职业列表改按村民唯一标识符存储（`villager_data.txt`）。
- **v1→v2 迁移**：将 v1 的玩家经验分配给第一个新分配的对应职业村民（分配后清 0）；`player_trades.txt` 未记录职业，不做迁移。
- **交易刷新基于 Age**：村民交易在 Age 增长超过阈值时刷新，持久化保存上次刷新 Age。
- **阻止命名**：阻止玩家用命名牌给村民命名（保护标识符）。
- **村民刷怪蛋**：可配置开关的合成配方（绿宝石+鸡蛋）及交易（放在 vtGeneric 职业）。
- **配置**：`settings.ini` 的 `[Features] EnableVillagerSpawnEggCrafting` 控制刷怪蛋合成（键名两侧不要加空格）。

# Features/ TODOs
- [x] Right click a Villager to open trade screen
- [x] 交易窗口使用与客户端一致的原版村民窗口（3 槽 + 背包），不再镜像背包
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
- [x] 右键输出槽循环切换匹配到的多条交易
- [ ] shift-right click in trade screen
- [ ] remove Herobrine
