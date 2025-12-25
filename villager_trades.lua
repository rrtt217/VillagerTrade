-- Sample villager trades for testing
-- 格式说明：返回一个表，键为职业或"default"，值为交易数组。
-- 每个交易包含：buy（支付物品列表），sell（获得物品列表）。
-- 物品使用简单表 { id = <itemid>, count = <数量> }

local trades = {
    default = {
        -- 测试交易：支付 10x 石头(id=1) 换取 1x 苹果(id=260)
        { buy = { { id = 1, count = 10 } }, sell = { { id = 260, count = 1 } } },
        -- 测试交易：支付 1x 铁锭(id=296) 换取 16x 牛排(id=364)
        { buy = { { id = 296, count = 1 } }, sell = { { id = 364, count = 16 } } },
    },
    farmer = {
        { buy = { { id = 295, count = 5 } }, sell = { { id = 297, count = 1 } } },
    },
}

return trades
