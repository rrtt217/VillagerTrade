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
    -- Hook right-clicking villager to open trade window
	cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_RIGHT_CLICKING_ENTITY, TradeOnRightClickingVillager)
    cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_JOINED, LoadTradeXpOnPlayerJoined)
    cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_DESTROYED, SaveTradeXpOnPlayerDestroyed)
	return true
end

-- @param Player cPlayer
function LoadTradeXpOnPlayerJoined(Player)
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
end

function SaveTradeXpOnPlayerDestroyed(Player)
    if XpTable then
        local uuid = Player:GetUUID()
        XpTable[uuid] = Player.TradeExperience
    end
    LOG("Saved trade experience for player " .. Player:GetName())
    for i, xp in ipairs(Player.TradeExperience) do
        LOG("  Profession " .. i .. ": " .. tostring(xp) .. " XP")
    end
end

function OnDisable()
    LOG("Saving player trade experience data...")
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
	LOG("Shutting down...")
end
    
