-- iron_golem_guard.lua
-- 铁傀儡：守卫行为 + 村庄里的"周期性满足条件才生成"（原型，默认关闭，见 settings.ini [IronGolem]）
--
-- 两部分：
--   ① 守卫（EnableGuard）：让**已经存在**的铁傀儡攻击附近的敌对怪。
--   ② 村庄生成（EnableVillageGolemSpawning）：周期性检查"含门村庄区块"，当
--      「门数达标 + 附近村民数达标 + 附近铁傀儡数未达上限」时生成一只守卫。
--      注意：**不在扫描到区块的那一刻生成**，一切生成都发生在这个周期判定里。
--      （严格 1.12 的村庄聚合——门 > 20、傀儡数 < 村民数/10、每 tick 1/7000——留作后续。）
--
-- 守卫部分的背景（源码 + 运行时均已核实）：
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
-- 模拟伤害的最小化（守卫部分最在意的点）：
--   Core 插件在 HOOK_TAKE_DAMAGE 里按**攻击者类**覆盖 FinalDamage
--   （MobDamages[cZombie]={2,3,4}、MobDamages[cSkeleton]={2,2,3}……按世界难度取下标）。
--   所以只要攻击者是这些常见敌对怪，注入给傀儡的伤害至少就是 2/3/4（普通难度=3），
--   我们传的 RawDamage 再小也会被覆盖。因此这里：
--     1) 用 4 参重载 TakeDamage(dtMobAttack, enemy, 1, 0)：RawDamage=1、Knockback=0；
--     2) 注入后立刻把掉的血 Heal 回去 —— 傀儡**净损失为 0**；
--     3) 同目标冷却 + 每傀儡全局最小注入间隔两道节流，避免受击音效被反复触发。

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

-- 村庄铁傀儡生成（周期性"满足条件才生成"，默认关闭）
iron_golem_guard.EnableVillageGolemSpawning = false
-- 区块内至少多少扇门才认为"这里有村庄"
iron_golem_guard.MinDoorsInChunk = 2
-- 半径内至少多少名村民才生成守卫（1.12 是"傀儡数 < 村民数/10"，这里先用绝对阈值近似）
iron_golem_guard.MinVillagers = 3
-- 半径内最多维持多少只铁傀儡
iron_golem_guard.MaxGolemsPerVillage = 2
-- 统计"附近村民/傀儡"的半径。必须覆盖村庄跨度，否则相邻区块互相看不到对方生成的傀儡，
-- 上限就形同虚设（实测：24 时一个村庄出 5 只；48 时仍出 3 只——村庄跨约 96 格；
-- 64 时能覆盖常见村庄，稳定 1~2 只）。严格解决需要先做村庄聚合。
iron_golem_guard.VillageGolemRadius = 64
-- 村庄生成检查间隔（秒）
iron_golem_guard.VillageCheckSeconds = 30

-- ============================================================================
-- 内部状态（插件重载即重置）
-- ============================================================================
local LastCheckAge = {}          -- worldName -> 上次守卫检查的世界年龄
local LastVillageCheckAge = {}   -- worldName -> 上次村庄生成检查的世界年龄
local GolemState = {}            -- golemUniqueID -> { enemyID =, nextInjectAge =, nextAnyInjectAge =, issuedPos = }
-- 同一轮检查里刚生成的傀儡（cWorld:ForEachEntity 要到下一 tick 才看得到），
-- 用于让 MaxGolemsPerVillage 的计数准确。
local RecentGolems = {}          -- { { x =, z =, age = } }

iron_golem_guard.InjectCount = 0
iron_golem_guard.PursueCount = 0
iron_golem_guard.SpawnCount = 0

local function DistanceSq(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return dx * dx + dy * dy + dz * dz
end

local function CountPointsNear(points, x, z, radiusSq)
    local count = 0
    for _, point in ipairs(points) do
        local dx, dz = point.x - x, point.z - z
        if dx * dx + dz * dz <= radiusSq then
            count = count + 1
        end
    end
    return count
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
-- ① 守卫：目标注入 + 追击
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

local function GuardTick(World)
    local worldName = World:GetName()
    local age = World:GetWorldAge()
    local interval = iron_golem_guard.CheckIntervalTicks
    if age - (LastCheckAge[worldName] or (-interval - 1)) < interval then
        return
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
        return
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
end

-- ============================================================================
-- ② 村庄生成：周期性"满足条件才生成"（扫描阶段不生成任何东西）
-- ============================================================================

local function TrySpawnVillageGolem(World, chunk, villagers, golems, radiusSq, worldAge)
    if chunk.doors < iron_golem_guard.MinDoorsInChunk then
        return
    end
    local baseX, baseZ = chunk.cx * 16, chunk.cz * 16
    local centerX, centerZ = baseX + 8, baseZ + 8

    -- 区块必须已加载（村民/傀儡/方块都只能看到已加载的部分）
    if not World:TryGetHeight(centerX, centerZ) then
        return
    end
    -- 条件 1：附近村民数量达标
    if CountPointsNear(villagers, centerX, centerZ, radiusSq) < iron_golem_guard.MinVillagers then
        return
    end
    -- 条件 2：附近傀儡数量未达上限（含本轮刚生成的）
    local golemCount = CountPointsNear(golems, centerX, centerZ, radiusSq)
        + CountPointsNear(RecentGolems, centerX, centerZ, radiusSq)
    if golemCount >= iron_golem_guard.MaxGolemsPerVillage then
        return
    end

    -- 生成位置：优先用扫描时记下的那扇门，否则用区块中心的地面
    local x, z, y
    if chunk.doorX then
        x = baseX + chunk.doorX + 0.5
        z = baseZ + chunk.doorZ + 0.5
        y = chunk.doorY
    else
        x = centerX + 0.5
        z = centerZ + 0.5
        local ok, height = World:TryGetHeight(centerX, centerZ)
        y = ok and (height + 1) or nil
    end
    if not y then
        return
    end

    local id = World:SpawnMob(x, y, z, mtIronGolem, false)
    if id and id >= 0 then
        RecentGolems[#RecentGolems + 1] = { x = x, z = z, age = worldAge }
        iron_golem_guard.SpawnCount = iron_golem_guard.SpawnCount + 1
        LOG("村庄铁傀儡：区块(" .. chunk.cx .. "," .. chunk.cz .. ") 门=" .. chunk.doors
            .. " 附近傀儡=" .. golemCount .. "，满足条件，生成 1 只。")
    end
end

local function VillageSpawnTick(World)
    if not (VillageLife and VillageLife.GetVillageChunks) then
        return
    end
    local worldName = World:GetName()
    local age = World:GetWorldAge()
    local interval = iron_golem_guard.VillageCheckSeconds * 20
    if age - (LastVillageCheckAge[worldName] or (-interval - 1)) < interval then
        return
    end
    LastVillageCheckAge[worldName] = age

    -- 一次遍历收集村民 / 傀儡位置
    local villagers, golems = {}, {}
    World:ForEachEntity(function(Entity)
        if Entity:IsMob() then
            local mobType = Entity:GetMobType()
            if (mobType == mtVillager) or (mobType == mtIronGolem) then
                local pos = Entity:GetPosition()
                local list = (mobType == mtVillager) and villagers or golems
                list[#list + 1] = { x = pos.x, z = pos.z }
            end
        end
        return false
    end)

    -- 清理过期的"刚生成"记录
    local kept = {}
    for _, recent in ipairs(RecentGolems) do
        if age - recent.age <= 100 then
            kept[#kept + 1] = recent
        end
    end
    RecentGolems = kept

    local radiusSq = iron_golem_guard.VillageGolemRadius * iron_golem_guard.VillageGolemRadius
    for _, chunk in ipairs(VillageLife.GetVillageChunks()) do
        if chunk.world == worldName then
            TrySpawnVillageGolem(World, chunk, villagers, golems, radiusSq, age)
        end
    end
end

-- ============================================================================
-- 钩子入口
-- ============================================================================
function iron_golem_guard.OnWorldTick(World, TimeDelta)
    if iron_golem_guard.EnableGuard then
        GuardTick(World)
    end
    if iron_golem_guard.EnableVillageGolemSpawning then
        VillageSpawnTick(World)
    end
    return false
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
        "IronGolemGuard: 守卫=%s 村庄生成=%s 注入=%d 追击=%d 村庄生成数=%d 跟踪傀儡=%d 半径=%d 冷却=%ds",
        tostring(iron_golem_guard.EnableGuard), tostring(iron_golem_guard.EnableVillageGolemSpawning),
        iron_golem_guard.InjectCount, iron_golem_guard.PursueCount, iron_golem_guard.SpawnCount,
        tracked, iron_golem_guard.GuardRadius, iron_golem_guard.InjectCooldownSeconds)
end

return iron_golem_guard
