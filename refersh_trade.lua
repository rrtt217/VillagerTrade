-- refersh_trades.lua
function RefreshVillagerTrades()
    -- 读取trades.txt文件内容
    local file = io.open("trades.txt", "r")
    if not file then
        print("Error: Could not open trades.txt")
        return
    end

    -- trades.txt Parser -> 
    local trades = {}
    for line in file:lines() do
        table.insert(trades, line)
    end
    file:close()

    -- 为每位玩家设置交易
    World:ForEachPlayer(function(player)
        player.VillagerTrades = trades
    end)
    
    print("Villager trades have been refreshed.")
end