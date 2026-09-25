-- Implements the g_PluginInfo standard plugin description
-- 插件名必须与文件夹名（VillagerTrade）一致，否则 ReloadPlugin/UnloadPlugin 无法按文件夹定位。
g_PluginInfo =
{
	Name = "VillagerTrade",
	Version = "2.5",
	Date = "2026-09-25",
	Description = [[为 Cuberite 提供“近似原版”的村民交易：右键村民打开交易界面，
交易列表按村民唯一标识符（CustomName）持久化，包含职业、经验等级解锁与按世界时间刷新。

另含两组默认关闭的实验性村庄生态特性：
① 新村庄自动生成村民（持久化“每区块只扫一次”）；
② 村庄铁傀儡守卫（按 1.12 思路生成守卫，并以最小模拟伤害注入目标，让引擎自带的战斗 AI 自行作战）。]],

	Commands = { },          -- 暂无玩家命令
	-- 下面两条由 Initialize 里手动 BindConsoleCommand 注册；这里仅作说明用途
	ConsoleCommands =
	{
		["villagelife"] = { HelpString = "显示村庄生态状态（villagelife flush | villagelife scan <cx> <cz>）" },
		["golemguard"]  = { HelpString = "显示铁傀儡守卫状态" },
	},
	Permissions = { },       -- 暂无自定义权限
}
