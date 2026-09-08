-- villager_manager.lua
-- v2 核心模块：管理村民唯一标识符、村民数据（经验/上次刷新世界年龄）、v1->v2 迁移。
--
-- 设计说明：
--   * 村民唯一标识符使用 CustomName（会持久化到 NBT，服务器重启后保留）。
--   * 标识符格式：<职业编号>-<随机字符>，例如 "0-a1b2c3"。
--     由于 Lua 无法读取村民真实职业（cVillager 未导出），职业是插件虚拟分配的。
--   * 村民数据按标识符存储到 villager_data.txt：
--       <villagerID> = <profession> | <xp1> | <xp2> | <xp3> | <xp4> | <xp5> | <xp6> | <lastRefreshWorldAge>
--     lastRefreshWorldAge 为上次刷新交易时的世界 tick 年龄（World:GetWorldAge()）。
--     注意：村民的 GetAge() 不是 tick 数而是年龄状态（负数=幼年，1=成年），成年后恒为 1，不能作为刷新依据。
--
-- 职业编号（与 trades.txt 中 vtXXX 对应）：
--   0 = vtFarmer, 1 = vtLibrarian, 2 = vtPriest, 3 = vtBlacksmith, 4 = vtButcher, 5 = vtGeneric

local villager_manager = {}

-- 职业名称表（用于标识符前缀）
villager_manager.PROFESSION_NAMES = {
    [0] = "farmer",
    [1] = "librarian",
    [2] = "priest",
    [3] = "blacksmith",
    [4] = "butcher",
    [5] = "generic",
}

-- 职业编号 -> 名称
villager_manager.PROFESSION_NUM_TO_NAME = villager_manager.PROFESSION_NAMES

-- 职业名称 -> 编号
villager_manager.PROFESSION_NAME_TO_NUM = {}
for num, name in pairs(villager_manager.PROFESSION_NAMES) do
    villager_manager.PROFESSION_NAME_TO_NUM[name] = num
end

-- 标识符前缀（用于识别我们分配的村民名字）
villager_manager.ID_PREFIX = "vt-"

-- 村民数据表：villagerID -> { profession = <num>, xp = {6个}, lastRefreshAge = <num> }
villager_manager.Villagers = {}

-- 已分配标识符集合（用于避免重复）
villager_manager.AssignedIDs = {}

-- 随机字符集（用于生成标识符后缀）
local CHARSET = "abcdefghijklmnopqrstuvwxyz0123456789"

-- ============================================================================
-- 私有伪随机数生成器
-- ============================================================================
-- 为什么不用 math.random：
--   * Cuberite 内嵌 Lua 5.1，math.random 用的是**进程级全局**的 C rand()，
--     任何插件调用 math.randomseed 都会影响其它插件（本机 MCPServer、
--     NetworkTest、VanillaFeatureComplement 都有 math.randomseed 调用）。
--   * math.randomseed 的参数在 Lua 5.1 里会被截断成 32 位整数，而
--     os.time() 加上 ID 后缀的 36 进制值经常超过 2^31（未定义行为）。
--   * 某些种子会让 glibc 的 rand() 进入极短周期：例如种子 2147483647 时，
--     职业只在 2 与 5 之间跳、字符只出现 '9' 和 'r'（实测复现）。
-- 这里自带一个 32 位 LCG：乘积 < 2^53，double 下精确；只取高位，质量足够，
-- 且完全不受其它插件影响、同一 (村民, 世界年龄) 可复现。
local Random = {}
villager_manager.Random = Random

Random.state = 12345

-- 把任意数值映射到 [1, 2^31-1]
function Random.Seed(seed)
    local s = math.floor(math.abs(tonumber(seed) or 0)) % 2147483647
    if s == 0 then s = 12345 end
    Random.state = s
end

local function Next32()
    Random.state = (1664525 * Random.state + 1013904223) % 4294967296
    return Random.state
end

-- [0, 1)
function Random.Float()
    return math.floor(Next32() / 4096) / 1048576
end

-- [min, max] 闭区间整数
function Random.Int(min, max)
    min = math.floor(tonumber(min) or 0)
    max = math.floor(tonumber(max) or 0)
    if max < min then min, max = max, min end
    local span = max - min + 1
    if span <= 1 then return min end
    return min + (math.floor(Next32() / 65536) % span)
end

-- 字符串哈希（用于按村民 ID 播种）
function villager_manager.HashString(s)
    local h = 0
    for i = 1, #s do
        h = (h * 31 + s:byte(i)) % 2147483647
    end
    return h
end

-- 模块加载时的初始种子（时间 + CPU 时间，避免同秒内多个状态完全相同）
Random.Seed(os.time() * 1000 + math.floor(os.clock() * 1000))

-- 生成随机后缀（6 位）
function villager_manager.GenerateRandomSuffix()
    local suffix = ""
    for _ = 1, 6 do
        local idx = Random.Int(1, #CHARSET)
        suffix = suffix .. CHARSET:sub(idx, idx)
    end
    return suffix
end

-- 生成唯一标识符（职业编号 + 随机字符），确保不与已分配的重名
function villager_manager.GenerateID(profession)
    local name = villager_manager.PROFESSION_NAMES[profession] or "generic"
    local id
    repeat
        id = villager_manager.ID_PREFIX .. name .. "-" .. villager_manager.GenerateRandomSuffix()
    until not villager_manager.AssignedIDs[id]
    villager_manager.AssignedIDs[id] = true
    return id
end

-- 从标识符解析职业编号；无法解析时返回 nil
function villager_manager.GetProfessionFromID(id)
    if not id then return nil end
    -- 格式: vt-<name>-<suffix>（注意 - 在 Lua 模式中需转义为 %-）
    local prefix, name = id:match("^(" .. villager_manager.ID_PREFIX:gsub("%-", "%%-") .. ")([%a]+)-")
    if not name then return nil end
    return villager_manager.PROFESSION_NAME_TO_NUM[name]
end

-- 判断一个 CustomName 是否是我们分配的标识符
function villager_manager.IsAssignedID(name)
    if not name then return false end
    return name:sub(1, #villager_manager.ID_PREFIX) == villager_manager.ID_PREFIX
end

-- 确保村民有标识符；若没有则分配一个并设置 CustomName。
-- 返回村民标识符。
function villager_manager.EnsureVillagerID(villager)
    local name = villager:GetCustomName()
    if villager_manager.IsAssignedID(name) then
        -- 已有标识符，登记到已分配集合
        villager_manager.AssignedIDs[name] = true
        return name
    end

    -- 没有标识符，分配一个（随机职业）
    local profession = Random.Int(0, 5)
    local id = villager_manager.GenerateID(profession)
    villager:SetCustomName(id)
    villager:SetCustomNameAlwaysVisible(false)  -- 不常显，减少视觉干扰
    DEBUGLOG("为村民分配标识符: " .. id)
    return id
end

-- 获取村民数据；若不存在则创建默认数据。
-- 返回 { profession = <num>, xp = {6个}, lastRefreshAge = <num> }
function villager_manager.GetVillagerData(villagerID)
    if not villagerID then
        return { profession = 5, xp = {0, 0, 0, 0, 0, 0}, lastRefreshAge = nil }
    end
    local data = villager_manager.Villagers[villagerID]
    if not data then
        local profession = villager_manager.GetProfessionFromID(villagerID) or 5
        data = {
            profession = profession,
            xp = {0, 0, 0, 0, 0, 0},
            lastRefreshAge = nil,
        }
        villager_manager.Villagers[villagerID] = data
    end
    return data
end

-- 遍历世界所有村民，确保每个都有标识符。
-- 返回 { villagerID -> cMonster } 映射（仅当前已加载的村民）。
function villager_manager.EnsureAllVillagersHaveIDs(World)
    local found = {}
    World:ForEachEntity(function(Entity)
        if Entity:IsMob() and Entity:GetMobType() == mtVillager then
            local id = villager_manager.EnsureVillagerID(Entity)
            found[id] = Entity
        end
        return false  -- 继续遍历
    end)
    return found
end

-- 加载村民数据文件 villager_data.txt
function villager_manager.LoadVillagerData()
    local path = PLUGIN:GetLocalFolder() .. "/villager_data.txt"
    local file = io.open(path, "r")
    if not file then
        LOG("未找到 villager_data.txt，使用空数据。")
        return
    end
    local loaded, skipped = 0, 0
    for line in file:lines() do
        if not line:match("^%s*#") then
            line = line:gsub("%s*#.*$", "")
            line = line:gsub("%s+$", "")
            if line ~= "" then
                -- 格式: <villagerID> = <profession> | <xp1> | ... | <xp6> | <lastRefreshAge>
                -- 字段数必须与 SaveVillagerData 写出的完全一致：
                -- 1 个职业 + 6 个经验 + 1 个年龄 = 8 个数字（多一个捕获会导致永远匹配失败，数据随后被覆盖丢失）
                local id, prof, x1, x2, x3, x4, x5, x6, age =
                    line:match("^(%S+)%s*=%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%-?%d+)$")
                if id then
                    local lastAge = tonumber(age)
                    if lastAge == -1 then
                        lastAge = nil  -- -1 是 SaveVillagerData 对 nil 写的占位值
                    end
                    villager_manager.Villagers[id] = {
                        profession = tonumber(prof),
                        xp = {
                            tonumber(x1), tonumber(x2), tonumber(x3),
                            tonumber(x4), tonumber(x5), tonumber(x6),
                        },
                        lastRefreshAge = lastAge,
                    }
                    villager_manager.AssignedIDs[id] = true
                    loaded = loaded + 1
                else
                    skipped = skipped + 1
                    LOGWARNING("跳过无法解析的数据行: " .. line)
                end
            end
        end
    end
    file:close()
    LOG("已加载 " .. tostring(loaded) .. " 个村民的数据（表内共 "
        .. tostring(villager_manager.CountVillagers()) .. " 个）。")
end

-- 保存村民数据文件 villager_data.txt
function villager_manager.SaveVillagerData()
    local path = PLUGIN:GetLocalFolder() .. "/villager_data.txt"
    local file = io.open(path, "w")
    if not file then
        LOG("无法写入 " .. path)
        return
    end
    for id, data in pairs(villager_manager.Villagers) do
        local line = id .. " = " .. tostring(data.profession)
        for i = 1, 6 do
            line = line .. " | " .. tostring(data.xp[i] or 0)
        end
        line = line .. " | " .. tostring(data.lastRefreshAge or -1)
        file:write(line .. "\n")
    end
    file:close()
    villager_manager.LastSaveTime = os.time()
    LOG("已保存 " .. tostring(villager_manager.CountVillagers()) .. " 个村民的数据。")
end

-- 定期保存（默认 5 分钟）：由交易刷新任务周期性调用，避免服务器崩溃时丢失全部 XP
villager_manager.LastSaveTime = 0
local AUTOSAVE_INTERVAL_SECONDS = 300

function villager_manager.SaveVillagerDataIfDue(IntervalSeconds)
    local interval = IntervalSeconds or AUTOSAVE_INTERVAL_SECONDS
    if os.time() - (villager_manager.LastSaveTime or 0) < interval then
        return false
    end
    villager_manager.SaveVillagerData()
    return true
end

-- 统计村民数量
function villager_manager.CountVillagers()
    local count = 0
    for _ in pairs(villager_manager.Villagers) do
        count = count + 1
    end
    return count
end

-- ============================================================================
-- v1 -> v2 数据迁移
-- ============================================================================

-- 读取 v1 的 player_trade_experience.txt（按玩家 UUID 存储 6 个职业经验）
-- 返回 { uuid -> {6个经验} }
function villager_manager.LoadV1PlayerExperience()
    local ok, parser = pcall(require, "player_trade_xp_parser")
    if ok and parser and type(parser.LoadPlayerTradeExperience) == "function" then
        return parser.LoadPlayerTradeExperience()
    end
    return nil
end

-- 执行 v1 -> v2 迁移：
--   将 v1 中每个玩家每个职业的经验，分配给第一个新分配的具有该职业的村民（分配后清 0）。
--   player_trades.txt 未记录交易所属职业，不做迁移。
-- 参数：
--   VillagerList: 所有世界中已加载的村民实体列表（迁移只做一次，避免多世界重复分配）
--   v1XpTable: v1 的经验表（可为 nil）
function villager_manager.MigrateV1ToV2(VillagerList, v1XpTable)
    if not v1XpTable then
        LOG("无 v1 经验数据，跳过迁移。")
        return
    end

    -- 统计 v1 中每个职业的总经验（跨所有玩家累加）
    local professionTotalXp = {0, 0, 0, 0, 0, 0}
    local hasAnyXp = false
    for uuid, xpList in pairs(v1XpTable) do
        for prof = 0, 5 do
            local xp = xpList[prof + 1] or 0
            if xp > 0 then
                hasAnyXp = true
            end
            professionTotalXp[prof + 1] = professionTotalXp[prof + 1] + xp
        end
    end

    if not hasAnyXp then
        LOG("v1 经验数据全为 0，无需迁移。")
        return
    end

    -- 遍历村民，为每个职业找到"第一个新分配的村民"，把该职业的总经验分配给它
    local migratedCount = 0
    local assignedForProfession = {}  -- 记录每个职业是否已分配过
    for _, Entity in ipairs(VillagerList or {}) do
        local id = villager_manager.EnsureVillagerID(Entity)
        local data = villager_manager.GetVillagerData(id)
        local prof = data.profession
        if not assignedForProfession[prof] then
            assignedForProfession[prof] = true
            -- 把该职业的 v1 总经验分配给这个村民
            data.xp[prof + 1] = (data.xp[prof + 1] or 0) + professionTotalXp[prof + 1]
            LOG("迁移: 职业 " .. prof .. " 的 " .. professionTotalXp[prof + 1] .. " XP 分配给村民 " .. id)
            migratedCount = migratedCount + 1
        end
    end

    LOG("v1->v2 迁移完成，共迁移 " .. tostring(migratedCount) .. " 个职业的经验。")
end

return villager_manager