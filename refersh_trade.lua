-- refersh_trades.lua
function RefreshVillagerTrades()
    
    -- 为每位玩家设置交易
    cRoot:ForEachPlayer(function(player)
        XpLevel = 0
        if player.TradeExperience then
            XpLevel = math.floor(math.sqrt(player.TradeExperience / 10))
        end
    end)
    
    print("Villager trades have been refreshed.")
end