-- refersh_trade.lua
-- v2：村民交易刷新，基于世界时间（World:GetWorldAge()，以 tick 为单位）。
-- 注意：村民的 GetAge() 不是 tick 数，而是年龄状态（负数=幼年，1=成年），成年后恒为 1，无法作为刷新依据。
-- 因此改用世界 tick 年龄作为刷新依据，持久化保存上次刷新的世界 tick 年龄。
-- 交易列表按村民 ID 存储到 VillagerTrades[villagerID]。

-- 刷新间隔（世界 tick）：世界 tick 年龄每增长这么多就刷新一次交易
local REFRESH_AGE_INTERVAL = 20 * 60 * 5  -- 5 分钟（20 tick/秒）

-- 村民交易列表：villagerID -> { {profession槽位} = {交易数组} }
VillagerTrades = {}

-- 根据经验值计算等级（0~3）
local function GetXpLevel(xp)
    if xp >= 600 then return 3
    elseif xp >= 300 then return 2
    elseif xp >= 100 then return 1
    else return 0 end
end

-- 生成单个交易条目（从 trades.txt 的原始定义生成实际物品）
local function BuildTradeItem(itemSpec, min, max)
    local item = cItem()
    if tonumber(itemSpec.type) == nil then
        if StringToItem(itemSpec.type, item) then
            DEBUGLOG("Converted item string to item: " .. itemSpec.type)
        end
    else
        item = cItem(tonumber(itemSpec.type))
    end
    local itemCount = math.random(min, max)
    if itemCount <= 0 then itemCount = 1 end
    if itemCount > item:GetMaxStackSize() then
        itemCount = item:GetMaxStackSize()
    end
    item.m_ItemCount = itemCount
    item.m_ItemDamage = itemSpec.damage or 0
    if itemSpec.enchantments and not itemSpec.enchantments:match("ByXpLevels") then
        item.m_Enchantments = cEnchantments(itemSpec.enchantments)
    elseif itemSpec.enchantments and itemSpec.enchantments:match("ByXpLevels") then
        local enchantLevelMin, enchantLevelMax = itemSpec.enchantments:match("ByXpLevels%((%d+),%s*(%d+)%)")
        local enchantLevel = math.random(tonumber(enchantLevelMin) or 0, tonumber(enchantLevelMax) or 0)
        item:EnchantByXPLevels(enchantLevel)
    end
    return item
end

-- 为指定村民生成交易列表（基于其职业和经验等级）
-- 返回 { {inputs = {...}, output = item}, ... }
function GenerateTradesForVillager(villagerID)
    local data = VillagerManager.GetVillagerData(villagerID)
    local profession = data.profession
    local level = GetXpLevel(data.xp[profession + 1] or 0)
    DEBUGLOG("[VillagerTrade][DEBUG] GenerateTradesForVillager: id=" .. tostring(villagerID) .. " profession=" .. tostring(profession) .. " level=" .. tostring(level) .. " xp=" .. tostring(data.xp[profession + 1] or 0))

    local trades = {}
    local totalTrades = 0
    local matchedProfession = 0
    local matchedLevel = 0
    local matchedWeight = 0
    for entry in pairs(Trades or {}) do
        local trade = Trades[entry]
        if trade then
            totalTrades = totalTrades + 1
            local tradeProfession = trade.profession
            -- 只生成属于该村民职业的交易
            if tradeProfession == profession then
                matchedProfession = matchedProfession + 1
                if trade.unlockLevel and level >= trade.unlockLevel then
                    matchedLevel = matchedLevel + 1
                    if trade.weight and math.random() < trade.weight then
                        matchedWeight = matchedWeight + 1
                        local formattedTrade = {}
                        formattedTrade.inputs = {}
                        for _, input in ipairs(trade.inputs) do
                            table.insert(formattedTrade.inputs, BuildTradeItem(input.item, input.min, input.max))
                        end
                        formattedTrade.output = BuildTradeItem(trade.output.item, trade.output.min, trade.output.max)
                        table.insert(trades, formattedTrade)
                    end
                end
            end
        end
    end
    DEBUGLOG("[VillagerTrade][DEBUG] GenerateTradesForVillager 结果: id=" .. tostring(villagerID) .. " 总交易=" .. tostring(totalTrades) .. " 职业匹配=" .. tostring(matchedProfession) .. " 等级匹配=" .. tostring(matchedLevel) .. " 权重匹配=" .. tostring(matchedWeight) .. " 生成=" .. tostring(#trades))
    return trades
end

-- 刷新单个村民的交易（若世界 tick 年龄超过上次刷新阈值）
-- @param villager cMonster
-- @param World cWorld
function RefreshVillagerTradesForVillager(villager, World)
    local id = VillagerManager.EnsureVillagerID(villager)
    local data = VillagerManager.GetVillagerData(id)
    local worldAge = World:GetWorldAge()
    DEBUGLOG("[VillagerTrade][DEBUG] RefreshVillagerTradesForVillager: id=" .. tostring(id) .. " worldAge=" .. tostring(worldAge) .. " lastRefreshAge=" .. tostring(data.lastRefreshAge) .. " profession=" .. tostring(data.profession))

    -- 判断是否需要刷新：上次刷新世界年龄为空，或世界年龄增长超过阈值
    local shouldRefresh = false
    if data.lastRefreshAge == nil then
        shouldRefresh = true
    else
        local ageDiff = worldAge - data.lastRefreshAge
        if ageDiff >= REFRESH_AGE_INTERVAL then
            shouldRefresh = true
        end
    end

    if shouldRefresh then
        -- 用村民 ID 作为随机种子，保证同一村民刷新结果稳定
        local seedPart = tonumber(string.sub(id, -8), 16) or 0
        math.randomseed(os.time() + seedPart)
        VillagerTrades[id] = GenerateTradesForVillager(id)
        data.lastRefreshAge = worldAge
        DEBUGLOG("[VillagerTrade] 刷新村民 " .. id .. " 的交易（worldAge=" .. tostring(worldAge) .. "），共 " .. tostring(#VillagerTrades[id]) .. " 条")
    else
        DEBUGLOG("[VillagerTrade][DEBUG] 村民 " .. id .. " 未到刷新时间（ageDiff=" .. tostring(worldAge - (data.lastRefreshAge or 0)) .. " < " .. tostring(REFRESH_AGE_INTERVAL) .. "）")
    end
end

-- 刷新世界中所有村民的交易
-- @param World cWorld
function RefreshVillagerTrades(World)
    World:ForEachEntity(function(Entity)
        if Entity:IsMob() and Entity:GetMobType() == mtVillager then
            RefreshVillagerTradesForVillager(Entity, World)
        end
        return false
    end)
    -- 定时再次刷新
    World:ScheduleTask(20 * 20, RefreshVillagerTrades)  -- 每 20 秒检查一次
end

-- 获取村民的交易列表（若未生成则先生成）
function GetVillagerTrades(villagerID)
    if not villagerID then
        DEBUGLOG("[VillagerTrade][DEBUG] GetVillagerTrades: villagerID 为 nil")
        return {}
    end
    if not VillagerTrades[villagerID] then
        DEBUGLOG("[VillagerTrade][DEBUG] GetVillagerTrades: 村民 " .. villagerID .. " 无缓存交易，重新生成")
        VillagerTrades[villagerID] = GenerateTradesForVillager(villagerID)
    end
    DEBUGLOG("[VillagerTrade][DEBUG] GetVillagerTrades: 村民 " .. villagerID .. " 返回 " .. tostring(#VillagerTrades[villagerID]) .. " 条交易")
    return VillagerTrades[villagerID]
end
