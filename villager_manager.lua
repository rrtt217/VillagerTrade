-- villager_manager.lua
-- v2 核心模块：管理村民唯一标识符、村民数据（经验/上次刷新世界年龄）、v1->v2 迁移。
--
-- 设计说明：
--   * 村民唯一标识符使用 CustomName（会持久化到 NBT，服务器重启后保留）。
--     引擎没有可持久化的实体 UUID（cEntity 无 m_UUID，GetUniqueID 只是会话内 EntityID），
--     所以 CustomName 是唯一可用的持久键，名字必须保持唯一。
--   * 名字格式：可读英文名 "<Profession> <Name>"（例如 "Butcher Bill"），重名时加数字后缀；
--     旧格式 "vt-<职业>-<随机码>" 会在村民被看到时自动迁移（重命名 + 数据键搬移）。
--   * 职业由插件分配（虚拟职业），并通过 villager_profession.WriteProfession 写回引擎的
--     cVillager::m_Type，让 AI（农夫种田）、僵尸村民转化与客户端渲染（1.8-1.12 会下发职业元数据）
--     与交易内容一致。
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

-- 可读名字用的职业显示名（英文，保持单个词，便于在名字里辨认）
villager_manager.PROFESSION_DISPLAY = {
    [0] = "Farmer",
    [1] = "Librarian",
    [2] = "Priest",
    [3] = "Blacksmith",
    [4] = "Butcher",
    [5] = "Merchant",
}

-- 可读名字用的名字表（英文，短、易读、无空格）
villager_manager.FIRST_NAMES = {
    "Abe", "Alice", "Ann", "Bess", "Bill", "Bob", "Bram", "Cole", "Daisy", "Dora",
    "Edith", "Eli", "Fern", "Fred", "Gus", "Gwen", "Hank", "Hattie", "Ike", "Ivy",
    "Jack", "Jane", "Kate", "Kirk", "Lena", "Luke", "Mabel", "Meg", "Milo", "Ned",
    "Nell", "Olive", "Owen", "Pearl", "Pete", "Quinn", "Ralph", "Rose", "Sadie", "Sam",
    "Seth", "Silas", "Ted", "Tess", "Tilly", "Tom", "Uma", "Vince", "Walt", "Willa",
    "Zeke",
}

-- 旧格式标识符前缀（迁移用）
villager_manager.ID_PREFIX = "vt-"

-- 运行开关（由 main.lua 依据 settings.ini 覆盖；此处给默认值以便单独加载时也能工作）
villager_manager.AlignRealProfession = true   -- 把引擎职业对齐为插件职业
villager_manager.ReadableNames = true         -- 使用可读英文名

-- 会话内重命名映射：old -> new（供已打开的交易窗口沿用同一个数据条目）
villager_manager.RenamedIDs = {}

-- 本次会话已确认对齐过的村民（name -> profession），避免每轮扫描都读引擎字段
villager_manager.AlignedIDs = {}

-- 迁移/对齐统计
villager_manager.MigratedCount = 0
villager_manager.AlignCount = 0

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

-- 生成旧格式标识符（职业编号 + 随机字符）——仅在 ReadableNames=false 时作为回退
function villager_manager.GenerateID(profession)
    local name = villager_manager.PROFESSION_NAMES[profession] or "generic"
    local id
    repeat
        id = villager_manager.ID_PREFIX .. name .. "-" .. villager_manager.GenerateRandomSuffix()
    until not villager_manager.AssignedIDs[id]
    villager_manager.AssignedIDs[id] = true
    return id
end

-- 生成可读名字 "<Profession> <Name>"；重名时加 " 2"/" 3"… 后缀（AssignedIDs 保证唯一）
function villager_manager.GenerateName(profession)
    local Display = villager_manager.PROFESSION_DISPLAY[profession] or "Merchant"
    local Base = Display .. " " .. villager_manager.FIRST_NAMES[Random.Int(1, #villager_manager.FIRST_NAMES)]
    local Name, N = Base, 1
    while villager_manager.AssignedIDs[Name] do
        N = N + 1
        Name = Base .. " " .. N
    end
    villager_manager.AssignedIDs[Name] = true
    return Name
end

-- 旧格式（vt-<职业>-<随机码>）？
function villager_manager.IsLegacyID(name)
    return (type(name) == "string") and (name:sub(1, #villager_manager.ID_PREFIX) == villager_manager.ID_PREFIX)
end

-- 从旧格式标识符解析职业编号；无法解析时返回 nil
function villager_manager.GetProfessionFromID(id)
    if not id then return nil end
    -- 格式: vt-<name>-<suffix>（注意 - 在 Lua 模式中需转义为 %-）
    local prefix, name = id:match("^(" .. villager_manager.ID_PREFIX:gsub("%-", "%%-") .. ")([%a]+)-")
    if not name then return nil end
    return villager_manager.PROFESSION_NAME_TO_NUM[name]
end

-- 这个名字是不是插件管理的标识符（旧格式，或数据表里已有，或本次会话分配过）
function villager_manager.IsAssignedID(name)
    if (name == nil) or (name == "") then return false end
    if villager_manager.IsLegacyID(name) then return true end
    return (villager_manager.Villagers[name] ~= nil) or (villager_manager.AssignedIDs[name] == true)
end

-- 跟随重命名映射，拿到当前有效的标识符（已打开的交易窗口沿用新条目）
function villager_manager.ResolveID(id)
    local Cur, Guard = id, 0
    while (Cur ~= nil) and villager_manager.RenamedIDs[Cur] do
        Cur = villager_manager.RenamedIDs[Cur]
        Guard = Guard + 1
        if Guard > 16 then break end
    end
    return Cur
end

-- 强制下一次 SaveVillagerDataIfDue 立刻落盘
function villager_manager.MarkDataDirty()
    villager_manager.LastSaveTime = 0
end

-- 迁移前备份一次（已存在备份则跳过）
function villager_manager.BackupDataFileOnce()
    if villager_manager.BackupDone then return end
    villager_manager.BackupDone = true
    local Folder = PLUGIN:GetLocalFolder()
    local Src = Folder .. "/villager_data.txt"
    local Dst = Folder .. "/villager_data.txt.pre-migration.bak"
    if (not cFile:IsFile(Src)) or cFile:IsFile(Dst) then return end
    local In = io.open(Src, "r")
    if not In then return end
    local Content = In:read("*a")
    In:close()
    local Out = io.open(Dst, "w")
    if not Out then return end
    Out:write(Content)
    Out:close()
    LOG("已备份迁移前的村民数据: villager_data.txt.pre-migration.bak")
end

-- 把引擎内部职业（cVillager::m_Type）对齐为插件职业。
-- 读取模块不可用/未校准时静默跳过（下次扫描再试）；成功结果按名字缓存，避免每次扫描都读一遍。
function villager_manager.AlignEngineProfession(villager, profession, name)
    if not villager_manager.AlignRealProfession then
        return false
    end
    name = name or villager:GetCustomName()
    if (name ~= nil) and (villager_manager.AlignedIDs[name] == profession) then
        return true
    end
    if (type(villager_profession) ~= "table") or (villager_profession.WriteProfession == nil) then
        return false
    end
    local Current = villager_profession.ReadProfession(villager)
    if (Current == nil) then
        return false
    end
    if (Current ~= profession) then
        local Ok, Err = villager_profession.WriteProfession(villager, profession)
        if not Ok then
            if not villager_manager.AlignWarned then
                villager_manager.AlignWarned = true
                LOGWARNING("无法对齐引擎职业（后续不再重复报告）: " .. tostring(Err))
            end
            return false
        end
        villager_manager.AlignCount = villager_manager.AlignCount + 1
        LOG(("已对齐引擎职业: %s -> %d"):format(tostring(name), profession))
    end
    if (name ~= nil) then
        villager_manager.AlignedIDs[name] = profession
    end
    return true
end

-- 把旧格式标识符迁移为可读名字：搬移数据条目、重命名、对齐引擎职业。
function villager_manager.MigrateVillagerIdentity(villager, OldName, data)
    local FinalName = OldName
    if villager_manager.ReadableNames then
        villager_manager.BackupDataFileOnce()
        local NewName = villager_manager.GenerateName(data.profession)
        villager_manager.Villagers[NewName] = data
        villager_manager.Villagers[OldName] = nil
        villager_manager.RenamedIDs[OldName] = NewName
        villager:SetCustomName(NewName)
        villager:SetCustomNameAlwaysVisible(false)
        villager_manager.MigratedCount = villager_manager.MigratedCount + 1
        villager_manager.MarkDataDirty()
        LOG(("村民标识符迁移: %s -> %s（职业 %d）"):format(OldName, NewName, data.profession))
        FinalName = NewName
    end
    villager_manager.AlignEngineProfession(villager, data.profession, FinalName)
    return FinalName
end

-- 确保村民有（当前格式的）标识符：迁移旧格式、接管陌生村民、把引擎职业对齐。
-- 返回村民标识符。交易刷新 / 右键交互 / 启动扫描都走这个入口。
function villager_manager.EnsureVillagerID(villager)
    local Name = villager:GetCustomName()
    local Data = ((Name ~= nil) and (Name ~= "")) and villager_manager.Villagers[Name] or nil

    if Data ~= nil then
        villager_manager.AssignedIDs[Name] = true
        if villager_manager.IsLegacyID(Name) then
            return villager_manager.MigrateVillagerIdentity(villager, Name, Data)
        end
        -- 名字前缀必须与职业一致：职业被改过、或早期版本错标过名字时自愈重命名
        local Expected = villager_manager.PROFESSION_DISPLAY[Data.profession]
        if (Expected ~= nil) and (Name:sub(1, #Expected) ~= Expected) then
            LOG(("村民名字与职业不符，重新命名: %s（职业 %d）"):format(Name, Data.profession))
            return villager_manager.MigrateVillagerIdentity(villager, Name, Data)
        end
        villager_manager.AlignEngineProfession(villager, Data.profession, Name)
        return Name
    end

    -- 旧格式名字但数据表里没有（数据被清理过 / 手工改名过）：按名字重建条目再迁移
    if villager_manager.IsLegacyID(Name) then
        local Profession = villager_manager.GetProfessionFromID(Name)
        if (Profession == nil) then
            Profession = Random.Int(0, 5)
        end
        local NewData = { profession = Profession, xp = {0, 0, 0, 0, 0, 0}, lastRefreshAge = nil }
        villager_manager.Villagers[Name] = NewData
        villager_manager.AssignedIDs[Name] = true
        return villager_manager.MigrateVillagerIdentity(villager, Name, NewData)
    end

    -- 完全陌生（自然生成 / 刷怪蛋）：随机职业 + 可读名字，并对齐引擎职业
    local Profession = Random.Int(0, 5)
    local NewName
    if villager_manager.ReadableNames then
        NewName = villager_manager.GenerateName(Profession)
    else
        NewName = villager_manager.GenerateID(Profession)
    end
    villager_manager.Villagers[NewName] = { profession = Profession, xp = {0, 0, 0, 0, 0, 0}, lastRefreshAge = nil }
    villager_manager.AssignedIDs[NewName] = true
    villager:SetCustomName(NewName)
    villager:SetCustomNameAlwaysVisible(false)  -- 不常显，减少视觉干扰
    villager_manager.AlignEngineProfession(villager, Profession, NewName)
    villager_manager.MarkDataDirty()
    DEBUGLOG("为村民分配标识符: " .. NewName)
    return NewName
end

-- 获取村民数据；若不存在则创建默认数据。
-- 返回 { profession = <num>, xp = {6个}, lastRefreshAge = <num> }
function villager_manager.GetVillagerData(villagerID)
    if not villagerID then
        return { profession = 5, xp = {0, 0, 0, 0, 0, 0}, lastRefreshAge = nil }
    end
    -- 已打开的交易窗口持有的是旧标识符：跟随本次会话的重命名映射
    villagerID = villager_manager.ResolveID(villagerID)
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
    local BeforeMigrated = villager_manager.MigratedCount
    local BeforeAligned = villager_manager.AlignCount
    World:ForEachEntity(function(Entity)
        local Ok = pcall(function()
            if Entity:IsMob() and Entity:GetMobType() == mtVillager then
                local id = villager_manager.EnsureVillagerID(Entity)
                found[id] = Entity
            end
        end)
        if not Ok then
            LOGWARNING("处理村民标识符时出错（已跳过该实体）")
        end
        return false  -- 继续遍历
    end)
    local Migrated = villager_manager.MigratedCount - BeforeMigrated
    local Aligned = villager_manager.AlignCount - BeforeAligned
    if (Migrated > 0) or (Aligned > 0) then
        LOG(("本轮村民维护: 重命名迁移 %d 个，引擎职业对齐 %d 个"):format(Migrated, Aligned))
    end
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
                -- 标识符里可能含空格（可读名字 "Butcher Bill"），所以用惰性匹配到 " =" 之前
                local Pattern =
                    "^(.-)%s*=%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%-?%d+)$"
                local id, prof, x1, x2, x3, x4, x5, x6, age = line:match(Pattern)
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
-- 崩溃安全：先写 villager_data.txt.tmp，成功后再原子 rename 覆盖正式文件。
-- 这样即使进程在写入中途被杀死（SIGABRT/SIGKILL/掉电），磁盘上的正式文件
-- 要么是"上一次的完整内容"，要么是"本次的完整内容"，绝不会被截断成半截文件。
-- （此前直接 io.open(path, "w") 会先截断正式文件，写一半崩溃就丢掉全部村民数据。）
function villager_manager.SaveVillagerData()
    local path = PLUGIN:GetLocalFolder() .. "/villager_data.txt"
    local tmpPath = path .. ".tmp"
    local file = io.open(tmpPath, "w")
    if not file then
        LOG("无法写入 " .. tmpPath)
        return false
    end
    for id, data in pairs(villager_manager.Villagers) do
        local line = id .. " = " .. tostring(data.profession)
        for i = 1, 6 do
            line = line .. " | " .. tostring(data.xp[i] or 0)
        end
        line = line .. " | " .. tostring(data.lastRefreshAge or -1)
        file:write(line .. "\n")
    end
    local closeOk, closeErr = file:close()
    if closeOk == nil then
        LOG("写入 " .. tmpPath .. " 失败: " .. tostring(closeErr))
        os.remove(tmpPath)
        return false
    end
    local renamed, renameErr = os.rename(tmpPath, path)
    if not renamed then
        LOG("重命名 " .. tmpPath .. " -> " .. path .. " 失败: " .. tostring(renameErr))
        os.remove(tmpPath)
        return false
    end
    villager_manager.LastSaveTime = os.time()
    LOG("已保存 " .. tostring(villager_manager.CountVillagers()) .. " 个村民的数据。")
    return true
end

-- 定期保存：由交易刷新任务（每 20 秒）周期性调用。
-- 文件很小（几十行），把间隔从 5 分钟缩短到 60 秒，崩溃时最多只丢 1 分钟的 XP。
villager_manager.LastSaveTime = 0
local AUTOSAVE_INTERVAL_SECONDS = 60

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