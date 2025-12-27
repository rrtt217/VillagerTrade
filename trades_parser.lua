-- trades_parser.lua
local trades_parser = {}

local function trim(s)
    return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- 分割字符串，忽略引号内的等号
local function splitIgnoringQuotes(line)
    local inQuotes = false
    local escape = false
    for i = 1, #line do
        local ch = line:sub(i, i)
        if ch == '\\' and not escape then
            escape = true
        elseif ch == '"' and not escape then
            inQuotes = not inQuotes
        elseif ch == '=' and not inQuotes then
            local left = line:sub(1, i - 1)
            local right = line:sub(i + 1)
            return left, right
        else
            escape = false
        end
    end
    return line, nil
end

local function parseRange(s)
    if not s then return nil, nil end
    local a, b = s:match("%(%s*(%d+)%s*,%s*(%d+)%s*%)")
    if a and b then return tonumber(a), tonumber(b) end
    return nil, nil
end

local function parseItemSpec(spec)
    local item = trim(spec)
    local enchantments = nil
    local damage = nil

    -- 使用 '-' 作为附魔字符串的分隔符，附魔字符串应用双引号括起来
    local before, after = item:match("^(.-)-(.+)$")
    if before and after then
        item = trim(before)
        -- 去除附魔字符串前后的双引号
        after = trim(after)
        if after:match('^".*"$') then
            after = after:sub(2, -2)
        end
        enchantments = after
    end

    local base, d = item:match("^(.-)%^(%d+)$")
    if base and d then
        item = trim(base)
        damage = tonumber(d)
    end

    local name, id = item:match("^(%w+)%((%d+)%)$")
    if name and id then
        item = name
        damage = tonumber(id)
    end

    return {type = item, damage = damage, enchantments = enchantments}
end

function trades_parser.parseTradesFromFile(filename)
    local path = PLUGIN:GetLocalFolder() .. "/trades.txt"
    local file = io.open(path, "r")
    if not file then
        return nil, "Could not open " .. path
    end

    local Trades = {}

    for rawline in file:lines() do
        local line = trim(rawline)
        if line ~= "" and not line:match("^%s*#") then
            local left, right = splitIgnoringQuotes(line)
            if right then
                LOG("Left: " .. left)
                LOG("Right: " .. right)
                local entry = {inputs = {}, output = {}, weight = nil, unlockLevel = nil, profession = nil, tradeXp = nil}

                for inpart in left:gmatch("[^;]+") do
                    local ip = trim(inpart)
                    local itemSpec, range = ip:match("^(.-)%s*,%s*(%b())%s*$")
                    if not itemSpec then
                        itemSpec, range = ip:match("^(.-)%s*(%b())%s*$")
                    end
                    if not itemSpec then itemSpec = ip end
                    local item = parseItemSpec(itemSpec)
                    local minv, maxv = parseRange(range)
                    if not minv and not maxv then minv, maxv = 1, 1 end
                    table.insert(entry.inputs, {item = item, min = minv, max = maxv})
                end

                local outpart, rest = right:match("^([^|]*)|?(.*)$")
                LOG("Outpart:" .. outpart)
                LOG("Rest:" .. rest)
                outpart = trim(outpart)
                rest = rest or ""

                local itemSpec, range = outpart:match("^(.-)%s*,%s*(%b())%s*$")
                if not itemSpec then
                    itemSpec, range = outpart:match("^(.-)%s*(%b())%s*$")
                end
                if not itemSpec then itemSpec = outpart end
                local item = parseItemSpec(itemSpec)
                local minv, maxv = parseRange(range)
                if not minv and not maxv then minv, maxv = 1, 1 end
                entry.output.item = item
                entry.output.min = minv
                entry.output.max = maxv

                for token in rest:gmatch("[^|]+") do
                    local t = trim(token)
                    if t ~= "" then
                        if t:match("id=%d+") or t:match("ByXpLevels") then
                            entry.output.item.enchantments = t
                        elseif t:match("^vt%w+") then
                            entry.profession = t
                        else
                            local n = tonumber(t)
                            if n then
                                if not entry.weight then
                                    entry.weight = n
                                elseif not entry.unlockLevel and n >= 0 and n <= 3 then
                                    entry.unlockLevel = n
                                else
                                    entry.tradeXp = n
                                end
                            else
                                entry.misc = entry.misc or {}
                                table.insert(entry.misc, t)
                            end
                        end
                    end
                end

                table.insert(Trades, entry)
            end
        end
    end

    file:close()
    return Trades
end

return trades_parser
