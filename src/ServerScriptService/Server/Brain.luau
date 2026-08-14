--!strict
-- Bot brain v1 — the tactical layer.
--
-- Every decision tick a bot scores its available intents and commits to the
-- winner. Two design rules matter more than the numbers:
--
--  1. ATTRIBUTES ARE CAUSAL. Aggression moves Push. Game Sense moves Rotate.
--     Role templates bias the whole vector. This is why we author the brain
--     instead of cloning a neural policy from footage: a manager game needs
--     Aim 94 / Aggression 90 to visibly behave differently from Aim 63 /
--     Aggression 55, and needs a designer to be able to turn that dial.
--
--  2. BOTS TARGET ZONES, NOT COORDINATES. "Rotate to B Site" is a decision a
--     caster can narrate. Movement is ONE ZONE HOP per decision, so a bot
--     re-evaluates continuously rather than blindly finishing a long path.
--
-- Not here yet: Plant / Defuse / Retake / Save need a round state machine, and
-- shooting needs the duel model lifted out of the range spike. Bots currently
-- maneuver and observe without firing, which is deliberate — it makes the
-- decision log pure.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Zones = require(Shared.MapData.Zones)
local Scenario = require(Shared.Constants.Scenario)
local SimConfig = require(Shared.Constants.SimConfig)

local Pathing = require(script.Parent.Pathing)
local Perception = require(script.Parent.Perception)
local Telemetry = require(script.Parent.Telemetry)

local HYSTERESIS = 0.08 -- switching cost, stops intent flip-flop
local CANDIDATES = 6
local CLEARANCE_RADIUS = 2.6
local GROUND_TOLERANCE = 2.5
local ALLY_CROWD_STUDS = 25

-- Role templates. These are the ~40 numbers self-play tuning will eventually
-- optimise; hand-set for now so the behaviour is legible while we watch it.
local HOLD_ROLE: { [string]: number } =
	{ Anchor = 0.45, Sniper = 0.35, Support = 0.15, IGL = 0.10, Lurker = 0.05, Entry = 0.00 }
local PUSH_ROLE: { [string]: number } =
	{ Entry = 0.45, Support = 0.20, IGL = 0.15, Lurker = 0.10, Sniper = 0.05, Anchor = 0.00 }
local LURK_ROLE: { [string]: number } =
	{ Lurker = 0.50, Sniper = 0.15, Drift = 0.00, Entry = 0.00, Support = 0.05, IGL = 0.05, Anchor = 0.00 }

local SITES = { "A_SITE", "B_SITE" }
local DEF_HOLDS = { "A_SITE", "A_HEAVEN", "B_SITE", "B_HEAVEN", "MID_BACK" }
local ATK_FORWARD = { "MID", "MID_LEDGE", "A_LOBBY", "B_LOBBY", "A_ELBOW", "B_ELBOW" }
local DEF_FORWARD = { "MID", "MID_LEDGE", "MID_WINDOW", "A_SHORT", "B_SHORT" }
local FLANKS = { "A_MAIN", "B_MAIN", "A_ELBOW", "B_ELBOW" }

export type Intent = "Hold" | "Push" | "Rotate" | "Lurk"

local INTENTS: { Intent } = { "Hold", "Push", "Rotate", "Lurk" }

type Context = {
	side: string,
	role: string,
	zoneKey: string,
	aggression: number,
	gameSense: number,
	decisiveness: number,
	contact: Perception.Contact?,
	visible: boolean,
	allyZones: { string },
	alliesNear: number,
}

local Brain = {}

-- ---------------------------------------------------------------- geometry --

local function isStandable(point: Vector3, ignore: Model): boolean
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { ignore }

	local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), rayParams)
	if not hit then
		return false
	end
	if math.abs((hit.Position.Y + 0.5) - point.Y) > GROUND_TOLERANCE then
		return false
	end

	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = { ignore }
	local blockers = workspace:GetPartBoundsInRadius(hit.Position + Vector3.new(0, 2.5, 0), CLEARANCE_RADIUS, overlapParams)
	for _, part in blockers do
		if part.CanCollide then
			return false
		end
	end
	return true
end

local function standablePointIn(key: string, rng: Random, ignore: Model): Vector3?
	for _ = 1, CANDIDATES do
		local candidate = Zones.samplePoint(key, rng)
		if candidate and isStandable(candidate, ignore) then
			return candidate
		end
	end
	return Zones.center(key)
end

local function nearestOf(keys: { string }, from: string): string
	local best = keys[1]
	local bestHops = math.huge
	for _, key in keys do
		local hops = Zones.hops(from, key)
		if hops < bestHops then
			best = key
			bestHops = hops
		end
	end
	return best
end

-- ----------------------------------------------------------------- scoring --

local function scoreHold(ctx: Context): number
	local score = 0.30
	score += HOLD_ROLE[ctx.role] or 0.10
	score += if ctx.side == "Defense" then 0.22 else 0.00
	score -= ctx.aggression * 0.28
	score -= ctx.decisiveness * 0.35 -- the anti-stall ramp pushes bots off angles
	if ctx.contact == nil then
		score += 0.08 -- nothing to react to, so setting up is fine
	end
	if Zones.hasTag(ctx.zoneKey, "site") or Zones.hasTag(ctx.zoneKey, "heaven") then
		score += 0.12 -- already on a real anchor
	end
	return score
end

local function scorePush(ctx: Context): number
	local score = 0.22
	score += PUSH_ROLE[ctx.role] or 0.10
	score += ctx.aggression * 0.32
	score += if ctx.side == "Attack" then 0.20 else 0.00
	score += ctx.decisiveness * 0.40
	if ctx.visible then
		score += ctx.gameSense * 0.12 -- committing onto a known target
	end
	return score
end

local function scoreRotate(ctx: Context): number
	local contact = ctx.contact
	if not contact then
		return -1
	end
	local hops = Zones.hops(ctx.zoneKey, contact.zoneKey)
	if hops == 0 or hops == math.huge then
		return -1 -- already there, or unreachable
	end
	local score = 0.28
	score += ctx.gameSense * 0.35 -- reading the map is a Game Sense skill
	score += math.clamp(hops / 6, 0, 1) * 0.20
	if contact.source == "sound" then
		score -= 0.10 -- footsteps are softer evidence than a sighting
	end
	return score
end

local function scoreLurk(ctx: Context): number
	local score = 0.10
	score += LURK_ROLE[ctx.role] or 0.00
	score += (1 - ctx.aggression) * 0.18
	score -= ctx.decisiveness * 0.20
	if ctx.alliesNear >= 1 then
		score -= 0.12 -- lurking next to a teammate is not lurking
	end
	return score
end

local SCORERS: { [Intent]: (Context) -> number } = {
	Hold = scoreHold,
	Push = scorePush,
	Rotate = scoreRotate,
	Lurk = scoreLurk,
}

-- --------------------------------------------------------- target selection --

local function pickLurkZone(ctx: Context): string
	-- The flank furthest from where teammates already are
	local best = FLANKS[1]
	local bestDistance = -1
	for _, key in FLANKS do
		local nearestAlly = math.huge
		for _, allyZone in ctx.allyZones do
			local hops = Zones.hops(key, allyZone)
			if hops < nearestAlly then
				nearestAlly = hops
			end
		end
		if nearestAlly == math.huge then
			nearestAlly = 99
		end
		if nearestAlly > bestDistance then
			best = key
			bestDistance = nearestAlly
		end
	end
	return best
end

local function resolveTarget(intent: Intent, ctx: Context): string
	if intent == "Rotate" then
		local contact = ctx.contact
		return if contact then contact.zoneKey else ctx.zoneKey
	elseif intent == "Push" then
		if ctx.side == "Attack" then
			return nearestOf(SITES, ctx.zoneKey)
		end
		return nearestOf(DEF_FORWARD, ctx.zoneKey)
	elseif intent == "Lurk" then
		return pickLurkZone(ctx)
	end

	-- Hold
	if ctx.side == "Defense" then
		if table.find(DEF_HOLDS, ctx.zoneKey) then
			return ctx.zoneKey
		end
		return nearestOf(DEF_HOLDS, ctx.zoneKey)
	end
	if Zones.hasTag(ctx.zoneKey, "choke") or Zones.hasTag(ctx.zoneKey, "heaven") then
		return ctx.zoneKey
	end
	return nearestOf(ATK_FORWARD, ctx.zoneKey)
end

-- ------------------------------------------------------------------ logging --

local function formatScores(scores: { [Intent]: number }): string
	local parts = {}
	for _, intent in INTENTS do
		table.insert(parts, ("%s %.2f"):format(intent, scores[intent]))
	end
	return table.concat(parts, "  ")
end

local function describeContact(contact: Perception.Contact?, now: number): string
	if not contact then
		return "no contact"
	end
	return ("%s in %s (%s, %.1fs ago)"):format(
		contact.name,
		contact.zoneCallout,
		contact.source,
		now - contact.seenAt
	)
end

local function calloutOf(key: string): string
	local zone = Zones.byKey[key]
	return if zone then zone.callout else key
end

-- -------------------------------------------------------------------- brain --

function Brain.start(bot: any, side: string, enemies: { any }, allies: { any }, rng: Random, clock: () -> number)
	local model = bot.model :: Model
	local attrs = bot.attributes

	local perception = Perception.new()
	Perception.startLoop(perception, bot, enemies, clock)

	local intent: Intent = if side == "Defense" then "Hold" else "Push"
	local lastProgressAt = clock()

	Telemetry.setIntent(bot.name, intent)

	task.spawn(function()
		-- Stagger so ten brains do not all raycast on the same frame
		task.wait(rng:NextNumber(0, SimConfig.DecisionTickSeconds * 4))

		while model.Parent do
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health <= 0 then
				break
			end

			local now = clock()
			local ground = Zones.groundOf(model)
			local zone = Zones.at(ground)
			local currentKey = if zone then zone.key else Zones.VOID

			if currentKey == Zones.VOID then
				-- Off the labelled map: either a zone bound is wrong or the bot is
				-- somewhere it should not be. Worth shouting about.
				warn(("[CLUTCH] %s is outside every zone at %.0f, %.0f, %.0f"):format(
					bot.name,
					ground.X,
					ground.Y,
					ground.Z
				))
			end

			-- Ally positions, for crowding and lurk spacing
			local allyZones: { string } = {}
			local alliesNear = 0
			for _, ally in allies do
				if ally.name == bot.name then
					continue
				end
				local allyModel = ally.model :: Model
				if not allyModel.Parent then
					continue
				end
				local allyGround = Zones.groundOf(allyModel)
				table.insert(allyZones, Zones.keyAt(allyGround))
				if (allyGround - ground).Magnitude <= ALLY_CROWD_STUDS then
					alliesNear += 1
				end
			end

			-- Decisiveness ramp. With no round clock yet, it grows on time since
			-- the bot last made progress or last knew anything — boring standoffs
			-- are the silent killer of a spectator game.
			local reference = math.max(lastProgressAt, perception.lastContactAt)
			local decisiveness = math.clamp((now - reference) / Scenario.StallRampSeconds, 0, 1)

			local contact = Perception.bestContact(perception, now)
			local ctx: Context = {
				side = side,
				role = bot.role,
				zoneKey = currentKey,
				aggression = attrs.Aggression / 100,
				gameSense = attrs.GameSense / 100,
				decisiveness = decisiveness,
				contact = contact,
				visible = Perception.anyVisible(perception),
				allyZones = allyZones,
				alliesNear = alliesNear,
			}

			local scores: { [Intent]: number } = {}
			local bestIntent: Intent = intent
			local bestScore = -math.huge
			for _, candidate in INTENTS do
				local score = SCORERS[candidate](ctx)
				scores[candidate] = score
				if score > bestScore then
					bestIntent = candidate
					bestScore = score
				end
			end

			-- Switching costs something, or bots dither on the boundary
			local previous = intent
			if bestIntent ~= intent and bestScore < scores[intent] + HYSTERESIS then
				bestIntent = intent
			end

			local targetKey = resolveTarget(bestIntent, ctx)
			local hopKey = Zones.nextHop(currentKey, targetKey) or targetKey

			if bestIntent ~= previous then
				intent = bestIntent
				Telemetry.setIntent(bot.name, intent)
				if Scenario.VerboseBrain then
					print(("[CLUTCH] %6.1fs  THINK %s (%s) %s -> %s | %s | target %s via %s | %s | ramp %.2f"):format(
						now,
						bot.name,
						if side == "Attack" then "ATK" else "DEF",
						previous,
						intent,
						formatScores(scores),
						calloutOf(targetKey),
						calloutOf(hopKey),
						describeContact(contact, now),
						decisiveness
					))
				end
			end

			if currentKey == targetKey then
				-- Already where we want to be. Reposition inside the zone rather
				-- than standing in one spot like a lamp post.
				local spot = standablePointIn(currentKey, rng, model)
				if spot then
					Pathing.walkTo(model, spot)
				end
				task.wait(rng:NextNumber(1.5, 3.5))
			else
				local spot = standablePointIn(hopKey, rng, model)
				if spot and Pathing.walkTo(model, spot) then
					lastProgressAt = clock()
				else
					-- Hop refused. Wait a tick so a blocked bot does not spin.
					task.wait(SimConfig.DecisionTickSeconds * 2)
				end
			end

			task.wait(SimConfig.DecisionTickSeconds)
		end

		perception.running = false
	end)
end

return Brain
