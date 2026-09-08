-- Implements the g_PluginInfo standard plugin description
-- 插件名必须与文件夹名（VillagerTrade）一致，否则 ReloadPlugin/UnloadPlugin 无法按文件夹定位。
g_PluginInfo =
{
	Name = "VillagerTrade",
	Version = "2.1",
	Date = "2026-09-08",
	Description = [[为 Cuberite 提供“近似原版”的村民交易：右键村民打开交易界面，
交易列表按村民唯一标识符（CustomName）持久化，包含职业、经验等级解锁与按世界时间刷新。]],

	Commands = { },          -- 暂无玩家命令
	ConsoleCommands = { },   -- 暂无控制台命令
	Permissions = { },       -- 暂无自定义权限
}
