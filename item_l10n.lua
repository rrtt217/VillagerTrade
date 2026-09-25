-- item_l10n.lua
-- 把 cItem 渲染成"客户端可翻译"的聊天组件。
--
-- 原理：cPlayer:SendMessageRaw(json) 可以把 JSON 文本组件直接发给客户端，
--       {"translate":"<key>"} 由客户端用自己的语言文件渲染成玩家母语。
-- 注意：翻译键随客户端协议版本变化——
--   * 1.8 ~ 1.12.2（协议 < 393）：旧式驼峰键，如 item.emerald.name / tile.cloth.white.name
--   * 1.13+（协议 >= 393）      ：扁平键，如 item.minecraft.emerald / block.minecraft.white_wool
--   Cuberite 的 ItemToString 返回的是 items.ini 别名（cookedfished / whitewool / fishingrod），
--   与原版注册名与翻译键都不一致，所以这里为 trades.txt 涉及的物品维护静态映射表。
--   表中键逐个取自 minecraft-data 的 1.12 / 1.13 / 1.14.4 language.json 并核对存在。
--
-- 未收录的物品会回退到 ItemToString，避免把原始键（如 item.minecraft.emerald）直接显示给玩家。

local item_l10n = {}

-- 协议版本 >= 此值时使用扁平化键（1.13 的协议版本是 393）
item_l10n.FLATTENED_MIN_PROTOCOL = 393

-- ["<type>:<damage>"] = { legacy = <键或组件>, flat = <键或组件> }
item_l10n.Keys = {
    ["260:0"] = { legacy = "item.apple.name", flat = "item.minecraft.apple" }, -- apple
    ["262:0"] = { legacy = "item.arrow.name", flat = "item.minecraft.arrow" }, -- arrow
    ["340:0"] = { legacy = "item.book.name", flat = "item.minecraft.book" }, -- book
    ["47:0"] = { legacy = "tile.bookshelf.name", flat = "block.minecraft.bookshelf" }, -- bookshelf
    ["261:0"] = { legacy = "item.bow.name", flat = "item.minecraft.bow" }, -- bow
    ["297:0"] = { legacy = "item.bread.name", flat = "item.minecraft.bread" }, -- bread
    ["354:0"] = { legacy = "tile.cake.name", flat = "block.minecraft.cake" }, -- cake
    ["391:0"] = { legacy = "item.carrots.name", flat = "item.minecraft.carrot" }, -- carrot
    ["305:0"] = { legacy = "item.bootsChain.name", flat = "item.minecraft.chainmail_boots" }, -- chainmail_boots
    ["303:0"] = {
        legacy = "item.chestplateChain.name", flat = "item.minecraft.chainmail_chestplate",
    }, -- chainmail_chestplate
    ["302:0"] = { legacy = "item.helmetChain.name", flat = "item.minecraft.chainmail_helmet" }, -- chainmail_helmet
    ["304:0"] = {
        legacy = "item.leggingsChain.name", flat = "item.minecraft.chainmail_leggings",
    }, -- chainmain_leggings
    ["365:0"] = { legacy = "item.chickenRaw.name", flat = "item.minecraft.chicken" }, -- chicken
    ["347:0"] = { legacy = "item.clock.name", flat = "item.minecraft.clock" }, -- clock
    ["263:0"] = { legacy = "item.coal.name", flat = "item.minecraft.coal" }, -- coal
    ["345:0"] = { legacy = "item.compass.name", flat = "item.minecraft.compass" }, -- compass
    ["366:0"] = { legacy = "item.chickenCooked.name", flat = "item.minecraft.cooked_chicken" }, -- cooked_chicken
    ["320:0"] = { legacy = "item.porkchopCooked.name", flat = "item.minecraft.cooked_porkchop" }, -- cooked_porkchop
    ["350:0"] = { legacy = "item.fish.cod.cooked.name", flat = "item.minecraft.cooked_cod" }, -- cookedfish
    ["357:0"] = { legacy = "item.cookie.name", flat = "item.minecraft.cookie" }, -- cookie
    ["264:0"] = { legacy = "item.diamond.name", flat = "item.minecraft.diamond" }, -- diamond
    ["279:0"] = { legacy = "item.hatchetDiamond.name", flat = "item.minecraft.diamond_axe" }, -- diamond_axe
    ["311:0"] = {
        legacy = "item.chestplateDiamond.name", flat = "item.minecraft.diamond_chestplate",
    }, -- diamond_chestplate
    ["278:0"] = { legacy = "item.pickaxeDiamond.name", flat = "item.minecraft.diamond_pickaxe" }, -- diamond_pickaxe
    ["276:0"] = { legacy = "item.swordDiamond.name", flat = "item.minecraft.diamond_sword" }, -- diamond_sword
    ["388:0"] = { legacy = "item.emerald.name", flat = "item.minecraft.emerald" }, -- emerald
    ["368:0"] = { legacy = "item.enderPearl.name", flat = "item.minecraft.ender_pearl" }, -- ender_pearl
    ["384:0"] = { legacy = "item.expBottle.name", flat = "item.minecraft.experience_bottle" }, -- experience_bottle
    ["349:0"] = { legacy = "item.fish.cod.raw.name", flat = "item.minecraft.cod" }, -- fish
    ["346:0"] = { legacy = "item.fishingRod.name", flat = "item.minecraft.fishing_rod" }, -- fishing_rod
    ["318:0"] = { legacy = "item.flint.name", flat = "item.minecraft.flint" }, -- flint
    ["20:0"] = { legacy = "tile.glass.name", flat = "block.minecraft.glass" }, -- glass
    ["348:0"] = { legacy = "item.yellowDust.name", flat = "item.minecraft.glowstone_dust" }, -- glowstone_dust
    ["266:0"] = { legacy = "item.ingotGold.name", flat = "item.minecraft.gold_ingot" }, -- gold_ingot
    ["13:0"] = { legacy = "tile.gravel.name", flat = "block.minecraft.gravel" }, -- gravel
    ["258:0"] = { legacy = "item.hatchetIron.name", flat = "item.minecraft.iron_axe" }, -- iron_axe
    ["307:0"] = { legacy = "item.chestplateIron.name", flat = "item.minecraft.iron_chestplate" }, -- iron_chestplate
    ["306:0"] = { legacy = "item.helmetIron.name", flat = "item.minecraft.iron_helmet" }, -- iron_helmet
    ["265:0"] = { legacy = "item.ingotIron.name", flat = "item.minecraft.iron_ingot" }, -- iron_ingot
    ["257:0"] = { legacy = "item.pickaxeIron.name", flat = "item.minecraft.iron_pickaxe" }, -- iron_pickaxe
    ["256:0"] = { legacy = "item.shovelIron.name", flat = "item.minecraft.iron_shovel" }, -- iron_shovel
    ["267:0"] = { legacy = "item.swordIron.name", flat = "item.minecraft.iron_sword" }, -- iron_sword
    ["351:4"] = { legacy = "item.dyePowder.blue.name", flat = "item.minecraft.lapis_lazuli" }, -- lapislazuli
    ["395:0"] = { legacy = "item.emptyMap.name", flat = "item.minecraft.map" }, -- map
    ["360:0"] = { legacy = "tile.melon.name", flat = "block.minecraft.melon" }, -- melon
    ["421:0"] = { legacy = "item.nameTag.name", flat = "item.minecraft.name_tag" }, -- name_tag
    ["339:0"] = { legacy = "item.paper.name", flat = "item.minecraft.paper" }, -- paper
    ["319:0"] = { legacy = "item.porkchopRaw.name", flat = "item.minecraft.porkchop" }, -- porkchop
    ["392:0"] = { legacy = "item.potato.name", flat = "item.minecraft.potato" }, -- potato
    ["86:0"] = { legacy = "tile.pumpkin.name", flat = "block.minecraft.pumpkin" }, -- pumpkin
    ["400:0"] = { legacy = "item.pumpkinPie.name", flat = "item.minecraft.pumpkin_pie" }, -- pumpkin_pie
    ["331:0"] = { legacy = "item.redstone.name", flat = "item.minecraft.redstone" }, -- redstone
    ["367:0"] = { legacy = "item.rottenFlesh.name", flat = "item.minecraft.rotten_flesh" }, -- rottenflesh
    ["359:0"] = { legacy = "item.shears.name", flat = "item.minecraft.shears" }, -- shears
    -- 1.12 的刷怪蛋名字由 "Spawn" + 生物名 组合而成（原版行为）；1.13+ 有独立键
    ["383:120"] = {
        legacy = { translate = "item.monsterPlacer.name",
                   extra = { { text = " " }, { translate = "entity.Villager.name" } } },
        flat = "item.minecraft.villager_spawn_egg",
    }, -- spawn_egg
    ["287:0"] = { legacy = "item.string.name", flat = "item.minecraft.string" }, -- string
    ["296:0"] = { legacy = "item.wheat.name", flat = "item.minecraft.wheat" }, -- wheat
    ["35:0"] = { legacy = "tile.cloth.white.name", flat = "block.minecraft.white_wool" }, -- wool
    ["387:0"] = { legacy = "item.writtenBook.name", flat = "item.minecraft.written_book" }, -- writtenbook
}

function item_l10n.CountKeys()
    local n = 0
    for _ in pairs(item_l10n.Keys) do n = n + 1 end
    return n
end

-- 把"字符串键"或"现成组件"统一成组件
local function AsPart(v)
    if type(v) == "table" then return v end
    if type(v) == "string" then return { translate = v } end
    return nil
end

-- 取客户端协议版本；拿不到时按旧版处理（旧客户端不支持扁平键）
function item_l10n.GetProtocolVersion(Player)
    if Player and Player.GetClientHandle then
        local ch = Player:GetClientHandle()
        if ch and ch.GetProtocolVersion then
            return ch:GetProtocolVersion()
        end
    end
    return 0
end

-- 单个物品的聊天组件
function item_l10n.ItemPart(Item, ProtocolVersion)
    local entry = item_l10n.Keys[Item.m_ItemType .. ":" .. Item.m_ItemDamage]
        or item_l10n.Keys[Item.m_ItemType .. ":0"]
    if not entry then
        return { text = ItemToString(Item) }   -- 兜底，绝不显示原始键
    end
    if (ProtocolVersion or 0) >= item_l10n.FLATTENED_MIN_PROTOCOL then
        return AsPart(entry.flat) or AsPart(entry.legacy)
    end
    return AsPart(entry.legacy) or AsPart(entry.flat)
end

-- 把片段数组发成一条聊天消息。
-- 片段可以是字符串（普通文本），或 { item = cItem }（走客户端翻译）。
function item_l10n.Send(Player, Parts)
    local proto = item_l10n.GetProtocolVersion(Player)
    local extra = {}
    for _, part in ipairs(Parts) do
        if type(part) == "table" and part.item then
            extra[#extra + 1] = item_l10n.ItemPart(part.item, proto)
        else
            extra[#extra + 1] = { text = tostring(part) }
        end
    end
    Player:SendMessageRaw(cJson:Serialize({ text = "", extra = extra }))
end

return item_l10n
