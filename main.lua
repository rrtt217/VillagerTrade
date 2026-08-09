PLUGIN = nil

-- 全局调试日志函数（供所有模块使用；DEBUG 开关在 Initialize 末尾设置）
function DEBUGLOG(a_1, a_2)
    if DEBUG then
        LOG(a_1, a_2)
    end
end

function Initialize(Plugin)
	Plugin:SetName("Trade")
	Plugin:SetVersion(2)

	-- Hooks

	PLUGIN = Plugin -- NOTE: only needed if you want OnDisable() to use GetName() or something like that

	-- Command Bindings

    -- Initialize trades from trades.txt
	LOG("Initialised version " .. Plugin:GetVersion())
    -- Use external parser module to parse trades.txt
    local trades_parser = require("trades_parser")
    if not trades_parser or type(trades_parser) ~= "table" or type(trades_parser.parseTradesFromFile) ~= "function" then
        LOG("Error: could not load trades_parser.lua")
        return
    end

    local Trades, err = trades_parser.parseTradesFromFile("trades.txt")
    if not Trades then
        LOG("Error parsing trades.txt: " .. tostring(err))
        return
    end

    _G.Trades = Trades
    LOG("Loaded " .. tostring(#Trades) .. " trades from trades.txt")
    for i, trade in ipairs(Trades) do
        DEBUGLOG("Trade " .. i .. ": " .. tostring(trade.inputs[1].item.type) .. " x" .. tostring(trade.inputs[1].min) .. " -> " .. tostring(trade.output.item.type) .. " x" .. tostring(trade.output.min))
    end

    -- 加载 v2 核心模块（村民管理）
    local villager_manager = require("villager_manager")
    if not villager_manager or type(villager_manager) ~= "table" then
        LOG("Error: could not load villager_manager.lua")
        return
    end
    _G.VillagerManager = villager_manager

    -- 加载村民数据（v2 格式）
    villager_manager.LoadVillagerData()

    -- 读取 v1 经验数据（用于迁移）
    local v1XpTable = villager_manager.LoadV1PlayerExperience()

    -- 遍历所有世界，确保村民有标识符，并执行 v1->v2 迁移
    cRoot:Get():ForEachWorld(function(World)
        -- 确保所有村民有标识符
        villager_manager.EnsureAllVillagersHaveIDs(World)
        -- 执行 v1->v2 迁移（将 v1 经验分配给第一个新分配的对应职业村民）
        villager_manager.MigrateV1ToV2(World, v1XpTable)
        return false
    end)

    -- 迁移完成后，将 v1 经验文件重命名为 .bak（避免重复迁移）
    local v1Path = PLUGIN:GetLocalFolder() .. "/player_trade_experience.txt"
    if v1XpTable and cFile:IsFile(v1Path) then
        local bakPath = PLUGIN:GetLocalFolder() .. "/player_trade_experience_v1.bak"
        os.rename(v1Path, bakPath)
        LOG("[VillagerTrade] v1 经验文件已重命名为 player_trade_experience_v1.bak")
    end

    -- 保存迁移后的村民数据
    villager_manager.SaveVillagerData()

    -- 注册钩子
---@diagnostic disable-next-line: param-type-mismatch
    cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_RIGHT_CLICKING_ENTITY, TradeOnRightClickingVillager)
---@diagnostic disable-next-line: param-type-mismatch
    cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_JOINED, LoadTradeOnPlayerJoined)
---@diagnostic disable-next-line: param-type-mismatch
    cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_DESTROYED, SaveTradeOnPlayerDestroyed)
---@diagnostic disable-next-line: param-type-mismatch
    cPluginManager.AddHook(cPluginManager.HOOK_CRAFTING_NO_RECIPE, OnCraftingNoRecipe)

    -- 启动交易刷新（基于 Age）
    cRoot:Get():ForEachWorld(RefreshVillagerTrades)

    _G.DEBUG = false -- Set to true to enable debug logging
	return true
end

-- ============================================================================
-- 村民刷怪蛋合成配方（通过 HOOK_CRAFTING_NO_RECIPE 提供）
-- ============================================================================
-- 配方：村民刷怪蛋（E_ITEM_SPAWN_EGG, meta=120）
-- 材料：绿宝石 + 鸡蛋（可配置开关见下方 EnableVillagerSpawnEggCrafting）
-- 由于 cCraftingRecipes 未导出到 Lua，无法直接添加内置配方，只能通过此钩子动态提供。
local EnableVillagerSpawnEggCrafting = true  -- 可配置开关

-- 村民刷怪蛋物品 ID 与 meta
local VILLAGER_SPAWN_EGG_ITEM = 383  -- E_ITEM_SPAWN_EGG
local VILLAGER_SPAWN_EGG_META = 120  -- E_META_SPAWN_EGG_VILLAGER

function OnCraftingNoRecipe(Player, Grid, Recipe)
    if not EnableVillagerSpawnEggCrafting then
        return false
    end

    -- 检查 2x2 合成格：绿宝石 + 鸡蛋
    -- Grid 是 cCraftingGrid，用 GetItem(x, y) 读取（x,y 从 0 开始）
    local emeraldCount = 0
    local eggCount = 0
    local totalItems = 0
    local width = Grid:GetWidth()
    local height = Grid:GetHeight()
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local item = Grid:GetItem(x, y)
            if item.m_ItemType ~= -1 then
                totalItems = totalItems + 1
                if item.m_ItemType == 388 then  -- E_ITEM_EMERALD
                    emeraldCount = emeraldCount + item.m_ItemCount
                elseif item.m_ItemType == 344 then  -- E_ITEM_EGG
                    eggCount = eggCount + item.m_ItemCount
                end
            end
        end
    end

    -- 配方：1 绿宝石 + 1 鸡蛋 = 1 村民刷怪蛋
    if totalItems == 2 and emeraldCount >= 1 and eggCount >= 1 then
        Recipe:SetResult(VILLAGER_SPAWN_EGG_ITEM, 1, VILLAGER_SPAWN_EGG_META)
        return true
    end

    return false
end

-- @param Player cPlayer
-- v2：交易按村民存储，玩家加入时无需加载交易列表。
function LoadTradeOnPlayerJoined(Player)
    -- 空操作（保留钩子以兼容）
end

-- @param Player cPlayer
-- v2：交易按村民存储，玩家销毁时无需保存交易列表。
function SaveTradeOnPlayerDestroyed(Player)
    -- 空操作（保留钩子以兼容）
end

function OnDisable()
    LOG("Saving villager data...")
    -- 保存村民数据（经验、上次刷新Age）
    if VillagerManager then
        VillagerManager.SaveVillagerData()
    end
    LOG("Shutting down...")
end