--!strict
-- Patrol orders: bots pick random POIs and walk between them, forever.
-- This is not the bot brain — it's the map's navmesh stress test and a
-- stand-in for 'idle movement' until the intent scorer lands.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Greybox = require(Shared.MapData.Greybox)

local Pathing = require(script.Parent.Pathing)

local Patrol = {}

local JITTER = 6 -- studs of spread around a POI
local ELEVATED_Y = 4 -- POIs above this count as a climb

function Patrol.start(bot: any, rng: Random)
	task.spawn(function()
		-- Stagger: ten bots computing paths on the same frame thrashes the navmesh
		task.wait(rng:NextNumber(0, 2.5))

		local humanoid = bot.model:FindFirstChildOfClass("Humanoid")
		while bot.model.Parent and humanoid and humanoid.Health > 0 do
			local pois = Greybox.pois
			local poi = pois[rng:NextInteger(1, #pois)]

			-- Jitter the destination so bots don't converge on one stud and
			-- body-block each other into a stall (playtest #2).
			local target = poi.pos
				+ Vector3.new(rng:NextNumber(-JITTER, JITTER), 0, rng:NextNumber(-JITTER, JITTER))

			local arrived = Pathing.walkTo(bot.model, target)

			-- Verticality check: prove ramps are walkable straight from Output
			if arrived and poi.pos.Y >= ELEVATED_Y then
				print(("[CLUTCH] CLIMB: %s reached %s"):format(bot.name, poi.name))
			end

			if humanoid.Health <= 0 then
				break
			end
			task.wait(rng:NextNumber(1, 3.5)) -- linger: reads as "holding" a spot
		end
	end)
end

return Patrol
