PLUGIN = nil

function Initialize(Plugin)
	Plugin:SetName("Trade")
	Plugin:SetVersion(1)

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
        LOG("Trade " .. i .. ": " .. tostring(trade.inputs[1].item.type) .. " x" .. tostring(trade.inputs[1].min) .. " -> " .. tostring(trade.output.item.type) .. " x" .. tostring(trade.output.min))
    end
    -- Load player trade experience data  
    local player_trade_xp_parser= require("player_trade_xp_parser")
    if not player_trade_xp_parser or type(player_trade_xp_parser) ~= "table" or type(player_trade_xp_parser.LoadPlayerTradeExperience) ~= "function" then
        LOG("Error: could not load player_trade_xp_parser.lua")
        return
    end
    XpTable = player_trade_xp_parser.LoadPlayerTradeExperience()
    if XpTable then
        LOG("Loaded player trade experience data for " .. tostring(#XpTable) .. " players.")
    else
        LOG("No player trade experience data loaded.")
    end
    _G.XpTable = XpTable
    local PlayerTrades = {}
    local pathTrades = PLUGIN:GetLocalFolder() .. "/player_trades.txt"
    local fileTrades = io.open(pathTrades, "r")
    if fileTrades then
        for line in fileTrades:lines() do
            local uuid, tradesJson = line:match("^(%S+)%s*=%s*(.+)$")
            if uuid and tradesJson then
                LOG("Loading trades for player UUID " .. uuid)
                LOG("Trades JSON: " .. tradesJson)
                local success, trades = pcall(function() return cJson:Parse(tradesJson) end)
                if success and trades then
                    LOG("Successfully parsed trades for player UUID " .. uuid)
                    PlayerTrades[uuid] = trades
                end
            end
        end
        fileTrades:close()
    end
    PlayerTrades = GeneratePlayerTradesFromSerializable(PlayerTrades)
    LOG("Loaded player trades for " .. tostring(#PlayerTrades) .. " players.")
    cRoot:Get():ForEachPlayer(function(player)
        local uuid = player:GetUUID()
        if XpTable and XpTable[uuid] then
            player.TradeExperience = XpTable[uuid]
        else
            player.TradeExperience = {0, 0, 0, 0, 0, 0}
        end
        LOG("Loaded trade experience for player " .. player:GetName())
    end)
    _G.PlayerTrades = PlayerTrades
    -- Hook right-clicking villager to open trade window
    cRoot:Get():ForEachWorld(RefreshVillagerTrades)
---@diagnostic disable-next-line: param-type-mismatch
	cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_RIGHT_CLICKING_ENTITY, TradeOnRightClickingVillager)
---@diagnostic disable-next-line: param-type-mismatch
    cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_JOINED, LoadTradeOnPlayerJoined)
---@diagnostic disable-next-line: param-type-mismatch
    cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_DESTROYED, SaveTradeOnPlayerDestroyed)
    _G.DEBUG = false -- Set to true to enable debug logging
	return true
end

function MyItemToFullString(item)
    local itemStr = string.format("%s:%d * %d - %s", ItemToString(item), item.m_ItemDamage, item.m_ItemCount, item.m_Enchantments:ToString())
    return itemStr
end

function MyFullStringToItem(itemStr)
    local itemType, itemDamage, itemCount, enchantmentsStr = itemStr:match("^(.-):(%d+)%s*%*%s*(%d+)%s*-%s*(.*)$")
    if not itemType or not itemDamage or not itemCount then
        return nil
    end
    local item = cItem()
    StringToItem(itemType, item)
    item.m_ItemDamage = tonumber(itemDamage) or 0
    item.m_ItemCount = tonumber(itemCount) or 1
    if enchantmentsStr and enchantmentsStr ~= "" then
        item.m_Enchantments = cEnchantments(enchantmentsStr)
    end
    return item
end

function ConvertPlayerTradesToSerializable()
    local serializableTrades = {}
    for uuid, trades in pairs(PlayerTrades) do
        serializableTrades[uuid] = {}
        for profIndex, profTrades in pairs(trades) do
            serializableTrades[uuid][profIndex] = {}
            for i, trade in ipairs(profTrades) do
                local serializableInputs = {}
                if not trade.inputs then break end
                for j, input in ipairs(trade.inputs) do
                    serializableInputs[j] = MyItemToFullString(input)
                end
                local serializableOutput = MyItemToFullString(trade.output)
                serializableTrades[uuid][profIndex][i] = {["inputs"] = serializableInputs, ["output"] = serializableOutput}
            end
        end
    end
    return serializableTrades
end

function GeneratePlayerTradesFromSerializable(serializableTrades)
    local playerTrades = {}
    for uuid, trades in pairs(serializableTrades) do
        playerTrades[uuid] = {}
        LOG("Generating trades for player UUID " .. uuid)
        LOG("Trades data: " .. cJson:Serialize(trades,{indentation = ""}))
        for profIndex, profTrades in pairs(trades) do
            playerTrades[uuid][profIndex] = {}
            for i, trade in ipairs(profTrades) do
                local deserializedInputs = {}
                for j, inputStr in ipairs(trade.inputs) do
                    local item = MyFullStringToItem(inputStr)
                    deserializedInputs[j] = item
                end
                local outputItem = MyFullStringToItem(trade.output)
                LOG(MyItemToFullString(outputItem or cItem()) )
                playerTrades[uuid][profIndex][i] = {inputs = deserializedInputs, output = outputItem}
                LOG("  Trade " .. i .. ":")
                for j, input in ipairs(deserializedInputs) do
                    LOG("    Input " .. j .. ": " .. MyItemToFullString(input))
                end
            end
        end
    end
    LOG("Generated player trades from serializable data.")
    LOG("Player Trades: " .. cJson:Serialize(playerTrades,{indentation = ""}))
    return playerTrades
end

-- @param Player cPlayer
function LoadTradeOnPlayerJoined(Player)
    local uuid = Player:GetUUID()
    if XpTable and XpTable[uuid] then
        Player.TradeExperience = XpTable[uuid]
    else
        Player.TradeExperience = {0, 0, 0, 0, 0, 0}
    end
    LOG("Loaded trade experience for player " .. Player:GetName())
    for i, xp in ipairs(Player.TradeExperience) do
        LOG("  Profession " .. i .. ": " .. tostring(xp) .. " XP")
    end
    if PlayerTrades[Player:GetUUID()] then
        Player.trades = PlayerTrades[Player:GetUUID()]
    else
        RefreshTradesForPlayer(Player)
    end
end

-- @param Player cPlayer
function SaveTradeOnPlayerDestroyed(Player)
    if XpTable then
        local uuid = Player:GetUUID()
        XpTable[uuid] = Player.TradeExperience
    end
    LOG("Saved trade experience for player " .. Player:GetName())
    for i, xp in ipairs(Player.TradeExperience) do
        LOG("  Profession " .. i .. ": " .. tostring(xp) .. " XP")
    end
    PlayerTrades[Player:GetUUID()] = Player.trades
end

function OnDisable()
    LOG("Saving player trade experience data...")
    cRoot:Get():ForEachPlayer(function(player)
        SaveTradeOnPlayerDestroyed(player)
    end)
    local path = PLUGIN:GetLocalFolder() .. "/player_trade_experience.txt"
    local file = io.open(path, "w")
    if file then
        for uuid, xpList in pairs(XpTable) do
            local line = uuid .. " = "
            for i, xp in ipairs(xpList) do
                line = line .. tostring(xp)
                if i < #xpList then
                    line = line .. " | "
                end
            end
            file:write(line .. "\n")
        end
        file:close()
    end
    local pathTrades = PLUGIN:GetLocalFolder() .. "/player_trades.txt"
    local fileTrades = io.open(pathTrades, "w")
    if fileTrades then
        for uuid, trades in pairs(ConvertPlayerTradesToSerializable()) do
            fileTrades:write(uuid .. " = " .. cJson:Serialize(trades,{indentation = ""}) .. "\n")
        end
        fileTrades:close()
    end
    LOG("Shutting down...")
end