-- iron_golem_guard.lua
-- 村庄铁傀儡守卫（原型，默认关闭，见 settings.ini [IronGolem]）
--
-- 背景（源码 + 运行时均已核实）：
--   * 类链是 cIronGolem : cPassiveAggressiveMonster : cAggressiveMonster : cMonster : cPawn
--     —— 铁傀儡就是 cMonster，并且继承了完整的战斗 AI：
--         InStateChasing()  -> MoveToPosition(target)
--         Tick()            -> target!=null && TargetIsInRange() && LineOfSightTrace() 时 Attack()
--         Attack()          -> target:TakeDamage(dtMobAttack, this, m_AttackDamage, 9)
--       （伤害来自 monsters.ini [IronGolem] AttackDamage=6.0，再经 Core 的难度表缩放）
--   * 唯一缺的是"目标获取"：cPassiveAggressiveMonster 把 m_EMPersonality 设为 PASSIVE，
--     并把 EventSeePlayer() 覆写成空实现 —— 中性怪不会主动锁定，只有**挨打**时
--     cMonster::DoTakeDamage() 才会 SetTarget(TDI.Attacker)。
--   * Lua 侧没有 GetTarget/SetTarget 绑定，所以插件只能"伪造一次攻击"来注入目标。
--
-- 模拟伤害的最小化（这是本模块最在意的点）：
--   Core 插件在 HOOK_TAKE_DAMAGE 里按**攻击者类**覆盖 FinalDamage
--   （MobDamages[cZombie]={2,3,4}、MobDamages[cSkeleton]={2,2,3}……按世界难度取下标）。
--   所以只要攻击者是这些常见敌对怪，注入给傀儡的伤害至少就是 2/3/4（普通难度=3），
--   我们传的 RawDamage 再小也会被覆盖。因此这里：
--     1) 用 4 参重载 TakeDamage(dtMobAttack, enemy, 1, 0)：RawDamage=1、Knockback=0
--        （对不在难度表里的攻击者，实际就只掉 1 点）；
--     2) 注入后立刻把掉的血 Heal 回去 —— 傀儡**净损失为 0**；
--     3) 同一个傀儡对同一个目标只注入一次，另加 InjectCooldownSeconds 兜底，
--        避免 cMonster::DoTakeDamage 里的受击音效被反复触发。

local iron_golem_guard = {}

-- ============================================================================
-- 配置（默认值；Initialize 中由 settings.ini [IronGolem] 覆盖）
-- ============================================================================
iron_golem_guard.EnableGuard = false
-- 傀儡搜索敌对怪物的半径（格）
iron_golem_guard.GuardRadius = 16
-- 搜索间隔（tick）
iron_golem_guard.CheckIntervalTicks = 20
-- 同一傀儡对同一目标的最短重复注入间隔（秒，兜底用）
iron_golem_guard.InjectCooldownSeconds = 10
-- 同一傀儡的"全局"最小注入间隔（秒）：不管目标换没换，两次注入至少隔这么久。
-- 人海战里目标会频繁切换，没有它会出现大量"刚注入完又换目标再注入"的无效伤害/音效。
iron_golem_guard.MinInjectIntervalSeconds = 2
-- 注入后把模拟伤害补回去（净损失 0）
iron_golem_guard.HealAfterInject = true
-- 需要视线才注入
iron_golem_guard.RequireLineOfSight = true
-- 是否替傀儡下发追击路径（cMonster:MoveToPosition）
iron_golem_guard.PursueTarget = true
-- 进入这个距离就停止追击，把最后一击交给引擎的 Attack()
iron_golem_guard.PursueStopDistance = 2.0
-- 目标移动超过这个距离才重新下发路径（避免每 tick 重置寻路）
iron_golem_guard.PursueRefreshDistance = 1.5

-- 村庄铁傀儡生成（简化版，默认关闭）
iron_golem_guard.EnableVillageGolemSpawning = false
-- 区块内至少多少扇门才认为"这里有村庄"
iron_golem_guard.MinDoorsInChunk = 2
-- 半径内最多维持多少只铁傀儡
iron_golem_guard.MaxGolemsPerVillage = 2
-- 统计"附近已有多少只傀儡"的半径。必须大于村庄跨度（约 48~96 格），
-- 否则相邻区块互相看不到对方生成的傀儡，上限就形同虚设（实测 24 时一个村庄出了 5 只）。
iron_golem_guard.VillageGolemRadius = 48

-- ============================================================================
-- 内部状态（插件重载即重置）
-- ============================================================================
local LastCheckAge = {}   -- worldName -> 上次检查的世界年龄
local GolemState = {}     -- golemUniqueID -> { enemyID =, nextInjectAge =, issuedPos = }
-- 同一 tick 内刚生成的傀儡（cWorld:ForEachEntity 要到下一 tick 才看得到），
-- 用于让 MaxGolemsPerVillage 的计数在同一批扫描里也准确。
local RecentGolems = {}   -- { { x =, z =, age = } }

iron_golem_guard.InjectCount = 0
iron_golem_guard.PursueCount = 0
iron_golem_guard.SpawnCount = 0

local function DistanceSq(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

local function HasLineOfSight(World, a, b)
    if not iron_golem_guard.RequireLineOfSight then
        return true
    end
    return cLineBlockTracer:LineOfSightTrace(World,
        Vector3d(a.x, a.y + 1.0, a.z),
        Vector3d(b.x, b.y + 1.0, b.z),
        cLineBlockTracer.losAir)
end

-- ============================================================================
-- 目标注入
-- ============================================================================

-- 伪造"敌人打了傀儡一次"。引擎随即 cMonster::DoTakeDamage -> SetTarget(敌人)，
-- 之后追击 / 寻路 / 攻击 / 冷却 / 击退 / 难度伤害全部由 cAggressiveMonster 处理。
local function InjectTarget(golem, enemy, worldAge)
    local golemID = golem:GetUniqueID()
    local enemyID = enemy:GetUniqueID()
    local state = GolemState[golemID]
    if state and (state.enemyID == enemyID) and (worldAge < (state.nextInjectAge or 0)) then
        return false
    end
    -- 全局最小间隔：换目标也不能绕开
    if state and (worldAge < (state.nextAnyInjectAge or 0)) then
        return false
    end
    local healthBefore = golem:GetHealth()
    if healthBefore <= 5 then
        return false   -- 太残血，别拿模拟伤害冒险
    end

    golem:TakeDamage(dtMobAttack, enemy, 1, 0)
    local healthAfter = golem:GetHealth()
    local damageTaken = healthBefore - healthAfter

    if iron_golem_guard.HealAfterInject and damageTaken > 0 then
        golem:Heal(damageTaken)   -- 把模拟伤害补回去，净损失 0
    end

    GolemState[golemID] = {
        enemyID = enemyID,
        nextInjectAge = worldAge + iron_golem_guard.InjectCooldownSeconds * 20,
        nextAnyInjectAge = worldAge + iron_golem_guard.MinInjectIntervalSeconds * 20,
        issuedPos = nil,
    }
    iron_golem_guard.InjectCount = iron_golem_guard.InjectCount + 1
    DEBUGLOG(string.format("铁傀儡 %d 注入目标 enemy=%d（实际伤害 %d，已补回）",
        golemID, enemyID, damageTaken))
    return true
end

-- 引擎只在"目标进入攻击距离"时才 Attack()；对非玩家目标它不会自己切到 CHASING，
-- 所以由插件用 cMonster:MoveToPosition（引擎自己的 pathfinder）把傀儡带过去，
-- 进入 PursueStopDistance 后停手，交给 Attack() 收尾。
local function PursueTarget(golem, enemy, distanceSq)
    if not iron_golem_guard.PursueTarget then
        return
    end
    local stopSq = iron_golem_guard.PursueStopDistance * iron_golem_guard.PursueStopDistance
    if distanceSq <= stopSq then
        return
    end
    local state = GolemState[golem:GetUniqueID()]
    if not state then
        return
    end
    local enemyPos = enemy:GetPosition()
    local refreshSq = iron_golem_guard.PursueRefreshDistance * iron_golem_guard.PursueRefreshDistance
    if state.issuedPos and (DistanceSq(state.issuedPos, enemyPos) <= refreshSq) then
        return
    end
    golem:MoveToPosition(enemyPos)
    state.issuedPos = { x = enemyPos.x, y = enemyPos.y, z = enemyPos.z }
    iron_golem_guard.PursueCount = iron_golem_guard.PursueCount + 1
end

function iron_golem_guard.OnWorldTick(World, TimeDelta)
    if not iron_golem_guard.EnableGuard then
        return false
    end

    local worldName = World:GetName()
    local age = World:GetWorldAge()
    local interval = iron_golem_guard.CheckIntervalTicks
    if age - (LastCheckAge[worldName] or (-interval - 1)) < interval then
        return false
    end
    LastCheckAge[worldName] = age

    local golems, hostiles = {}, {}
    World:ForEachEntity(function(Entity)
        if Entity:IsMob() then
            if Entity:GetMobType() == mtIronGolem then
                golems[#golems + 1] = Entity
            elseif Entity:GetMobFamily() == cMonster.mfHostile then
                hostiles[#hostiles + 1] = Entity
            end
        end
        return false
    end)
    if (#golems == 0) or (#hostiles == 0) then
        return false
    end

    local radiusSq = iron_golem_guard.GuardRadius * iron_golem_guard.GuardRadius
    for _, golem in ipairs(golems) do
        local golemPos = golem:GetPosition()
        local target, targetDist = nil, radiusSq
        for _, hostile in ipairs(hostiles) do
            local hostilePos = hostile:GetPosition()
            local dist = DistanceSq(golemPos, hostilePos)
            if (dist <= targetDist) and HasLineOfSight(World, golemPos, hostilePos) then
                target, targetDist = hostile, dist
            end
        end
        if target then
            InjectTarget(golem, target, age)
            PursueTarget(golem, target, targetDist)
        else
            -- 保留 nextInjectAge（冷却），只清掉当前目标，避免短时间内反复注入
            local state = GolemState[golem:GetUniqueID()]
            if state then
                state.enemyID = nil
                state.issuedPos = nil
            end
        end
    end
    return false
end

-- ============================================================================
-- 村庄铁傀儡生成（简化版，由 village_life 在扫描到含门的村庄区块时回调）
-- ============================================================================
-- 真实 1.12 是"村庄级"判定：门 > 20 且 铁傀儡数 < 村民数/10，每 tick 1/7000 概率，
-- 需要先把门聚合为村庄（中心/半径/村民数）。这里先用"区块门数 + 附近傀儡上限"近似，
-- 保证村庄里能稳定出现 1~2 只守卫；要严格还原 1.12 需要补村庄聚合。
function iron_golem_guard.OnVillageChunkScanned(World, chunkX, chunkZ, doors)
    if not iron_golem_guard.EnableVillageGolemSpawning then
        return
    end
    if #doors < iron_golem_guard.MinDoorsInChunk then
        return
    end

    local baseX, baseZ = chunkX * 16, chunkZ * 16
    local centerX, centerZ = baseX + 8, baseZ + 8
    local radiusSq = iron_golem_guard.VillageGolemRadius * iron_golem_guard.VillageGolemRadius

    local worldAge = World:GetWorldAge()
    local keptRecent = {}
    for _, recent in ipairs(RecentGolems) do
        if worldAge - recent.age <= 40 then
            keptRecent[#keptRecent + 1] = recent
        end
    end
    RecentGolems = keptRecent

    local golemCount = 0
    World:ForEachEntity(function(Entity)
        if Entity:IsMob() and (Entity:GetMobType() == mtIronGolem) then
            local pos = Entity:GetPosition()
            local dx, dz = pos.x - centerX, pos.z - centerZ
            if dx * dx + dz * dz <= radiusSq then
                golemCount = golemCount + 1
            end
        end
        return false
    end)
    for _, recent in ipairs(RecentGolems) do
        local dx, dz = recent.x - centerX, recent.z - centerZ
        if dx * dx + dz * dz <= radiusSq then
            golemCount = golemCount + 1
        end
    end
    if golemCount >= iron_golem_guard.MaxGolemsPerVillage then
        return
    end

    local random = VillagerManager and VillagerManager.Random
    local index = random and random.Int(1, #doors) or 1
    local door = doors[index]
    local id = World:SpawnMob(baseX + door.x + 0.5, door.y, baseZ + door.z + 0.5, mtIronGolem, false)
    if id and id >= 0 then
        RecentGolems[#RecentGolems + 1] = { x = baseX + door.x, z = baseZ + door.z, age = worldAge }
        iron_golem_guard.SpawnCount = iron_golem_guard.SpawnCount + 1
        LOG("村庄铁傀儡：区块(" .. chunkX .. "," .. chunkZ .. ") 附近已有 " .. golemCount
            .. " 只，生成 1 只（该区块 " .. #doors .. " 扇门）。")
    end
end

-- ============================================================================
-- 状态查询（控制台命令 golemguard）
-- ============================================================================
function iron_golem_guard.GetStatus()
    local tracked = 0
    for _ in pairs(GolemState) do
        tracked = tracked + 1
    end
    return string.format(
        "IronGolemGuard: 守卫=%s 村庄生成=%s 注入=%d 追击=%d 跟踪傀儡=%d 村庄生成数=%d 半径=%d 冷却=%ds",
        tostring(iron_golem_guard.EnableGuard), tostring(iron_golem_guard.EnableVillageGolemSpawning),
        iron_golem_guard.InjectCount, iron_golem_guard.PursueCount, tracked,
        iron_golem_guard.SpawnCount, iron_golem_guard.GuardRadius, iron_golem_guard.InjectCooldownSeconds)
end

return iron_golem_guard
