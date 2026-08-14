--!strict
-- Patrol orders: bots pick random POIs and walk between them, forever.
-- This is not the bot brain — it's the map's navmesh stress test and a
-- stand-in for 'idle movement' until the intent scorer lands.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Greybox = require(Shared.MapData.Greybox)

local Pathing = require(script.Parent.Pathing)

local Patrol = {}

function Patrol.start(bot: any, rng: Random)
	task.spawn(function()
		local humanoid = bot.model:FindFirstChildOfClass("Humanoid")
		while bot.model.Parent and humanoid and humanoid.Health > 0 do
			local pois = Greybox.pois
			local poi = pois[rng:NextInteger(1, #pois)]
			Pathing.walkTo(bot.model, poi.pos)
			if humanoid.Health <= 0 then
				break
			end
			task.wait(rng:NextNumber(1, 3.5)) -- linger: reads as "holding" a spot
		end
	end)
end

return Patrol
