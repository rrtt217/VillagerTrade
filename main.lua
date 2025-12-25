PLUGIN = nil

function Initialize(Plugin)
	Plugin:SetName("Trade")
	Plugin:SetVersion(1)

	-- Hooks

	PLUGIN = Plugin -- NOTE: only needed if you want OnDisable() to use GetName() or something like that

	-- Command Bindings

	LOG("Initialised version " .. Plugin:GetVersion())
	cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_RIGHT_CLICKING_ENTITY, TradeOnRightClickingVillager)
	return true
end

function OnDisable()
	LOG("Shutting down...")
end