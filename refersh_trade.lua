-- refersh_trades.lua
-- @param World cWorld
function RefreshVillagerTrades(World)
    World:ForEachPlayer(RefreshTradesForPlayer)
    print("Villager trades have been refreshed.")
    World:ScheduleTask(20*40*60, RefreshVillagerTrades)
end
-- @param Player cPlayer
function RefreshTradesForPlayer(player)
    math.randomseed(os.time() + tonumber(string.sub(player:GetUUID(), 1, 8), 16))
    XpLevels = {0,0,0,0,0,0}
    for i, xp in ipairs(player.TradeExperience) do
        if xp >= 600 then
            XpLevels[i] = 3
        elseif xp >= 300 then
            XpLevels[i] = 2
        elseif xp >= 100 then
            XpLevels[i] = 1
        else
            XpLevels[i] = 0
        end
    end
    player.trades = {{}, {}, {}, {}, {}, {}}
    for entry in pairs(Trades or {}) do
        local trade = Trades[entry]
        if trade then
            local profession = trade.profession
            local level = XpLevels[(profession or 5) + 1]
            if trade.unlockLevel and level >= trade.unlockLevel and trade.weight and math.random() < trade.weight then
                local formattedTrade = {}
                formattedTrade.inputs = {}
                for _, input in ipairs(trade.inputs) do
                    local item = cItem()
                    if tonumber(input.item.type) == nil then
                        if StringToItem(input.item.type, item) then
                            LOG("Converted item string to item: " .. input.item.type)
                        end
                    else
                        item = cItem(tonumber(input.item.type))
                    end
                    local itemCount = math.random(input.min, input.max)
                    if itemCount <= 0 then itemCount = 1 end
                    if itemCount > item:GetMaxStackSize() then
                        itemCount = item:GetMaxStackSize()
                    end
                    item.m_ItemCount = itemCount
                    item.m_ItemDamage = input.item.damage or 0
                    if input.item.enchantments and not input.item.enchantments:match("ByXpLevels") then
                        item.m_Enchantments = cEnchantments(input.item.enchantments)
                    elseif input.item.enchantments and input.item.enchantments:match("ByXpLevels") then
                        local enchantLevelMin, enchantLevelMax = input.item.enchantments:match("ByXpLevels%((%d+),%s*(%d+)%)")
                        local enchantLevel = math.random(tonumber(enchantLevelMin) or 0, tonumber(enchantLevelMax) or 0)
                        item:EnchantByXPLevels(enchantLevel)
                    end
                    table.insert(formattedTrade.inputs, item)
                end
                local outItem = cItem()
                if tonumber(trade.output.item.type) == nil then
                    StringToItem(trade.output.item.type, outItem)
                else
                    outItem = cItem(tonumber(trade.output.item.type))
                end
                local outItemCount = math.random(trade.output.min, trade.output.max)
                if outItemCount <= 0 then outItemCount = 1 end
                if outItemCount > outItem:GetMaxStackSize() then
                    outItemCount = outItem:GetMaxStackSize()
                end
                outItem.m_ItemCount = outItemCount
                outItem.m_ItemDamage = trade.output.item.damage or 0
                if trade.output.item.enchantments and not trade.output.item.enchantments:match("ByXpLevels") then
                    outItem.m_Enchantments = cEnchantments(trade.output.item.enchantments)
                elseif trade.output.item.enchantments and trade.output.item.enchantments:match("ByXpLevels") then
                    local enchantLevelMin, enchantLevelMax = trade.output.item.enchantments:match("ByXpLevels%((%d+),%s*(%d+)%)")
                    local enchantLevel = math.random(tonumber(enchantLevelMin) or 0, tonumber(enchantLevelMax) or 0)
                    outItem:EnchantByXPLevels(enchantLevel)
                end
                formattedTrade.output = outItem
                table.insert(player.trades[(profession or 5) + 1], formattedTrade)
            end
        end
    end
    PlayerTrades[player:GetUUID()] = player.trades
    LOG("Trades refreshed for player " .. player:GetName())
    LOG("  New trades:")
    for profIndex, trades in ipairs(player.trades) do
        LOG("    Profession " .. (profIndex - 1) .. ":")
        for tradeIndex, trade in ipairs(trades) do
            local inputDesc = {}
            for _, input in ipairs(trade.inputs) do
                table.insert(inputDesc, ItemToFullString(input))
            end
            local outputDesc = ItemToFullString(trade.output)
            LOG("      Trade " .. tradeIndex .. ": " .. table.concat(inputDesc, ", ") .. " -> " .. outputDesc)
        end 
    end
end
