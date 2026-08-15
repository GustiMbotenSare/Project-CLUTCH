--!strict
-- Bot brain v4.2: score every intent, commit to the winner, act on it — with
-- team comms, a retake structure, and every weight on the tuning rack.
--
-- v4.2 (the pre-rerun batch):
--   * ALL SCORING WEIGHTS now read from Shared/Constants/BrainTuning.luau,
--     live, at score time. That table is what the in-game CEM (Tuner.luau,
--     Scenario.TuningMode) perturbs between matches — the brain's judgment
--     is data now, not constants buried in code.
--   * ROLE-BASED POSITIONING: within an assigned site/zone, the role biases
--     WHICH angle gets held — Snipers gravitate to heaven rails, Lurkers to
--     connector/choke watches, Anchors to site cover, Entries to choke-side
--     partials. The plan says WHERE; the role says HOW it stands there.
--   * Angle-hold facing turns smoothly (360°/s cap) instead of snapping.
--     Combat owns its own turn rate + accuracy coupling.
--
-- v4.1 carried: the barrier phase (defenders live during Buy), the rebuilt
-- sampler (ground-part exclusion, local-height center-line, named rejection
-- diagnostics), personal space (6 studs), the retake structure (two closest
-- defuse, the rest rotate on the loud plant contact), the post-plant site
-- web, swings, the info doctrine, callout range/honesty fixes. v4.0: team
-- callouts, cover claims, approach peeks. Earlier history in the git log.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local SimConfig = require(Shared.Constants.SimConfig)
local Scenario = require(Shared.Constants.Scenario)
local Zones = require(Shared.MapData.Zones)
local Greybox = require(Shared.MapData.Greybox)
local Tuning = require(Shared.Constants.BrainTuning)

local Pathing = require(script.Parent.Pathing)
local Perception = require(script.Parent.Perception)
local Combat = require(script.Parent.Combat)
local Telemetry = require(script.Parent.Telemetry)
local Objective = require(script.Parent.Objective)
local MatchState = require(script.Parent.MatchState)

local Brain = {}

-- Every living brain's perception, keyed by name. Callouts write into these;
-- brains read their own.
Brain.perceptions = {} :: { [string]: any }

local CANDIDATES = 6
local CLEARANCE_RADIUS = 2.6
local GROUND_TOLERANCE = 2.5
local ALLY_CROWD_STUDS = 25
local PERSONAL_SPACE = 6 -- sampled destinations keep this much room per teammate
local DIRECT_WALK_MAX_HOPS = 6
local INTERRUPT_RECHECK = 0.3
local FRESH_CONTACT_SECONDS = 6
local MAX_PEEKS = 3
local SWING_CHANCE = 0.25 -- occasional wide peek; the rest are jiggles
local SWING_STUDS = 9
local ENEMY_NEAR_HOPS = 2
local INTERRUPT_COMBAT_RANGE = 30
local STALL_LOG_SECONDS = 8
local CALLOUT_COOLDOWN = 4
local APPROACH_PEEK_COOLDOWN = 6
local APPROACH_PEEK_HOPS = 2
local SAMPLE_DIAG_SECONDS = 10
local HOLD_TURN_DEG_PER_SEC = 360 -- angle-hold facing cap (combat has its own)

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

local SAFE_ZONES = {
	Attack = { "ATK_LOBBY", "MID_COURT", "ATK_SPAWN" },
	Defense = { "DEF_LOBBY", "DEF_SPAWN" },
}

-- Role-based positioning: within an assigned zone, which KIND of angle the
-- role gravitates to (matched against the point's zone tags).
local ROLE_ZONE_AFFINITY = {
	Sniper = { heaven = 0.25 },
	Lurker = { connector = 0.25, choke = 0.15 },
	Entry = { site = 0.15, choke = 0.10 },
	Anchor = { site = 0.20 },
	Support = { site = 0.10, heaven = 0.10 },
	IGL = { mid = 0.20, choke = 0.10 },
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
	closerToSite: number,
	coverZoneSet: { string }?,
}

local function clamp01(n: number): number
	return math.clamp(n, 0, 1)
end

-- The barrier phase: defenders are live during Buy (deploying to their
-- holds); attackers sleep frozen until LIVE.
local function phaseIsLive(side: string): boolean
	return MatchState.phase == "Live"
		or MatchState.phase == "Planted"
		or (MatchState.phase == "Buy" and side == "Defense")
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

-- WALK OR SPRINT — the info doctrine's speed half:
local function wantsWalk(intent: string, side: string, currentKey: string, routeKey: string?, contact: any, now: number): boolean
	if intent == "Engage" or intent == "Plant" or intent == "Defuse" then
		return true
	end
	if intent == "Lurk" or intent == "FallBack" then
		return true
	end
	if contact and now - contact.seenAt < FRESH_CONTACT_SECONDS then
		return true -- fresh info: go quiet
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
	return false -- no info, no threat: run
end

-- ---------------------------------------------------------------------------
-- SCORERS. Every weight reads BrainTuning LIVE — the tuner perturbs the
-- table between matches and the next tick plays by the new numbers.
-- ---------------------------------------------------------------------------
local function scoreHold(ctx: Context): number
	local T = Tuning.Hold
	local score = T.Base + (T.Role[ctx.role] or 0.10)
	if ctx.side == "Defense" then
		score += T.DefenseBonus
	end
	score += ctx.aggression * T.AggressionPenalty
	score += ctx.decisiveness * T.DecisivenessPenalty
	if not ctx.contact then
		score += T.NoContactBonus
	end
	if Zones.hasTag(ctx.zoneKey, "site") or Zones.hasTag(ctx.zoneKey, "heaven") then
		score += T.HighGroundBonus
	end
	return score
end

local function scorePush(ctx: Context): number
	local T = Tuning.Push
	local score = T.Base + (T.Role[ctx.role] or 0.08)
	score += ctx.aggression * T.AggressionBonus
	if ctx.side == "Attack" then
		score += T.AttackBonus
	end
	score += ctx.decisiveness * T.DecisivenessBonus
	if ctx.atObjective then
		score += T.AtObjectivePenalty
	end
	if ctx.side == "Attack" and not MatchState.planted then
		if MatchState.spikeCarrier == ctx.bot then
			score += T.CarrierBonus
			-- CARRIER DISCIPLINE: alone with a fresh nearby contact, the spike
			-- does not entry-frag. Let the team catch up.
			if ctx.alliesNear == 0 and ctx.contact and Zones.hops(ctx.zoneKey, ctx.contact.zoneKey) <= ENEMY_NEAR_HOPS then
				score += T.CarrierAloneHotPenalty
			end
		elseif MatchState.spikeCarrier == nil and MatchState.spikePart then
			-- Recovery — but cautiously: a spike in a known-hot zone is a trap.
			local spikeZone = Zones.keyAt(MatchState.spikePart.Position)
			local hot = ctx.contact and ctx.contact.zoneKey == spikeZone and ctx.contact.source == "sight"
			score += if hot then T.RetrieveHotBonus else T.RetrieveBonus
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
	local T = Tuning.Rotate
	local score = T.Base + ctx.gameSense * T.GameSenseBonus
	score += clamp01(hops / 6) * T.DistanceBonus
	if ctx.contact.source == "sound" then
		score += T.SoundPenalty
	end
	if Zones.hasTag(ctx.contact.zoneKey, "site") then
		score += T.SiteBonus
	end
	return score
end

local function scoreLurk(ctx: Context): number
	local T = Tuning.Lurk
	local score = T.Base + (T.Role[ctx.role] or 0.02)
	score += (1 - ctx.aggression) * T.CalmBonus
	score += ctx.decisiveness * T.DecisivenessPenalty
	if ctx.alliesNear >= 1 then
		score += T.CrowdPenalty
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
		return -1
	end
	local T = Tuning.FallBack
	local score = T.Base + (ctx.enemiesNear - 1) * T.PerExtraEnemy
	score += T.Role[ctx.role] or 0
	score += ctx.aggression * T.AggressionPenalty
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
	local T = Tuning.Plant
	local score = T.Base + ctx.decisiveness * T.DecisivenessBonus
	if Zones.hasTag(ctx.zoneKey, "plant") then
		score += T.OnSiteBonus
	end
	if ctx.contact then
		local hops = Zones.hops(ctx.zoneKey, ctx.contact.zoneKey)
		if hops <= 2 then
			score += T.HotSitePenalty
		else
			score += T.ContactPenalty
		end
	end
	return score
end

-- RETAKE STRUCTURE: only the two CLOSEST defenders take the defuse itself;
-- everyone else rotates in as the trade wave (driven by the plant contact).
local function scoreDefuse(ctx: Context): number
	if ctx.side ~= "Defense" or not MatchState.planted then
		return -1
	end
	local T = Tuning.Defuse
	local score = T.Base + ctx.gameSense * T.GameSenseBonus
	if ctx.closerToSite >= 2 then
		score += T.SupportWavePenalty
	end
	if ctx.zoneKey == MatchState.plantedZoneKey then
		score += T.OnSiteBonus
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

-- ---------------------------------------------------------------------------
-- SAMPLER. 1. The ground a point stands on is never an obstruction. 2. Bots
-- never veto ground for bots — but destinations keep PERSONAL_SPACE from
-- living teammates. 3. Failure speaks: the rejecting part's name is logged.
-- ---------------------------------------------------------------------------
local function standableReason(point: Vector3, ignore: Model): (boolean, string?)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }

	local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), params)
	if not hit then
		return false, "no ground"
	end
	if math.abs(hit.Position.Y + 0.5 - point.Y) > GROUND_TOLERANCE then
		return false, "off-height"
	end

	local parts = workspace:GetPartBoundsInRadius(hit.Position + Vector3.new(0, 2.5, 0), CLEARANCE_RADIUS)
	for _, part in parts do
		if part.CanCollide
			and part ~= hit.Instance -- the floor beneath you is not an obstruction
			and not part:IsDescendantOf(ignore)
			and not isBotPart(part)
		then
			return false, part:GetFullName()
		end
	end
	return true, nil
end

local function crowdClear(point: Vector3, allies: { any }?, selfBot: any): boolean
	if not allies then
		return true
	end
	for _, ally in allies do
		if ally == selfBot then
			continue
		end
		local allyModel = ally.model
		if not allyModel or not allyModel.Parent then
			continue
		end
		local allyHumanoid = allyModel:FindFirstChildOfClass("Humanoid")
		if not allyHumanoid or allyHumanoid.Health <= 0 then
			continue
		end
		local allyRoot = allyModel:FindFirstChild("HumanoidRootPart") :: BasePart?
		if allyRoot then
			local flat = Vector3.new(allyRoot.Position.X, point.Y, allyRoot.Position.Z)
			if (flat - point).Magnitude < PERSONAL_SPACE then
				return false
			end
		end
	end
	return true
end

-- Ground-only validation for AUTHORED positions (cover points hug their own
-- cover by design; a clearance sphere vetoes all of them).
local function hasGround(point: Vector3, ignore: Model): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }
	local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), params)
	return hit ~= nil and math.abs(hit.Position.Y + 0.5 - point.Y) <= GROUND_TOLERANCE
end

-- Random samples, then center-LINE samples at the LOCAL ground height, then
-- the zone center. Returns the point, or nil plus the last rejection reason.
local function standablePointIn(
	key: string,
	rng: Random,
	ignore: Model,
	fromPos: Vector3?,
	allies: { any }?,
	selfBot: any
): (Vector3?, string?)
	local lastReason: string? = nil
	local function try(point: Vector3?): Vector3?
		if not point then
			return nil
		end
		local ok, reason = standableReason(point, ignore)
		if not ok then
			lastReason = reason
			return nil
		end
		if not crowdClear(point, allies, selfBot) then
			lastReason = "a teammate is standing there"
			return nil
		end
		return point
	end

	for _ = 1, CANDIDATES do
		local point = try(Zones.samplePoint(key, rng))
		if point then
			return point, nil
		end
	end
	local center = Zones.center(key)
	if not center then
		return nil, "unknown zone"
	end
	if fromPos then
		for _, t in { 0.25, 0.5, 0.75 } do
			local along = fromPos + (center - fromPos) * t
			-- ride the LOCAL ground; the destination's height belongs to the deck
			local point = try(Vector3.new(along.X, fromPos.Y, along.Z))
			if point then
				return point, nil
			end
		end
	end
	local point = try(center)
	return point, lastReason
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

-- COVER. Pick the declared cover point whose watch direction best matches the
-- threat, across the bot's cover zone set, skipping points claimed by a
-- living teammate — with a role affinity bump (the plan says WHERE, the role
-- says how it stands there).
local function pickCoverPoint(ctx: Context, allies: { any }): (any?, Vector3?)
	local zones = ctx.coverZoneSet or { ctx.zoneKey }
	local affinity = ROLE_ZONE_AFFINITY[ctx.role]
	local best: any = nil
	local bestFace: Vector3? = nil
	local bestScore = -0.2
	for _, point in Greybox.coverPoints do
		if not table.find(zones, point.zone) then
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
		if affinity then
			for tag, bonus in affinity do
				if Zones.hasTag(point.zone, tag) then
					score += bonus
				end
			end
		end
		if score > bestScore then
			best = point
			bestFace = face
			bestScore = score
		end
	end
	return best, bestFace
end

-- Smooth facing for angle holds. Combat owns its own turn rate and its
-- accuracy coupling; this is the watch-line version.
local function faceTowardSmooth(root: BasePart, dir: Vector3, dt: number)
	local currentYaw = math.atan2(-root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
	local desiredYaw = math.atan2(-dir.X, -dir.Z)
	local delta = (desiredYaw - currentYaw + math.pi) % (math.pi * 2) - math.pi
	local maxStep = math.rad(HOLD_TURN_DEG_PER_SEC) * dt
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, currentYaw + math.clamp(delta, -maxStep, maxStep), 0)
end

-- HOLD THE ANGLE. Walk to the point, turn onto the watch line smoothly, then
-- jiggle-peek — or occasionally SWING wide.
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
			if root then
				faceTowardSmooth(root, faceDir, 0.25)
			end
			task.wait(0.25)
		end

		-- Jiggle or swing? Swings are rare and committed.
		local swinging = rng:NextNumber() < SWING_CHANCE
		local peekDistance = if swinging then SWING_STUDS elseif cover.kind == "partial" then 4 else 5
		local peekPos = cover.pos + perp * peekDistance
		if not hasGround(peekPos, model) then
			peekPos = cover.pos - perp * peekDistance
		end
		if not hasGround(peekPos, model) then
			continue
		end
		if swinging and Scenario.VerboseBrain then
			print(("[CLUTCH] %6.1fs  SWING %s swings wide off %s"):format(clock(), bot.name, cover.name))
		end
		if Pathing.walkToWithResult(model, peekPos, shouldInterrupt) ~= "arrived" then
			return true
		end
		local checkUntil = clock() + (if swinging then 0.45 else 0.7)
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
	-- Post-plant attackers take the site web (site + heaven + short), not a
	-- spot in the open.
	if MatchState.planted and ctx.coverZoneSet then
		if table.find(ctx.coverZoneSet, ctx.zoneKey) then
			return nil
		end
		return nearestOf(ctx.coverZoneSet, ctx.zoneKey, ctx.side)
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
		local lastSampleDiagAt = -math.huge
		local lastCalloutAt: { [string]: number } = {}
		local lastDamageSeen = combatState.lastDamagedAt or 0
		local lastApproachPeekAt = -math.huge

		-- Radio a contact to every living teammate. They receive it as a
		-- SOUND-class memory carrying the RECEIVER's range to it — and it never
		-- overwrites a teammate's fresher own-eyes sighting.
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
					local allyRoot = ally.model and ally.model:FindFirstChild("HumanoidRootPart") :: BasePart?
					if allyPerception and allyHumanoid and allyHumanoid.Health > 0 and allyRoot then
						local existing = allyPerception.memory[contact.name]
						if existing and existing.source == "sight" and existing.seenAt >= contact.seenAt - 0.5 then
							continue -- their eyes beat my radio
						end
						allyPerception.memory[contact.name] = {
							name = contact.name,
							pos = contact.pos,
							zoneKey = contact.zoneKey,
							zoneCallout = contact.zoneCallout,
							seenAt = clock(),
							source = "sound", -- the radio is approximate, deliberately
							distance = (contact.pos - allyRoot.Position).Magnitude,
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
			if not phaseIsLive(side) then
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

			-- The barrier phase: defenders live during Buy; attackers sleep frozen.
			if not phaseIsLive(side) then
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

			-- THE PLANT IS LOUD. Every defender hears it: a standing sound contact
			-- at the planted site, so Rotate drives the trade wave while the two
			-- closest defenders take the defuse itself.
			if side == "Defense" and MatchState.planted and MatchState.plantedZoneKey then
				local spikeZone = Zones.byKey[MatchState.plantedZoneKey]
				local spikePos = if MatchState.spikePart
					then MatchState.spikePart.Position
					elseif spikeZone then Zones.center(MatchState.plantedZoneKey)
					else nil
				if spikePos then
					perception.memory["the spike"] = {
						name = "the spike",
						pos = spikePos,
						zoneKey = MatchState.plantedZoneKey,
						zoneCallout = if spikeZone then spikeZone.callout else "the site",
						seenAt = now,
						source = "sound",
						distance = (spikePos - ground).Magnitude,
					}
					perception.lastContactAt = now
				end
			end

			local assessment = nil
			if visible then
				assessment = Combat.assess(bot, weapon, visible, enemies, currentKey, combatState, now)
			end

			local allyZones = {}
			local alliesNear = 0
			local closerToSite = 0
			local myHopsToSite = math.huge
			if side == "Defense" and MatchState.planted and MatchState.plantedZoneKey then
				myHopsToSite = hopsSafe(currentKey, MatchState.plantedZoneKey, side)
			end
			for _, ally in allies do
				if ally == bot or not ally.model.Parent then
					continue
				end
				local allyHumanoid = ally.model:FindFirstChildOfClass("Humanoid")
				if not allyHumanoid or allyHumanoid.Health <= 0 then
					continue -- the dead do not count as company
				end
				local allyGround = Zones.groundOf(ally.model)
				local allyKey = Zones.keyAt(allyGround)
				table.insert(allyZones, allyKey)
				if (allyGround - ground).Magnitude <= ALLY_CROWD_STUDS then
					alliesNear += 1
				end
				if myHopsToSite ~= math.huge then
					if hopsSafe(allyKey, MatchState.plantedZoneKey, side) < myHopsToSite then
						closerToSite += 1
					end
				end
			end

			local enemiesNear = 0
			for _, memoryContact in perception.memory do
				if memoryContact.name == "the spike" then
					continue -- the objective is not a threat count
				end
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

			-- Post-plant attackers spread across the site web, not a spot in the
			-- open: the planted site + its heaven + its short.
			local coverZoneSet: { string }? = nil
			if MatchState.planted and side == "Attack" and MatchState.plantedZoneKey then
				local pz = MatchState.plantedZoneKey
				coverZoneSet = {
					pz,
					if pz == "A_SITE" then "A_HEAVEN" else "B_HEAVEN",
					if pz == "A_SITE" then "A_SHORT" else "B_SHORT",
				}
			end

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
				closerToSite = closerToSite,
				coverZoneSet = coverZoneSet,
			}

			local scores: { [string]: number } = {}
			for _, name in INTENTS do
				scores[name] = SCORERS[name](ctx)
			end

			local winner = intent
			local winnerScore = scores[intent]
			for _, name in INTENTS do
				local margin = if name == "Engage" then 0 else Tuning.Hysteresis
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
						local spot = standablePointIn(currentKey, rng, model, ground, allies, bot)
						if spot then
							Pathing.walkToWithResult(model, spot, shouldInterrupt)
						end
						task.wait(rng:NextNumber(0.6, 1.4))
					end
				else
					-- THE INFO DOCTRINE, approach half: check the angle before you
					-- cross it. Fires on decaying contacts within 2 hops, or simply
					-- because the next zone is a choke (check corners). Cooldown-
					-- gated so a rotation can't stall.
					local contactClose = contact ~= nil
						and now - contact.seenAt < SimConfig.MemoryDecaySeconds
						and hopsSafe(currentKey, contact.zoneKey, side) <= APPROACH_PEEK_HOPS
					local chokeAhead = routeKey ~= nil and Zones.hasTag(routeKey, "choke")
					if (intent == "Push" or intent == "Rotate" or intent == "Lurk")
						and (contactClose or chokeAhead)
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
						local spot, sampleReason
						if retrieving then
							local spikePos = MatchState.spikePart.Position
							spot = Vector3.new(spikePos.X, 1, spikePos.Z)
							local ok, reason = standableReason(spot, model)
							if not ok then
								sampleReason = reason
								spot = nil
							end
						else
							spot, sampleReason = standablePointIn(routeKey, rng, model, ground, allies, bot)
						end

						if spot then
							local result = Pathing.walkToWithResult(model, spot, shouldInterrupt)
							if result == "failed" then
								routeKey = nil
								task.wait(SimConfig.DecisionTickSeconds * 2)
							end
						else
							-- The sampler used to fail SILENTLY (the "via nil" stalls).
							if now - lastSampleDiagAt > SAMPLE_DIAG_SECONDS then
								lastSampleDiagAt = now
								warn(("[CLUTCH] SAMPLE %s: no standable point in %s — last rejection: %s"):format(
									bot.name,
									tostring(routeKey),
									tostring(sampleReason)
								))
							end
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
