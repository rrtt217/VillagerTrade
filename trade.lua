-- trade.lua
-- v2.1 修复：
--   * 交易窗口/村民 ID/交易选择按玩家隔离（原为全局单例，多人互相破坏）
--   * 窗口尺寸改为 3x1（3 槽 + 玩家背包 36 槽 = 39 槽），与客户端村民交易窗口一致，
--     不再向窗口写入玩家背包的镜像（原 10x10 窗口槽位数与客户端预期不符，会导致槽位错乱/物品丢失）
--   * Shift+左键“尽量交易”按各输入自身的需求量扣减（原实现对两个输入槽重复扣减）
--   * UUID 为空时不再因 tonumber 返回 nil 而报错
--   * 关窗时只掉落非空的输入槽物品

-- 每个玩家的交易会话：key = UUID（无 UUID 时回退到玩家名）
--   { window = cLuaWindow, villagerID = string, selectedMatch = number }
local TradeSessions = {}

local function GetSessionKey(Player)
    local uuid = Player:GetUUID()
    if uuid == nil or uuid == "" then
        return "name:" .. Player:GetName()
    end
    return uuid
end

local function GetSession(Player)
    local key = GetSessionKey(Player)
    local session = TradeSessions[key]
    if not session then
        session = { window = nil, villagerID = nil, selectedMatch = 0 }
        TradeSessions[key] = session
    end
    return session
end

-- 用玩家 UUID 前 8 位作随机种子；UUID 为空（离线 / 无 Mojang 账号）时退回 os.time()
local function ReseedRandom(Player)
    local seedPart = 0
    local uuid = Player:GetUUID()
    if uuid and uuid ~= "" then
        seedPart = tonumber(string.sub(uuid, 1, 8), 16) or 0
    end
    math.randomseed(os.time() + seedPart)
end

-- 根据交易条目反查 trades.txt 中定义的 tradeXp
function GetXpForTradeEntry(Entry)
    for i, entryTrades in ipairs(Trades or {}) do
        local match = true
        for j, input in ipairs(entryTrades.inputs) do
            if Entry.inputs[j].m_ItemType ~= input.item.type or Entry.inputs[j].m_ItemCount < input.min or (input.max and Entry.inputs[j].m_ItemCount > input.max) then
                match = false
                break
            end
        end
        if Entry.output then
            if Entry.output.m_ItemType ~= entryTrades.output.item.type or Entry.output.m_ItemCount < entryTrades.output.min or (entryTrades.output.max and Entry.output.m_ItemCount > entryTrades.output.max) then
                match = false
            end
        end
        if match then
            return entryTrades.tradeXp or 2
        end
    end
    return 2
end

-- 取槽位内容；若该槽为空且玩家正把物品拖到该槽上，则返回被拖动的物品
-- （点击回调在默认处理之前触发，此时槽位还是空的）
function cWindow:GetSlotAfterDrag(Player, SlotNum, ClickedSlotNum)
    if self:GetSlot(Player, SlotNum).m_ItemType == -1 and SlotNum == ClickedSlotNum then
        return Player:GetDraggingItem()
    end
    return self:GetSlot(Player, SlotNum)
end

-- Shift + 左键：把指定槽位的物品移到快捷栏（窗口槽 30-38 即玩家快捷栏 0-8）
function HandleShiftLeftClick(Window, Player, SlotNum)
    local item = Window:GetSlot(Player, SlotNum)
    if item.m_ItemType == -1 then
        return false
    end
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
    return true -- 无法移动，阻止操作
end

function OnClickTradeWindow(Window, Player, SlotNum, ClickAction, ClickedItem)
    local session = GetSession(Player)
    local click = ClickActionToString(ClickAction)
    local tradeAsMuch = false
    local blocked = false

    if click == "caShiftLeftClick" then
        if SlotNum == 2 then
            -- 一次性完成尽可能多的交易
            tradeAsMuch = true
        elseif HandleShiftLeftClick(Window, Player, SlotNum) then
            return true
        end
    end
    if click == "caShiftRightClick" and SlotNum < 3 then
        -- 阻止 Shift + 右键点击交易槽
        return true
    end

    -- 右键点击输出槽：在“当前输入可匹配的多条交易”之间循环切换（不执行交易）
    local cycleOnly = false
    if SlotNum == 2 and click == "caRightClick" then
        session.selectedMatch = session.selectedMatch + 1
        cycleOnly = true
    end

    -- 使用当前玩家正在交易的村民的交易列表（按玩家隔离）
    local currentVillagerTrades = GetVillagerTrades(session.villagerID)
    local matchedTrades = {}
    for i, r in ipairs(currentVillagerTrades or {}) do
        -- 检查输入物品是否匹配交易要求
        local match = true
        if r.inputs then
            for j, b in ipairs(r.inputs) do
                if j == 1 then
                    if (Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemType ~= b.m_ItemType or Window:GetSlotAfterDrag(Player, 0, SlotNum).m_ItemCount < b.m_ItemCount) then
                        match = false
                        break
                    end
                elseif j == 2 then
                    if (Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemType ~= b.m_ItemType or Window:GetSlotAfterDrag(Player, 1, SlotNum).m_ItemCount < b.m_ItemCount) then
                        match = false
                        break
                    end
                end
            end
        end
        if match then
            table.insert(matchedTrades, {trade = r, indexProf = i})
        end
    end

    local matchedTradesCount = #matchedTrades
    DEBUGLOG("Total matched trades: " .. tostring(matchedTradesCount))
    if matchedTradesCount == 0 then
        DEBUGLOG("No matching trades found.")
        return cycleOnly
    end

    local selectedIndex = ((session.selectedMatch % matchedTradesCount) + matchedTradesCount) % matchedTradesCount + 1
    local r = matchedTrades[selectedIndex].trade
    if not r then
        return cycleOnly
    end

    -- 展示当前选中的交易结果
    if r.output and not tradeAsMuch then
        Window:SetSlot(Player, 2, r.output)
    end

    if SlotNum ~= 2 then
        return cycleOnly
    end
    if cycleOnly then
        return true -- 只切换显示，不执行交易
    end

    if tradeAsMuch then
        -- 计算最大可交易次数：所有输入中能凑出的最小次数
        local HowManyCanTrade = math.huge
        for j, b in ipairs(r.inputs or {}) do
            if j <= 2 and b.m_ItemCount > 0 then
                local slot = (j == 1) and 0 or 1
                local possibleTrades = math.floor(Window:GetSlotAfterDrag(Player, slot, SlotNum).m_ItemCount / b.m_ItemCount)
                HowManyCanTrade = math.min(HowManyCanTrade, possibleTrades)
            end
        end
        if HowManyCanTrade == math.huge or HowManyCanTrade < 1 then
            return true
        end
        -- 按每个输入自身的需求量扣除（原实现会对两个槽重复扣减）
        for j, b in ipairs(r.inputs or {}) do
            if j <= 2 then
                local slot = (j == 1) and 0 or 1
                local cur = cItem(Window:GetSlotAfterDrag(Player, slot, SlotNum))
                Window:SetSlot(Player, slot, cur:AddCount(-b.m_ItemCount * HowManyCanTrade))
            end
        end
        local newOutputAsMuch = cItem(r.output)
        Window:SetSlot(Player, 2, newOutputAsMuch:AddCount(r.output.m_ItemCount * (HowManyCanTrade - 1)))
        local vData2 = VillagerManager.GetVillagerData(session.villagerID)
        local vProf2 = vData2.profession
        vData2.xp[vProf2 + 1] = (vData2.xp[vProf2 + 1] or 0) + HowManyCanTrade * GetXpForTradeEntry(r)
        ReseedRandom(Player)
        Player:GetWorld():SpawnExperienceOrb(Player:GetPosition(), math.random(3, 6) * HowManyCanTrade)
        DEBUGLOG(" Completed " .. tostring(HowManyCanTrade) .. " trades")
        if HandleShiftLeftClick(Window, Player, 2) then
            return true
        end
        return true
    end

    -- 单次交易：从输入槽扣除物品，把结果留在输出槽由客户端取走
    for j, b in ipairs(r.inputs or {}) do
        if j == 1 then
            local newInput1 = cItem(Window:GetSlotAfterDrag(Player, 0, SlotNum))
            Window:SetSlot(Player, 0, newInput1:AddCount(-b.m_ItemCount))
            local vData = VillagerManager.GetVillagerData(session.villagerID)
            local vProf = vData.profession
            vData.xp[vProf + 1] = (vData.xp[vProf + 1] or 0) + GetXpForTradeEntry(r)
            ReseedRandom(Player)
            Player:GetWorld():SpawnExperienceOrb(Player:GetPosition(), math.random(3, 6))
        elseif j == 2 then
            local newInput2 = cItem(Window:GetSlotAfterDrag(Player, 1, SlotNum))
            Window:SetSlot(Player, 1, newInput2:AddCount(-b.m_ItemCount))
        end
    end
    return blocked
end

function OnCloseTradeWindow(Window, Player)
    local session = GetSession(Player)
    -- 只有“当前会话的窗口”关闭时才清理状态：
    -- 打开新窗口时旧窗口的 OnClosing 也会触发，不能把刚设置好的状态清掉
    if session.window == Window then
        session.selectedMatch = 0
        session.villagerID = nil
        session.window = nil
    end
    -- 把输入槽里没用掉的物品掉落在玩家脚下
    local world = Player:GetWorld()
    for _, slot in ipairs({0, 1}) do
        local item = Window:GetSlot(Player, slot)
        if item and item.m_ItemType ~= -1 then
            world:SpawnItemPickup(Player:GetPosition(), item, Vector3f(0, 0, 0))
        end
    end
end

--- @param Player cPlayer
--- @param Entity cMonster
function TradeOnRightClickingVillager(Player, Entity)
    if not Entity:IsMob() or Entity:GetMobType() ~= mtVillager then
        return false
    end

    -- 阻止玩家给村民命名（手持命名牌右键村民时返回 true，跳过默认命名处理）
    if Player:GetEquippedItem().m_ItemType == E_ITEM_NAME_TAG then
        Player:SendMessage("[VillagerTrade] 该村民已被插件管理，无法命名。")
        return true
    end

    local villagerID = VillagerManager.EnsureVillagerID(Entity)
    local session = GetSession(Player)

    -- 潜行：不打开界面，只在聊天栏列出可用交易
    if Player:IsCrouched() then
        local trades = GetVillagerTrades(villagerID)
        DEBUGLOG("[DEBUG] 潜行查看村民 " .. villagerID .. " 交易，共 " .. tostring(#trades) .. " 条")
        if trades and #trades > 0 then
            Player:SendMessage("[VillagerTrade] 可用交易：")
            for i, t in ipairs(trades) do
                local buyParts = {}
                if t.inputs then
                    for _, b in ipairs(t.inputs) do
                        table.insert(buyParts, (b.m_ItemCount or 1) .. "x " .. (ItemToString(b) or "?"))
                    end
                end
                local sellParts = {}
                if t.output then
                    table.insert(sellParts, (t.output.m_ItemCount or 1) .. "x " .. (ItemToString(t.output) or "?"))
                end
                Player:SendMessage(" - 交易 " .. i .. ": 给 " .. table.concat(buyParts, ", ") .. " -> 得到 " .. table.concat(sellParts, ", "))
            end
        else
            Player:SendMessage("[VillagerTrade] 该村民暂无可用交易。")
        end
        return
    end

    -- 打开交易窗口：尺寸必须与客户端村民交易窗口一致（3 槽 + 玩家背包 36 槽 = 39 槽）。
    -- Cuberite 文档明确警告：窗口尺寸与客户端预期不符时可能让客户端崩溃。
    session.selectedMatch = 0
    session.villagerID = villagerID
    session.window = cLuaWindow(cWindow.wtNPCTrade, 3, 1, "Villager Trade")
    session.window:SetOnClicked(OnClickTradeWindow)
    session.window:SetOnClosing(OnCloseTradeWindow)
    Player:OpenWindow(session.window)
    DEBUGLOG("Opened VillagerTrade window for player " .. Player:GetName() .. " (villager " .. villagerID .. ")")
end
