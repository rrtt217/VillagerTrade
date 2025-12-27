local player_trade_xp_parser = {}
function player_trade_xp_parser.LoadPlayerTradeExperience()
    local path = PLUGIN:GetLocalFolder() .. "/player_trade_experience.txt"
    local file = io.open(path, "r")
    if file then
        local xpTable = {}
        for line in file:lines() do
            -- 跳过注释行
            if not line:match("^%s*#") then
                -- 去除行内注释
                line = line:gsub("%s*#.*$", "")
                line = line:gsub("%s+$", "")  -- 去除尾部空格
                if line ~= "" then
                    -- 匹配格式: UUID = vtFarmerXp | vtLibrarianXp | vtPriestXp | vtBlacksmithXp | vtButcherXp | vtGenericXp
                    local uuid, f, l, p, b, u, g = line:match("^(%S+)%s*=%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)%s*|%s*(%d+)$")
                    if uuid then
                        xpTable[uuid] = {
                            tonumber(f),
                            tonumber(l),
                            tonumber(p),
                            tonumber(b),
                            tonumber(u),
                            tonumber(g)
                        }
                    end
                end
            end
        end
        file:close()
        LOG("Player trade experience data loaded from " .. path)
        return xpTable
    end
end
return player_trade_xp_parser