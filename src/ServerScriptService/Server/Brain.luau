--!strict
-- Bot brain v4.10: the RUNTIME half. BrainCore.luau owns the judgment
-- (scorers, routing, sampler, cover picks, team pressure, resolveTarget);
-- this module owns what the bot DOES about it each tick: comms, facing,
-- walks, holds, channels, diagnostics.
--
-- v4.10 (playtest #24): THE PAD STEP IS A COURTESY, NOT A VETO. The pads'
-- centers sat inside their default crates (fixed in Greybox v5.2), so the
-- step PATH FAILED forever while the carrier hovered Plant 1.00 at the
-- pad's edge. Now: step only when farther than 8 studs, and a failed step
-- never blocks a plant that's already legal.
--
-- v4.9 (playtest #23): buy-phase staging (form at the plan's barrier mouth),
-- the pad step. v4.8: the gaze priority list. v4.7: heading-tracked facing,
-- glances not camps, spike snap, the loud defuse tap. Style rule: no inner
-- quotes in log strings. Ever.

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
local MatchMemory = require(script.Parent.MatchMemory)
local BotSpawner = require(script.Parent.BotSpawner)
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
local HOT_ROUTE_HEAT = 3 -- MatchMemory heat that earns a habit peek
local WATCH_ROUTE_HEAT = 2 -- heat that earns the EYES while walking (#22)
local KNIFE_SPRINT_SPEED = 18.5 -- the oldest tac-shooter truth: knife = faster
local SPIKE_SNAP_RADIUS = 40 -- a marked drop this close with nobody around: grab it
local DEFUSE_HEAR_RADIUS = 55 -- the tap is audible across the site web
local RELOCATE_BEAT_SECONDS = 2.5 -- after a quiet hold: move, then look again

local K = BrainCore.K -- shared constants (freshness windows, hop budgets, spacing)

-- Zones defenders consider "forward" positions (for the at-objective read).
local DEF_FORWARD = { "MID", "MID_LEDGE", "MID_WINDOW", "A_SHORT", "B_SHORT" }

-- Buy-phase staging (playtest #23): the named barrier mouths, just inside
-- the attacker half. A bot forms up at the mouth its PLAN exits through.
local STAGE_MOUTH_A = Vector3.new(-53, 1, 36)
local STAGE_MOUTH_B = Vector3.new(53, 1, 36)
local STAGE_MOUTH_MID = Vector3.new(0, 1, 36)
local STAGE_WEST = Vector3.new(-82, 1, 52) -- the outside-long barrier approach
local STAGE_EAST = Vector3.new(82, 1, 52)

local function stagingPointFor(bot: any): Vector3
	local base: Vector3
	if bot.siteChoice == "A_SITE" then
		base = STAGE_MOUTH_A
	elseif bot.siteChoice == "B_SITE" then
		base = STAGE_MOUTH_B
	elseif bot.role == "Sniper" then
		base = STAGE_MOUTH_MID
	elseif #bot.name % 2 == 0 then
		base = STAGE_WEST
	else
		base = STAGE_EAST
	end
	-- deterministic per-bot jitter: two bots sharing a mouth must not stack
	-- (per-bot collision is on — they can't occupy the same studs)
	local hash = 0
	for i = 1, #bot.name do
		hash += string.byte(bot.name, i)
	end
	local jitter = (hash % 5 - 2) * 3 -- -6..6 studs along the mouth
	return base + Vector3.new(jitter, 0, 0)
end

-- WALK OR SPRINT — the info doctrine's speed half, now with clear marks:
-- a zone your side has proven safe is a zone you RUN through.
local function wantsWalk(intent: string, side: string, currentKey: string, routeKey: string?, contact: any, now: number): boolean
	if intent == "Engage" or intent == "Plant" or intent == "Defuse" then
		return true
	end
	if intent == "Lurk" or intent == "FallBack" then
		return true
	end
	-- ALL-CLEAR: attackers wiped, spike ticking — there is nothing to sneak on.
	if side == "Defense" and MatchState.planted and (MatchState.atkAlive or 1) == 0 then
		return false
	end
	if contact and now - contact.seenAt < K.FRESH_CONTACT_SECONDS then
		return true -- fresh info: go quiet
	end
	if side == "Attack" and MatchState.planted then
		return true
	end
	local cleared = MatchState.clearMarks[side]
	if Zones.hasTag(currentKey, "choke") and not (cleared and cleared[currentKey]) then
		return true
	end
	if routeKey and Zones.hasTag(routeKey, "choke") and not (cleared and cleared[routeKey]) then
		return true
	end
	return false -- no info, no threat: run
end

-- HOLD THE ANGLE, v4.7-style: walk to the point, GLANCE (0.7–1.8s — corners
-- are checked, not camped), then jiggle-peek — or occasionally SWING. The
-- caller decides how many peeks the bot's Game Sense buys.
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
	bot.faceMode = "point"
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
		local holdUntil = clock() + rng:NextNumber(0.7, 1.8) -- a glance, not a camp
		while clock() < holdUntil do
			if shouldInterrupt() then
				return true
			end
			if Perception.visibleContact(perception) then
				return true -- contact: the main loop owns the fight
			end
			task.wait(0.25)
		end

		-- Jiggle or swing? Swings are rare and committed. Peek steps need REAL
		-- room — ground alone wasn't enough (the rail-sliver PATH FAILEDs).
		local swinging = rng:NextNumber() < SWING_CHANCE
		local peekDistance = if swinging then SWING_STUDS elseif cover.kind == "partial" then 4 else 5
		local peekPos = cover.pos + perp * peekDistance
		local peekOk = BrainCore.standableReason(peekPos, model)
		if not peekOk then
			peekPos = cover.pos - perp * peekDistance
			peekOk = BrainCore.standableReason(peekPos, model)
		end
		if not peekOk then
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

	-- THE FACING LOOP. The brain leaves either a facePoint (a spot worth
	-- watching) or a faceMode "heading" + moveDir (a walking bot watches where
	-- it's GOING — derived from the live position every 80ms, so it can never
	-- be passed and flipped). Combat owns facing mid-burst.
	bot.facePoint = nil :: Vector3?
	bot.moveDir = nil :: Vector3?
	bot.faceMode = "point" :: string -- "point" watches facePoint; "heading" watches the walk direction
	task.spawn(function()
		while model.Parent do
			local humanoidNow = model:FindFirstChildOfClass("Humanoid")
			if not humanoidNow or humanoidNow.Health <= 0 then
				break
			end
			local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			local target = bot.facePoint :: Vector3?
			if root and bot.faceMode == "heading" and bot.moveDir then
				-- TRACK ahead of the feet: 30 studs out, recomputed every tick —
				-- a fixed point gets walked past and reads as staring backwards.
				target = root.Position + bot.moveDir * 30
			end
			if root and target and clock() - combatState.lastShotAt > 0.4 then
				local dir = (target - root.Position) * Vector3.new(1, 0, 1)
				if dir.Magnitude > 0.5 then
					BrainCore.turnToward(bot, root, target, K.HOLD_TURN_DEG_PER_SEC)
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
				local heldWeapon = Combat.activeWeapon(bot)
				if heldWeapon == nil then
					interruptAnswer = true -- caught with the knife out: react NOW
				else
					local assessment = Combat.assess(bot, heldWeapon, visible, enemies, here, combatState, now)
					interruptAnswer = assessment.engage
						and (assessment.forced or assessment.distance <= INTERRUPT_COMBAT_RANGE)
				end
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

			-- The barrier phase: BOTH sides run during Buy now (batch E); only
			-- PostRound sleeps.
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

			-- AREA CLEAR: standing a zone down with no fresh contact earns the
			-- mark and the callout; teammates hasten through proven-safe ground.
			do
				local contactForClear = Perception.bestContact(perception, now)
				if intent ~= "Engage"
					and (contactForClear == nil or now - contactForClear.seenAt > K.FRESH_CONTACT_SECONDS)
					and now - zoneSince >= 4
				then
					local marks = MatchState.clearMarks[side]
					if marks and marks[currentKey] == nil then
						marks[currentKey] = now
						if Scenario.VerboseBrain then
							print(("[CLUTCH] %6.1fs  CALLOUT %s: area clear — %s"):format(
								now,
								bot.name,
								if Zones.byKey[currentKey] then Zones.byKey[currentKey].callout else currentKey
							))
						end
					end
				end
			end

			local visible = Perception.visibleContact(perception)
			local contact = Perception.bestContact(perception, now)
			if not visible then
				Combat.disengage(combatState)
			end

			-- The ACTIVE weapon drives everything combat-shaped this tick — the
			-- buy is not the held item (knife, sidearm-after-dry included).
			local activeWeapon = Combat.activeWeapon(bot)

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
				-- Calm hands top off a light magazine between contacts.
				if intent ~= "Engage" then
					Combat.maybeReload(bot, combatState, now)
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

			-- THE DEFUSE TAP IS LOUD (playtest #20): a defusing defender within
			-- earshot is a sound contact at the spike for every attacker.
			if side == "Attack" and MatchState.defusing and MatchState.plantedZoneKey then
				local tapPos = MatchState.defusing.pos
				local tapDist = (tapPos - ground).Magnitude
				if tapDist <= DEFUSE_HEAR_RADIUS then
					local spikeZone = Zones.byKey[MatchState.plantedZoneKey]
					perception.memory["the defuse"] = {
						name = "the defuse",
						pos = tapPos,
						zoneKey = MatchState.plantedZoneKey,
						zoneCallout = if spikeZone then spikeZone.callout else "the site",
						seenAt = now,
						source = "sound",
						distance = tapDist,
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
			-- The callout prints only when the mark CHANGES — re-confirming the
			-- same zone every 3 seconds was log spam, not intel (playtest #18).
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
						local changed = existing == nil or existing.zoneKey ~= spikeFactZoneKey
						if changed or now - existing.at > 3 then
							MatchState[markField] = { pos = MatchState.spikePart.Position, zoneKey = spikeFactZoneKey, at = now }
						end
						if changed and Scenario.VerboseBrain then
							print(("[CLUTCH] %6.1fs  CALLOUT %s: spike marked — %s"):format(
								now,
								bot.name,
								if Zones.byKey[spikeFactZoneKey] then Zones.byKey[spikeFactZoneKey].callout else spikeFactZoneKey
							))
						end
					end
				end
			end

			-- What MY side knows about where the spike lies (nil = we don't).
			local mySpikeMark = if side == "Attack" then MatchState.spikeMarkAtk else MatchState.spikeMarkDef
			local mySpikeZoneKey: string? = if spikeDown and mySpikeMark then mySpikeMark.zoneKey else nil

			-- FACING DISCIPLINE: a contact owns the eyes only while it's CLOSE or
			-- in front of the walk direction — a bot sprinting away from distant
			-- stale news watches where it's GOING, not backwards. Owning the eyes
			-- means faceMode "point"; a free bot mid-walk runs "heading".
			local contactOwnsEyes = false
			if visible then
				bot.faceMode = "point"
				bot.facePoint = visible.pos
				contactOwnsEyes = true
			elseif contact and now - contact.seenAt < K.FRESH_CONTACT_SECONDS then
				local toContact = (contact.pos - ground) * Vector3.new(1, 0, 1)
				local behind = bot.moveDir ~= nil
					and toContact.Magnitude > 0.5
					and toContact.Unit:Dot(bot.moveDir) < -0.5
				local far = toContact.Magnitude > 25
				if not (behind and far) then
					bot.faceMode = "point"
					bot.facePoint = contact.pos
					contactOwnsEyes = true
				end
			end

			local assessment = nil
			if visible and activeWeapon then
				assessment = Combat.assess(bot, activeWeapon, visible, enemies, currentKey, combatState, now)
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
				if memoryContact.name == "the spike" or memoryContact.name == "the defuse" then
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

			-- ALL-CLEAR: attackers wiped with the spike ticking — the defuse is a
			-- sprint, not a creep. Read by wantsWalk, the peek gate, and scoring.
			local allClear = side == "Defense" and MatchState.planted and (MatchState.atkAlive or 1) == 0

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

			-- KNIFE DISCIPLINE: knife out on safe sprints, gun out the moment
			-- anything is real. The draw costs the ACTIVE weapon's EquipSeconds
			-- before it can fire — greed is priced per gun.
			local danger = visible ~= nil
				or (contact ~= nil and now - contact.seenAt < K.FRESH_CONTACT_SECONDS
					and BrainCore.hopsSafe(currentKey, contact.zoneKey, side) <= K.ENEMY_NEAR_HOPS)
			local objectiveDuty = intent == "Plant" or intent == "Defuse" or intent == "Engage"
				or (side == "Defense" and MatchState.planted)
				or (side == "Attack" and MatchState.spikeCarrier == bot and contact ~= nil)
			local wantKnife = not walking and not danger and not objectiveDuty
				and (intent == "Push" or intent == "Rotate" or intent == "FallBack" or intent == "Lurk")
			local heldWanted = if wantKnife then "Knife" elseif bot.primaryDry then "Sidearm" else "Primary"
			if heldWanted ~= bot.held then
				bot.held = heldWanted
				bot.heldAt = now
				BotSpawner.styleHeld(model, if heldWanted == "Knife" then "Knife" else "Gun")
			end
			bot.speedMode = if bot.held == "Knife" then "knife" elseif walking then "walk" else "sprint"
			alive.WalkSpeed = if bot.held == "Knife" then KNIFE_SPRINT_SPEED elseif walking then SimConfig.WalkSpeed else SimConfig.SprintSpeed

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

			if intent == "Engage" and visible and assessment and activeWeapon then
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
					Combat.fireBurst(bot, activeWeapon, targetModel, combatState, rng, clock)
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
				bot.faceMode = "point" -- the planter watches the threat, not its feet
				-- THE PAD STEP IS A COURTESY, NOT A VETO (playtest #24): the pads'
				-- centers once sat inside the default crates, so the step PATH
				-- FAILED forever. Step only when actually far — and a failed step
				-- never blocks a plant that's already legal.
				local pad, padDist = Objective.nearestPad(ground)
				if pad and padDist > 8 then
					local stepped = Pathing.walkToWithResult(model, Vector3.new(pad.pos.X, 1, pad.pos.Z), shouldInterrupt)
					if stepped ~= "arrived" and padDist <= pad.size.X / 2 + 1.5 then
						Objective.tryStartPlant(bot, clock, channelAbort, if contact then contact.pos else nil)
					end
				else
					Objective.tryStartPlant(bot, clock, channelAbort, if contact then contact.pos else nil)
				end
				lastProgressAt = clock()
			elseif intent == "Defuse" and currentKey == MatchState.plantedZoneKey and MatchState.spikePart then
				local result = Pathing.walkToWithResult(model, MatchState.spikePart.Position, shouldInterrupt)
				if result == "arrived" then
					Objective.tryStartDefuse(bot, clock, channelAbort)
				end
				lastProgressAt = clock()
			elseif intent ~= "Engage" then
				-- SPIKE SNAP: a marked drop within arm's reach and nobody fresh
				-- around — grab it NOW, whatever the plan said. Wider and quicker
				-- in v4.7: 40 studs, 3s freshness gate (playtest #20).
				local snapped = false
				if side == "Attack" and spikeDown and mySpikeMark then
					local toMark = mySpikeMark.pos - ground
					if toMark.Magnitude <= SPIKE_SNAP_RADIUS
						and (contact == nil or now - contact.seenAt > 3)
					then
						local snapSpot = Vector3.new(mySpikeMark.pos.X, 1, mySpikeMark.pos.Z)
						if BrainCore.standableReason(snapSpot, model) then
							Pathing.walkToWithResult(model, snapSpot, shouldInterrupt)
							Objective.tryPickup(bot)
							snapped = true
						end
					end
				end

				if snapped then
					-- grabbed (or walking to grab): nothing else this tick
				elseif targetKey == nil or targetKey == currentKey then
					routeKey = nil
					if MatchState.phase == "Buy" and side == "Attack" then
						-- STAGING (playtest #23): the barrier phase is prep time.
						-- Form up at the mouth the plan exits through — not a
						-- crumple around the spawn strip. Face the way you'll go.
						local spot = stagingPointFor(bot)
						local toSpot = (spot - ground) * Vector3.new(1, 0, 1)
						if toSpot.Magnitude > 6 then
							bot.moveDir = toSpot.Unit
							if not contactOwnsEyes then
								bot.faceMode = "heading"
							end
							Pathing.walkToWithResult(model, spot, shouldInterrupt)
						end
						bot.moveDir = nil -- arrived: stand and watch the line
						local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
						if root and not contactOwnsEyes then
							bot.faceMode = "point"
							bot.facePoint = root.Position + Vector3.new(0, 0, -20)
						end
						task.wait(rng:NextNumber(0.4, 0.9))
					else
						-- Settle the zone. GLANCE, don't camp: holds are short, the
						-- peek count follows Game Sense, and a quiet hold earns a
						-- relocate beat before the next angle (anti-glue, #20).
						bot.moveDir = nil -- standing: no heading to protect
						local cover, faceDir = nil, nil
						if not (bot.relocateUntil and now < bot.relocateUntil) then
							cover, faceDir = BrainCore.pickCoverPoint(ctx, allies)
						end
						if cover and faceDir then
							bot.claimedCover = cover.name
							local gs = bot.attributes.GameSense / 100
							local peeks = 1
								+ (if rng:NextNumber() < gs * 0.6 then 1 else 0)
								+ (if rng:NextNumber() < gs * 0.35 then 1 else 0)
							if holdAngle(bot, model, cover, faceDir, shouldInterrupt, perception, rng, clock, peeks) then
								lastProgressAt = clock()
							end
							bot.claimedCover = nil
							if not Perception.visibleContact(perception) then
								-- quiet hold: remember the crate (BrainCore skips it for a
								-- beat) and force a relocation before the next angle
								bot.lastHeldCover = cover.name
								bot.lastHeldAt = os.clock()
								bot.relocateUntil = clock() + RELOCATE_BEAT_SECONDS
							end
						else
							local spot = BrainCore.standablePointIn(currentKey, rng, model, ground, allies, bot)
							if spot then
								Pathing.walkToWithResult(model, spot, shouldInterrupt)
							end
							-- Face the threat, never the wall: idle settles leave a
							-- facePoint for the facing loop to turn onto.
							local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
							if root then
								bot.faceMode = "point"
								bot.facePoint = root.Position + BrainCore.threatFaceDir(side, contact, root.Position) * 20
							end
							task.wait(rng:NextNumber(0.6, 1.4))
						end
					end
				else
					-- THE INFO DOCTRINE, approach half: check the angle before you
					-- cross it — as a Game-Sense-scaled CHANCE (playtest #20), never
					-- when a living teammate is ALREADY in that zone, never on an
					-- all-clear, and — batch C — when MATCH MEMORY says the enemy
					-- keeps owning the route you're about to walk.
					local contactClose = contact ~= nil
						and now - contact.seenAt < SimConfig.MemoryDecaySeconds
						and BrainCore.hopsSafe(currentKey, contact.zoneKey, side) <= APPROACH_PEEK_HOPS
					local chokeAhead = routeKey ~= nil and Zones.hasTag(routeKey, "choke")
					local allyAhead = routeKey ~= nil and table.find(allyZones, routeKey) ~= nil
					local enemySide = if side == "Attack" then "Defense" else "Attack"
					local routeHot = routeKey ~= nil and MatchMemory.zoneHeat(enemySide, routeKey) >= HOT_ROUTE_HEAT
					if (intent == "Push" or intent == "Rotate" or intent == "Lurk")
						and (contactClose or chokeAhead or routeHot)
						and not allyAhead
						and not allClear
						and now - lastApproachPeekAt > APPROACH_PEEK_COOLDOWN
						and rng:NextNumber() < 0.3 + ctx.gameSense * 0.55 -- the careful check more
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
							-- THE GAZE PRIORITY LIST (playtest #22): a walking bot watches
							-- the highest-priority thing, not its feet — the ROTATE
							-- target first (eyes up toward trouble), then the corner or
							-- hot lane it's about to cross, and only then the heading.
							local moveVec = (spot - ground) * Vector3.new(1, 0, 1)
							if moveVec.Magnitude > 1 then
								bot.moveDir = moveVec.Unit
								if not contactOwnsEyes then
									local watchPoint: Vector3? = nil
									if intent == "Rotate" and contact then
										watchPoint = contact.pos -- rotating to a call: eyes on it
									elseif routeKey and (Zones.hasTag(routeKey, "choke") or MatchMemory.zoneHeat(enemySide, routeKey) >= WATCH_ROUTE_HEAT) then
										watchPoint = Zones.center(routeKey) -- watch the corner you're crossing
									end
									if watchPoint then
										bot.faceMode = "point"
										bot.facePoint = watchPoint
									else
										bot.faceMode = "heading"
									end
								end
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
