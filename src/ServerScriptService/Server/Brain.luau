--!strict
-- Bot brain v4.4: the RUNTIME half. BrainCore.luau owns the judgment
-- (scorers, routing, sampler, cover picks, team pressure, resolveTarget);
-- this module owns what the bot DOES about it each tick: comms, facing,
-- walks, holds, channels, diagnostics.
--
-- v4.4 (playtest #16):
--   * THE FACING LOOP. AutoRotate is off — the legs no longer own the eyes.
--     The brain leaves a facePoint every tick (a visible enemy, a fresh
--     contact, the waypoint, the watch line, the threat direction) and a
--     dedicated loop turns toward it at the hold rate. Combat owns facing
--     mid-burst (faster, accuracy-coupled). A bot can now watch the flank
--     while it crosses the lane.
--   * SUPPRESSION RIDES THE RADIO: getting pinned by near-misses (Combat
--     stamps it) produces a callout like taking damage does.
--   * HONEST SPIKE MARKS (joined memory): the drop's FACT is public, its
--     LOCATION is per-side intel — attackers heard the carrier die (radio
--     mark from the round machine), defenders must put eyes on the drop.
--     Retrieval and spike-guard both walk to the side's MARK, never the
--     omniscient truth.
--   * Solo-defuser scoring threshold (BrainCore: closerToSite >= 1).
--
-- v4.3 carried: team-pressure confirmation gate, the round-4 retrieval fix,
-- spike guard, deliberate idle facing, anti-train peeks. v4.1/v4.2: barrier
-- phase, sampler rebuild, retake structure, post-plant web, swings, the
-- tuning rack, role affinity. Earlier history in the git log. Style rule:
-- no inner quotes in log strings. Ever. (Brain:772, 2026-08-15.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local SimConfig = require(Shared.Constants.SimConfig)
local Scenario = require(Shared.Constants.Scenario)
local Zones = require(Shared.MapData.Zones)
local Tuning = require(Shared.Constants.BrainTuning)

local Pathing = require(script.Parent.Pathing)
local Perception = require(script.Parent.Perception)
local Combat = require(script.Parent.Combat)
local Telemetry = require(script.Parent.Telemetry)
local Objective = require(script.Parent.Objective)
local MatchState = require(script.Parent.MatchState)
local BrainCore = require(script.Parent.BrainCore)

local Brain = {}

-- Every living brain's perception, keyed by name. Callouts write into these;
-- brains read their own — and the TEAM PRESSURE model reads all of them.
Brain.perceptions = {} :: { [string]: any }

local INTERRUPT_RECHECK = 0.3
local MAX_PEEKS = 3
local SWING_CHANCE = 0.25 -- occasional wide peek; the rest are jiggles
local SWING_STUDS = 9
local INTERRUPT_COMBAT_RANGE = 30
local STALL_LOG_SECONDS = 8
local CALLOUT_COOLDOWN = 4
local APPROACH_PEEK_COOLDOWN = 6
local APPROACH_PEEK_HOPS = 2
local SAMPLE_DIAG_SECONDS = 10

local K = BrainCore.K -- shared constants (freshness windows, hop budgets, spacing)

-- WALK OR SPRINT — the info doctrine's speed half:
local function wantsWalk(intent: string, side: string, currentKey: string, routeKey: string?, contact: any, now: number): boolean
	if intent == "Engage" or intent == "Plant" or intent == "Defuse" then
		return true
	end
	if intent == "Lurk" or intent == "FallBack" then
		return true
	end
	if contact and now - contact.seenAt < K.FRESH_CONTACT_SECONDS then
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

-- HOLD THE ANGLE. Walk to the point, leave the watch line as a facePoint
-- (the facing loop owns the turn), then jiggle-peek — or occasionally SWING.
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
	if not BrainCore.hasGround(cover.pos, model) then
		return false
	end
	local result = Pathing.walkToWithResult(model, cover.pos, shouldInterrupt)
	if result ~= "arrived" then
		return false
	end

	local perp = Vector3.new(-faceDir.Z, 0, faceDir.X)
	bot.facePoint = cover.pos + faceDir * 20

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
			task.wait(0.25)
		end

		-- Jiggle or swing? Swings are rare and committed.
		local swinging = rng:NextNumber() < SWING_CHANCE
		local peekDistance = if swinging then SWING_STUDS elseif cover.kind == "partial" then 4 else 5
		local peekPos = cover.pos + perp * peekDistance
		if not BrainCore.hasGround(peekPos, model) then
			peekPos = cover.pos - perp * peekDistance
		end
		if not BrainCore.hasGround(peekPos, model) then
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

local function formatScores(scores: { [string]: number }): string
	local parts = {}
	for _, intent in BrainCore.INTENTS do
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
	Combat.states[bot.name] = combatState -- incoming fire stamps suppression here

	-- THE FACING LOOP. The brain leaves a facePoint every tick; this loop
	-- turns toward it at the hold rate. Combat owns facing mid-burst (the
	-- 0.4s after a shot); the rest of the time the eyes are the brain's.
	bot.facePoint = nil :: Vector3?
	task.spawn(function()
		while model.Parent do
			local humanoidNow = model:FindFirstChildOfClass("Humanoid")
			if not humanoidNow or humanoidNow.Health <= 0 then
				break
			end
			local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			local target = bot.facePoint :: Vector3?
			if root and target and clock() - combatState.lastShotAt > 0.4 then
				local dir = (target - root.Position) * Vector3.new(1, 0, 1)
				if dir.Magnitude > 0.5 then
					BrainCore.faceTowardSmooth(root, dir.Unit, 0.08)
				end
			end
			task.wait(0.08)
		end
	end)

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
		local lastSuppressSeen = combatState.lastSuppressedAt or -math.huge
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
				print(("[CLUTCH] %6.1fs  CALLOUT %s: %s — %s"):format(now, bot.name, verb, contact.zoneCallout))
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
			if not BrainCore.phaseIsLive(side) then
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
			if not BrainCore.phaseIsLive(side) then
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
			-- fire from a known suspect — and so does getting PINNED by fire
			-- that never lands. Cooldown per enemy.
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
				local suppressedAt = combatState.lastSuppressedAt or -math.huge
				if suppressedAt > lastSuppressSeen then
					lastSuppressSeen = suppressedAt
					if contact then
						shareContact(contact, ("Pinned by %s"):format(contact.name), now)
					end
				end
			end

			if side == "Attack" and not MatchState.planted then
				Objective.tryPickup(bot)
			end

			-- THE PLANT IS LOUD. Every defender hears it: a standing sound contact
			-- at the planted site, so Rotate drives the guard ring while the
			-- single closest defender takes the defuse itself.
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

			-- THE DROPPED SPIKE, honestly. The FACT is public (a carrier died);
			-- WHERE it lies is per-side intel: attackers heard it on the radio,
			-- defenders must put eyes on the drop to mark it.
			local spikeDown = not MatchState.planted and MatchState.spikeCarrier == nil and MatchState.spikePart ~= nil
			local spikeFactZoneKey: string? = nil
			if spikeDown and MatchState.spikePart then
				spikeFactZoneKey = Zones.keyAt(MatchState.spikePart.Position)
			end

			-- EYES ON THE DROP: seeing the dropped spike marks it for your side.
			-- (The spike part is CanQuery=false: LOS means nothing solid sits
			-- between you and it.)
			if spikeDown and MatchState.spikePart and spikeFactZoneKey then
				local toSpike = MatchState.spikePart.Position - ground
				local dist = toSpike.Magnitude
				if dist <= SimConfig.VisionRangeStuds then
					local losParams = RaycastParams.new()
					losParams.FilterType = Enum.RaycastFilterType.Exclude
					losParams.FilterDescendantsInstances = { model }
					local hit = workspace:Raycast(ground, toSpike, losParams)
					local blocked = hit ~= nil and (hit.Position - ground).Magnitude < dist - 1.5
					if not blocked then
						local markField = if side == "Attack" then "spikeMarkAtk" else "spikeMarkDef"
						local existing = MatchState[markField]
						if existing == nil or existing.zoneKey ~= spikeFactZoneKey or now - existing.at > 3 then
							MatchState[markField] = { pos = MatchState.spikePart.Position, zoneKey = spikeFactZoneKey, at = now }
							if Scenario.VerboseBrain then
								print(("[CLUTCH] %6.1fs  CALLOUT %s: spike marked — %s"):format(
									now,
									bot.name,
									if Zones.byKey[spikeFactZoneKey] then Zones.byKey[spikeFactZoneKey].callout else spikeFactZoneKey
								))
							end
						end
					end
				end
			end

			-- What MY side knows about where the spike lies (nil = we don't).
			local mySpikeMark = if side == "Attack" then MatchState.spikeMarkAtk else MatchState.spikeMarkDef
			local mySpikeZoneKey: string? = if spikeDown and mySpikeMark then mySpikeMark.zoneKey else nil

			-- Deliberate facing: look at what matters, not where the legs point.
			if visible then
				bot.facePoint = visible.pos
			elseif contact and now - contact.seenAt < K.FRESH_CONTACT_SECONDS then
				bot.facePoint = contact.pos
			end

			local assessment = nil
			if visible then
				assessment = Combat.assess(bot, weapon, visible, enemies, currentKey, combatState, now)
			end

			-- Team intel pool: distinct fresh enemies per zone, across the whole
			-- side's combined senses. The confirmation gate runs on this.
			local pressure = BrainCore.teamPressure(allies, Brain.perceptions, now)

			local allyZones = {}
			local alliesNear = 0
			local closerToSite = 0
			local guardRank = 0
			local myHopsToSite = math.huge
			if side == "Defense" and MatchState.planted and MatchState.plantedZoneKey then
				myHopsToSite = BrainCore.hopsSafe(currentKey, MatchState.plantedZoneKey, side)
			end
			local myHopsToSpike = math.huge
			if spikeDown and mySpikeZoneKey and side == "Defense" then
				myHopsToSpike = BrainCore.hopsSafe(currentKey, mySpikeZoneKey, side)
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
				if (allyGround - ground).Magnitude <= K.ALLY_CROWD_STUDS then
					alliesNear += 1
				end
				if myHopsToSite ~= math.huge then
					if BrainCore.hopsSafe(allyKey, MatchState.plantedZoneKey, side) < myHopsToSite then
						closerToSite += 1
					end
				end
				if myHopsToSpike ~= math.huge then
					if BrainCore.hopsSafe(allyKey, mySpikeZoneKey :: string, side) < myHopsToSpike then
						guardRank += 1
					end
				end
			end

			local enemiesNear = 0
			for _, memoryContact in perception.memory do
				if memoryContact.name == "the spike" then
					continue -- the objective is not a threat count
				end
				if now - memoryContact.seenAt < K.FRESH_CONTACT_SECONDS
					and Zones.hops(currentKey, memoryContact.zoneKey) <= K.ENEMY_NEAR_HOPS
				then
					enemiesNear += 1
				end
			end

			local reference = math.max(lastProgressAt, perception.lastContactAt)
			local decisiveness = math.clamp((now - reference) / Scenario.StallRampSeconds, 0, 1)

			local atObjective = if side == "Attack"
				then Zones.hasTag(currentKey, "site")
				else table.find(BrainCore.DEF_FORWARD_SET, currentKey) ~= nil

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

			local ctx: BrainCore.Context = {
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
				onAnchor = table.find(BrainCore.DEF_HOLDS, currentKey) ~= nil,
				alliesNear = alliesNear,
				enemiesNear = enemiesNear,
				closerToSite = closerToSite,
				coverZoneSet = coverZoneSet,
				pressure = pressure,
				spikeDown = spikeDown,
				spikeZoneKey = mySpikeZoneKey,
				guardRank = guardRank,
			}

			local scores: { [string]: number } = {}
			for _, name in BrainCore.INTENTS do
				scores[name] = BrainCore.SCORERS[name](ctx)
			end

			local winner = intent
			local winnerScore = scores[intent]
			for _, name in BrainCore.INTENTS do
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
				bot.siteChoice = BrainCore.SITES[rng:NextInteger(1, #BrainCore.SITES)]
				if Scenario.VerboseBrain then
					print(("[CLUTCH] %6.1fs  PLAN %s calls %s this round"):format(
						clock(),
						bot.name,
						if Zones.byKey[bot.siteChoice] then Zones.byKey[bot.siteChoice].callout else bot.siteChoice
					))
				end
			elseif side == "Defense" and bot.holdChoice == nil then
				bot.holdChoice = BrainCore.DEF_HOLDS[rng:NextInteger(1, #BrainCore.DEF_HOLDS)]
				if Scenario.VerboseBrain then
					print(("[CLUTCH] %6.1fs  PLAN %s anchors %s this round"):format(
						clock(),
						bot.name,
						if Zones.byKey[bot.holdChoice] then Zones.byKey[bot.holdChoice].callout else bot.holdChoice
					))
				end
			end

			local targetKey = BrainCore.resolveTarget(intent, ctx, allyZones, rng)

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
					local cover, faceDir = BrainCore.pickCoverPoint(ctx, allies)
					if cover and faceDir then
						bot.claimedCover = cover.name
						if holdAngle(bot, model, cover, faceDir, shouldInterrupt, perception, rng, clock) then
							lastProgressAt = clock()
						end
						bot.claimedCover = nil
					else
						local spot = BrainCore.standablePointIn(currentKey, rng, model, ground, allies, bot)
						if spot then
							Pathing.walkToWithResult(model, spot, shouldInterrupt)
						end
						-- Face the threat, never the wall: idle settles leave a
						-- facePoint for the facing loop to turn onto.
						local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
						if root then
							bot.facePoint = root.Position + BrainCore.threatFaceDir(side, contact, root.Position) * 20
						end
						task.wait(rng:NextNumber(0.6, 1.4))
					end
				else
					-- THE INFO DOCTRINE, approach half: check the angle before you
					-- cross it — but never when a living teammate is ALREADY in that
					-- zone: the first bot checks the corner, the rest trade off it.
					local contactClose = contact ~= nil
						and now - contact.seenAt < SimConfig.MemoryDecaySeconds
						and BrainCore.hopsSafe(currentKey, contact.zoneKey, side) <= APPROACH_PEEK_HOPS
					local chokeAhead = routeKey ~= nil and Zones.hasTag(routeKey, "choke")
					local allyAhead = routeKey ~= nil and table.find(allyZones, routeKey) ~= nil
					if (intent == "Push" or intent == "Rotate" or intent == "Lurk")
						and (contactClose or chokeAhead)
						and not allyAhead
						and now - lastApproachPeekAt > APPROACH_PEEK_COOLDOWN
					then
						local cover, faceDir = BrainCore.pickCoverPoint(ctx, allies)
						if cover and faceDir then
							lastApproachPeekAt = now
							bot.claimedCover = cover.name
							holdAngle(bot, model, cover, faceDir, shouldInterrupt, perception, rng, clock, 1)
							bot.claimedCover = nil
						end
					end

					if routeKey == nil then
						local hops = BrainCore.hopsSafe(currentKey, targetKey, side)
						routeKey = if hops > K.DIRECT_WALK_MAX_HOPS
							then (BrainCore.nextHopSafe(currentKey, targetKey, side) or targetKey)
							else targetKey
					end

					if currentKey == routeKey then
						if routeKey == targetKey then
							lastProgressAt = clock()
						end
						routeKey = nil
					else
						local retrieving = side == "Attack"
							and spikeDown
							and mySpikeZoneKey ~= nil
							and routeKey == mySpikeZoneKey
						local spot, sampleReason
						if retrieving and mySpikeMark then
							local spikePos = mySpikeMark.pos
							spot = Vector3.new(spikePos.X, 1, spikePos.Z)
							local ok, reason = BrainCore.standableReason(spot, model)
							if not ok then
								sampleReason = reason
								spot = nil
							end
						else
							spot, sampleReason = BrainCore.standablePointIn(routeKey, rng, model, ground, allies, bot)
						end

						if spot then
							if not (visible or (contact and now - contact.seenAt < K.FRESH_CONTACT_SECONDS)) then
								bot.facePoint = spot -- watch where you're walking
							end
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
			-- zones in 8s reports its exact situation. (Cross-map rotates trip
			-- this legitimately; read them as pace, not guilt.)
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
		if Combat.states[bot.name] == combatState then
			Combat.states[bot.name] = nil
		end
		if onStop then
			task.defer(onStop)
		end
	end)
end

return Brain
