-- trade.lua

function SyncInventoryToTradeWindow(Window, Player)
    -- 同步玩家物品栏到交易窗口的槽位 3-38
    for i = 4, 40 do
        local item = Player:GetInventory():GetSlot(i)
        if item.m_ItemType ~= -1 then
            LOG(" Inventory Slot " .. i .. ": ItemType=" .. tostring(item.m_ItemType) .. " Count=" .. tostring(item.m_ItemCount))
        end
        Window:SetSlot(Player, i - 1, item)
    end
end

function SyncTradeWindowToInventory(Window, Player)
    -- 同步交易窗口的槽位 3-38 回玩家物品栏
    for i = 4, 40 do
        local item = Window:GetSlot(Player, i - 1)
        Player:GetInventory():SetSlot(i, item)
    end
end

function cWindow:GetSlotAfterDrag(Player, SlotNum, ClickedSlotNum)
    if self:GetSlot(Player,SlotNum).m_ItemType == -1 and SlotNum == ClickedSlotNum then
        LOG("Getting dragging item for slot " .. SlotNum)
        LOG(" Dragging Item: Type=" .. tostring(Player:GetDraggingItem().m_ItemType) .. " Count=" .. tostring(Player:GetDraggingItem().m_ItemCount))
        return Player:GetDraggingItem()
    end
    return self:GetSlot(Player,SlotNum)
end

function HandleShiftLeftClick(Window, Player, SlotNum)
    -- 处理 Shift + 左键点击的逻辑
    -- 尝试移动至快捷栏 30-38, 失败则返回true阻止操作
    local item = Window:GetSlot(Player, SlotNum)
    for hotbarSlot = 30, 38 do
        local invItem = Window:GetSlot(Player, hotbarSlot)
        if invItem.m_ItemType == -1 then
            -- 空位，直接移动
            Window:SetSlot(Player, hotbarSlot, item)
            Window:SetSlot(Player, SlotNum, cItem())
            return false
        elseif invItem.m_ItemType == item.m_ItemType and invItem.m_ItemCount < invItem:GetMaxStackSize() then
            -- 可叠加
            local space = invItem:GetMaxStackSize() - invItem.m_ItemCount
            if item.m_ItemCount <= space then
                invItem.m_ItemCount = invItem.m_ItemCount + item.m_ItemCount
                Window:SetSlot(Player, SlotNum, cItem())
                Window:SetSlot(Player, hotbarSlot, invItem)
                return false
            else
                invItem.m_ItemCount = invItem.m_ItemCount + space
                item.m_ItemCount = item.m_ItemCount - space
                Window:SetSlot(Player, hotbarSlot, invItem)
                Window:SetSlot(Player, SlotNum, item)
            end
        end
    end
end

function OnClickTradeWindow(Window, Player, SlotNum, ClickAction, ClickedItem)
    -- 处理交易窗口点击事件的逻辑
    -- 同步玩家物品栏到交易窗口的槽位 5-39
    local click = ClickActionToString(ClickAction)
    local tradeAsMuch = false
    if SlotNum == -999 then
        return true
    end
    if click == "caShiftLeftClick" then
        if SlotNum == 2 then
            -- 尝试一次性完成交易
            tradeAsMuch = true
        else
            HandleShiftLeftClick(Window, Player, SlotNum)
        end
        SyncTradeWindowToInventory(Window, Player)
    end
    if click == "caShiftRightClick" and SlotNum < 3 then
        -- 阻止 Shift + 右键点击操作
        return true
    end
    if SlotNum == 30 then
       -- 临时修复措施：未知问题导致点击槽30时物品丢失，阻止该操作
       return true
    end
    SyncTradeWindowToInventory(Window, Player)
    SyncInventoryToTradeWindow(Window, Player)
    for i, r in ipairs(TradeList) do
        -- 检查输入物品是否匹配交易要求
        local match = true
        if r.buy then
            for j, b in ipairs(r.buy) do
                if j == 1 then
                    if (Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemType ~= b.id or Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemCount < b.count) then
                        match = false
                        break
                    end
                elseif j == 2 then
                    if (Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemType ~= b.id or Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemCount < b.count) then
                        match = false
                        break
                    end
                end
            end
        end
        LOG("Trade check for trade " .. i .. ": match=" .. tostring(match))
        if match then
            -- 执行交易：添加输出物品至槽位2
            if r.sell and not tradeAsMuch then
                for _, s in ipairs(r.sell) do
                    if Window:GetSlot(Player, 2).m_ItemType ~= -1 then
                        break
                else
                    -- 输出槽为空，放入新物品
                    Window:SetSlot(Player, 2, cItem(s.id, s.count))
                    end
                end
            end
        end
        local HowManyCanTrade = math.huge
        if SlotNum == 2 then
            -- 从输入槽扣除物品
            for j, b in ipairs(r.buy) do
                    match = true
                    if j == 1 and not tradeAsMuch then
                        Window:SetSlot(Player, 0, cItem(Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemType, Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemCount - b.count))
                        if Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemCount < 0 then
                            Window:SetSlot(Player, 0, cItem(Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemType, Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemCount + b.count))
                            return true
                        end
                    elseif j == 2 and not tradeAsMuch then
                        Window:SetSlot(Player, 1, cItem(Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemType, Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemCount - b.count))
                        if Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemCount < 0 then
                            Window:SetSlot(Player, 1, cItem(Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemType, Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemCount + b.count))
                            return true
                        end
                    elseif tradeAsMuch then
                        local possibleTrades = math.huge
                        if j == 1 then
                            possibleTrades = math.floor(Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemCount / b.count)
                        elseif j == 2 then
                            possibleTrades = math.floor(Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemCount / b.count)
                        end
                        HowManyCanTrade = math.min(HowManyCanTrade, possibleTrades)
                        if HowManyCanTrade > 0 then
                            Window:SetSlot(Player, 0, cItem(Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemType, Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemCount - b.count * HowManyCanTrade))
                            Window:SetSlot(Player, 1, cItem(Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemType, Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemCount - b.count * HowManyCanTrade))
                            Window:SetSlot(Player, 2, cItem(r.sell[1].id, r.sell[1].count * HowManyCanTrade))
                            HandleShiftLeftClick(Window, Player, 2)
                        else
                            return true
                        end
                    end
                end
        end
    -- 更新窗口槽位
    -- Window:SetSlot(Player, 0, Window:GetSlot(Player, 0))
    -- Window:SetSlot(Player, 1, Window:GetSlot(Player, 1))
    -- Window:SetSlot(Player, 2, Window:GetSlot(Player, 2))
    LOG("After trade processing:")
    LOG(" Input Slot 1: ItemType=" .. tostring(Window:GetSlot(Player, 0).m_ItemType) .. " Count=" .. tostring(Window:GetSlot(Player, 0).m_ItemCount))
    LOG(" Input Slot 2: ItemType=" .. tostring(Window:GetSlot(Player, 1).m_ItemType) .. " Count=" .. tostring(Window:GetSlot(Player, 1).m_ItemCount))
    LOG(" Output Slot: ItemType=" .. tostring(Window:GetSlot(Player, 2).m_ItemType) .. " Count=" .. tostring(Window:GetSlot(Player, 2).m_ItemCount))
    SyncTradeWindowToInventory(Window, Player)
    SyncInventoryToTradeWindow(Window, Player)
    break -- 假设一次只处理一个匹配的交易
    end
    SyncTradeWindowToInventory(Window, Player)
    SyncInventoryToTradeWindow(Window, Player)
    LOG("Player " .. Player:GetName() .. " clicked slot " .. SlotNum .. " in trade window. Action: " .. click)
end

function OnCloseTradeWindow(Window, Player)
    -- 处理交易窗口关闭事件的逻辑
    LOG("Player " .. Player:GetName() .. " closed the trade window.")
    -- 在窗口关闭时同步物品栏
    SyncTradeWindowToInventory(Window, Player)
    World = Player:GetWorld()
    -- 将未交易的物品掉落在玩家位置
    World:SpawnItemPickup(Player:GetPosition(), Window:GetSlot(Player, 0),Vector3f(0,0,0))
    World:SpawnItemPickup(Player:GetPosition(), Window:GetSlot(Player, 1),Vector3f(0,0,0))
end

--- @param Player cPlayer
--- @param Entity cEntity
function TradeOnRightClickingVillager(Player, Entity)
    -- 尝试打开交易窗口并列出可用测试交易（如果定义了）
    VillagerTradeWindow = cLuaWindow(cWindow.wtNPCTrade,10,10,"Villager Trade")
    VillagerTradeWindow:SetOnClicked(OnClickTradeWindow)
    VillagerTradeWindow:SetOnClosing(OnCloseTradeWindow)
    -- 加载插件目录下的 villager_trades.lua（如果存在）
    Trades = {}
    if PLUGIN ~= nil then
        local path = PLUGIN:GetLocalFolder() .. "/villager_trades.lua"
        local f = io.open(path, "r")
        if f then
            f:close()
            local ok, result = pcall(dofile, path)
            if ok and type(result) == "table" then
                Trades = result
                LOG("Loaded villager trades from " .. path)
            end
        end
    end

    if Entity:IsMob() then
        tolua:cast(Entity, "cMonster")
        LOG("Right clicked mob type: " .. Entity:GetMobType())
        if Entity:GetMobType() == mtVillager then
            -- 按玩家是否潜行决定行为：潜行则不打开 UI，仅发送交易信息
            local prof = "default"
            TradeList = Trades[prof] or Trades.default
            if Player:IsCrouched() then
                if TradeList and #TradeList > 0 then
                    Player:SendMessage("[VillagerTrade] 可用交易：")
                    for i, t in ipairs(TradeList) do
                        local buyParts = {}
                        if t.buy then
                            for _, b in ipairs(t.buy) do
                                table.insert(buyParts, (b.count or 1) .. "x id" .. (b.id or "?"))
                            end
                        end
                        local sellParts = {}
                        if t.sell then
                            for _, s in ipairs(t.sell) do
                                table.insert(sellParts, (s.count or 1) .. "x id" .. (s.id or "?"))
                            end
                        end
                        Player:SendMessage(" - 交易 " .. i .. ": 给 " .. table.concat(buyParts, ", ") .. " -> 得到 " .. table.concat(sellParts, ", "))
                    end
                else
                    Player:SendMessage("[VillagerTrade] 该村民暂无可用交易（测试数据缺失）。")
                end
                return
            end

            -- 非潜行：打开交易窗口并用 GetSlot/SetSlot 填充格子(0,1 作为输入, 2 作为输出)
            Player:OpenWindow(VillagerTradeWindow)
            SyncInventoryToTradeWindow(VillagerTradeWindow, Player)
            Inventory = Player:GetInventory()
            LOG("Opened VillagerTrade window for player " .. Player:GetName())
        end
    end
end