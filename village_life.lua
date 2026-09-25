-- village_life.lua
-- 村庄生态：新村庄自动生成村民（默认关闭，见 settings.ini [VillageLife]）
--
-- 机制：持久化"每区块只扫一次"
--   * 区块首次变为可用（HOOK_CHUNK_AVAILABLE；生成和从磁盘加载都算）时，
--     只要它从未被标记为"已扫描"、且落在可能的村庄生物群系里，就放进扫描队列；
--   * HOOK_WORLD_TICK 每 tick 最多处理 ChunksPerTick 个区块，把扫描开销摊到多个 tick，
--     避免在"区块加载风暴"里一次性扫描大量区块而拖垮 tick 线程；
--   * 扫描用世界 API（此时区块已加载），以"木门"作为村庄特征；
--   * 扫描完立刻在内存里标记，并追加写入 village_scanned.txt（节流刷盘 + OnDisable 刷盘）。
--     下次启动读回标记，同一个区块不会再扫第二遍。
--
-- 依赖：VillagerManager（村民唯一标识符）、PLUGIN、LOG、DEBUGLOG。
--
-- 设计依据（均在本机运行时核实）：
--   * Cuberite 的村庄由生成器 finisher "Villages" + Prefabs/Villages/*.cubeset 放置，
--     cubeset 只含方块、不含实体 —— 村庄生成时不会自带村民。
--   * 向未加载区块 SpawnMob 会"成功"返回一个 ID，但实体立刻消失 —— 只能对已加载区块生成。
--   * 在 tick 线程里做大规模同步方块扫描会被看门狗判定死锁并 SIGABRT（实测）。

local village_life = {}

-- ============================================================================
-- 配置（默认值；Initialize 中由 settings.ini [VillageLife] 覆盖）
-- ============================================================================
village_life.EnableVillageSpawning = false
-- 单个村庄区块最多生成多少名村民（村庄跨多个区块，实际总数会更大）
village_life.MaxVillagersPerChunk = 2
-- 每 tick 每个世界最多扫描多少个区块（限制单 tick 开销）
village_life.ChunksPerTick = 2
-- 已扫描标记的刷盘间隔（秒）
village_life.SaveIntervalSeconds = 30

-- ============================================================================
-- 内部常量与状态
-- ============================================================================
local DOOR_BLOCK = E_BLOCK_WOODEN_DOOR
-- 每个柱子从高度图往下最多扫多少格找门（避免全高度扫描）
local DOOR_SCAN_DEPTH = 12
-- 区块排队期间被卸载时，最多重试几次
local MAX_SCAN_TRIES = 3
-- 判定"附近已有村民"的半径——即使标记因崩溃丢失，也不会重复生成
local DEDUP_RADIUS = 24

-- 已扫描区块：["<world>|<cx>|<cz>"] = true（内存 + village_scanned.txt 持久化）
local Scanned = {}
-- 已排队区块：key -> { world =, cx =, cz =, tries = }
local Queued = {}
-- 扫描队列（数组，元素是 key）
local ScanQueue = {}
-- 待落盘的标记（追加写文件）
local PendingWrites = {}
local LastFlush = 0
local SavePath = nil

-- 可能出现村庄的生物群系（Prefabs/Villages/*.cubeset 的 AllowedBiomes 并集）。
-- 用 _G 动态取，缺哪个就跳过，避免不同版本常量名不一致。
local VILLAGE_BIOMES = {}
for _, name in ipairs({
    "biPlains", "biSunflowerPlains", "biSavanna", "biSavannaM",
    "biDesert", "biDesertM", "biDesertHills",
}) do
    local value = _G[name]
    if value then
        VILLAGE_BIOMES[value] = true
    end
end

local function KeyOf(worldName, cx, cz)
    return worldName .. "|" .. cx .. "|" .. cz
end

-- ============================================================================
-- 持久化
-- ============================================================================

-- 启动时读回已扫描区块标记。
function village_life.LoadScanned()
    SavePath = PLUGIN:GetLocalFolder() .. "/village_scanned.txt"
    local file = io.open(SavePath, "r")
    if not file then
        LOG("未找到 village_scanned.txt，所有候选区块都视为未扫描。")
        return
    end
    local loaded = 0
    for line in file:lines() do
        local worldName, cx, cz = line:match("^(%S+)%s+(%-?%d+)%s+(%-?%d+)$")
        if worldName then
            Scanned[KeyOf(worldName, tonumber(cx), tonumber(cz))] = true
            loaded = loaded + 1
        end
    end
    file:close()
    LOG("已加载 " .. loaded .. " 个已扫描区块标记。")
end

-- 标记一个区块为已扫描，并加入待落盘队列。
local function MarkScanned(worldName, cx, cz)
    local key = KeyOf(worldName, cx, cz)
    if Scanned[key] then
        return
    end
    Scanned[key] = true
    PendingWrites[#PendingWrites + 1] = worldName .. " " .. cx .. " " .. cz
end

-- 把待落盘的标记追加到文件（追加写，崩溃时最多丢最后一次刷盘）。
function village_life.FlushScanned()
    if #PendingWrites == 0 or not SavePath then
        return false
    end
    local file = io.open(SavePath, "a")
    if not file then
        LOG("无法写入 " .. SavePath)
        return false
    end
    file:write(table.concat(PendingWrites, "\n"), "\n")
    file:close()
    PendingWrites = {}
    LastFlush = os.time()
    return true
end

-- ============================================================================
-- 扫描与生成
-- ============================================================================

-- 只用 4 个采样点的生物群系判断，避免加载范围内的每个区块都做一次扫描。
-- 非候选区块不扫描、也不标记（下次加载重新做一次 O(1) 的生物群系判断即可）。
local function ChunkMayContainVillage(World, chunkX, chunkZ)
    local baseX, baseZ = chunkX * 16, chunkZ * 16
    for _, off in ipairs({ { 4, 4 }, { 12, 4 }, { 4, 12 }, { 12, 12 } }) do
        local biome = World:GetBiomeAt(baseX + off[1], baseZ + off[2])
        if VILLAGE_BIOMES[biome] then
            return true
        end
    end
    return false
end

-- 扫描区块里的木门，返回门下半部分的相对坐标。
-- 注意 GetBlock/GetBlockMeta 必须用 Vector3i 重载：3 个数字的旧重载每次调用都会
-- 打印一条带栈回溯的弃用警告，批量扫描会把日志刷爆并严重拖慢 tick。
local function ScanDoors(World, baseX, baseZ)
    local doors = {}
    for x = 0, 15 do
        for z = 0, 15 do
            local ok, height = World:TryGetHeight(baseX + x, baseZ + z)
            if ok and type(height) == "number" and height > 1 then
                local bottom = math.max(1, height - DOOR_SCAN_DEPTH)
                for y = height, bottom, -1 do
                    if World:GetBlock(Vector3i(baseX + x, y, baseZ + z)) == DOOR_BLOCK then
                        local meta = World:GetBlockMeta(Vector3i(baseX + x, y, baseZ + z))
                        local yLower = y
                        -- 门 meta 的 bit3（值 8）= 上半部分；下半部分才是脚所在高度
                        if math.floor((meta or 0) / 8) % 2 == 1 then
                            yLower = y - 1
                        end
                        doors[#doors + 1] = { x = x, y = yLower, z = z }
                        break
                    end
                end
            end
        end
    end
    return doors
end

-- 附近是否已有村民（幂等保护：标记丢失时也不会重复生成）
local function HasVillagersNear(World, blockX, blockZ, radius)
    local radiusSq = radius * radius
    local found = false
    World:ForEachEntity(function(Entity)
        if found then
            return true
        end
        if Entity:IsMob() and Entity:GetMobType() == mtVillager then
            local pos = Entity:GetPosition()
            local dx, dz = pos.x - blockX, pos.z - blockZ
            if dx * dx + dz * dz <= radiusSq then
                found = true
                return true
            end
        end
        return false
    end)
    return found
end

local function SpawnVillagers(World, entry, doors)
    local baseX, baseZ = entry.cx * 16, entry.cz * 16
    local count = math.min(#doors, village_life.MaxVillagersPerChunk)
    local spawned = 0
    for i = 1, count do
        local door = doors[i]
        local id = World:SpawnMob(baseX + door.x + 0.5, door.y, baseZ + door.z + 0.5, mtVillager, false)
        if id and id >= 0 then
            World:DoWithEntityByID(id, function(Entity)
                if VillagerManager then
                    VillagerManager.EnsureVillagerID(Entity)
                end
            end)
            spawned = spawned + 1
        end
    end
    if spawned > 0 then
        LOG("新村庄：区块(" .. entry.cx .. "," .. entry.cz .. ") 有 " .. #doors
            .. " 扇门，生成 " .. spawned .. " 名村民。")
    end
end

-- 处理一个排队区块（每 tick 只处理有限个，见 OnWorldTick）
local function ProcessChunk(World, entry)
    local cx, cz = entry.cx, entry.cz
    local baseX, baseZ = cx * 16, cz * 16

    -- 区块可能在排队期间被卸载；重试有限次，失败就放弃（下次加载会重新入队）
    local ok = World:TryGetHeight(baseX + 8, baseZ + 8)
    if not ok then
        if entry.tries < MAX_SCAN_TRIES then
            entry.tries = entry.tries + 1
            local key = KeyOf(entry.world, cx, cz)
            Queued[key] = entry
            ScanQueue[#ScanQueue + 1] = key
        end
        return
    end

    local doors = ScanDoors(World, baseX, baseZ)
    DEBUGLOG("扫描区块(" .. cx .. "," .. cz .. ") 找到 " .. #doors .. " 扇门")
    MarkScanned(entry.world, cx, cz)   -- 扫过一次就标记，不再重复扫
    if #doors == 0 then
        return
    end
    if HasVillagersNear(World, baseX + 8, baseZ + 8, DEDUP_RADIUS) then
        DEBUGLOG("区块(" .. cx .. "," .. cz .. ") 有 " .. #doors .. " 扇门，但附近已有村民，跳过生成。")
        return
    end
    SpawnVillagers(World, entry, doors)
end

-- ============================================================================
-- 钩子入口
-- ============================================================================

-- 区块首次可用（生成或从磁盘加载）时入队；已扫描/已排队/非候选生物群系直接跳过。
function village_life.OnChunkAvailable(World, ChunkX, ChunkZ)
    if not village_life.EnableVillageSpawning then
        return false
    end
    local key = KeyOf(World:GetName(), ChunkX, ChunkZ)
    if Scanned[key] or Queued[key] then
        return false
    end
    if not ChunkMayContainVillage(World, ChunkX, ChunkZ) then
        return false
    end
    Queued[key] = { world = World:GetName(), cx = ChunkX, cz = ChunkZ, tries = 0 }
    ScanQueue[#ScanQueue + 1] = key
    return false
end

-- 每 tick 消化扫描队列，并按间隔刷盘。
function village_life.OnWorldTick(World, TimeDelta)
    if not village_life.EnableVillageSpawning then
        return false
    end
    local worldName = World:GetName()
    local budget = village_life.ChunksPerTick
    local i = 1
    while i <= #ScanQueue and budget > 0 do
        local key = ScanQueue[i]
        local entry = Queued[key]
        if not entry then
            table.remove(ScanQueue, i)          -- 过期条目
        elseif entry.world ~= worldName then
            i = i + 1                           -- 属于别的世界，留给那个世界的 tick
        else
            table.remove(ScanQueue, i)
            Queued[key] = nil
            budget = budget - 1
            ProcessChunk(World, entry)
        end
    end

    if os.time() - LastFlush >= village_life.SaveIntervalSeconds then
        village_life.FlushScanned()
    end
    return false
end

-- 运维/调试：强制扫描一个区块（忽略"已扫描"标记），返回结果描述。
function village_life.ForceScan(World, cx, cz)
    local baseX, baseZ = cx * 16, cz * 16
    if not World:TryGetHeight(baseX + 8, baseZ + 8) then
        return "区块(" .. cx .. "," .. cz .. ") 未加载"
    end
    local doors = ScanDoors(World, baseX, baseZ)
    if #doors == 0 then
        return "区块(" .. cx .. "," .. cz .. ") 未找到木门"
    end
    if HasVillagersNear(World, baseX + 8, baseZ + 8, DEDUP_RADIUS) then
        return "区块(" .. cx .. "," .. cz .. ") 有 " .. #doors .. " 扇门，但附近已有村民，跳过"
    end
    SpawnVillagers(World, { cx = cx, cz = cz }, doors)
    return "区块(" .. cx .. "," .. cz .. ") 有 " .. #doors .. " 扇门，已尝试生成"
end

-- ============================================================================
-- 状态查询（控制台命令 villagelife）
-- ============================================================================
function village_life.GetStatus()
    local queuedCount = 0
    for _ in pairs(Queued) do
        queuedCount = queuedCount + 1
    end
    local scannedCount = 0
    for _ in pairs(Scanned) do
        scannedCount = scannedCount + 1
    end
    return string.format(
        "VillageLife: 村庄生成=%s 扫描队列=%d(总队列 %d) 已扫描=%d 待落盘=%d",
        tostring(village_life.EnableVillageSpawning), queuedCount, #ScanQueue,
        scannedCount, #PendingWrites)
end

return village_life
