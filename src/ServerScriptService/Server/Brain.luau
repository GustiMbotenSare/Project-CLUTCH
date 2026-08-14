--!strict
-- Bot brain v3.4: score every intent, commit to the winner, act on it — with
-- the round in the loop, survival instincts that fire, two feet, angle
-- holding, and now FIGHT-OR-FLIGHT plus safe routing.
--
-- Utility AI rather than a state machine, because a state machine hides its
-- reasoning. Every tick produces a full score vector and the log prints it,
-- so a bad decision can be traced to the term that caused it.
--
-- New after playtest #11 (first 5v5):
--   * FALLBACK, the "surrender" the user asked for: a bot that is ALONE with
--     2+ fresh enemy contacts within 2 hops computes whether this fight is
--     worth taking. Anchors and Snipers peel off readily; Entries need to be
--     deeper in trouble; Aggression talks bots out of it. Falling back toward
--     your own lobby with the spike beats donating it to a stacked site.
--   * SAFE ROUTING: rotations no longer path through the enemy's spawn lobby
--     (map v3 opened sites to the defender lobby, and the graph happily
--     routed Rook through it). Deep enemy territory is off-limits for
--     intermediate hops; the destination itself stays reachable.
--   * CARRIER DISCIPLINE: the spike carrier alone with a fresh contact within
--     2 hops of a site stops entry-fragging (Push −0.40). The spike leads
--     nothing.
--   * SPIKE RECOVERY walks to the spike itself (7-stud pickup), and the
--     retrieve bonus collapses to +0.05 when the spike's zone is known-hot —
--     cautiously, per the user's ask, not an instant five-man yolo.
--   * Phase changes interrupt walks: the PostRound freeze used to trip the
--     stuck timer into BLOCKED spam.
--   * Corridor sampling fallback: door-throat destinations no longer default
--     to the geometric center (a wall-adjacent, unpathable point that four
--     bots converged on). Center-line samples toward the zone instead.
--
-- ---------------------------------------------------------------------------
-- History: v3.3 cover points / jiggle peek · v3.2 walk-sprint, objective
-- interrupts · v3.1 engage hysteresis, sticky picks, hot-site plants · v3
-- plant/defuse · v2 scoring bands, route commitment · v1 intent scorer.
-- ---------------------------------------------------------------------------

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

local HYSTERESIS = 0.08 -- how much better a rival intent must be to win
local CANDIDATES = 6 -- standable-point attempts per destination
local CLEARANCE_RADIUS = 2.6
local GROUND_TOLERANCE = 2.5
local ALLY_CROWD_STUDS = 25
-- Walk whole routes, not two-hop legs. Interrupts (combat, the spike, phase
-- changes) still poll every 0.3s inside the walk.
local DIRECT_WALK_MAX_HOPS = 6
local INTERRUPT_RECHECK = 0.3 -- seconds between interrupt polls mid-walk
local FRESH_CONTACT_SECONDS = 6 -- contact newer than this means quiet feet
local MAX_PEEKS = 3 -- jiggle-peeks per cover hold before re-deciding
local ENEMY_NEAR_HOPS = 2 -- "in my area" for the fallback math

-- Role priors. Kept in the same band as the situational terms on purpose: a
-- role should bias a decision, never decide it outright.
local HOLD_ROLE = { Anchor = 0.30, Sniper = 0.23, Support = 0.10, IGL = 0.07, Lurker = 0.03, Entry = 0.00 }
local PUSH_ROLE = { Entry = 0.25, Support = 0.11, IGL = 0.08, Lurker = 0.06, Sniper = 0.03, Anchor = 0.00 }
local LURK_ROLE = { Lurker = 0.30, Sniper = 0.09, Support = 0.03, IGL = 0.03, Entry = 0.00, Anchor = 0.00 }
-- How willingly each role gives ground when outnumbered alone.
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
	enemiesNear: number, -- fresh, within ENEMY_NEAR_HOPS
}

local function clamp01(n: number): number
	return math.clamp(n, 0, 1)
end

-- ---------------------------------------------------------------------------
-- SAFE ROUTING. BFS over the zone graph that refuses to pass through deep
-- enemy territory. The destination itself is exempt — rotating INTO the
-- enemy's site is the job; strolling through their spawn lobby to get there
-- was the playtest #11 bug.
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

-- Nearest zone from a list by SAFE hops, never the one we are standing in.
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
		return true -- fights and channels are careful by definition
	end
	if intent == "Lurk" or intent == "FallBack" then
		return true -- quiet is the entire point
	end
	if contact and now - contact.seenAt < FRESH_CONTACT_SECONDS then
		return true -- danger is fresh: go quiet
	end
	if side == "Attack" and MatchState.planted then
		return true -- post-plant: hold the site quietly
	end
	if Zones.hasTag(currentKey, "choke") then
		return true -- inside a door/short/window: check it, don't sprint through
	end
	if routeKey and Zones.hasTag(routeKey, "choke") then
		return true -- about to enter one
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
		score += 0.14 -- ground worth standing on
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
		-- There is nothing left to push toward. Without this the bot repositions
		-- inside its own objective forever, which is exactly what Ace did.
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
		score -= 0.10 -- footsteps are worth less than eyes
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
		score -= 0.12 -- lurking in a group is not lurking
	end
	return score
end

-- FALLBACK: alone, outnumbered, and not chained to the objective. The
-- survival instinct — retreat, regroup, rotate, or re-peek from a better
-- angle instead of donating the round (or the spike) to a stacked site.
local function scoreFallBack(ctx: Context): number
	if ctx.enemiesNear < 2 or ctx.alliesNear > 0 then
		return -1
	end
	if MatchState.planted then
		return -1 -- the objective overrides survival: retake or die trying
	end
	if MatchState.spikeCarrier == ctx.bot and Zones.hasTag(ctx.zoneKey, "plant") then
		return -1 -- on the site with the spike: plant duty, not retreat
	end
	local score = 0.30 + (ctx.enemiesNear - 1) * 0.25
	score += FALLBACK_ROLE[ctx.role] or 0
	score -= ctx.aggression * 0.30
	return score
end

-- Engage is scored entirely by Combat, so range discipline lives in one place.
local function scoreEngage(ctx: Context): number
	if not ctx.assessment then
		return -1
	end
	return ctx.assessment.score
end

-- The carrier on a live round: get to a site, then put the spike down. A
-- contact close to the site taxes the plant hard — clear first, plant after.
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
			score -= 0.45 -- the site is hot
		else
			score -= 0.15
		end
	end
	return score
end

-- The spike is down: every defender collapses on it. Off site this still has
-- to beat a comfortable Hold, or nobody retakes.
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

-- Can a humanoid actually stand here?
local function isStandable(point: Vector3, ignore: Model): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }

	local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), params)
	if not hit then
		return false
	end
	if math.abs(hit.Position.Y + 0.5 - point.Y) > GROUND_TOLERANCE then
		return false -- floating in the air or buried in geometry
	end

	local parts = workspace:GetPartBoundsInRadius(hit.Position + Vector3.new(0, 2.5, 0), CLEARANCE_RADIUS)
	for _, part in parts do
		if part.CanCollide and not part:IsDescendantOf(ignore) then
			return false
		end
	end
	return true
end

-- Corridor-aware sampling: random points first, then center-LINE samples from
-- the bot toward the zone's middle. The old fallback returned the geometric
-- center — in a 12-stud door throat that's wall-adjacent and unpathable, and
-- playtest #11 had four bots converge on exactly that point at B Door.
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

-- The flank that maximises distance from every teammate.
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
-- matches the threat: the freshest contact's zone if we have one, else the
-- side's default axis (defenders watch south, post-plant attackers watch the
-- defender side — the declared face flips).
local function pickCoverPoint(ctx: Context): (any?, Vector3?)
	local best: any = nil
	local bestFace: Vector3? = nil
	local bestScore = -0.2 -- below this the angle watches the wrong way entirely
	for _, point in Greybox.coverPoints do
		if point.zone ~= ctx.zoneKey then
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

-- HOLD THE ANGLE. Walk to the point, face the watch line, then jiggle-peek:
-- step out perpendicular, check, step back. Returns when combat/objectives
-- interrupt, when a contact appears (the main loop re-scores), when the phase
-- changes, or after MAX_PEEKS cycles. True if the bot actually held it.
local function holdAngle(
	bot: any,
	model: Model,
	cover: any,
	faceDir: Vector3,
	shouldInterrupt: () -> boolean,
	perception: any,
	rng: Random,
	clock: () -> number
): boolean
	if not isStandable(cover.pos, model) then
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
	if not isStandable(peekPos, model) then
		peekPos = cover.pos - perp * peekDistance
	end
	local canPeek = isStandable(peekPos, model)

	if Scenario.VerboseBrain then
		local watchProbe = Zones.calloutAt(cover.pos + faceDir * 20)
		print(("[CLUTCH] %6.1fs  ANGLE %s holds %s, watching %s"):format(
			clock(),
			bot.name,
			cover.name,
			watchProbe
		))
	end

	for _ = 1, MAX_PEEKS do
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
		return nil -- stand and fight
	elseif intent == "Plant" then
		if Zones.hasTag(ctx.zoneKey, "plant") then
			return nil -- channel in place
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
			-- A dropped spike outranks map control: walk to where it fell.
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
			return nil -- already somewhere worth holding
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

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local combatState = Combat.newState(if humanoid then humanoid.Health else 100)
	bot.combatState = combatState -- exposed so the round machine can inspect it

	task.spawn(function()
		local intent = if side == "Attack" then "Push" else "Hold"
		local lastProgressAt = clock()
		local committedAt = clock()
		local lastThinkLogAt = -math.huge
		local routeKey: string? = nil -- committed intermediate zone; see header

		-- Cached interrupt predicate. Combat, the objective, and now the PHASE
		-- all cut a walk short — a frozen body mid-walk used to trip the stuck
		-- timer into between-round BLOCKED spam.
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
				return true -- frozen between phases: stop walking
			end
			local here = Zones.keyAt(Zones.groundOf(model))
			local visible = Perception.visibleContact(perception)
			if visible then
				local assessment = Combat.assess(bot, weapon, visible, enemies, here, combatState, now)
				interruptAnswer = assessment.engage
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

		-- A visible enemy also breaks plant/defuse channels (Objective polls this)
		local function channelAbort(): boolean
			return Perception.visibleContact(perception) ~= nil
		end

		task.wait(rng:NextNumber(0, SimConfig.DecisionTickSeconds * 4)) -- stagger

		while model.Parent do
			local alive = model:FindFirstChildOfClass("Humanoid")
			if not alive or alive.Health <= 0 then
				break
			end

			-- Frozen between phases: a body that cannot move must not path.
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

			local visible = Perception.visibleContact(perception)
			local contact = Perception.bestContact(perception, now)
			if not visible then
				Combat.disengage(combatState) -- next fight pays reaction cost again
			end

			-- A dropped spike is picked up by walking near it
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

			-- Fresh, nearby, DISTINCT enemies — the fallback math's "2-3
			-- movements in my area".
			local enemiesNear = 0
			for _, memoryContact in perception.memory do
				if now - memoryContact.seenAt < FRESH_CONTACT_SECONDS
					and Zones.hops(currentKey, memoryContact.zoneKey) <= ENEMY_NEAR_HOPS
				then
					enemiesNear += 1
				end
			end

			-- Anti-stall. Deliberately NOT reset by ordinary walking.
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

			-- ENGAGE BYPASSES HYSTERESIS. A forced engage at 0.88 lost to a
			-- 0.94 Push in playtest #8 and the bot walked into five bullets.
			-- Getting shot at outranks momentum.
			local winner = intent
			local winnerScore = scores[intent]
			for _, name in INTENTS do
				local margin = if name == "Engage" then 0 else HYSTERESIS
				if name ~= intent and scores[name] > winnerScore + margin then
					winner = name
					winnerScore = scores[name]
				end
			end

			-- Commitment stops intent chatter, but being shot at, a live
			-- objective — or a collapsing fight — outranks it.
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
				routeKey = nil -- a new intent re-plans its route from scratch
			end
			local previous = intent
			intent = winner
			Telemetry.setIntent(bot.name, intent)

			-- Sticky per-round picks — but the TEAM PLAN (RoundMachine) may have
			-- assigned them already. The coin roll below only fires for the
			-- freelancers a plan deliberately leaves open (sniper/lurker in a
			-- Default, both sides pre-plan).
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

			-- WALK OR SPRINT, decided per tick and applied to the humanoid.
			local walking = wantsWalk(intent, side, currentKey, routeKey, contact, now)
			bot.speedMode = if walking then "walk" else "sprint"
			alive.WalkSpeed = if walking then SimConfig.WalkSpeed else SimConfig.SprintSpeed

			-- Print on change, and periodically even without one.
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
						alive:MoveTo(root.Position) -- plant feet, then shoot
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
				-- Blocking channel; aborts on damage, movement, death — or a
				-- visible enemy. Face the last known threat before crouching.
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
					-- Settle the zone. With declared cover, HOLD THE ANGLE instead of
					-- shuffling: snap to the point facing the threat and jiggle-peek.
					routeKey = nil
					local cover, faceDir = pickCoverPoint(ctx)
					if cover and faceDir then
						if holdAngle(bot, model, cover, faceDir, shouldInterrupt, perception, rng, clock) then
							lastProgressAt = clock() -- holding the angle IS the finished goal
						end
					else
						local spot = standablePointIn(currentKey, rng, model, ground)
						if spot then
							Pathing.walkToWithResult(model, spot, shouldInterrupt)
						end
						task.wait(rng:NextNumber(0.6, 1.4))
					end
				else
					-- ROUTE COMMITMENT: one intermediate zone until the zone actually
					-- changes. Distances and hops are SAFE — deep enemy territory is
					-- never a corridor (the Rook-through-defender-lobby fix).
					if routeKey == nil then
						local hops = hopsSafe(currentKey, targetKey, side)
						routeKey = if hops > DIRECT_WALK_MAX_HOPS
							then (nextHopSafe(currentKey, targetKey, side) or targetKey)
							else targetKey
					end

					if currentKey == routeKey then
						-- Crossed into the committed zone: leg complete.
						if routeKey == targetKey then
							lastProgressAt = clock() -- only a FINISHED goal resets the ramp
						end
						routeKey = nil
					else
						-- Spike recovery walks to the SPIKE, not to a random sample of
						-- the zone it fell in.
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
								routeKey = nil -- try a fresh route next tick
								task.wait(SimConfig.DecisionTickSeconds * 2)
							end
							-- "arrived" but still outside routeKey means the walk stopped
							-- at the boundary: keep routeKey and sample a deeper point.
							-- "aborted" keeps routeKey too; Engage owns what happens next.
						else
							routeKey = nil
							task.wait(SimConfig.DecisionTickSeconds)
						end
					end
				end
			end

			task.wait(SimConfig.DecisionTickSeconds)
		end

		perception.running = false
		if onStop then
			task.defer(onStop)
		end
	end)
end

return Brain
