--!strict
-- BrainCore: the brain's JUDGMENT half — types, constants, routing, team
-- intel, and every intent scorer. Split from Brain.luau (the runtime loop)
-- at v4.4: one module decides WHAT scores mean, the other decides what the
-- bot DOES about it this tick. (Also: two 24KB pushes land reliably; one
-- 46KB push was eating transport errors.)
--
-- Everything here is pure functions over the Context + shared state — no
-- per-bot runtime locals live here. Brain.luau requires this module; nothing
-- here requires Brain (teamPressure takes the perceptions registry as an
-- argument, which keeps the graph acyclic).
--
-- TURNING IS PHYSICS-SAFE (playtest #17): direct CFrame writes on a WALKING
-- HumanoidRootPart stomp the humanoid mover — the v4.4 facing loop wrote at
-- 12.5Hz mid-walk and every walk in the match went BLOCKED. Rigs now carry
-- an AlignOrientation ("AimAlign"); turnToward points its target and caps
-- its angular velocity. Torque turns the body; the feet keep walking.
--
-- v4.5 (playtest #18): Hold takes SpikeDownAttackPenalty for attackers while
-- the spike is down — you can't hold a site the spike isn't at.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local SimConfig = require(Shared.Constants.SimConfig)
local Zones = require(Shared.MapData.Zones)
local Greybox = require(Shared.MapData.Greybox)
local Tuning = require(Shared.Constants.BrainTuning)

local MatchState = require(script.Parent.MatchState)

local BrainCore = {}

-- Constants shared with the runtime loop
BrainCore.K = {
	CANDIDATES = 6,
	CLEARANCE_RADIUS = 2.6,
	GROUND_TOLERANCE = 2.5,
	ALLY_CROWD_STUDS = 25,
	PERSONAL_SPACE = 6, -- sampled destinations keep this much room per teammate
	DIRECT_WALK_MAX_HOPS = 6,
	FRESH_CONTACT_SECONDS = 6,
	ENEMY_NEAR_HOPS = 2,
	HOLD_TURN_DEG_PER_SEC = 360, -- angle-hold / idle facing cap (combat's is faster)
	PRESSURE_FRESH_SECONDS = 5, -- a contact older than this is not pressure
}

BrainCore.INTENTS = { "Hold", "Push", "Rotate", "Lurk", "FallBack", "Engage", "Plant", "Defuse" }

local SITES = { "A_SITE", "B_SITE" }
BrainCore.SITES = SITES

-- MID_BACK deliberately absent. Including it made a corridor an acceptable
-- anchor, which is how a defender ended up holding nothing for 84 seconds.
local DEF_HOLDS = { "A_SITE", "A_HEAVEN", "B_SITE", "B_HEAVEN" }
BrainCore.DEF_HOLDS = DEF_HOLDS
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

export type Pressure = { [string]: { [string]: boolean } }

export type Context = {
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
	pressure: Pressure,
	spikeDown: boolean,
	spikeZoneKey: string?,
	guardRank: number,
}

local function clamp01(n: number): number
	return math.clamp(n, 0, 1)
end

-- The barrier phase: defenders are live during Buy (deploying to their
-- holds); attackers sleep frozen until LIVE.
function BrainCore.phaseIsLive(side: string): boolean
	return MatchState.phase == "Live"
		or MatchState.phase == "Planted"
		or (MatchState.phase == "Buy" and side == "Defense")
end

-- ---------------------------------------------------------------------------
-- TEAM PRESSURE. Pool every living teammate's fresh memory into a per-zone
-- set of DISTINCT confirmed enemies. One shoulder is a bait; two is a hit.
-- ---------------------------------------------------------------------------
function BrainCore.teamPressure(allies: { any }, perceptions: { [string]: any }, now: number): Pressure
	local pressure: Pressure = {}
	for _, ally in allies do
		local allyPerception = perceptions[ally.name]
		local allyHumanoid = ally.model and ally.model:FindFirstChildOfClass("Humanoid")
		if not allyPerception or not allyHumanoid or allyHumanoid.Health <= 0 then
			continue
		end
		for enemyName, memoryContact in allyPerception.memory do
			if enemyName ~= "the spike" and now - memoryContact.seenAt <= BrainCore.K.PRESSURE_FRESH_SECONDS then
				local atZone = pressure[memoryContact.zoneKey]
				if not atZone then
					atZone = {}
					pressure[memoryContact.zoneKey] = atZone
				end
				atZone[enemyName] = true
			end
		end
	end
	return pressure
end

function BrainCore.pressureCount(pressure: Pressure, zoneKey: string): number
	local names = pressure[zoneKey]
	if not names then
		return 0
	end
	local count = 0
	for _ in names do
		count += 1
	end
	return count
end

-- ---------------------------------------------------------------------------
-- SAFE ROUTING. BFS over the zone graph that refuses to pass through deep
-- enemy territory. The destination itself is exempt.
-- ---------------------------------------------------------------------------
function BrainCore.hopsSafe(from: string, to: string, side: string): number
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

function BrainCore.nextHopSafe(from: string, to: string, side: string): string?
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
		local dist = BrainCore.hopsSafe(neighbour, to, side)
		if dist < bestDist then
			best = neighbour
			bestDist = dist
		end
	end
	return best
end

function BrainCore.nearestOf(keys: { string }, from: string, side: string): string?
	local best: string? = nil
	local bestHops = math.huge
	for _, key in keys do
		if key == from then
			continue
		end
		local hops = BrainCore.hopsSafe(from, key, side)
		if hops < bestHops then
			best = key
			bestHops = hops
		end
	end
	return best
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
	-- Guarding the dropped spike IS defending it.
	if ctx.spikeDown and ctx.spikeZoneKey and ctx.zoneKey == ctx.spikeZoneKey then
		score += T.SpikeGuardBonus
	end
	-- An attacker can't hold a site the spike isn't at (playtest #18 round 4:
	-- three of them parked on B for 70s while the spike lay in A Lobby).
	if ctx.side == "Attack" and ctx.spikeDown then
		score += T.SpikeDownAttackPenalty
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
	-- A site WITHOUT the spike is not an objective. The at-objective penalty
	-- is waived while the spike is down — #15 round 4's 70-second freeze.
	if ctx.atObjective and not ctx.spikeDown then
		score += T.AtObjectivePenalty
	end
	if ctx.side == "Attack" and not MatchState.planted then
		if MatchState.spikeCarrier == ctx.bot then
			score += T.CarrierBonus
			-- CARRIER DISCIPLINE: alone with a fresh nearby contact, the spike
			-- does not entry-frag. Let the team catch up.
			if ctx.alliesNear == 0 and ctx.contact and Zones.hops(ctx.zoneKey, ctx.contact.zoneKey) <= BrainCore.K.ENEMY_NEAR_HOPS then
				score += T.CarrierAloneHotPenalty
			end
		elseif MatchState.spikeCarrier == nil and MatchState.spikePart then
			-- Recovery — but cautiously: a spike in a known-hot zone is a trap.
			local hot = ctx.contact and ctx.contact.zoneKey == ctx.spikeZoneKey and ctx.contact.source == "sight"
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
	-- CONFIRMATION GATE (defense): rotate on a confirmed hit — 2+ distinct
	-- fresh contacts at the area — not on a one-man bait. Post-plant the
	-- objective itself is confirmation enough.
	if ctx.side == "Defense" and not MatchState.planted then
		local count = BrainCore.pressureCount(ctx.pressure, ctx.contact.zoneKey)
		if count >= 2 then
			score += T.PressureBonus
		elseif count <= 1 then
			score += T.BaitPenalty
		end
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

-- THE DEFUSE IS A SOLO JOB: only the single CLOSEST living defender takes
-- the channel; everyone else rotates in as the guard ring.
local function scoreDefuse(ctx: Context): number
	if ctx.side ~= "Defense" or not MatchState.planted then
		return -1
	end
	local T = Tuning.Defuse
	local score = T.Base + ctx.gameSense * T.GameSenseBonus
	if ctx.closerToSite >= 1 then
		score += T.SupportWavePenalty
	end
	if ctx.zoneKey == MatchState.plantedZoneKey then
		score += T.OnSiteBonus
	end
	return score
end

BrainCore.SCORERS = {
	Hold = scoreHold,
	Push = scorePush,
	Rotate = scoreRotate,
	Lurk = scoreLurk,
	FallBack = scoreFallBack,
	Engage = scoreEngage,
	Plant = scorePlant,
	Defuse = scoreDefuse,
} :: { [string]: (Context) -> number }

-- ---------------------------------------------------------------------------
-- SAMPLER. 1. The ground a point stands on is never an obstruction. 2. Bots
-- never veto ground for bots — but destinations keep PERSONAL_SPACE from
-- living teammates. 3. Failure speaks: the rejecting part's name is logged.
-- ---------------------------------------------------------------------------
local function isBotPart(part: BasePart): boolean
	local ancestor = part:FindFirstAncestorOfClass("Model")
	return ancestor ~= nil and ancestor:GetAttribute("ClutchBot") == true
end

function BrainCore.standableReason(point: Vector3, ignore: Model): (boolean, string?)
	local K = BrainCore.K
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }

	local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), params)
	if not hit then
		return false, "no ground"
	end
	if math.abs(hit.Position.Y + 0.5 - point.Y) > K.GROUND_TOLERANCE then
		return false, "off-height"
	end

	local parts = workspace:GetPartBoundsInRadius(hit.Position + Vector3.new(0, 2.5, 0), K.CLEARANCE_RADIUS)
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
			if (flat - point).Magnitude < BrainCore.K.PERSONAL_SPACE then
				return false
			end
		end
	end
	return true
end

-- Ground-only validation for AUTHORED positions (cover points hug their own
-- cover by design; a clearance sphere vetoes all of them).
function BrainCore.hasGround(point: Vector3, ignore: Model): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ignore }
	local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), params)
	return hit ~= nil and math.abs(hit.Position.Y + 0.5 - point.Y) <= BrainCore.K.GROUND_TOLERANCE
end

-- Random samples, then center-LINE samples at the LOCAL ground height, then
-- the zone center. Returns the point, or nil plus the last rejection reason.
function BrainCore.standablePointIn(
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
		local ok, reason = BrainCore.standableReason(point, ignore)
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

	for _ = 1, BrainCore.K.CANDIDATES do
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
function BrainCore.pickCoverPoint(ctx: Context, allies: { any }): (any?, Vector3?)
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

-- PHYSICS-SAFE TURNING. Point the rig's AlignOrientation at the target and
-- cap its angular velocity — torque turns the body at a human rate while the
-- feet keep walking. Returns the remaining angular error (radians) so a
-- shooter pays for however far the body still has to swing.
function BrainCore.turnToward(_bot: any, root: BasePart, targetPos: Vector3, maxRateDegPerSec: number): number
	local flat = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z)
	local toTarget = flat - root.Position
	if toTarget.Magnitude < 0.1 then
		return 0
	end
	local currentYaw = math.atan2(-root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
	local desiredYaw = math.atan2(-toTarget.X / toTarget.Magnitude, -toTarget.Z / toTarget.Magnitude)
	local ao = root:FindFirstChild("AimAlign") :: AlignOrientation?
	if ao then
		ao.MaxAngularVelocity = math.rad(maxRateDegPerSec)
		ao.CFrame = CFrame.Angles(0, desiredYaw, 0)
	end
	local delta = (desiredYaw - currentYaw + math.pi) % (math.pi * 2) - math.pi
	return math.abs(delta)
end

-- Where should an idle bot LOOK? At the freshest contact if there is one,
-- else toward the enemy's half. Never the wall.
function BrainCore.threatFaceDir(side: string, contact: any, fromPos: Vector3): Vector3
	if contact then
		local dir = (contact.pos - fromPos) * Vector3.new(1, 0, 1)
		if dir.Magnitude > 0.1 then
			return dir.Unit
		end
	end
	return if side == "Defense" then Vector3.zAxis else -Vector3.zAxis
end

-- The target-zone decider. resolveTarget only maps an intent to a ZONE;
-- the runtime loop owns the walking.
function BrainCore.resolveTarget(intent: string, ctx: Context, allyZones: { string }, rng: Random): string?
	if intent == "Engage" then
		return nil
	elseif intent == "Plant" then
		if Zones.hasTag(ctx.zoneKey, "plant") then
			return nil
		end
		return ctx.bot.siteChoice or BrainCore.nearestOf(SITES, ctx.zoneKey, ctx.side)
	elseif intent == "Defuse" then
		return MatchState.plantedZoneKey
	elseif intent == "FallBack" then
		return BrainCore.nearestOf(SAFE_ZONES[ctx.side], ctx.zoneKey, ctx.side)
	elseif intent == "Rotate" then
		return if ctx.contact then ctx.contact.zoneKey else nil
	elseif intent == "Push" then
		if ctx.side == "Attack" then
			-- The dropped spike outranks any site assignment: the round is
			-- un-winnable without it — but you can only walk to a mark you HAVE.
			if not MatchState.planted and MatchState.spikeCarrier == nil and MatchState.spikePart and ctx.spikeZoneKey then
				return ctx.spikeZoneKey
			end
			return ctx.bot.siteChoice or BrainCore.nearestOf(SITES, ctx.zoneKey, ctx.side)
		end
		return BrainCore.nearestOf(DEF_FORWARD, ctx.zoneKey, ctx.side)
	elseif intent == "Lurk" then
		return pickLurkZone(ctx, allyZones)
	end

	-- Hold
	if ctx.side == "Defense" then
		-- GUARD THE DROP: a dropped spike is a third site. The two closest
		-- living defenders sit on it; everyone else keeps their assignments.
		-- (Defenders with no spike MARK keep their assignment — you can't
		-- guard a drop you don't know about.)
		if ctx.spikeDown and ctx.spikeZoneKey then
			if ctx.zoneKey == ctx.spikeZoneKey then
				return nil -- on guard
			end
			if ctx.guardRank < 2 then
				return ctx.spikeZoneKey
			end
		end
		if ctx.onAnchor then
			return nil
		end
		return ctx.bot.holdChoice or BrainCore.nearestOf(DEF_HOLDS, ctx.zoneKey, ctx.side)
	end
	-- Post-plant attackers take the site web (site + heaven + short), not a
	-- spot in the open.
	if MatchState.planted and ctx.coverZoneSet then
		if table.find(ctx.coverZoneSet, ctx.zoneKey) then
			return nil
		end
		return BrainCore.nearestOf(ctx.coverZoneSet, ctx.zoneKey, ctx.side)
	end
	if Zones.hasTag(ctx.zoneKey, "site") or Zones.hasTag(ctx.zoneKey, "choke") or Zones.hasTag(ctx.zoneKey, "heaven") then
		return nil
	end
	return BrainCore.nearestOf(ATK_FORWARD, ctx.zoneKey, ctx.side)
end

return BrainCore
