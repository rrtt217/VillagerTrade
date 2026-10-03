# 用 tolua.cast 类型重解释读取村民真实职业 —— 研究记录

日期：2026-10-03（本机 x86-64 Cuberite，构建 2025-08-08，上游 master `3ec51bc`，源码见 raspi `~/compile-cuberite/cuberite`；
同一结论已在 raspi 的 **32 位 armv6l 构建**上实机复验，见 [ilp32-test/README.md](ilp32-test/README.md)）

## 结论

**可行。** 已实现为插件内模块 [villager_profession.lua](../villager_profession.lua)：

- **LP64（x86-64）**：16 只村民与引擎自己写进区块 NBT 的 `Profession` **16/16 一致**。
- **ILP32（armv6l，raspi 实机）**：另一套偏移，模块自校准切换到它，16 只村民同样 **16/16 一致**。

模块内置两套已用反汇编测定的布局，并在运行期自校准（见下文「平台适用性」）：确认前一律返回 nil，
确认后每次读取仍做自检，失败永久禁用。

```lua
-- 在实体存活的回调里同步调用（钩子 / DoWithEntityByID / ForEachEntity）：
local prof, meta = villager_profession.ReadProfession(Ent)   -- 0..5 或 nil
-- 0=vtFarmer 1=vtLibrarian 2=vtPriest 3=vtBlacksmith 4=vtButcher 5=vtGeneric
```

## 为什么正规 API 读不到

- `cVillager`（`src/Mobs/Villager.h`）**没有注册进 tolua 绑定**：APIDump 无此类，
  `debug.getregistry()` 里也没有 `cVillager` 键。直接 `tolua.cast(x, "cVillager")`
  会走 `tolua_pushusertype` 对 nil 元表 rawget 的路径 = **整服 SIGSEGV**，绝对禁止。
- 职业 `m_Type` 是 private，`GetVilType()` 未导出。
- **网络上会发（1.8–1.12 全都发）**：协议层按生物类型写元数据，村民那一支直接写 `GetVilType()`——
  1.8 `0x50`/BEInt32、1.9 索引 12/VarInt、1.10–1.12 `VILLAGER_PROFESSION`/VarInt，僵尸村民同理写 `GetProfession()`。
  也就是说**职业对客户端可见**（客户端按职业渲染外观），这正是"把引擎职业对齐到插件职业"的价值所在：
  对齐后外观与交易内容一致。（早先根据 1.13/1.14 分支得出"客户端不可见"是错的。）
- 职业只在两处真实存在：内存（`cVillager::m_Type`）与保存的区块 NBT
  （`NBTChunkSerializer.cpp:898` 写 `Profession`，`WSSAnvil.cpp:3238` 读回）。
  运行中的村民只能从内存拿。

## 类结构与字段布局（x86-64 / LP64）

```
cVillager : cPassiveMonster : cMonster : cPawn : cEntity   （cPassiveMonster 无数据成员）
```

`cVillager::cVillager(eVillagerType)` @ `0x83c380`（构造函数反汇编，布局的直接证据）：

```asm
call cPassiveMonster::cPassiveMonster   ; 基类构造
movl $0xffffffff, 0x420(%rbx)           ; m_ActionCountDown = -1
mov  %r13d,        0x424(%rbx)          ; m_Type = 职业参数   ← 目标字段
movups %xmm0,      0x428(%rbx)          ; m_FarmerAction=0 + m_CropsPos={0,0,0}（16B 合并写）
lea  0x438(%rbx),%rdi; cItemGrid(8,1)   ; m_Inventory（农民隐藏背包 8 格）
```

即 `sizeof(cMonster) = 0x420`，`offsetof(cVillager, m_Type) = 0x424`。

## 读取链（只借用已注册类型）

锚点：`cPlayer::GetInventory` 包装器 @ `0x6a0c90`：

```asm
tolua_tousertype(L, 1, "cPlayer")
add $0x2f0, %rax                        ; offsetof(cPawn/cPlayer, m_Inventory)
pushusertype(..., "cInventory")         ; 引用推送：无 new、无拷贝、无 tolua_register_gc
```

`GetInventory()` 是 **cPawn 的非虚内联方法**，返回的是对象内真实存在的成员子对象
（cVillager 也是 cPawn 后代，cPawn 基类子对象位于偏移 0——这不是危险的含义混淆调用，
读到的是语义正确的成员）。

步进：`cCuboid.p2` 访问器 @ `0x6866f0`：`add $0xc,%rbx; pushusertype(..., "Vector3<int>")`。
纯地址算术，getter **不解引用**；唯一的读发生在最后对 `Vector3<int>` 访问器
`.x/.y/.z`（int32 @ +0/+4/+8）的调用上。

数值闭合：

```
0x424 − 0x2F0 = 0x134 = 308 = 25×12 + 8
链：cast(Ent,"cPlayer"):GetInventory() → [cast(_,"cCuboid").p2] × 25 → 指针 +0x41C
    .y = +0x420  m_ActionCountDown
    .z = +0x424  m_Type ← 职业
    再一步 .x = +0x428  m_FarmerAction
```

## 验证（三重独立证据）

1. **构造函数字节码**：三个相邻字段的初值 -1 / 0..5 / 0..2 与读点完全对应。
2. **分布**：16 只新生成村民的职业覆盖 0..5（引擎 `GetRandomProfession()` 均匀随机），
   无一越界；非农夫的 countdown 恒为 -1（`TickFarmer` 在
   `VillagersShouldHarvestCrops=false` 时提前返回，与观察一致）。
3. **NBT 金标准**：`/save-all` 后用 [docs/check_saved_professions.py](check_saved_professions.py)
   解析 `world/region/r.0.0.mca`（注意：区块 NBT 根是 `Level` 复合标签，
   实体在其 `Entities` 列表），16 只村民按坐标逐一对位，`Profession` 值**全部一致**。

## 安全纪律（全部落实在模块里）

| 风险 | 处置 |
|---|---|
| cast 到未注册类型 = SIGSEGV | 只 cast `cPlayer`/`cCuboid`，且运行前用 `debug.getregistry()` 门控 |
| 虚调用派发到错误 vtable | 只调非虚、且读真实基类成员的方法（`GetInventory`/`GetMobType`），绝不调 cPlayer 其它方法 |
| 指针寿命 | 整条链在一次同步调用内完成，不跨 tick 持有任何指针/对象 userdata |
| 布局漂移（换构建/换平台） | 两套布局候选 + 三字段联合自检（0..5 / 0..2 / ≥−1）+ 跨村民取值多样性确认；确认后每次读取仍自检，失败永久降级返回 nil |
| 写坏内存 | 读取全程只读；写入仅限「已校准布局 + 原始 setter + 4 字节对齐写 + 立即回读校验」，失败永久禁用写入 |
| `__newindex` 成员赋值 | **禁止** `P.z = v`：实测破坏 Lua 栈平衡并让引擎 SIGABRT（见下文写入章节） |

## 平台适用性（LP64 / ILP32 双布局）

偏移随 ABI 变（指针宽度改变实体类布局），模块内置**两套实测布局**并在运行期自校准：

| | LP64（x86-64 / aarch64） | ILP32（armv6l / i386） |
|---|---|---|
| 锚点 `cPawn::m_Inventory` | 0x2F0 | 0x240 |
| `m_ActionCountDown` | 0x420 | 0x378 |
| **`m_Type`（职业）** | **0x424** | **0x37C** |
| `m_FarmerAction` | 0x428 | 0x380 |
| `cCuboid.p2` 步长 | 12 | 12（`Vector3<int>` 与指针宽度无关） |
| 闭合式 | 0x424−0x2F0 = 25×12+8 → 25 步读 `.z` | 0x37C−0x240 = 26×12+4 → 26 步读 `.y` |

ILP32 数据来自 raspi 上 32 位 ARM 二进制（`~/cuberite/Cuberite`，ELF 32-bit ARM EABI5，未 strip）的反汇编：
构造函数 `0x1f5874` 里 `str r1,[r4,#892]`（职业）、`str lr,[r4,#888]`（−1）、
`add r0,r4,#912`（cItemGrid）；`GetInventory` 包装器 `0x45fb18` 是 `add r1,r5,#576` + 引用推送。

### 为什么必须是「自校准 + 多样性」，而不是单点自检

三字段自检（职业 0..5、farmerAction 0..2、countdown ≥ −1）**单独不足以分辨布局**：
在 LP64 上试读 ILP32 布局会落到 `m_FarmerAction`/`m_CropsPos`，实测恒为 `prof=0 farmer=0 cd=0`，
完全「合理」；反过来在 ILP32 上试读 LP64 布局会读到 `farmer=-1`（正是 `m_ActionCountDown`）而被淘汰。

因此模块的判定规则是：

1. 每个候选先过三字段自检，在任一村民上失败即**永久淘汰**该候选；
2. 幸存候选累计样本，要求 **≥3 个样本且出现过 ≥2 种不同职业**才确认（错误布局读到的是常量，多样性恒为 1）；
3. 若其它候选都已被淘汰（结构上只剩一个），2 个样本即可确认；
4. 确认前一律返回 nil（fail-closed）；确认后每次读取仍自检，失败即永久禁用。

实测：LP64 上第 3 只村民确认 `lp64`；ILP32 上第 1 只村民就淘汰 `lp64` 候选，第 2 只确认 `ilp32`。

## 运行时写入：把引擎职业对齐为插件职业

写入用**类表上的原始 setter 闭包**（不是成员赋值）：

```lua
local Set = debug.getregistry()["Vector3<int>"][".set"]
Set.z(LandedPointer, Profession)   -- LP64：25 步落点 +0x41C，.z 即 +0x424
-- ILP32：26 步落点 +0x378，.y 即 +0x37C（组件由布局表自动派生）
```

- 反汇编可见这些闭包只做 `tolua_tonumber(L, 2, 0)` 再写 4 字节，**不碰 Lua 栈**。
- ⚠️ **绝不能用 `P.z = v` 成员赋值**：它走 `__newindex`，实测触发
  `Unable to re-balance Lua stack ... Expected at least 2 elements, got 1` 并 SIGABRT 整服。
- 写入后沿**新链**回读校验（不信任缓存指针）；不一致即永久禁用写入（读取不受影响）。
- 只在实体存活的同步回调内写（不跨 tick 持有指针），且必须已校准布局。

生产验证（本机 x86-64，由 VillagerTrade 插件自身执行；先人为把引擎职业改成错值）：

```
[14:55:58] [villager_profession] 自校准完成：布局 lp64（样本 11，职业种类 2）
[14:55:58] [VillagerTrade] 已对齐引擎职业: Farmer Bess -> 0      ← 修正人为写坏的 5
[14:57:59] [VillagerTrade] 已对齐引擎职业: Farmer Ann -> 0
[14:57:59] [VillagerTrade] 已对齐引擎职业: Farmer Jack -> 0
```

之后 `save-all` 并解析区块 NBT：`CustomName` 与 `Profession` 都与插件数据一致
（`Farmer Bess`/0、`Blacksmith Fred`/3 …），写入确实随 NBT 持久化。

**校准门槛**：插件侧先只读不写——必须先自校准（≥3 样本且 ≥2 种职业）。村民少的服务器要等几轮
20 秒扫描；在此之前对齐不生效（fail-closed），绝不会写错值。

**ILP32 写入已在 raspi 生产服务器上验证**（2026-10-03，插件自身完成 41 只村民的迁移/对齐，
无崩溃）。事后扫描 `world/region` 的区块 NBT，**12 只已迁移村民的名字与 `Profession` 全部一致**：

```
Butcher Lena/Olive/Ralph/Gus  prof=4      Librarian Fred/Uma   prof=1
Farmer Bob/Daisy             prof=0      Priest Bess/Tom/Ralph/Bill prof=2
（未迁移的 4 只仍是 vt-... 旧名 + 随机职业，说明懒迁移按设计工作）
```

## 已知边界与后续可能

- 引擎只在生成时随机职业（`Monster.cpp:1277`）或从 NBT 读回；插件采取"分配职业 → 写回引擎"，
  从而让外观（1.8–1.12 客户端按职业渲染）、AI（农夫种田）与交易内容一致。关闭
  `[Features] AlignRealProfession` 则只读不写（外观与交易可能不符）。
- 引擎没有持久实体 UUID：`CustomName` 就是村民身份。旧格式 `vt-<职业>-<随机码>` 在被看到时
  迁移为可读英文名 `<Profession> <Name>`（数据键同步搬移；迁移前自动备份
  `villager_data.txt.pre-migration.bak`）。名字必须保持唯一，重名自动加数字后缀。
- 职业分布仍由插件完全控制（虚拟职业为准，引擎职业被对齐过去），因此刷怪蛋/村庄布置
  依然可以按职业安排（后续可加"指定职业刷怪蛋"）。

## 复现工具链

```sh
# --- 本机 x86-64 (LP64) ---
nm -C Cuberite | grep cVillager::                       # 类存在性与符号
objdump -d --start-address=0x83c380 --stop-address=0x83c5f0 Cuberite  # 构造函数 → 字段偏移
nm Cuberite | grep -m1 tolua_AllToLua_cPlayer_GetInventory00          # 锚点包装器
objdump -d --start-address=0x6a0c90 --stop-address=0x6a0d30 Cuberite  # add $0x2f0
# 注册类型名（Vector3 的真名是 "Vector3<int>"，另有 const 别名；cCuboid/cPlayer 均已注册）

# --- raspi 32 位 armv6l (ILP32) ---
ssh raspi "cd ~/cuberite && nm -C Cuberite | grep -E 'cVillager::cVillager|tolua_AllToLua_cPlayer_GetInventory00'"
# 0x1f5874 / 0x45fb18；再 objdump -d 看 str r1,[r4,#892] 与 add r1,r5,#576

# --- 端到端验证（两个平台同一套流程）---
# 见 ilp32-test/README.md：独立临时实例 + ProfTest 插件 + 存档后解析 NBT
python3 docs/check_saved_professions.py <region文件> <chunkX> <chunkZ>
```
