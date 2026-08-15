--!strict
-- Bot brain v4.0: score every intent, commit to the winner, act on it — and
-- now bots TALK.
--
-- Playtest #13 additions:
--   * TEAM CALLOUTS. A fresh sighting (or taking fire with a known suspect)
--     is radio'd to living teammates after the human callout delay. Teammates
--     receive it as a SOUND-class contact — a zone and a rough position, not
--     wallhacks (injected contacts never count as "visible", so they can't
--     trigger shots). This is the awareness depth the user asked for, and the
--     seed of the comms feed the caster will narrate.
--   * COVER CLAIMS. The first bot to hold an angle claims it; teammates pick
--     a different point. Two anchors stacking the same crate was playtest
--     #13's doorway traffic jam.
--   * APPROACH PEEKS. Pushing/rotating toward a fresh contact within 2 hops,
--     a bot first snaps to the current zone's cover facing the threat for one
--     peek cycle — the "take cover and check the angle before walking in"
--     behavior the site approaches were missing. Cooldown-gated so it can't
--     stall a rotation forever.
--
-- Still carrying: FallBack fight-or-flight, safe routing, carrier discipline,
-- spike recovery, phase-interrupted walks, corridor sampling, stall
-- diagnostics, bots-never-veto-ground, the interrupt-storm threshold, and
-- ground-only validation for authored cover points. (History in the git log.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local SimConfig = require(Shared.Constants.SimConfig)
local Scenario = require(Shared.Constants.Scenario)
local Zones = require(Shared.MapData.Zones)
local Greybox = require(Shared.MapData.Greybox)

local Pathing = require(script.Parent.Pathing)
local Perception = require(script.Parent.Perception)
local Combat = require(script.Parent.Combat)
local Telemetry = require(script.Parent.Telemetry)
local Objective = require(script.Parent.Objective)
local MatchState = require(script.Parent.MatchState)

local Brain = {}

-- Every living brain's perception, keyed by name. Callouts write into these;
-- brains read their own. Cleared by model teardown, refilled by Brain.start.
Brain.perceptions = {} :: { [string]: any }

local HYSTERESIS = 0.08 -- how much better a rival intent must be to win
local CANDIDATES = 6 -- standable-point attempts per destination
local CLEARANCE_RADIUS = 2.6
local GROUND_TOLERANCE = 2.5
local ALLY_CROWD_STUDS = 25
local DIRECT_WALK_MAX_HOPS = 6
local INTERRUPT_RECHECK = 0.3 -- seconds between interrupt polls mid-walk
local FRESH_CONTACT_SECONDS = 6 -- contact newer than this means quiet feet
local MAX_PEEKS = 3 -- jiggle-peeks per cover hold before re-deciding
local ENEMY_NEAR_HOPS = 2 -- "in my area" for the fallback math
local INTERRUPT_COMBAT_RANGE = 30 -- a glimpse farther than this never aborts a walk
local STALL_LOG_SECONDS = 8 -- zone unchanged with a live target this long = report
local CALLOUT_COOLDOWN = 4 -- seconds between one bot re-calling the same enemy
local APPROACH_PEEK_COOLDOWN = 6 -- seconds between pre-push cover checks
local APPROACH_PEEK_HOPS = 2 -- only peek when the contact is this close

-- Role priors. A role biases a decision, never decides it outright.
local HOLD_ROLE = { Anchor = 0.30, Sniper = 0.23, Support = 0.10, IGL = 0.07, Lurker = 0.03, Entry = 0.00 }
local PUSH_ROLE = { Entry = 0.25, Support = 0.11, IGL = 0.08, Lurker = 0.06, Sniper = 0.03, Anchor = 0.00 }
local LURK_ROLE = { Lurker = 0.30, Sniper = 0.09, Support = 0.03, IGL = 0.03, Entry = 0.00, Anchor = 0.00 }
local FALLBACK_ROLE = { Anchor = 0.15, Sniper = 0.10, IGL = 0.05, Support = 0.00, Lurker = -0.05, Entry = -0.20 }

local SITES = { "A_SITE", "B_SITE" }

-- MID_BACK deliberately absent. Including it made a corridor an acceptable
-- anchor, which is how a defender ended up holding nothing for 84 seconds.
local DEF_HOLDS = { "A_SITE", "A_HEAVEN", "B_SITE", "B_HEAVEN" }
local ATK_FORWARD = { "MID", "MID_LEDGE", "A_LOBBY", "B_LOBBY", "A_ELBOW", "B_ELBOW" }
local DEF_FORWARD = { "MID", "MID_LEDGE", "MID_WINDOW", "A_SHORT", "B_SHORT" }
local FLANKS = { "A_MAIN", "B_MAIN", "A_ELBOW", "B_ELBOW" }

-- Deep enemy territory: fine as a DESTINATION, never as a corridor.
local ENEMY_DEEP = {
	Attack = { DEF_LOBBY = true, DEF_SPAWN = true },
	Defense = { ATK_LOBBY = true, ATK_SPAWN = true, MID_COURT = true },
}

-- Where a falling-back bot regroups.
local SAFE_ZONES = {
	Attack = { "ATK_LOBBY", "MID_COURT", "ATK_SPAWN" },
	Defense = { "DEF_LOBBY", "DEF_SPAWN" },
}

local INTENTS = { "Hold", "Push", "Rotate", "Lurk", "FallBack", "Engage", "Plant", "Defuse" }

type Context = {
	bot: any,
	side: string,
	role: string,
	zoneKey: string,
	aggression: number,
	gameSense: number,
	decisiveness: number,
	contact: any,
	visible: any,
	assessment: any,
	atObjective: boolean,
	onAnchor: boolean,
	alliesNear: number,
	enemiesNear: number,
}

local function clamp01(n: number): number
	return math.clamp(n, 0, 1)
end

-- ---------------------------------------------------------------------------
-- SAFE ROUTING. BFS over the zone graph that refuses to pass through deep
-- enemy territory. The destination itself is exempt.
-- ---------------------------------------------------------------------------
local function hopsSafe(from: string, to: string, side: string): number
	if from == to then
		return 0
	end
	local banned = ENEMY_DEEP[side]
	local dist: { [string]: number } = { [from] = 0 }
	local queue = { from }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		local zone = Zones.byKey[current]
		if zone then
			for _, nextKey in zone.adjacent do
				if dist[nextKey] == nil and (not banned[nextKey] or nextKey == to) then
					dist[nextKey] = dist[current] + 1
					table.insert(queue, nextKey)
				end
			end
		end
	end
	return dist[to] or math.huge
end

local function nextHopSafe(from: string, to: string, side: string): string?
	if from == to then
		return nil
	end
	local zone = Zones.byKey[from]
	if not zone then
		return nil
	end
	local best: string? = nil
	local bestDist = math.huge
	for _, neighbour in zone.adjacent do
		local dist = hopsSafe(neighbour, to, side)
		if dist < bestDist then
			best = neighbour
			bestDist = dist
		end
	end
	return best
end

local function nearestOf(keys: { string }, from: string, side: string): string?
	local best: string? = nil
	local bestHops = math.huge
	for _, key in keys do
		if key == from then
			continue
		end
		local hops = hopsSafe(from, key, side)
		if hops < bestHops then
			best = key
			bestHops = hops
		end
	end
	return best
end

-- WALK OR SPRINT. The shift-walk rules, checked in order:
local function wantsWalk(intent: string, side: string, currentKey: string, routeKey: string?, contact: any, now: number): boolean
	if intent == "Engage" or intent == "Plant" or intent == "Defuse" then
		return true
	end
	if intent == "Lurk" or intent == "FallBack" then
		return true
	end
	if contact and now - contact.seenAt < FRESH_CONTACT_SECONDS then
		return true
	end
	if side == "Attack" and MatchState.planted then
		return true
	end
	if Zones.hasTag(currentKey, "choke") then
		return true
	end
	if routeKey and Zones.hasTag(routeKey, "choke") then
		return true
	end
	return false
end

local function scoreHold(ctx: Context): number
	local score = 0.30 + (HOLD_ROLE[ctx.role] or 0.10)
	if ctx.side == "Defense" then
		score += 0.18
	end
	score -= ctx.aggression * 0.22
	score -= ctx.decisiveness * 0.30
	if not ctx.contact then
		score += 0.10
	end
	if Zones.hasTag(ctx.zoneKey, "site") or Zones.hasTag(ctx.zoneKey, "heaven") then
		score += 0.14
	end
	return score
end

local function scorePush(ctx: Context): number
	local score = 0.20 + (PUSH_ROLE[ctx.role] or 0.08)
	score += ctx.aggression * 0.25
	if ctx.side == "Attack" then
		score += 0.15
	end
	score += ctx.decisiveness * 0.30
	if ctx.atObjective then
		score -= 0.65
	end
	if ctx.side == "Attack" and not MatchState.planted then
		if MatchState.spikeCarrier == ctx.bot then
			score += 0.15
			-- CARRIER DISCIPLINE: alone with a fresh nearby contact, the spike
			-- does not entry-frag. Let the team catch up.
			if ctx.alliesNear == 0 and ctx.contact and Zones.hops(ctx.zoneKey, ctx.contact.zoneKey) <= ENEMY_NEAR_HOPS then
				score -= 0.40
			end
		elseif MatchState.spikeCarrier == nil and MatchState.spikePart then
			-- Recovery — but cautiously: a spike in a known-hot zone is a trap
			-- until proven otherwise.
			local spikeZone = Zones.keyAt(MatchState.spikePart.Position)
			local hot = ctx.contact and ctx.contact.zoneKey == spikeZone and ctx.contact.source == "sight"
			score += if hot then 0.05 else 0.20
		end
	end
	return score
end

local function scoreRotate(ctx: Context): number
	if not ctx.contact then
		return -1
	end
	local hops = Zones.hops(ctx.zoneKey, ctx.contact.zoneKey)
	if hops == 0 or hops == math.huge then
		return -1
	end
	local score = 0.25 + ctx.gameSense * 0.30
	score += clamp01(hops / 6) * 0.15
	if ctx.contact.source == "sound" then
		score -= 0.10
	end
	if Zones.hasTag(ctx.contact.zoneKey, "site") then
		score += 0.10 -- they're hitting a site — go
	end
	return score
end

local function scoreLurk(ctx: Context): number
	local score = 0.10 + (LURK_ROLE[ctx.role] or 0.02)
	score += (1 - ctx.aggression) * 0.18
	score -= ctx.decisiveness * 0.20
	if ctx.alliesNear >= 1 then
		score -= 0.12
	end
	return score
end

-- FALLBACK: alone, outnumbered, and not chained to the objective.
local function scoreFallBack(ctx: Context): number
	if ctx.enemiesNear < 2 or ctx.alliesNear > 0 then
		return -1
	end
	if MatchState.planted then
		return -1 -- the objective overrides survival
	end
	if MatchState.spikeCarrier == ctx.bot and Zones.hasTag(ctx.zoneKey, "plant") then
		return -1 -- on the site with the spike: plant duty, not retreat
	end
	local score = 0.30 + (ctx.enemiesNear - 1) * 0.25
	score += FALLBACK_ROLE[ctx.role] or 0
	score -= ctx.aggression * 0.30
	return score
end

local function scoreEngage(ctx: Context): number
	if not ctx.assessment then
		return -1
	end
	return ctx.assessment.score
end

local function scorePlant(ctx: Context): number
	if ctx.side ~= "Attack" or MatchState.planted or MatchState.phase ~= "Live" then
		return -1
	end
	if MatchState.spikeCarrier ~= ctx.bot then
		return -1
	end
	local score = 0.45 + ctx.decisiveness * 0.20
	if Zones.hasTag(ctx.zoneKey, "plant") then
		score += 0.55
	end
	if ctx.contact then
		local hops = Zones.hops(ctx.zoneKey, ctx.contact.zoneKey)
		if hops <= 2 then
			score -= 0.45
		else
			score -= 0.15
		end
	end
	return score
end

local function scoreDefuse(ctx: Context): number
	if ctx.side ~= "Defense" or not MatchState.planted then
		return -1
	end
	local score = 0.75 + ctx.gameSense * 0.15
	if ctx.zoneKey == MatchState.plantedZoneKey then
		score += 0.50
	end
	return score
end

local SCORERS: { [string]: (Context) -> number } = {
	Hold = scoreHold,
	Push = scorePush,
	Rotate = scoreRotate,
	Lurk = scoreLurk,
	FallBack = scoreFallBack,
	Engage = scoreEngage,
	Plant = scorePlant,
	Defuse = scoreDefuse,
}

local function isBotPart(part: BasePart): boolean
	local ancestor = part:FindFirstAncestorOfClass("Model")
	return ancestor ~= nil and ancestor:GetAttribute("ClutchBot") == true
end

-- Can a humanoid actually stand here? Clearance checks the MAP, never other
-- bots.
local function isStandable(point: Vector3, ignore: Model): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }

	local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), params)
	if not hit then
		return false
	end
	if math.abs(hit.Position.Y + 0.5 - point.Y) > GROUND_TOLERANCE then
		return false
	end

	local parts = workspace:GetPartBoundsInRadius(hit.Position + Vector3.new(0, 2.5, 0), CLEARANCE_RADIUS)
	for _, part in parts do
		if part.CanCollide and not part:IsDescendantOf(ignore) and not isBotPart(part) then
			return false
		end
	end
	return true
end

-- Ground-only validation for AUTHORED positions (cover points hug their own
-- cover by design; a 2.6-stud clearance sphere vetoes all of them).
local function hasGround(point: Vector3, ignore: Model): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }
	local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), params)
	return hit ~= nil and math.abs(hit.Position.Y + 0.5 - point.Y) <= GROUND_TOLERANCE
end

-- Corridor-aware sampling: random points first, then center-LINE samples from
-- the bot toward the zone's middle, never the wall-adjacent geometric center.
local function standablePointIn(key: string, rng: Random, ignore: Model, fromPos: Vector3?): Vector3?
	for _ = 1, CANDIDATES do
		local candidate = Zones.samplePoint(key, rng)
		if candidate and isStandable(candidate, ignore) then
			return candidate
		end
	end
	local center = Zones.center(key)
	if not center then
		return nil
	end
	if fromPos then
		for _, t in { 0.25, 0.5, 0.75 } do
			local point = fromPos + (center - fromPos) * t
			point = Vector3.new(point.X, center.Y, point.Z)
			if isStandable(point, ignore) then
				return point
			end
		end
	end
	if isStandable(center, ignore) then
		return center
	end
	return nil
end

local function pickLurkZone(ctx: Context, allyZones: { string }): string?
	local best: string? = nil
	local bestScore = -math.huge
	for _, key in FLANKS do
		if key == ctx.zoneKey then
			continue
		end
		local minHops = math.huge
		for _, allyKey in allyZones do
			local hops = Zones.hops(key, allyKey)
			if hops ~= math.huge then
				minHops = math.min(minHops, hops)
			end
		end
		local score = if minHops == math.huge then 99 else minHops
		if score > bestScore then
			best = key
			bestScore = score
		end
	end
	return best
end

-- COVER. Pick the declared cover point in this zone whose watch direction best
-- matches the threat — skipping points a living teammate has already claimed
-- (two bots one crate was the doorway traffic jam). Attackers post-plant flip
-- the declared face.
local function pickCoverPoint(ctx: Context, allies: { any }): (any?, Vector3?)
	local best: any = nil
	local bestFace: Vector3? = nil
	local bestScore = -0.2
	for _, point in Greybox.coverPoints do
		if point.zone ~= ctx.zoneKey then
			continue
		end
		local taken = false
		for _, ally in allies do
			if ally ~= ctx.bot and ally.claimedCover == point.name then
				local allyHumanoid = ally.model and ally.model:FindFirstChildOfClass("Humanoid")
				if allyHumanoid and allyHumanoid.Health > 0 then
					taken = true
					break
				end
			end
		end
		if taken then
			continue
		end
		local face = if ctx.side == "Attack" and MatchState.planted then -point.face else point.face
		face = Vector3.new(face.X, 0, face.Z).Unit
		local threatDir: Vector3
		if ctx.contact then
			local contactCenter = Zones.center(ctx.contact.zoneKey)
			if contactCenter then
				threatDir = (contactCenter - point.pos) * Vector3.new(1, 0, 1)
				threatDir = if threatDir.Magnitude > 0.1 then threatDir.Unit else Vector3.zAxis
			else
				threatDir = if ctx.side == "Defense" then Vector3.zAxis else -Vector3.zAxis
			end
		else
			threatDir = if ctx.side == "Defense" then Vector3.zAxis else -Vector3.zAxis
		end
		local score = face:Dot(threatDir) + (if point.kind == "partial" then 0.10 else 0)
		if score > bestScore then
			best = point
			bestFace = face
			bestScore = score
		end
	end
	return best, bestFace
end

-- HOLD THE ANGLE. Walk to the point, face the watch line, then jiggle-peek.
-- Authored positions use ground-only validation (see hasGround).
local function holdAngle(
	bot: any,
	model: Model,
	cover: any,
	faceDir: Vector3,
	shouldInterrupt: () -> boolean,
	perception: any,
	rng: Random,
	clock: () -> number,
	maxPeeks: number?
): boolean
	if not hasGround(cover.pos, model) then
		return false
	end
	local result = Pathing.walkToWithResult(model, cover.pos, shouldInterrupt)
	if result ~= "arrived" then
		return false
	end

	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local perp = Vector3.new(-faceDir.Z, 0, faceDir.X)
	local peekDistance = if cover.kind == "partial" then 4 else 5
	local peekPos = cover.pos + perp * peekDistance
	if not hasGround(peekPos, model) then
		peekPos = cover.pos - perp * peekDistance
	end
	local canPeek = hasGround(peekPos, model)

	if Scenario.VerboseBrain then
		local watchProbe = Zones.calloutAt(cover.pos + faceDir * 20)
		print(("[CLUTCH] %6.1fs  ANGLE %s holds %s, watching %s"):format(
			clock(),
			bot.name,
			cover.name,
			watchProbe
		))
	end

	for _ = 1, (maxPeeks or MAX_PEEKS) do
		local holdUntil = clock() + rng:NextNumber(2.5, 4)
		while clock() < holdUntil do
			if shouldInterrupt() then
				return true
			end
			if Perception.visibleContact(perception) then
				return true -- contact: the main loop owns the fight
			end
			if MatchState.phase ~= "Live" and MatchState.phase ~= "Planted" then
				return true
			end
			if root then
				root.CFrame = CFrame.lookAt(root.Position, root.Position + faceDir)
			end
			task.wait(0.25)
		end

		if not canPeek then
			continue
		end
		if Pathing.walkToWithResult(model, peekPos, shouldInterrupt) ~= "arrived" then
			return true
		end
		local checkUntil = clock() + 0.7
		while clock() < checkUntil do
			if shouldInterrupt() then
				return true
			end
			if Perception.visibleContact(perception) then
				return true
			end
			task.wait(0.15)
		end
		Pathing.walkToWithResult(model, cover.pos, shouldInterrupt)
	end
	return true
end

local function resolveTarget(intent: string, ctx: Context, allyZones: { string }, rng: Random): string?
	if intent == "Engage" then
		return nil
	elseif intent == "Plant" then
		if Zones.hasTag(ctx.zoneKey, "plant") then
			return nil
		end
		return ctx.bot.siteChoice or nearestOf(SITES, ctx.zoneKey, ctx.side)
	elseif intent == "Defuse" then
		return MatchState.plantedZoneKey
	elseif intent == "FallBack" then
		return nearestOf(SAFE_ZONES[ctx.side], ctx.zoneKey, ctx.side)
	elseif intent == "Rotate" then
		return if ctx.contact then ctx.contact.zoneKey else nil
	elseif intent == "Push" then
		if ctx.side == "Attack" then
			if not MatchState.planted and MatchState.spikeCarrier == nil and MatchState.spikePart then
				return Zones.keyAt(MatchState.spikePart.Position)
			end
			return ctx.bot.siteChoice or nearestOf(SITES, ctx.zoneKey, ctx.side)
		end
		return nearestOf(DEF_FORWARD, ctx.zoneKey, ctx.side)
	elseif intent == "Lurk" then
		return pickLurkZone(ctx, allyZones)
	end

	-- Hold
	if ctx.side == "Defense" then
		if ctx.onAnchor then
			return nil
		end
		return ctx.bot.holdChoice or nearestOf(DEF_HOLDS, ctx.zoneKey, ctx.side)
	end
	if Zones.hasTag(ctx.zoneKey, "site") or Zones.hasTag(ctx.zoneKey, "choke") or Zones.hasTag(ctx.zoneKey, "heaven") then
		return nil
	end
	return nearestOf(ATK_FORWARD, ctx.zoneKey, ctx.side)
end

local function formatScores(scores: { [string]: number }): string
	local parts = {}
	for _, intent in INTENTS do
		table.insert(parts, ("%s %.2f"):format(intent, scores[intent]))
	end
	return table.concat(parts, "  ")
end

local function describeContact(contact: any, now: number): string
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

function Brain.start(bot: any, side: string, enemies: { any }, allies: { any }, rng: Random, clock: () -> number, weapon: any, onStop: (() -> ())?)
	local model = bot.model :: Model
	local perception = Perception.new()
	Perception.startLoop(perception, bot, enemies, clock)
	Brain.perceptions[bot.name] = perception -- teammates' callouts land here

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local combatState = Combat.newState(if humanoid then humanoid.Health else 100)
	bot.combatState = combatState

	task.spawn(function()
		local intent = if side == "Attack" then "Push" else "Hold"
		local lastProgressAt = clock()
		local committedAt = clock()
		local lastThinkLogAt = -math.huge
		local routeKey: string? = nil

		-- Diagnostics + comms state
		local prevZoneKey = Zones.VOID
		local zoneSince = clock()
		local lastStallLogAt = -math.huge
		local lastCalloutAt: { [string]: number } = {}
		local lastDamageSeen = combatState.lastDamagedAt or 0
		local lastApproachPeekAt = -math.huge

		-- Radio a contact to every living teammate. They receive it as a
		-- SOUND-class memory — a zone and a rough position, never a wallhack
		-- (injected contacts aren't "visible", so they can't trigger shots).
		local function shareContact(contact: any, verb: string, now: number)
			local lastCall = lastCalloutAt[contact.name] or -math.huge
			if now - lastCall < CALLOUT_COOLDOWN then
				return
			end
			lastCalloutAt[contact.name] = now
			if Scenario.VerboseBrain then
				print(("[CLUTCH] %6.1fs  CALLOUT %s: "%s — %s""):format(now, bot.name, verb, contact.zoneCallout))
			end
			task.delay(SimConfig.CalloutDelaySeconds, function()
				for _, ally in allies do
					if ally == bot then
						continue
					end
					local allyPerception = Brain.perceptions[ally.name]
					local allyHumanoid = ally.model and ally.model:FindFirstChildOfClass("Humanoid")
					if allyPerception and allyHumanoid and allyHumanoid.Health > 0 then
						allyPerception.memory[contact.name] = {
							name = contact.name,
							pos = contact.pos,
							zoneKey = contact.zoneKey,
							zoneCallout = contact.zoneCallout,
							seenAt = clock(),
							source = "sound", -- the radio is approximate, deliberately
							distance = 0,
						}
						allyPerception.lastContactAt = clock()
					end
				end
			end)
		end

		-- Cached interrupt predicate. Combat only aborts a walk when the fight
		-- is forced or close.
		local interruptCheckedAt = -math.huge
		local interruptAnswer = false
		local function shouldInterrupt(): boolean
			local now = clock()
			if now - interruptCheckedAt < INTERRUPT_RECHECK then
				return interruptAnswer
			end
			interruptCheckedAt = now
			interruptAnswer = false
			if MatchState.phase ~= "Live" and MatchState.phase ~= "Planted" then
				return true
			end
			local here = Zones.keyAt(Zones.groundOf(model))
			local visible = Perception.visibleContact(perception)
			if visible then
				local assessment = Combat.assess(bot, weapon, visible, enemies, here, combatState, now)
				interruptAnswer = assessment.engage
					and (assessment.forced or assessment.distance <= INTERRUPT_COMBAT_RANGE)
			end
			if not interruptAnswer then
				if MatchState.planted and side == "Defense" and intent ~= "Defuse" then
					interruptAnswer = true
				elseif side == "Attack"
					and not MatchState.planted
					and MatchState.spikeCarrier == bot
					and intent ~= "Plant"
					and Zones.hasTag(here, "plant")
				then
					interruptAnswer = true
				end
			end
			return interruptAnswer
		end

		local function channelAbort(): boolean
			return Perception.visibleContact(perception) ~= nil
		end

		task.wait(rng:NextNumber(0, SimConfig.DecisionTickSeconds * 4)) -- stagger

		while model.Parent do
			local alive = model:FindFirstChildOfClass("Humanoid")
			if not alive or alive.Health <= 0 then
				break
			end

			if MatchState.phase ~= "Live" and MatchState.phase ~= "Planted" then
				task.wait(0.5)
				continue
			end

			local now = clock()
			Combat.pollHealth(bot, combatState, now)

			local ground = Zones.groundOf(model)
			local currentKey = Zones.keyAt(ground)
			if currentKey == Zones.VOID then
				warn(("[CLUTCH] %s is in VOID at %.0f, %.0f, %.0f — zone bounds are wrong"):format(
					bot.name,
					ground.X,
					ground.Y,
					ground.Z
				))
			end
			if currentKey ~= prevZoneKey then
				prevZoneKey = currentKey
				zoneSince = now
			end

			local visible = Perception.visibleContact(perception)
			local contact = Perception.bestContact(perception, now)
			if not visible then
				Combat.disengage(combatState)
			end

			-- CALLOUTS. A fresh sighting goes out on the radio; so does taking
			-- fire from a suspect we already know about. Cooldown per enemy.
			if visible then
				shareContact(visible, ("Contact: %s"):format(visible.name), now)
			else
				local damagedAt = combatState.lastDamagedAt or 0
				if damagedAt > lastDamageSeen then
					lastDamageSeen = damagedAt
					if contact then
						shareContact(contact, ("Under fire — %s"):format(contact.name), now)
					end
				end
			end

			if side == "Attack" and not MatchState.planted then
				Objective.tryPickup(bot)
			end

			local assessment = nil
			if visible then
				assessment = Combat.assess(bot, weapon, visible, enemies, currentKey, combatState, now)
			end

			local allyZones = {}
			local alliesNear = 0
			for _, ally in allies do
				if ally == bot or not ally.model.Parent then
					continue
				end
				local allyHumanoid = ally.model:FindFirstChildOfClass("Humanoid")
				if not allyHumanoid or allyHumanoid.Health <= 0 then
					continue -- the dead do not count as company
				end
				local allyGround = Zones.groundOf(ally.model)
				table.insert(allyZones, Zones.keyAt(allyGround))
				if (allyGround - ground).Magnitude <= ALLY_CROWD_STUDS then
					alliesNear += 1
				end
			end

			local enemiesNear = 0
			for _, memoryContact in perception.memory do
				if now - memoryContact.seenAt < FRESH_CONTACT_SECONDS
					and Zones.hops(currentKey, memoryContact.zoneKey) <= ENEMY_NEAR_HOPS
				then
					enemiesNear += 1
				end
			end

			local reference = math.max(lastProgressAt, perception.lastContactAt)
			local decisiveness = clamp01((now - reference) / Scenario.StallRampSeconds)

			local atObjective = if side == "Attack"
				then Zones.hasTag(currentKey, "site")
				else table.find(DEF_FORWARD, currentKey) ~= nil

			local ctx: Context = {
				bot = bot,
				side = side,
				role = bot.role,
				zoneKey = currentKey,
				aggression = bot.attributes.Aggression / 100,
				gameSense = bot.attributes.GameSense / 100,
				decisiveness = decisiveness,
				contact = contact,
				visible = visible,
				assessment = assessment,
				atObjective = atObjective,
				onAnchor = table.find(DEF_HOLDS, currentKey) ~= nil,
				alliesNear = alliesNear,
				enemiesNear = enemiesNear,
			}

			local scores: { [string]: number } = {}
			for _, name in INTENTS do
				scores[name] = SCORERS[name](ctx)
			end

			local winner = intent
			local winnerScore = scores[intent]
			for _, name in INTENTS do
				local margin = if name == "Engage" then 0 else HYSTERESIS
				if name ~= intent and scores[name] > winnerScore + margin then
					winner = name
					winnerScore = scores[name]
				end
			end

			if winner ~= intent
				and winner ~= "Engage"
				and winner ~= "Plant"
				and winner ~= "Defuse"
				and winner ~= "FallBack"
			then
				if now - committedAt < Scenario.MinIntentSeconds then
					winner = intent
				end
			end

			local switched = winner ~= intent
			if switched then
				committedAt = now
				routeKey = nil
			end
			local previous = intent
			intent = winner
			Telemetry.setIntent(bot.name, intent)

			-- The TEAM PLAN (RoundMachine) may have assigned these already; the
			-- roll only fires for freelancers the plan leaves open.
			if side == "Attack" and bot.siteChoice == nil then
				bot.siteChoice = SITES[rng:NextInteger(1, #SITES)]
				if Scenario.VerboseBrain then
					print(("[CLUTCH] %6.1fs  PLAN %s calls %s this round"):format(
						clock(),
						bot.name,
						if Zones.byKey[bot.siteChoice] then Zones.byKey[bot.siteChoice].callout else bot.siteChoice
					))
				end
			elseif side == "Defense" and bot.holdChoice == nil then
				bot.holdChoice = DEF_HOLDS[rng:NextInteger(1, #DEF_HOLDS)]
				if Scenario.VerboseBrain then
					print(("[CLUTCH] %6.1fs  PLAN %s anchors %s this round"):format(
						clock(),
						bot.name,
						if Zones.byKey[bot.holdChoice] then Zones.byKey[bot.holdChoice].callout else bot.holdChoice
					))
				end
			end

			local targetKey = resolveTarget(intent, ctx, allyZones, rng)

			local walking = wantsWalk(intent, side, currentKey, routeKey, contact, now)
			bot.speedMode = if walking then "walk" else "sprint"
			alive.WalkSpeed = if walking then SimConfig.WalkSpeed else SimConfig.SprintSpeed

			if Scenario.VerboseBrain and (switched or now - lastThinkLogAt >= Scenario.BrainHeartbeatSeconds) then
				lastThinkLogAt = now
				local transition = if switched then ("%s -> %s"):format(previous, intent) else ("%s (steady)"):format(intent)
				print(("[CLUTCH] %6.1fs  THINK %s (%s) %s | %s | in %s | target %s | %s | ramp %.2f | %s"):format(
					now,
					bot.name,
					if side == "Attack" then "ATK" else "DEF",
					transition,
					formatScores(scores),
					Zones.byKey[currentKey] and Zones.byKey[currentKey].callout or currentKey,
					if targetKey and Zones.byKey[targetKey] then Zones.byKey[targetKey].callout else "hold position",
					describeContact(contact, now),
					decisiveness,
					bot.speedMode
				))
			end

			if intent == "Engage" and visible and assessment then
				if Scenario.LogCombat and switched then
					print(("[CLUTCH] %6.1fs  ENGAGE %s -> %s | %.0f studs %s | dmg x%.2f | %s%s"):format(
						now,
						bot.name,
						assessment.targetName,
						assessment.distance,
						assessment.band,
						assessment.multiplier,
						if assessment.forced then "FORCED: " else "",
						assessment.reason
					))
				end

				local targetModel = nil
				for _, enemy in enemies do
					if enemy.name == assessment.targetName then
						targetModel = enemy.model
						break
					end
				end

				if targetModel then
					local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
					if root and alive then
						alive:MoveTo(root.Position)
					end
					Combat.fireBurst(bot, weapon, targetModel, combatState, rng, clock)
					lastProgressAt = clock()
				end
			elseif visible and assessment and not assessment.engage and Scenario.LogCombat and switched then
				print(("[CLUTCH] %6.1fs  HOLD FIRE %s | %s at %.0f studs %s | %s"):format(
					now,
					bot.name,
					assessment.targetName,
					assessment.distance,
					assessment.band,
					assessment.reason
				))
			end

			if intent == "Plant" and Zones.hasTag(currentKey, "plant") then
				Objective.tryStartPlant(bot, clock, channelAbort, if contact then contact.pos else nil)
				lastProgressAt = clock()
			elseif intent == "Defuse" and currentKey == MatchState.plantedZoneKey and MatchState.spikePart then
				local result = Pathing.walkToWithResult(model, MatchState.spikePart.Position, shouldInterrupt)
				if result == "arrived" then
					Objective.tryStartDefuse(bot, clock, channelAbort)
				end
				lastProgressAt = clock()
			elseif intent ~= "Engage" then
				if targetKey == nil or targetKey == currentKey then
					-- Settle the zone. Claim the angle first — two bots on one crate
					-- was the doorway traffic jam.
					routeKey = nil
					local cover, faceDir = pickCoverPoint(ctx, allies)
					if cover and faceDir then
						bot.claimedCover = cover.name
						if holdAngle(bot, model, cover, faceDir, shouldInterrupt, perception, rng, clock) then
							lastProgressAt = clock()
						end
						bot.claimedCover = nil
					else
						local spot = standablePointIn(currentKey, rng, model, ground)
						if spot then
							Pathing.walkToWithResult(model, spot, shouldInterrupt)
						end
						task.wait(rng:NextNumber(0.6, 1.4))
					end
				else
					-- APPROACH PEEK: about to walk toward a fresh, close contact?
					-- Snap to this zone's cover facing the threat for one peek first.
					if (intent == "Push" or intent == "Rotate" or intent == "Lurk")
						and contact
						and now - contact.seenAt < FRESH_CONTACT_SECONDS
						and hopsSafe(currentKey, contact.zoneKey, side) <= APPROACH_PEEK_HOPS
						and now - lastApproachPeekAt > APPROACH_PEEK_COOLDOWN
					then
						local cover, faceDir = pickCoverPoint(ctx, allies)
						if cover and faceDir then
							lastApproachPeekAt = now
							bot.claimedCover = cover.name
							holdAngle(bot, model, cover, faceDir, shouldInterrupt, perception, rng, clock, 1)
							bot.claimedCover = nil
						end
					end

					if routeKey == nil then
						local hops = hopsSafe(currentKey, targetKey, side)
						routeKey = if hops > DIRECT_WALK_MAX_HOPS
							then (nextHopSafe(currentKey, targetKey, side) or targetKey)
							else targetKey
					end

					if currentKey == routeKey then
						if routeKey == targetKey then
							lastProgressAt = clock()
						end
						routeKey = nil
					else
						local retrieving = side == "Attack"
							and not MatchState.planted
							and MatchState.spikeCarrier == nil
							and MatchState.spikePart ~= nil
							and routeKey == Zones.keyAt(MatchState.spikePart.Position)
						local spot
						if retrieving then
							local spikePos = MatchState.spikePart.Position
							spot = Vector3.new(spikePos.X, 1, spikePos.Z)
							if not isStandable(spot, model) then
								spot = standablePointIn(routeKey, rng, model, ground)
							end
						else
							spot = standablePointIn(routeKey, rng, model, ground)
						end

						if spot then
							local result = Pathing.walkToWithResult(model, spot, shouldInterrupt)
							if result == "failed" then
								routeKey = nil
								task.wait(SimConfig.DecisionTickSeconds * 2)
							end
						else
							routeKey = nil
							task.wait(SimConfig.DecisionTickSeconds)
						end
					end
				end
			end

			-- Stall diagnostics: a bot that wants to move but hasn't changed
			-- zones in 8s reports its exact situation.
			if targetKey ~= nil
				and targetKey ~= currentKey
				and now - zoneSince > STALL_LOG_SECONDS
				and now - lastStallLogAt > STALL_LOG_SECONDS
			then
				lastStallLogAt = now
				warn(("[CLUTCH] STALL %s at %.0f, %.0f, %.0f — intent %s, in %s, wants %s via %s"):format(
					bot.name,
					ground.X,
					ground.Y,
					ground.Z,
					intent,
					currentKey,
					targetKey,
					tostring(routeKey)
				))
			end

			task.wait(SimConfig.DecisionTickSeconds)
		end

		perception.running = false
		if Brain.perceptions[bot.name] == perception then
			Brain.perceptions[bot.name] = nil
		end
		if onStop then
			task.defer(onStop)
		end
	end)
end

return Brain
