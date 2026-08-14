--!strict
-- Patrol orders: bots pick random POIs and walk between them, forever.
-- This is not the bot brain — it's the map's navmesh stress test and a
-- stand-in for 'idle movement' until the intent scorer lands.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Greybox = require(Shared.MapData.Greybox)

local Pathing = require(script.Parent.Pathing)

local Patrol = {}

local FLOOR_JITTER = 6 -- studs of spread around a ground-level POI
local DECK_JITTER = 2.5 -- decks are only 12x8; wide jitter walks off the lip
local ELEVATED_Y = 4 -- POIs above this count as a climb
local CANDIDATES = 6 -- jitter attempts before falling back to the raw POI
local CLEARANCE_RADIUS = 2.6 -- keep in step with Pathing's AgentRadius
local SAME_SURFACE_EPSILON = 0.5 -- tolerance for adjacent floor slabs
local PROBE_HEIGHT = 6
local PROBE_DEPTH = 14

-- Where does a bot standing here actually land, and on what?
local function probeGround(point: Vector3, ignore: { Instance }): RaycastResult?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	return workspace:Raycast(
		point + Vector3.new(0, PROBE_HEIGHT, 0),
		Vector3.new(0, -PROBE_DEPTH, 0),
		params
	)
end

-- Playtest #3: blind +-6 stud jitter pushed destinations off deck edges, onto
-- the Heaven rails, and inside the site crates and MidBox — all of which are
-- off-navmesh, so every one became PATH FAILED. Rather than hand-auditing 19
-- POIs against 50 parts, verify each candidate against the surface the
-- authored POI itself rests on.
local function isStandable(candidate: Vector3, anchor: RaycastResult, ignore: { Instance }): boolean
	local ground = probeGround(candidate, ignore)
	if not ground then
		return false -- floating past the lip of a platform
	end

	local sameSurface = ground.Instance == anchor.Instance
		or math.abs(ground.Position.Y - anchor.Position.Y) <= SAME_SURFACE_EPSILON
	if not sameSurface then
		return false -- a crate top, a rail, or the floor far below the deck
	end

	-- Catch thin geometry the downward probe slipped past (wall edges, rails)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local occupied = workspace:GetPartBoundsInRadius(
		Vector3.new(candidate.X, ground.Position.Y + 2.5, candidate.Z),
		CLEARANCE_RADIUS,
		params
	)
	for _, part in occupied do
		if part.CanCollide then
			return false
		end
	end

	return true
end

local function pickDestination(poi: any, rng: Random, ignore: { Instance }): Vector3
	local anchor = probeGround(poi.pos, ignore)
	if not anchor then
		return poi.pos -- POI is authored over open space; let Pathing complain
	end

	local jitter = if poi.pos.Y >= ELEVATED_Y then DECK_JITTER else FLOOR_JITTER
	for _ = 1, CANDIDATES do
		local candidate = poi.pos
			+ Vector3.new(rng:NextNumber(-jitter, jitter), 0, rng:NextNumber(-jitter, jitter))
		if isStandable(candidate, anchor, ignore) then
			return candidate
		end
	end

	return poi.pos -- authored POIs are known good; the jitter is the risky part
end

function Patrol.start(bot: any, rng: Random)
	task.spawn(function()
		-- Stagger: ten bots computing paths on the same frame thrashes the navmesh
		task.wait(rng:NextNumber(0, 2.5))

		local humanoid = bot.model:FindFirstChildOfClass("Humanoid")
		while bot.model.Parent and humanoid and humanoid.Health > 0 do
			local pois = Greybox.pois
			local poi = pois[rng:NextInteger(1, #pois)]

			local target = pickDestination(poi, rng, { bot.model })
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
