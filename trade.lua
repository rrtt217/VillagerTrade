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

-- 空槽判定：客户端默认点击处理有时会把槽位留成 count=0 的"幽灵物品"，
-- 这类槽必须按空槽处理，否则会被当成占用格。
local function IsEmptyItem(it)
    return (not it) or it.m_ItemType == -1 or it.m_ItemCount <= 0
end

-- 写入槽位数量；减到 0 时写空物品，避免留下 count=0 的"幽灵物品"
-- （客户端/关窗掉落/空槽判定都会把 count=0 的槽当成有物品）
local function SetSlotCount(Window, Player, SlotNum, item, newCount)
    if newCount <= 0 then
        Window:SetSlot(Player, SlotNum, cItem())
    else
        item.m_ItemCount = newCount
        Window:SetSlot(Player, SlotNum, item)
    end
end

-- 取槽位内容；若该槽为空且玩家正把物品拖到该槽上，则返回被拖动的物品
-- （点击回调在默认处理之前触发，此时槽位还是空的）
function cWindow:GetSlotAfterDrag(Player, SlotNum, ClickedSlotNum)
    if IsEmptyItem(self:GetSlot(Player, SlotNum)) and SlotNum == ClickedSlotNum then
        return Player:GetDraggingItem()
    end
    return self:GetSlot(Player, SlotNum)
end

-- Shift + 左键：把指定槽位的物品移到快捷栏（窗口槽 30-38 即玩家快捷栏 0-8）
function HandleShiftLeftClick(Window, Player, SlotNum)
    local item = Window:GetSlot(Player, SlotNum)
    if IsEmptyItem(item) then
        return false
    end
    for hotbarSlot = 30, 38 do
        local invItem = Window:GetSlot(Player, hotbarSlot)
        if IsEmptyItem(invItem) then
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

-- 判断两个物品能否堆叠（类型/伤害/附魔一致）
local function CanStackTogether(a, b)
    if a.m_ItemType ~= b.m_ItemType or a.m_ItemDamage ~= b.m_ItemDamage then
        return false
    end
    return a.m_Enchantments == b.m_Enchantments
end

-- 玩家背包（窗口槽 3..38）还能容纳多少个 baseItem
local function GetOutputCapacity(Window, Player, baseItem)
    local maxStack = baseItem:GetMaxStackSize()
    local cap = 0
    for slot = 3, 38 do
        local it = Window:GetSlot(Player, slot)
        if IsEmptyItem(it) then
            cap = cap + maxStack
        elseif CanStackTogether(it, baseItem) and it.m_ItemCount < maxStack then
            cap = cap + (maxStack - it.m_ItemCount)
        end
    end
    return cap
end

-- 把 total 个 baseItem 放进玩家背包（先叠加到同类堆叠，再占用空槽），返回放不下的数量
local function PlaceOutput(Window, Player, baseItem, total)
    local left = total
    local maxStack = baseItem:GetMaxStackSize()
    for slot = 3, 38 do
        if left <= 0 then break end
        local it = Window:GetSlot(Player, slot)
        if not IsEmptyItem(it) and CanStackTogether(it, baseItem) and it.m_ItemCount < maxStack then
            local add = math.min(maxStack - it.m_ItemCount, left)
            it.m_ItemCount = it.m_ItemCount + add
            Window:SetSlot(Player, slot, it)
            left = left - add
        end
    end
    for slot = 3, 38 do
        if left <= 0 then break end
        local it = Window:GetSlot(Player, slot)
        if IsEmptyItem(it) then
            local add = math.min(maxStack, left)
            local newItem = cItem(baseItem)
            newItem.m_ItemCount = add
            Window:SetSlot(Player, slot, newItem)
            left = left - add
        end
    end
    return left
end

-- 交易描述（用于切换提示）
local function DescribeTrade(t)
    local parts = {}
    for _, b in ipairs(t.inputs or {}) do
        table.insert(parts, tostring(b.m_ItemCount) .. "x " .. (ItemToString(b) or "?"))
    end
    return table.concat(parts, " + ") .. " -> "
        .. tostring(t.output.m_ItemCount) .. "x " .. (ItemToString(t.output) or "?")
end

function OnClickTradeWindow(Window, Player, SlotNum, ClickAction, ClickedItem)
    local session = GetSession(Player)
    local click = ClickActionToString(ClickAction)
    local tradeAsMuch = false
    local cycleOnly = false

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

    -- 匹配集合变化时重置选择，避免"选择偏移"到别的交易
    local keyParts = {}
    for _, m in ipairs(matchedTrades) do
        table.insert(keyParts, tostring(m.indexProf))
    end
    local matchedKey = table.concat(keyParts, ",")
    if session.matchedKey ~= matchedKey then
        session.matchedKey = matchedKey
        session.selectedMatch = 0
    end

    -- 右键输出槽：在匹配到的多条交易之间循环切换（不执行交易）
    if SlotNum == 2 and click == "caRightClick" and #matchedTrades > 0 then
        session.selectedMatch = session.selectedMatch + 1
        cycleOnly = true
    end

    local matchedTradesCount = #matchedTrades
    DEBUGLOG("Total matched trades: " .. tostring(matchedTradesCount))
    local selectedIndex, r = 0, nil
    if matchedTradesCount > 0 then
        selectedIndex = ((session.selectedMatch % matchedTradesCount) + matchedTradesCount) % matchedTradesCount + 1
        r = matchedTrades[selectedIndex].trade
    end

    -- 输出槽由插件独占：
    --   * 无匹配交易 -> 清掉预览并阻止点击（否则客户端可以直接拿走"预览"物品）
    --   * 光标上有物品 -> 阻止放入（原版村民交易的结果槽同样不接受放置）
    if SlotNum == 2 and not tradeAsMuch then
        if not r then
            if not IsEmptyItem(Window:GetSlot(Player, 2)) then
                Window:SetSlot(Player, 2, cItem())
            end
            return true
        end
        if Player:GetDraggingItem().m_ItemType ~= -1 then
            return true
        end
    end

    if not r then
        return false
    end

    -- 展示当前选中的交易结果
    if not tradeAsMuch then
        Window:SetSlot(Player, 2, r.output)
    end

    if cycleOnly then
        if matchedTradesCount > 1 then
            Player:SendMessage("[VillagerTrade] 交易 " .. selectedIndex .. "/" .. matchedTradesCount
                .. "：" .. DescribeTrade(r))
        end
        return true
    end

    if SlotNum ~= 2 then
        return false
    end

    if tradeAsMuch then
        -- 可交易次数：受输入数量与背包可容纳量共同限制
        local maxByInput = math.huge
        for j, b in ipairs(r.inputs or {}) do
            if j <= 2 and b.m_ItemCount > 0 then
                local slot = (j == 1) and 0 or 1
                maxByInput = math.min(maxByInput,
                    math.floor(Window:GetSlotAfterDrag(Player, slot, SlotNum).m_ItemCount / b.m_ItemCount))
            end
        end
        if maxByInput == math.huge or maxByInput < 1 then
            return true
        end
        local perOut = r.output.m_ItemCount
        local capacity = GetOutputCapacity(Window, Player, r.output)
        local howMany = math.min(maxByInput, math.floor(capacity / perOut))
        if howMany < 1 then
            Player:SendMessage("[VillagerTrade] 背包空间不足，无法完成交易。")
            return true
        end
        -- 扣除输入：显式赋值。cItem:AddCount 的参数是 8 位有符号数，超过 ±127 会回绕，
        -- 大额连交会因此白扣物品或凭空给出物品。
        for j, b in ipairs(r.inputs or {}) do
            if j <= 2 then
                local slot = (j == 1) and 0 or 1
                local cur = cItem(Window:GetSlotAfterDrag(Player, slot, SlotNum))
                SetSlotCount(Window, Player, slot, cur, cur.m_ItemCount - b.m_ItemCount * howMany)
            end
        end
        -- 产出按最大堆叠分配到背包多个槽位
        PlaceOutput(Window, Player, r.output, perOut * howMany)
        Window:SetSlot(Player, 2, cItem())
        local vData2 = VillagerManager.GetVillagerData(session.villagerID)
        local vProf2 = vData2.profession
        vData2.xp[vProf2 + 1] = (vData2.xp[vProf2 + 1] or 0) + howMany * GetXpForTradeEntry(r)
        Player:GetWorld():SpawnExperienceOrb(Player:GetPosition(), VillagerManager.Random.Int(3, 6) * howMany)
        DEBUGLOG(" Completed " .. tostring(howMany) .. " trades")
        return true
    end

    -- 单次交易：从输入槽扣除物品，把结果留在输出槽由客户端取走
    for j, b in ipairs(r.inputs or {}) do
        if j == 1 then
            local newInput1 = cItem(Window:GetSlotAfterDrag(Player, 0, SlotNum))
            SetSlotCount(Window, Player, 0, newInput1, newInput1.m_ItemCount - b.m_ItemCount)
            local vData = VillagerManager.GetVillagerData(session.villagerID)
            local vProf = vData.profession
            vData.xp[vProf + 1] = (vData.xp[vProf + 1] or 0) + GetXpForTradeEntry(r)
            Player:GetWorld():SpawnExperienceOrb(Player:GetPosition(), VillagerManager.Random.Int(3, 6))
        elseif j == 2 then
            local newInput2 = cItem(Window:GetSlotAfterDrag(Player, 1, SlotNum))
            SetSlotCount(Window, Player, 1, newInput2, newInput2.m_ItemCount - b.m_ItemCount)
        end
    end
    return false
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
    -- 输出槽只可能存放插件生成的"预览"（未付款），关窗时直接清除；
    -- 掉落出去等于白送，因此绝不能像输入槽那样 SpawnItemPickup。
    if not IsEmptyItem(Window:GetSlot(Player, 2)) then
        Window:SetSlot(Player, 2, cItem())
    end
    -- 把输入槽里没用掉的物品掉落在玩家脚下
    local world = Player:GetWorld()
    for _, slot in ipairs({0, 1}) do
        local item = Window:GetSlot(Player, slot)
        if not IsEmptyItem(item) then
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
