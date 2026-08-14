--!strict
-- Bot brain v3.1: score every intent, commit to the winner, act on it — now
-- with the round in the loop and survival instincts that actually fire.
--
-- Utility AI rather than a state machine, because a state machine hides its
-- reasoning. Every tick produces a full score vector and the log prints it,
-- so a bad decision can be traced to the term that caused it.
--
-- ---------------------------------------------------------------------------
-- Fixed after the first 1v1 transcript: MID_BACK is not an anchor; intent
-- scores live in a comparable band; Push has a terminal condition; the stall
-- ramp resets only on a finished goal or contact.
-- Fixed after the second: ROUTE COMMITMENT — one intermediate zone until the
-- zone actually changes, no boundary churn.
-- Fixed after playtest #8:
--   * ENGAGE BYPASSES HYSTERESIS. Push-with-carrier-bonus scored 0.94 while a
--     forced Engage sat at 0.88 — under the 0.08 hysteresis margin Ace kept
--     walking toward A Site while Onyx shot him five times. Being shot at now
--     outranks momentum, exactly like it outranks the commitment gate.
--   * STICKY SITE/ANCHOR PICKS. Both sites are 4 hops from both spawns, so
--     "nearest" always resolved to A. Every round each bot rolls a site (ATK)
--     or anchor (DEF) once and commits; RoundMachine clears the pick between
--     rounds. Routes now vary.
--   * PLANT RESPECTS A HOT SITE. A contact within 2 hops of the plant zone
--     costs Plant 0.45 instead of 0.25 — clear first, plant after. And the
--     channel itself aborts when an enemy becomes visible (see Objective).
--   * Brains sleep during Buy/PostRound. Frozen bodies trying to path was the
--     source of the between-round BLOCKED spam.
-- ---------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local SimConfig = require(Shared.Constants.SimConfig)
local Scenario = require(Shared.Constants.Scenario)
local Zones = require(Shared.MapData.Zones)

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
-- Walk whole routes, not two-hop legs. Interrupts (combat) still poll every
-- 0.3s inside the walk, so long walks no longer mean slow reactions — and the
-- full stop at every zone boundary was the worst of the movement jank.
local DIRECT_WALK_MAX_HOPS = 6
local INTERRUPT_RECHECK = 0.3 -- seconds between combat interrupt polls

-- Role priors. Kept in the same band as the situational terms on purpose: a
-- role should bias a decision, never decide it outright.
local HOLD_ROLE = { Anchor = 0.30, Sniper = 0.23, Support = 0.10, IGL = 0.07, Lurker = 0.03, Entry = 0.00 }
local PUSH_ROLE = { Entry = 0.25, Support = 0.11, IGL = 0.08, Lurker = 0.06, Sniper = 0.03, Anchor = 0.00 }
local LURK_ROLE = { Lurker = 0.30, Sniper = 0.09, Support = 0.03, IGL = 0.03, Entry = 0.00, Anchor = 0.00 }

local SITES = { "A_SITE", "B_SITE" }

-- MID_BACK deliberately absent. Including it made a corridor an acceptable
-- anchor, which is how a defender ended up holding nothing for 84 seconds.
local DEF_HOLDS = { "A_SITE", "A_HEAVEN", "B_SITE", "B_HEAVEN" }
local ATK_FORWARD = { "MID", "MID_LEDGE", "A_LOBBY", "B_LOBBY", "A_ELBOW", "B_ELBOW" }
local DEF_FORWARD = { "MID", "MID_LEDGE", "MID_WINDOW", "A_SHORT", "B_SHORT" }
local FLANKS = { "A_MAIN", "B_MAIN", "A_ELBOW", "B_ELBOW" }

local INTENTS = { "Hold", "Push", "Rotate", "Lurk", "Engage", "Plant", "Defuse" }

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
}

local function clamp01(n: number): number
	return math.clamp(n, 0, 1)
end

-- Nearest zone from a list, never the one we are standing in.
local function nearestOf(keys: { string }, from: string): string?
	local best: string? = nil
	local bestHops = math.huge
	for _, key in keys do
		if key == from then
			continue
		end
		local hops = Zones.hops(from, key)
		if hops < bestHops then
			best = key
			bestHops = hops
		end
	end
	return best
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
	-- The carrier's job is the site; a dropped spike is everyone's job.
	if ctx.side == "Attack" and not MatchState.planted then
		if MatchState.spikeCarrier == ctx.bot then
			score += 0.15
		elseif MatchState.spikeCarrier == nil and MatchState.spikePart then
			score += 0.20 -- go get it
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
	Engage = scoreEngage,
	Plant = scorePlant,
	Defuse = scoreDefuse,
}

-- Can a humanoid actually stand here? Sampling a zone rectangle blindly puts
-- destinations inside crates and off deck edges; every PATH FAILED in an earlier
-- playtest traced back to skipping this check.
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

local function standablePointIn(key: string, rng: Random, ignore: Model): Vector3?
	for _ = 1, CANDIDATES do
		local candidate = Zones.samplePoint(key, rng)
		if candidate and isStandable(candidate, ignore) then
			return candidate
		end
	end
	return Zones.center(key)
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

local function resolveTarget(intent: string, ctx: Context, allyZones: { string }, rng: Random): string?
	if intent == "Engage" then
		return nil -- stand and fight
	elseif intent == "Plant" then
		if Zones.hasTag(ctx.zoneKey, "plant") then
			return nil -- channel in place
		end
		return ctx.bot.siteChoice or nearestOf(SITES, ctx.zoneKey)
	elseif intent == "Defuse" then
		return MatchState.plantedZoneKey
	elseif intent == "Rotate" then
		return if ctx.contact then ctx.contact.zoneKey else nil
	elseif intent == "Push" then
		if ctx.side == "Attack" then
			-- A dropped spike outranks map control: walk to where it fell.
			if not MatchState.planted and MatchState.spikeCarrier == nil and MatchState.spikePart then
				return Zones.keyAt(MatchState.spikePart.Position)
			end
			-- Both sites are 4 hops from spawn, so "nearest" always resolved to A.
			-- The per-round sticky pick is what makes routes vary.
			return ctx.bot.siteChoice or nearestOf(SITES, ctx.zoneKey)
		end
		return nearestOf(DEF_FORWARD, ctx.zoneKey)
	elseif intent == "Lurk" then
		return pickLurkZone(ctx, allyZones)
	end

	-- Hold
	if ctx.side == "Defense" then
		if ctx.onAnchor then
			return nil -- already somewhere worth holding
		end
		return ctx.bot.holdChoice or nearestOf(DEF_HOLDS, ctx.zoneKey)
	end
	if Zones.hasTag(ctx.zoneKey, "site") or Zones.hasTag(ctx.zoneKey, "choke") or Zones.hasTag(ctx.zoneKey, "heaven") then
		return nil
	end
	return nearestOf(ATK_FORWARD, ctx.zoneKey)
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

		-- Cached interrupt predicate. Polled every pathing tick, so it must be
		-- cheap; hasEyesOn casts rays, hence the recheck window.
		local interruptCheckedAt = -math.huge
		local interruptAnswer = false
		local function shouldInterrupt(): boolean
			local now = clock()
			if now - interruptCheckedAt < INTERRUPT_RECHECK then
				return interruptAnswer
			end
			interruptCheckedAt = now
			interruptAnswer = false
			local visible = Perception.visibleContact(perception)
			if visible then
				local here = Zones.keyAt(Zones.groundOf(model))
				local assessment = Combat.assess(bot, weapon, visible, enemies, here, combatState, now)
				interruptAnswer = assessment.engage
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
			-- (Frozen-walk stalls were the between-round BLOCKED spam.)
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

			-- A dropped spike is picked up by walking over it
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
				local allyGround = Zones.groundOf(ally.model)
				table.insert(allyZones, Zones.keyAt(allyGround))
				if (allyGround - ground).Magnitude <= ALLY_CROWD_STUDS then
					alliesNear += 1
				end
			end

			-- Anti-stall. Deliberately NOT reset by ordinary walking: resetting on
			-- every hop turned this into a metronome and produced a two-zone
			-- ping-pong every 25 seconds.
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

			-- Commitment stops intent chatter, but being shot at — or a live
			-- objective — outranks it.
			if winner ~= intent and winner ~= "Engage" and winner ~= "Plant" and winner ~= "Defuse" then
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

			-- Sticky per-round picks: same-site-every-round was a tie-break
			-- accident, not a personality. RoundMachine clears these between rounds.
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

			-- Print on change, and periodically even without one. A bot locked to a
			-- single intent used to produce no reasoning output whatsoever.
			if Scenario.VerboseBrain and (switched or now - lastThinkLogAt >= Scenario.BrainHeartbeatSeconds) then
				lastThinkLogAt = now
				local transition = if switched then ("%s -> %s"):format(previous, intent) else ("%s (steady)"):format(intent)
				print(("[CLUTCH] %6.1fs  THINK %s (%s) %s | %s | in %s | target %s | %s | ramp %.2f"):format(
					now,
					bot.name,
					if side == "Attack" then "ATK" else "DEF",
					transition,
					formatScores(scores),
					Zones.byKey[currentKey] and Zones.byKey[currentKey].callout or currentKey,
					if targetKey and Zones.byKey[targetKey] then Zones.byKey[targetKey].callout else "hold position",
					describeContact(contact, now),
					decisiveness
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
					-- Settle into the zone we already want to be in. Short dwell: the
					-- old 1.5-3.5s wait read as aimless shuffling.
					routeKey = nil
					local spot = standablePointIn(currentKey, rng, model)
					if spot then
						Pathing.walkToWithResult(model, spot, shouldInterrupt)
					end
					task.wait(rng:NextNumber(0.6, 1.4))
				else
					-- ROUTE COMMITMENT. The arrive radius lets a walk end just inside
					-- the OLD zone; re-deciding from scratch then picked a different
					-- neighbour and produced the A Site -> A Ramp -> A Site churn.
					-- Commit to ONE intermediate zone until the zone actually changes.
					if routeKey == nil then
						local hops = Zones.hops(currentKey, targetKey)
						routeKey = if hops > DIRECT_WALK_MAX_HOPS
							then (Zones.nextHop(currentKey, targetKey) or targetKey)
							else targetKey
					end

					if currentKey == routeKey then
						-- Crossed into the committed zone: leg complete.
						if routeKey == targetKey then
							lastProgressAt = clock() -- only a FINISHED goal resets the ramp
						end
						routeKey = nil
					else
						local spot = standablePointIn(routeKey, rng, model)
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
