-- Implements the g_PluginInfo standard plugin description
-- 插件名必须与文件夹名（VillagerTrade）一致，否则 ReloadPlugin/UnloadPlugin 无法按文件夹定位。
g_PluginInfo =
{
	Name = "VillagerTrade",
	Version = "2.6",
	Date = "2026-09-25",
	Description = [[为 Cuberite 提供“近似原版”的村民交易：右键村民打开交易界面，
交易列表按村民唯一标识符（CustomName）持久化，包含职业、经验等级解锁与按世界时间刷新。

另含默认关闭的实验性铁傀儡特性：
① 守卫：让已存在的铁傀儡攻击附近的敌对怪（以最小模拟伤害注入目标，追击/攻击交给引擎 AI）；
② 村庄生成：周期性复查含门村庄区块，在“门数、村民数达标且傀儡数未达上限”时才生成守卫
（扫描区块时不会立即生成）。]],

	Commands = { },          -- 暂无玩家命令
	-- 下面两条由 Initialize 里手动 BindConsoleCommand 注册；这里仅作说明用途
	ConsoleCommands =
	{
		["villagelife"] = { HelpString = "显示村庄区块扫描状态（villagelife flush | villagelife scan <cx> <cz>）" },
		["golemguard"]  = { HelpString = "显示铁傀儡守卫状态" },
	},
	Permissions = { },       -- 暂无自定义权限
}
