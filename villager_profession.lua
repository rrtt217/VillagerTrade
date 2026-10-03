-- villager_profession.lua
-- 读取引擎内部的村民真实职业（cVillager::m_Type，private，未经 Lua 绑定导出）。
--
-- 原理（推导、证据与 NBT 交叉验证见 docs/villager-profession-research.md）：
--   * cVillager : cPassiveMonster : cMonster : cPawn : cEntity，cVillager 自己的成员
--     紧跟在 cMonster 子对象之后。
--   * cVillager 没有注册进 tolua（直接 cast 到 "cVillager" = 整服 SIGSEGV，绝不允许）。
--     借用已注册类型做"指针重解释"：
--       tolua.cast(Ent, "cPlayer"):GetInventory()  —— cPawn 的非虚方法，返回真实成员
--       cPawn::m_Inventory（包装器是引用推送：无拷贝、无 GC 关联）
--     再用 cCuboid.p2（self+12 的引用推送）纯地址算术步进，读 Vector3<int> 的 .x/.y/.z。
--   * 两套已实测的布局（同一函数，偏移随 ABI 变；用 npm/objdump 从两个二进制反汇编得到）：
--       LP64  (x86-64 / aarch64): 锚点 0x2F0，25 步 → +0x41C，countdown=.y(+4) 职业=.z(+8) farmer=.next.x(+12)
--       ILP32 (armv6l / i386):    锚点 0x240，26 步 → +0x378，countdown=.x(+0) 职业=.y(+4) farmer=.z(+8)
--     两套布局均已在真实服务器上端到端验证：LP64（本机 x86-64）与 ILP32（raspi armv6l），
--     各自与引擎写入区块 NBT 的 Profession 值逐一比对全部一致；详见 docs/。
--   * 运行期自校准：两套布局都试读，用 0..5 / 0..2 / >=-1 的三字段联合自检筛掉明显不可能的，
--     再用"跨村民取值多样性"判定真正的那一套（错误布局通常读到恒定 0，多样性恒为 1）。
--     确认前一律返回 nil（fail-closed），确认后每次读取仍做自检，失败即永久禁用。
--   * 只读；指针只活在单次调用内；绝不调用 cast 后类型的其它方法。

villager_profession = {}
local S = villager_profession

S.PROFESSION_NAMES = { "vtFarmer", "vtLibrarian", "vtPriest", "vtBlacksmith", "vtButcher", "vtGeneric" }

-- 布局表：偏移单位是字节；步长恒为 12（Vector3<int> = 3×int32，与指针宽度无关）
local LAYOUTS = {
    { name = "lp64",  steps = 25, countdown = 4, profession = 8, farmer_action = 12 },
    { name = "ilp32", steps = 26, countdown = 0, profession = 4, farmer_action = 8 },
}
local CONFIRM_SAMPLES = 3     -- 多样本确认门槛
local CONFIRM_DISTINCT = 2    -- 至少见过 2 种不同职业

local CHECKED = false
local USABLE  = false
local REASON  = nil
local LOCKED  = nil           -- 确认后的布局
local ELIMINATED = {}         -- [layout] = 淘汰理由
local SAMPLES = {}            -- [layout] = { count = n, mask = 职业位图 }

local function CheckRegistry()
    local dbg = rawget(_G, "debug")
    if (dbg == nil) or (dbg.getregistry == nil) then
        return false, "debug 库不可用，无法确认类型注册"
    end
    local Reg = dbg.getregistry()
    if (Reg == nil) then
        return false, "无 Lua 注册表"
    end
    -- 只检查我们真正要 cast 的目标类型（cast 到未注册类型 = SIGSEGV）
    for _, Name in ipairs({ "cPlayer", "cCuboid" }) do
        if (Reg[Name] == nil) then
            return false, "tolua 类型未注册: " .. Name
        end
    end
    if (type(mtVillager) ~= "number") then
        return false, "缺少 mtVillager 常量"
    end
    return true
end

-- 纯地址算术：把任意 tolua 指针推进 n 步（每步 12 字节）。getter 只算 self+off，
-- 不解引用——中间步完全安全；唯一的读发生在对 Vector3<int> 访问器的调用上。
local function Advance(P, n)
    for _ = 1, n do
        P = tolua.cast(P, "cCuboid").p2
    end
    return P
end

local COMPONENTS = { "x", "y", "z" }

-- 在一套布局下读三字段；Anchor 为 cInventory userdata
local function ReadLayout(Anchor, Layout)
    local P = Advance(Anchor, Layout.steps)                 -- 落点（12 字节窗口）
    local Next = nil
    local function IntAt(Off)
        if (Off < 12) then
            return P[COMPONENTS[Off / 4 + 1]]
        end
        Next = Next or tolua.cast(P, "cCuboid").p2          -- +12
        return Next.x
    end
    return IntAt(Layout.profession), IntAt(Layout.farmer_action), IntAt(Layout.countdown)
end

local function Plausible(Prof, FarmerAction, Countdown)
    return (Prof ~= nil) and (Prof >= 0) and (Prof <= 5)
        and (FarmerAction >= 0) and (FarmerAction <= 2)
        and (Countdown >= -1) and (Countdown <= 1000000)
end

local function Disable(Why)
    if USABLE then
        LOG("[villager_profession] 已禁用真实职业读取: " .. tostring(Why))
    end
    USABLE = false
    REASON = tostring(Why)
end

-- ============================================================================
-- 写入路径
-- ============================================================================
-- 借用类表上的原始 setter 闭包：registry["Vector3<int>"][".set"].x/y/z(self, value)。
-- 这些是从 .set 表里直接取出的未包装 C 闭包，参数就是 (self, value)，栈是平的。
-- 绝对不要用 P.z = v 这种成员赋值：它走 __newindex，实测会破坏 Lua 栈平衡，
-- 引擎随即 "Unable to re-balance Lua stack" + SIGABRT 整服退出。
local SETTERS = nil          -- nil=未检查 / false=不可用 / table=可用
local WRITE_REASON = nil

local function CheckSetters()
    if (SETTERS ~= nil) then
        return (WRITE_REASON == nil), WRITE_REASON
    end
    local dbg = rawget(_G, "debug")
    local Reg = ((dbg ~= nil) and (dbg.getregistry ~= nil)) and dbg.getregistry() or nil
    local V3 = (Reg ~= nil) and Reg["Vector3<int>"] or nil
    local Set = (type(V3) == "table") and V3[".set"] or nil
    if (type(Set) ~= "table") or (type(Set.x) ~= "function")
        or (type(Set.y) ~= "function") or (type(Set.z) ~= "function") then
        SETTERS = false
        WRITE_REASON = "Vector3<int> 的原始 setter 不可用"
        return false, WRITE_REASON
    end
    SETTERS = Set
    WRITE_REASON = nil
    return true
end

local function DisableWrite(Why)
    if (WRITE_REASON == nil) then
        LOG("[villager_profession] 已禁用真实职业写入: " .. tostring(Why))
    end
    SETTERS = false
    WRITE_REASON = tostring(Why)
end

function S.IsAvailable()
    if not CHECKED then
        local Ok, Why = CheckRegistry()
        CHECKED, USABLE, REASON = true, Ok, Why
        if not USABLE then
            LOG("[villager_profession] 不可用: " .. tostring(Why))
        end
    end
    return USABLE
end

function S.UnavailableReason()
    S.IsAvailable()
    return REASON
end

-- 确认后的布局名（未确认返回 nil），以及各候选的自校准状态（诊断用）
function S.GetStatus()
    local Candidates = {}
    for _, Layout in ipairs(LAYOUTS) do
        local Sample = SAMPLES[Layout.name]
        Candidates[Layout.name] = {
            eliminated = ELIMINATED[Layout.name],
            samples = Sample and Sample.count or 0,
        }
    end
    return {
        available = USABLE,
        reason = REASON,
        layout = LOCKED and LOCKED.name or nil,
        can_write = (type(SETTERS) == "table") and (WRITE_REASON == nil),
        write_reason = WRITE_REASON,
        candidates = Candidates,
    }
end

-- 临时/运维用途的显式指定（跳过自校准）；传 "lp64"/"ilp32"
function S.UseLayout(Name)
    for _, Layout in ipairs(LAYOUTS) do
        if (Layout.name == Name) then
            if not S.IsAvailable() then
                return false
            end
            LOCKED = Layout
            LOG("[villager_profession] 已显式指定布局: " .. Name)
            return true
        end
    end
    return false
end

-- 重置自校准状态（测试用）
function S.Reset()
    LOCKED = nil
    ELIMINATED = {}
    SAMPLES = {}
end

-- 在实体存活的回调内（钩子 / DoWithEntityByID / ForEachEntity）同步调用。
-- 返回职业编号 0..5 与元数据表 { countdown, farmerAction }；未确认/失败返回 nil。
function S.ReadProfession(Ent)
    if not S.IsAvailable() then
        return nil
    end
    if (type(Ent) ~= "userdata") then
        return nil
    end
    local Ok, Result, Meta = pcall(function()
        -- 正规途径确认是村民（cVillager 本来就是 cMonster 的合法向上转型）
        if (tolua.cast(Ent, "cMonster")):GetMobType() ~= mtVillager then
            return nil
        end
        -- 锚点：真实的 cPawn::m_Inventory 成员（引用推送；不要用 cast 后对象的其它方法！）
        local Anchor = tolua.cast(Ent, "cPlayer"):GetInventory()

        if (LOCKED ~= nil) then
            local Prof, FarmerAction, Countdown = ReadLayout(Anchor, LOCKED)
            if not Plausible(Prof, FarmerAction, Countdown) then
                Disable(("布局 %s 读取越界(职业=%s farmer=%s countdown=%s)，二进制布局可能已变"):format(
                    LOCKED.name, tostring(Prof), tostring(FarmerAction), tostring(Countdown)))
                return nil
            end
            return Prof, { countdown = Countdown, farmerAction = FarmerAction }
        end

        -- 未确认：试读全部候选，收集样本
        local Alive = 0
        for _, Layout in ipairs(LAYOUTS) do
            if (ELIMINATED[Layout.name] == nil) then
                local Prof, FarmerAction, Countdown = ReadLayout(Anchor, Layout)
                if Plausible(Prof, FarmerAction, Countdown) then
                    Alive = Alive + 1
                    local Sample = SAMPLES[Layout.name]
                    if (Sample == nil) then
                        Sample = { count = 0, seen = {} }
                        SAMPLES[Layout.name] = Sample
                    end
                    Sample.count = Sample.count + 1
                    Sample.seen[Prof] = true
                else
                    ELIMINATED[Layout.name] = ("自检失败(职业=%s farmer=%s countdown=%s)"):format(
                        tostring(Prof), tostring(FarmerAction), tostring(Countdown))
                    LOG("[villager_profession] 布局候选 " .. Layout.name .. " 淘汰: " .. ELIMINATED[Layout.name])
                end
            end
        end

        if (Alive == 0) then
            Disable("所有布局候选都未通过自检")
            return nil
        end

        for _, Layout in ipairs(LAYOUTS) do
            local Sample = SAMPLES[Layout.name]
            if (Sample ~= nil) and (ELIMINATED[Layout.name] == nil) then
                -- 取值多样性：见过多少种不同的职业编号（Lua 5.1 无位运算）
                local Distinct = 0
                for Value = 0, 5 do
                    if Sample.seen[Value] then
                        Distinct = Distinct + 1
                    end
                end
                -- 规则 A：至少 3 个样本且见过 2 种以上职业；
                -- 规则 B：其它候选都已被淘汰（结构上只剩一个），2 个样本即可
                if ((Sample.count >= CONFIRM_SAMPLES) and (Distinct >= CONFIRM_DISTINCT))
                    or ((Alive == 1) and (Sample.count >= 2)) then
                    LOCKED = Layout
                    LOG(("[villager_profession] 自校准完成：布局 %s（样本 %d，职业种类 %d）"):format(
                        Layout.name, Sample.count, Distinct))
                    local Prof, FarmerAction, Countdown = ReadLayout(Anchor, LOCKED)
                    if not Plausible(Prof, FarmerAction, Countdown) then
                        Disable("确认后的首次读取越界")
                        return nil
                    end
                    return Prof, { countdown = Countdown, farmerAction = FarmerAction }
                end
            end
        end
        return nil   -- 校准中：fail-closed
    end)
    if not Ok then
        Disable("读取异常: " .. tostring(Result))
        return nil
    end
    return Result, Meta
end

-- 写入器是否可用（Vector3<int> 的原始 setter 是否可获取）
function S.CanWrite()
    if not S.IsAvailable() then
        return false, REASON
    end
    return CheckSetters()
end

function S.WriteReason()
    return WRITE_REASON
end

-- 把引擎内部职业字段写成 Prof（0..5）。需要已校准布局；写入后立刻回读校验。
-- 只做 4 字节对齐写（原始 setter）；失败即永久禁用写入（读取不受影响）。
function S.WriteProfession(Ent, Prof)
    if not S.IsAvailable() then
        return false, REASON
    end
    if (LOCKED == nil) then
        return false, "布局尚未校准（先读几只村民）"
    end
    if (type(Ent) ~= "userdata") or (type(Prof) ~= "number") then
        return false, "参数类型错误"
    end
    if (Prof ~= math.floor(Prof)) or (Prof < 0) or (Prof > 5) then
        return false, "职业编号必须在 0..5"
    end
    local Ok, Why = CheckSetters()
    if not Ok then
        return false, Why
    end
    local Field = COMPONENTS[LOCKED.profession / 4 + 1]
    local Setter = SETTERS[Field]
    local CallOk, Result = pcall(function()
        if (tolua.cast(Ent, "cMonster")):GetMobType() ~= mtVillager then
            return false
        end
        local P = Advance(tolua.cast(Ent, "cPlayer"):GetInventory(), LOCKED.steps)
        Setter(P, Prof)                                              -- 4 字节对齐写
        local Verify = Advance(tolua.cast(Ent, "cPlayer"):GetInventory(), LOCKED.steps)[Field]
        if (Verify ~= Prof) then
            error(("回读不一致：写入 %d，读回 %s"):format(Prof, tostring(Verify)))
        end
        return true
    end)
    if not CallOk then
        DisableWrite(tostring(Result))
        return false, tostring(Result)
    end
    if (Result ~= true) then
        return false, "目标不是村民"
    end
    return true
end

-- 便捷：返回职业名（"vtFarmer"…）或 nil
function S.GetProfessionName(Ent)
    local Prof = S.ReadProfession(Ent)
    if Prof == nil then
        return nil
    end
    return S.PROFESSION_NAMES[Prof + 1]
end
