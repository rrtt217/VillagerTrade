-- ProfTest：32 位实机验证村民职业重解释读取（配合 villager_profession.lua，二者同目录会被合并加载）
-- 流程：tick 20 起找地面生成 16 只村民 → tick 300 读取职业并写日志（校准阶段会返回 nil）→
--       tick 500 再读一次（此时应已锁定布局）→ 外部用 timeout -s INT 停止，保存后解析 NBT 核对。

local TICKS = 0
local SPAWNED = false

local function FindGround(World, x, z)
    for y = 100, 3, -1 do
        if World:GetBlock(x, y, z) ~= 0 then
            return y
        end
    end
    return nil
end

local function TrySpawn(World)
    if SPAWNED then
        return
    end
    local sx, sz = World:GetSpawnX(), World:GetSpawnZ()
    local y = FindGround(World, sx, sz)
    if y == nil then
        return   -- 区块还没加载，下个检查点再试
    end
    SPAWNED = true
    LOG(("ProfTest: 地面 %d,%d,%d，开始生成村民"):format(sx, y, sz))
    for i = 0, 15 do
        local Id = World:SpawnMob(sx + (i % 8) - 4, y + 1, sz + math.floor(i / 8), mtVillager, false)
        LOG(("ProfTest: 生成村民 #%d id=%s"):format(i, tostring(Id)))
    end
end

local function ReportProfessions(World, Tag)
    local Total, Read = 0, 0
    World:ForEachEntity(function(Ent)
        local Ok = pcall(function()
            if (tolua.cast(Ent, "cMonster")):GetMobType() ~= mtVillager then
                return
            end
            Total = Total + 1
            local Prof, Meta = villager_profession.ReadProfession(Ent)
            if Prof ~= nil then
                Read = Read + 1
            end
            LOG(("[ProfTest:%s] villager %s pos=(%.0f,%.0f,%.0f) prof=%s cd=%s"):format(
                Tag, tostring(Ent:GetUniqueID()), Ent:GetPosX(), Ent:GetPosY(), Ent:GetPosZ(),
                tostring(Prof), Meta and tostring(Meta.countdown) or "-"))
        end)
        if not Ok then
            LOG("[ProfTest] 读取异常")
        end
        return false
    end)
    local St = villager_profession.GetStatus()
    LOG(("[ProfTest:%s] 村民=%d 读到职业=%d 布局=%s available=%s reason=%s"):format(
        Tag, Total, Read, tostring(St.layout), tostring(St.available), tostring(St.reason)))
    for Name, C in pairs(St.candidates) do
        LOG(("[ProfTest:%s] 候选 %s 样本=%d 淘汰=%s"):format(Tag, Name, C.samples, tostring(C.eliminated)))
    end
end

function Initialize(Plugin)
    Plugin:SetName("ProfTest")
    Plugin:SetVersion(1)
    cPluginManager.AddHook(cPluginManager.HOOK_WORLD_TICK, OnWorldTick)
    LOG("ProfTest: 初始化完成，等 tick 20 开始")
    return true
end

function OnDisable()
    LOG("ProfTest: 卸载")
end

function OnWorldTick(World, TimeDelta)
    TICKS = TICKS + 1
    if (not SPAWNED) and ((TICKS % 40) == 0) then
        TrySpawn(World)   -- 新世界生成慢：每 40 tick 重试直到成功
    elseif TICKS == 400 then
        ReportProfessions(World, "校准中")
    elseif TICKS == 700 then
        ReportProfessions(World, "已锁定")
    elseif TICKS == 800 then
        World:QueueSaveAllChunks()
        LOG("ProfTest: 已请求存档（QueueSaveAllChunks），可停止服务并解析 NBT")
    end
    return false
end
