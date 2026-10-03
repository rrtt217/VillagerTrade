# 32 位（ILP32 / armv6l）实机验证记录

2026-10-03，在 raspi（ARMv6 32 位，`~/cuberite/Cuberite`，ELF 32-bit LSB ARM EABI5，未 strip）
上用一个**独立临时实例**验证：新世界 `testworld`、端口 25570、只启用 `Core` + `ProfTest`，
跑完主动 `QueueSaveAllChunks` 后停止，解析区块 NBT 与模块读数逐一比对。

## 1. ILP32 偏移的测定（反汇编，非猜测）

`cVillager::cVillager(eVillagerType)` @ `0x1f5874` 尾段：

```asm
1f5a80: mvn  lr, #0                  ; lr = -1
1f5a88: ldr  r1, [sp, #12]           ; 职业参数
1f5a8c: str  r2, [r4]                ; vptr
1f5a90: str  r1, [r4, #892]  @ 0x37C ; m_Type = 职业        ← 目标
1f5a94: str  lr, [r4, #888]  @ 0x378 ; m_ActionCountDown = -1
1f5a98: str  r3, [ip, #896]! @ 0x380 ; m_FarmerAction = 0
1f5aac: add  r0, r4, #912 @ 0x390    ; m_Inventory (cItemGrid 8×1)
```

`cPlayer::GetInventory` 包装器 @ `0x45fb18`：`add r1, r5, #576 @ 0x240` + `tolua_pushusertype`
（**引用推送，无拷贝**）。`cCuboid.p2` @ `0x42dfc0`：`add r1, r4, #12` → 步长仍 12 字节。

| | LP64 (x86-64/aarch64) | ILP32 (armv6l/i386) |
|---|---|---|
| 锚点 `cPawn::m_Inventory` | 0x2F0 | 0x240 |
| `m_ActionCountDown` | 0x420 | 0x378 |
| **`m_Type`（职业）** | **0x424** | **0x37C** |
| `m_FarmerAction` | 0x428 | 0x380 |
| 步进（p2） | 12 | 12 |
| 闭合式 | 0x424−0x2F0 = 25×12+8 → 25 步读 `.z` | 0x37C−0x240 = 26×12+4 → 26 步读 `.y` |

## 2. 自校准为什么必须有"取值多样性"

错误布局**能通过三字段自检**——本机 LP64 上实测（14 只村民）：

```
raw lp64[prof=2 farmer=0 cd=-1] ilp32[prof=0 farmer=0 cd=0]     ← 错误布局恒定 0/0/0，完全"合理"
raw lp64[prof=4 farmer=0 cd=-1] ilp32[prof=0 farmer=0 cd=0]
raw lp64[prof=3 farmer=0 cd=-1] ilp32[prof=0 farmer=0 cd=0]
```

而在 32 位构建上，错误布局（lp64）会读到 `farmer=-1`（正好是 `m_ActionCountDown`）→ 被自检淘汰。
两种构建上的表现都记在模块日志里，见下。

## 3. 32 位运行日志（节选）

```
[13:49:59] [ProfTest:校准中] 村民=16 读到职业=15 布局=ilp32 available=true reason=nil
[13:49:59] [ProfTest:校准中] 候选 lp64  样本=0 淘汰=自检失败(职业=0 farmer=-1 countdown=0)
[13:49:59] [ProfTest:校准中] 候选 ilp32 样本=2 淘汰=nil
[13:50:16] [ProfTest:已锁定] 村民=16 读到职业=16 布局=ilp32 available=true reason=nil
[13:50:22] [ProfTest] 已请求存档（QueueSaveAllChunks），可停止服务并解析 NBT
[13:51:53] Shutdown successful!
```

## 4. 与引擎 NBT 的最终比对（16/16 全一致）

`testworld` 区块 (-1,0)、(-1,1) 在 `r.-1.0.mca`，(0,0)、(0,1) 在 `r.0.0.mca`：

| 坐标 (x,z) | 模块读数 | NBT `Profession` | | 坐标 (x,z) | 模块读数 | NBT `Profession` |
|---|---|---|---|---|---|---|
| (-4,0) | 5 | 5 ✓ | | (0,0) | 4 | 4 ✓ |
| (-3,0) | 5 | 5 ✓ | | (1,0) | 3 | 3 ✓ |
| (-2,0) | 1 | 1 ✓ | | (2,0) | 2 | 2 ✓ |
| (-1,0) | 3 | 3 ✓ | | (3,0) | 2 | 2 ✓ |
| (-4,1) | 0 | 0 ✓ | | (0,1) | 5 | 5 ✓ |
| (-3,1) | 4 | 4 ✓ | | (1,1) | 4 | 4 ✓ |
| (-2,1) | 1 | 1 ✓ | | (2,1) | 4 | 4 ✓ |
| (-1,1) | 3 | 3 ✓ | | (3,1) | 1 | 1 ✓ |

## 5. 复现步骤

```sh
# raspi 上：独立实例（不碰正在运行的服务器）
mkdir -p ~/cubtest/Plugins && cd ~/cuberite
cp Cuberite ~/cubtest/ && cp *.txt *.ini *.png ~/cubtest/ && cp -r Plugins/Core ~/cubtest/Plugins/
mkdir ~/cubtest/Plugins/ProfTest        # 上传本目录 ProfTest/{Info,main}.lua 与 villager_profession.lua
sed -i 's/^Ports=.*/Ports=25570/; s/^DefaultWorld=.*/DefaultWorld=testworld/' ~/cubtest/settings.ini
sed -i '/^World=/d' ~/cubtest/settings.ini    # [Plugins] 只留 Core=1 / ProfTest=1
cd ~/cubtest && setsid timeout -s INT 150 ./Cuberite > run.out 2>&1 < /dev/null &
# 读日志里的 ProfTest 行；结束后解析 NBT：
python3 docs/check_saved_professions.py <region文件> <chunkX> <chunkZ>
```

> 注意：Cuberite 在本机以非 `--detached` 方式从前台启动，stdin 关闭（EOF）时会随之退出；
> 远程无人值守跑测试时用 `--detached` 或如上包在 `setsid … < /dev/null` 里，并自行控制停止时机。
