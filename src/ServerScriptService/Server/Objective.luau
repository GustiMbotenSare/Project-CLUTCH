--!strict
-- Objective: the spike. Carry it, drop it, pick it up, plant it, defuse it,
-- or watch it take the site and everyone standing on it.
--
-- The spike is a real workspace part — a small red neon ball welded above the
-- carrier's head, dropped where the carrier died, planted where the planter
-- stood. Bots reason about its position through zones; spectators see an
-- actual object. No hidden state pretending to be a bomb.
--
-- THE COLORED AREA IS THE RULE (playtest #23): planting requires standing ON
-- the glowing pad — planar distance to a plant pad, not anywhere inside the
-- site region. Bots walk onto the pad first (the brain steps them there),
-- then the channel runs.
--
-- Channels (plant 4s, defuse 7s) cancel on death, on taking damage, on
-- SPOTTING AN ENEMY — and the channeler PLANTS ITS FEET (playtest #22): the
-- root anchors for the duration. With per-bot collision back on, teammates
-- brushing past were shoving the planter past the move tolerance and
-- breaking the channel (Volt's four cancelled plants in one round). The
-- anchor is the plant crouch you can't be shoved out of.
--
-- THE DEFUSE IS A SOLO JOB (playtest #16): one channel, ever. The brain's
-- scoring already names the single closest defender as the defuser and turns
-- everyone else into the guard ring; this lock is the belt-and-braces for
-- the tie-break case. Plants never needed it — there's only ever one
-- carrier.
--
-- THE DEFUSE IS LOUD (playtest #20): starting the channel stamps
-- MatchState.defusing — attackers within earshot get a sound contact at the
-- spike, exactly like the tap in the original game.
--
-- Pickup is a WALK-OVER (playtest #20): 5 studs, instant, like any real FPS
-- — no reach-around ritual.
--
-- THE FUSE CANNOT CANCEL ITSELF. explode() runs ON the fuse thread; a naive
-- cancelFuse() inside it throws "cannot cancel thread" and — because that was
-- the FIRST line of explode() — the whole function died before setting
-- exploded. Playtest #12: the spike planted at 23s, the fuse errored at 67s,
-- and the round soft-locked past 130s with the spike live forever.
--
-- PLANT FACING IS A HANDOFF (playtest #17): faceThreat used to write the
-- root's CFrame directly — the same physics-stomp that put every walk in the
-- match into BLOCKED. Now it hands the brain's facing loop a facePoint and
-- the planter turns THROUGH the channel via AimAlign.
--
-- PLANTS AND DEFUSES FEED MATCH MEMORY (batch C): the ledger learns which
-- site the attack actually wants, and the plan roller reads it next round.
--
-- Round-scoped intel dies with the round (playtest #19): reset() also wipes
-- the area-clear marks — last round's "clear" means nothing now.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Zones = require(Shared.MapData.Zones)
local Greybox = require(Shared.MapData.Greybox)
local RoundConfig = require(Shared.Constants.RoundConfig)

local MatchState = require(script.Parent.MatchState)
local MatchMemory = require(script.Parent.MatchMemory)

local Objective = {}

local PICKUP_RADIUS = 5 -- walk-over: step on it, it's yours (playtest #20)
local DEFUSE_RADIUS = 7
local CHANNEL_MOVE_TOLERANCE = 2.5
local EXPLOSION_RADIUS = 30
local EXPLOSION_DAMAGE = 500

local fuseThread: thread? = nil
local defusingBot: any = nil -- the defuse is a solo job; everyone else guards

local function planarDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function rootOf(model: Model): BasePart?
	return model:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- The glowing pad is the plantable ground (playtest #23). Returns the
-- nearest pad spec and the planar distance to its center — the brain walks
-- carriers onto the pad, and tryStartPlant enforces it.
function Objective.nearestPad(pos: Vector3): (any?, number)
	local best: any = nil
	local bestDist = math.huge
	for _, pad in Greybox.plantZones do
		local d = planarDistance(pos, pad.pos)
		if d < bestDist then
			best = pad
			bestDist = d
		end
	end
	return best, bestDist
end

-- Never cancel the thread you are running on — explode() is called BY the
-- fuse thread when the timer expires.
local function cancelFuse()
	if fuseThread and fuseThread ~= coroutine.running() then
		task.cancel(fuseThread)
	end
	fuseThread = nil
end

-- Round reset: no spike, no fuse, no planted state, no marks, no channel,
-- no defuse noise, and no area-clear intel — last round's "clear" means nothing now.
function Objective.reset()
	cancelFuse()
	if MatchState.spikePart then
		MatchState.spikePart:Destroy()
	end
	MatchState.spikePart = nil
	MatchState.spikeCarrier = nil
	MatchState.planted = false
	MatchState.plantedZoneKey = nil
	MatchState.plantedAt = 0
	MatchState.defused = false
	MatchState.exploded = false
	MatchState.spikeMarkAtk = nil
	MatchState.spikeMarkDef = nil
	MatchState.clearMarks = { Attack = {}, Defense = {} }
	MatchState.defusing = nil
	defusingBot = nil
end

local function makeSpike(): Part
	local spike = Instance.new("Part")
	spike.Name = "Spike"
	spike.Shape = Enum.PartType.Ball
	spike.Size = Vector3.new(1.4, 1.4, 1.4)
	spike.Material = Enum.Material.Neon
	spike.Color = Color3.fromRGB(255, 60, 60)
	spike.CanCollide = false
	spike.CanQuery = false
	spike.Massless = true
	return spike
end

-- Weld rides above the carrier's head — the duel's most readable prop.
function Objective.assignCarrier(bot: any)
	local root = rootOf(bot.model)
	if not root then
		return
	end
	local spike = makeSpike()
	spike.CFrame = root.CFrame * CFrame.new(0, 2.8, 0)
	spike.Parent = workspace
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = spike
	weld.Part1 = root
	weld.Parent = spike
	MatchState.spikePart = spike
	MatchState.spikeCarrier = bot
end

-- Carrier died (or planted handled elsewhere): leave the spike where it fell.
function Objective.dropSpike(bot: any)
	local spike = MatchState.spikePart
	if not spike or MatchState.spikeCarrier ~= bot then
		return
	end
	local weld = spike:FindFirstChildOfClass("WeldConstraint")
	if weld then
		weld:Destroy()
	end
	local ground = Zones.groundOf(bot.model)
	spike.Anchored = true
	spike.Position = Vector3.new(ground.X, ground.Y + 0.7, ground.Z)
	MatchState.spikeCarrier = nil
	print(("[CLUTCH] %s dropped the spike at %s"):format(
		bot.name,
		if Zones.byKey[Zones.keyAt(ground)] then Zones.byKey[Zones.keyAt(ground)].callout else "unknown ground"
	))
end

-- An attacker walking over a dropped spike picks it up. Instant — no button,
-- no channel, like every FPS with a dropped objective.
function Objective.tryPickup(bot: any): boolean
	local spike = MatchState.spikePart
	if not spike or MatchState.spikeCarrier ~= nil or MatchState.planted then
		return false
	end
	local root = rootOf(bot.model)
	if not root or planarDistance(root.Position, spike.Position) > PICKUP_RADIUS then
		return false
	end
	spike.Anchored = false
	spike.CFrame = root.CFrame * CFrame.new(0, 2.8, 0)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = spike
	weld.Part1 = root
	weld.Parent = spike
	MatchState.spikeCarrier = bot
	print(("[CLUTCH] %s recovered the spike"):format(bot.name))
	return true
end

-- The honest channel: alive, unhurt, not visibly engaged — and ANCHORED
-- (playtest #22): with per-bot collision on, a teammate brushing the
-- channeler was shoving it past the move tolerance and breaking plants.
-- The root anchors for the duration; the living get it back, the dead stay
-- put (the corpse ghost owns them).
local function channel(bot: any, seconds: number, label: string, clock: () -> number, shouldAbort: (() -> boolean)?): boolean
	local humanoid = bot.model:FindFirstChildOfClass("Humanoid")
	local root = rootOf(bot.model)
	if not humanoid or not root then
		return false
	end
	root.Anchored = true
	local startPos = root.Position
	local startHealth = humanoid.Health
	local startedAt = clock()
	local ok = false
	while true do
		if clock() - startedAt >= seconds then
			ok = true
			break
		end
		if humanoid.Health <= 0 or not bot.model.Parent then
			break
		end
		if humanoid.Health < startHealth - 0.01 then
			print(("[CLUTCH] %s %s cancelled — took damage"):format(bot.name, label))
			break
		end
		if (root.Position - startPos).Magnitude > CHANNEL_MOVE_TOLERANCE then
			print(("[CLUTCH] %s %s cancelled — moved off the spot"):format(bot.name, label))
			break
		end
		if shouldAbort and shouldAbort() then
			print(("[CLUTCH] %s %s cancelled — enemy in sight, fight first"):format(bot.name, label))
			break
		end
		task.wait(0.1)
	end
	if humanoid.Health > 0 and root.Parent then
		root.Anchored = false
	end
	return ok
end

local function explode(clock: () -> number)
	cancelFuse() -- safe from the fuse thread itself now (see header)
	MatchState.planted = false
	MatchState.exploded = true

	local spike = MatchState.spikePart
	local at = if spike then spike.Position else Vector3.zero

	local flash = Instance.new("Part")
	flash.Shape = Enum.PartType.Ball
	flash.Anchored = true
	flash.CanCollide = false
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 160, 60)
	flash.Size = Vector3.new(EXPLOSION_RADIUS, EXPLOSION_RADIUS, EXPLOSION_RADIUS)
	flash.Transparency = 0.35
	flash.CFrame = CFrame.new(at)
	flash.Parent = workspace
	Debris:AddItem(flash, 0.6)

	for _, model in workspace:GetChildren() do
		if model:IsA("Model") and model:GetAttribute("ClutchBot") == true then
			local root = rootOf(model)
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if root and humanoid and humanoid.Health > 0 and (root.Position - at).Magnitude <= EXPLOSION_RADIUS then
				model:SetAttribute("LastKilledBy", "THE SPIKE")
				model:SetAttribute("LastKillHeadshot", false)
				model:SetAttribute("LastKillDistance", math.floor((root.Position - at).Magnitude))
				model:SetAttribute("LastKillWeapon", "Spike")
				humanoid:TakeDamage(EXPLOSION_DAMAGE)
			end
		end
	end

	print(("[CLUTCH] %6.1fs  EXPLODED — the spike takes the site"):format(clock()))
end

-- Face the last known threat before crouching: hand the facing loop the
-- point and the planter turns THROUGH the channel via AimAlign. (Direct
-- CFrame writes on a possibly-walking root were playtest #17's BLOCKED.)
local function faceThreat(bot: any, threatPos: Vector3?)
	if not threatPos then
		return
	end
	bot.facePoint = threatPos
end

-- Carrier standing ON THE PAD commits to the full 4 seconds — unless an
-- enemy becomes visible, it takes damage, or it moves.
function Objective.tryStartPlant(bot: any, clock: () -> number, shouldAbort: (() -> boolean)?, threatPos: Vector3?): boolean
	if MatchState.phase ~= "Live" or MatchState.planted then
		return false
	end
	if MatchState.spikeCarrier ~= bot then
		return false
	end
	local ground = Zones.groundOf(bot.model)
	-- THE COLORED AREA IS THE RULE (playtest #23): on the glowing pad, not
	-- vaguely near the site. The brain steps the carrier onto it first.
	local pad, padDist = Objective.nearestPad(ground)
	if not pad or padDist > pad.size.X / 2 + 1.5 then
		return false
	end
	local zoneKey = Zones.keyAt(ground)

	faceThreat(bot, threatPos)

	local zone = Zones.byKey[zoneKey]
	print(("[CLUTCH] %6.1fs  PLANT %s is planting at %s…"):format(
		clock(),
		bot.name,
		if zone then zone.callout else zoneKey
	))

	if not channel(bot, RoundConfig.PlantSeconds, "plant", clock, shouldAbort) then
		return false
	end

	-- The spike stays where the planter stood
	local spike = MatchState.spikePart
	if spike then
		local weld = spike:FindFirstChildOfClass("WeldConstraint")
		if weld then
			weld:Destroy()
		end
		spike.Anchored = true
		spike.Position = Vector3.new(ground.X, ground.Y + 0.7, ground.Z)
	end
	MatchState.spikeCarrier = nil
	MatchState.planted = true
	MatchState.plantedZoneKey = zoneKey
	MatchState.plantedAt = clock()
	MatchState.phase = "Planted"
	MatchMemory.recordPlant(zoneKey) -- the ledger learns where they want to plant
	print(("[CLUTCH] %6.1fs  PLANTED at %s — %ds fuse"):format(
		clock(),
		if zone then zone.callout else zoneKey,
		RoundConfig.SpikeFuseSeconds
	))

	fuseThread = task.spawn(function()
		task.wait(RoundConfig.SpikeFuseSeconds)
		if MatchState.planted then
			explode(clock)
		end
	end)
	return true
end

-- Defender next to a planted spike commits to the full 7 seconds. SOLO JOB:
-- if a teammate is already on the channel, you are the guard ring instead.
-- THE TAP IS LOUD: the channel stamps MatchState.defusing for its duration —
-- attackers within earshot hear it (the brain turns it into a sound contact).
function Objective.tryStartDefuse(bot: any, clock: () -> number, shouldAbort: (() -> boolean)?): boolean
	if not MatchState.planted then
		return false
	end
	if defusingBot ~= nil and defusingBot ~= bot then
		return false -- one pair of hands on the spike; the rest watch the doors
	end
	local spike = MatchState.spikePart
	local root = rootOf(bot.model)
	if not spike or not root or planarDistance(root.Position, spike.Position) > DEFUSE_RADIUS then
		return false
	end
	local plantedZone = MatchState.plantedZoneKey -- captured before the state flips

	print(("[CLUTCH] %6.1fs  DEFUSE %s is defusing…"):format(clock(), bot.name))

	defusingBot = bot
	MatchState.defusing = { pos = spike.Position, at = clock() }
	local ok = channel(bot, RoundConfig.DefuseSeconds, "defuse", clock, shouldAbort)
	defusingBot = nil
	MatchState.defusing = nil
	if not ok then
		return false
	end
	if not MatchState.planted then
		return false -- it went off mid-channel
	end

	cancelFuse()
	MatchState.planted = false
	MatchState.defused = true
	if plantedZone then
		MatchMemory.recordDefuse(plantedZone)
	end
	print(("[CLUTCH] %6.1fs  DEFUSED — %s saves the site"):format(clock(), bot.name))
	return true
end

return Objective
