--!strict
-- Combat: whether to shoot, and what happens when you do.
--
-- The decision is deliberately split from the act. `assess` produces a score
-- the brain can compare against Hold/Push/Rotate like any other intent, so
-- "take this fight" competes with "reposition first" instead of overriding it.
--
-- RANGE DISCIPLINE: every weapon has an optimal band; Game Sense decides
-- whether a bot respects it. Four situations override discipline entirely:
-- the enemy has eyes on it, it is contesting a site, it is taking damage —
-- or it is SUPPRESSED (playtest #16: a bullet cracking three studs past your
-- skull is information even when it doesn't hit).
--
-- SMOOTH AIM, PHYSICS-SAFE (playtest #17): AimAlign carries the rotation at
-- a capped angular velocity; nobody writes a root CFrame anymore. The shooter
-- pays for the turn: the measured remaining error widens the cone.
--
-- v2 (playtest #19) — the PRECISION GUNPLAY layer:
--   * EXPOSED-PART AIMING: a shot aims at the first body part with clear LOS
--     (head when hunting, torso, arms, legs, root last). Nothing exposed and
--     the shot doesn't happen — the wall-eating mag-dump is dead. FORCED
--     fights may still spray the cover — suppression is honest.
--   * AMMO IS REAL: magazines decrement, reserves drain, reloads channel.
--     Dry mid-fight = switch-or-reload by distance (close threat draws the
--     sidearm, a distant one buys time for the magazine). Calm bots with a
--     light mag reload proactively.
--   * CROUCH-SPRAY: spray weapons (CrouchAffinity) sometimes drop a crouch at
--     burst start — crouched spread is tighter (×0.78). Bolt guns and pistols
--     barely bother; the visual pose lands with batch D.
--   * THE KNIFE GATES FIRING: knife out = no trigger; drawing back costs the
--     ACTIVE weapon's EquipSeconds (per-weapon draw times, v2.1).
--
-- v2.1 (playtest #20): the crouch reads louder — a deeper drop (1.3 studs),
-- a higher proc chance, and a CROUCH log line so the feed shows it. The
-- switch-to-sidearm boundary widened to 35 studs: inside that, the pistol's
-- 0.5s draw beats any magazine change.
--
-- GUNFIRE IS HEARD: every burst stamps MatchState.lastShot; Perception turns
-- it into a SOUND contact for every enemy.
--
-- KILLS are reported two ways: the DOWN log line, and stamps on the victim's
-- model which the round machine's death watcher reads for the kill feed.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local SimConfig = require(Shared.Constants.SimConfig)
local Scenario = require(Shared.Constants.Scenario)
local Weapons = require(Shared.Constants.Weapons)
local Zones = require(Shared.MapData.Zones)
local Perception = require(script.Parent.Perception)
local MatchState = require(script.Parent.MatchState)
local BrainCore = require(script.Parent.BrainCore)

local Combat = {}

-- Every living bot's combat state, keyed by name (Brain.start writes it).
-- Shots read the TARGET's state to stamp suppression — near-misses are
-- team-free, victim-local information.
Combat.states = {} :: { [string]: any }

export type Band = "Optimal" | "Stretch" | "Extreme"

-- Willingness weights. These are exactly the numbers the self-play tuner will
-- eventually optimise, so they live together and are named after what they mean.
local ENGAGE_BASE = 0.35
local BAND_OPTIMAL_BONUS = 0.40
local BAND_STRETCH_BONUS = 0.12
local BAND_STRETCH_GS_PENALTY = 0.30 -- discipline: scales with Game Sense
local BAND_EXTREME_PENALTY = 0.45
local AGGRESSION_WEIGHT = 0.18
local FORCED_BONUS = 0.50
local ENGAGE_THRESHOLD = 0.50

local RECOIL_RESET_SHOTS = 4
local HEADSHOT_INTENT_FLOOR = 0.10
local HEADSHOT_INTENT_RANGE = 0.35
local TRACER_LIFETIME = 0.09

-- Smooth aim. Turn rate in degrees/sec: 140 at Reactions 0, ~400 at 100 —
-- human flick territory, not aimbot. Off-target shots pay for it: the cone
-- doubles for every 45° of remaining angular error.
local TURN_BASE_DEG_PER_SEC = 140
local TURN_REACTION_DEG_PER_SEC = 2.6
local TURN_INACCURACY_PER_45DEG = 1.0

-- Suppression: a miss passing this close to the head counts as being shot
-- AT, and the victim reacts for this long afterwards.
local SUPPRESS_RADIUS = 3
local SUPPRESS_MEMORY_SECONDS = 1.5

-- Crouch: tighter cone while planted on your heels; the drop reads on the
-- rig (v2.1: deeper, so it shows before the animation pass lands).
local CROUCH_SPREAD_MULTIPLIER = 0.78
local CROUCH_DROP = 1.3

-- Switch-vs-reload: a dry magazine with a threat THIS close draws the
-- sidearm (0.5s draw beats any reload); farther away buys time for the mag.
local SWITCH_DISTANCE = 35

-- Exposed-part aiming, in value order. The head leads when hunting it.
local PARTS_BODY_FIRST = { "Torso", "Head", "Left Arm", "Right Arm", "HumanoidRootPart", "Left Leg", "Right Leg" }
local PARTS_HEAD_FIRST = { "Head", "Torso", "Left Arm", "Right Arm", "HumanoidRootPart", "Left Leg", "Right Leg" }

export type Assessment = {
	engage: boolean,
	score: number,
	band: Band,
	distance: number,
	multiplier: number,
	reason: string,
	forced: boolean,
	targetName: string,
}

export type State = {
	shotsSinceReset: number,
	lastShotAt: number,
	engagedSince: number?,
	lastHealth: number,
	lastDamagedAt: number,
	lastSuppressedAt: number,
	shotsFired: number,
	hits: number,
	headshots: number,
	-- v2: the loadout layer
	ammoFor: string?,
	magAmmo: number,
	reserveAmmo: number,
	reloadingUntil: number,
	crouched: boolean,
	standHip: number?,
}

function Combat.newState(startHealth: number): State
	return {
		shotsSinceReset = 0,
		lastShotAt = -math.huge,
		engagedSince = nil,
		lastHealth = startHealth,
		lastDamagedAt = -math.huge,
		lastSuppressedAt = -math.huge,
		shotsFired = 0,
		hits = 0,
		headshots = 0,
		ammoFor = nil,
		magAmmo = 0,
		reserveAmmo = 0,
		reloadingUntil = -math.huge,
		crouched = false,
		standHip = nil,
	}
end

-- What's actually in the bot's hands. The knife means no trigger at all;
-- a dry primary means the sidearm.
function Combat.activeWeapon(bot: any): any
	if bot.held == "Knife" then
		return nil
	end
	if bot.held == "Sidearm" or bot.primaryDry then
		return Weapons.Sidearm
	end
	return bot.weapon
end

function Combat.band(weapon: any, distance: number): Band
	if distance <= weapon.OptimalRangeStuds then
		return "Optimal"
	elseif distance <= weapon.MaxEffectiveRangeStuds then
		return "Stretch"
	end
	return "Extreme"
end

-- Linear falloff from full damage at optimal range to MinDamageMultiplier at
-- the edge of effective range. Past that it keeps decaying.
function Combat.damageMultiplier(weapon: any, distance: number): number
	if distance <= weapon.OptimalRangeStuds then
		return 1
	end
	local span = weapon.MaxEffectiveRangeStuds - weapon.OptimalRangeStuds
	if span <= 0 then
		return weapon.MinDamageMultiplier
	end
	local t = (distance - weapon.OptimalRangeStuds) / span
	local multiplier = 1 - (1 - weapon.MinDamageMultiplier) * t
	return math.max(multiplier, weapon.MinDamageMultiplier * 0.6)
end

local function spreadFor(weapon: any, attributes: any, distance: number, sprayIndex: number, crouched: boolean): number
	local spread = weapon.FirstBulletSpreadDeg + sprayIndex * weapon.SprayErrorGrowthDeg
	spread = math.min(spread, math.max(weapon.MaxSprayErrorDeg, weapon.FirstBulletSpreadDeg))

	if distance > weapon.OptimalRangeStuds then
		local over = (distance - weapon.OptimalRangeStuds) / 10
		spread += over * weapon.RangeSpreadPer10Studs
	end

	spread *= 1.35 - (attributes.Aim / 100) * 0.7
	spread *= 1 + (100 - attributes.Consistency) / 100 * 0.25
	if crouched then
		spread *= CROUCH_SPREAD_MULTIPLIER
	end
	return math.max(spread, 0.01)
end

local function findEnemyModel(enemies: { any }, name: string): Model?
	for _, enemy in enemies do
		if enemy.name == name then
			return enemy.model
		end
	end
	return nil
end

-- Should this bot shoot the enemy it can currently see?
function Combat.assess(
	bot: any,
	weapon: any,
	contact: any,
	enemies: { any },
	myZoneKey: string,
	state: State,
	now: number
): Assessment
	local attributes = bot.attributes
	local gameSense = attributes.GameSense / 100
	local aggression = attributes.Aggression / 100
	local distance = contact.distance
	local band = Combat.band(weapon, distance)

	local score = ENGAGE_BASE + aggression * AGGRESSION_WEIGHT
	local reason: string

	if band == "Optimal" then
		score += BAND_OPTIMAL_BONUS
		reason = "inside optimal range"
	elseif band == "Stretch" then
		score += BAND_STRETCH_BONUS - gameSense * BAND_STRETCH_GS_PENALTY
		reason = ("past optimal (%d studs), GS %d wants %d"):format(
			math.floor(distance),
			attributes.GameSense,
			weapon.OptimalRangeStuds
		)
	else
		score -= BAND_EXTREME_PENALTY
		reason = ("beyond effective range (%d studs)"):format(math.floor(distance))
	end

	local forced = false
	local enemyModel = findEnemyModel(enemies, contact.name)
	if enemyModel and Perception.hasEyesOn(enemyModel, bot.model) then
		forced = true
		reason = ("%s has eyes on me"):format(contact.name)
	elseif Zones.hasTag(myZoneKey, "plant") then
		forced = true
		reason = "contesting the site"
	elseif now - state.lastDamagedAt <= 2.5 then
		forced = true
		reason = "taking fire"
	elseif now - state.lastSuppressedAt <= SUPPRESS_MEMORY_SECONDS then
		forced = true
		reason = "pinned down" -- bullets cracking past count as being shot AT
	end
	if forced then
		score += FORCED_BONUS
	end

	return {
		engage = score >= ENGAGE_THRESHOLD,
		score = score,
		band = band,
		distance = distance,
		multiplier = Combat.damageMultiplier(weapon, distance),
		reason = reason,
		forced = forced,
		targetName = contact.name,
	}
end

function Combat.pollHealth(bot: any, state: State, now: number)
	local humanoid = bot.model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if humanoid.Health < state.lastHealth - 0.01 then
		state.lastDamagedAt = now
	end
	state.lastHealth = humanoid.Health
end

-- CROUCH. The spread model and the hitbox both change; the pose animation
-- is batch D's job.
function Combat.setCrouch(bot: any, state: State, crouched: boolean)
	local humanoid = bot.model and bot.model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	if crouched and not state.crouched then
		state.standHip = state.standHip or humanoid.HipHeight
		humanoid.HipHeight = math.max(0.2, (state.standHip or 2) - CROUCH_DROP)
		state.crouched = true
	elseif not crouched and state.crouched then
		humanoid.HipHeight = state.standHip or 2
		state.crouched = false
	end
end

-- Ammo bookkeeping is lazy per weapon: first touch of a weapon loads it.
local function ensureLoaded(state: State, weapon: any)
	if state.ammoFor ~= weapon.Id then
		state.ammoFor = weapon.Id
		state.magAmmo = weapon.Magazine
		state.reserveAmmo = weapon.Magazine * weapon.ReserveMags
		state.reloadingUntil = -math.huge
	end
end

-- A finished reload moves rounds from the reserve into the magazine.
local function finishReload(state: State, weapon: any, now: number): boolean
	if state.reloadingUntil ~= -math.huge and now >= state.reloadingUntil then
		local moved = math.min(weapon.Magazine, state.reserveAmmo)
		state.magAmmo = moved
		state.reserveAmmo -= moved
		state.reloadingUntil = -math.huge
		return true
	end
	return state.reloadingUntil ~= -math.huge -- still channeling
end

-- Calm-moment reload: top off a light magazine when nothing is happening.
function Combat.maybeReload(bot: any, state: State, now: number): boolean
	local weapon = Combat.activeWeapon(bot)
	if not weapon or weapon.Class == "Melee" then
		return false
	end
	ensureLoaded(state, weapon)
	if state.reloadingUntil ~= -math.huge then
		return true -- already channeling
	end
	if state.magAmmo >= weapon.Magazine * 0.4 or state.reserveAmmo <= 0 then
		return false
	end
	state.reloadingUntil = now + weapon.ReloadSeconds
	if Scenario.LogCombat then
		print(("[CLUTCH] %6.1fs  RELOAD %s tops off (%d + %d)"):format(now, bot.name, state.magAmmo, state.reserveAmmo))
	end
	return true
end

-- EXPOSED-PART AIMING: the first body part with clear LOS wins the shot.
-- Nothing visible = no trigger pull (the wall-eating mag-dump is dead).
local function pickAimPart(origin: Vector3, targetModel: Model, selfModel: Model, preferHead: boolean): BasePart?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { selfModel }
	for _, partName in (if preferHead then PARTS_HEAD_FIRST else PARTS_BODY_FIRST) do
		local part = targetModel:FindFirstChild(partName) :: BasePart?
		if not part then
			continue
		end
		local result = workspace:Raycast(origin, part.Position - origin, params)
		if result and result.Instance:IsDescendantOf(targetModel) then
			return part
		end
	end
	return nil
end

local function tracer(from: Vector3, to: Vector3)
	local distance = (to - from).Magnitude
	if distance < 0.1 then
		return
	end
	local beam = Instance.new("Part")
	beam.Anchored = true
	beam.CanCollide = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = Color3.fromRGB(255, 220, 120)
	beam.Size = Vector3.new(0.08, 0.08, distance)
	beam.CFrame = CFrame.lookAt((from + to) / 2, to)
	beam.Parent = workspace
	Debris:AddItem(beam, TRACER_LIFETIME)
end

local function hitSpark(at: Vector3)
	local spark = Instance.new("Part")
	spark.Shape = Enum.PartType.Ball
	spark.Anchored = true
	spark.CanCollide = false
	spark.CastShadow = false
	spark.Material = Enum.Material.Neon
	spark.Color = Color3.fromRGB(255, 120, 60)
	spark.Size = Vector3.new(0.4, 0.4, 0.4)
	spark.Position = at
	spark.Parent = workspace
	Debris:AddItem(spark, 0.12)
end

-- SMOOTH AIM, PHYSICS-SAFE. AimAlign carries the rotation at the combat turn
-- rate (Reactions-driven); the shooter just pays the measured remaining
-- error in spread. No CFrame writes — a moving root is the humanoid's job.
function Combat.faceTargetSmooth(bot: any, root: BasePart, targetPos: Vector3, _dt: number): number
	return BrainCore.turnToward(
		bot,
		root,
		targetPos,
		TURN_BASE_DEG_PER_SEC + bot.attributes.Reactions * TURN_REACTION_DEG_PER_SEC
	)
end

-- Fires one burst. Returns true if the target died.
function Combat.fireBurst(
	bot: any,
	_weapon: any,
	targetModel: Model,
	state: State,
	rng: Random,
	clock: () -> number
): boolean
	local weapon = Combat.activeWeapon(bot) -- the held item decides, not the buy
	if not weapon or weapon.Class == "Melee" then
		return false -- the knife is out: no trigger to pull
	end

	local selfModel = bot.model :: Model
	local selfRoot = selfModel:FindFirstChild("HumanoidRootPart") :: BasePart?
	local selfHead = selfModel:FindFirstChild("Head") :: BasePart?
	local targetHumanoid = targetModel:FindFirstChildOfClass("Humanoid")
	local targetRoot = targetModel:FindFirstChild("HumanoidRootPart") :: BasePart?
	local targetHead = targetModel:FindFirstChild("Head") :: BasePart?
	if not selfRoot or not selfHead or not targetHumanoid or not targetRoot then
		return false
	end

	local attributes = bot.attributes
	local now = clock()

	-- Drawing the gun takes THIS gun's EquipSeconds — the knife's hidden tax
	-- is priced per weapon (knife 0.2 / pistol 0.5 / rifle 1.0 / sniper 1.25).
	if now - (bot.heldAt or -math.huge) < weapon.EquipSeconds then
		return false
	end

	ensureLoaded(state, weapon)
	if finishReload(state, weapon, now) then
		return false -- mid-magazine-change: the burst waits
	end

	-- DRY. The switch-or-reload call: a close threat draws the sidearm, a
	-- distant one buys time for the magazine.
	if state.magAmmo <= 0 then
		local distance = (targetRoot.Position - selfRoot.Position).Magnitude
		if state.reserveAmmo > 0 and (weapon.Class == "Pistol" or distance > SWITCH_DISTANCE) then
			state.reloadingUntil = now + weapon.ReloadSeconds
			if Scenario.LogCombat then
				print(("[CLUTCH] %6.1fs  RELOAD %s (dry at %.0f studs)"):format(now, bot.name, distance))
			end
			return false
		end
		if weapon.Class ~= "Pistol" then
			-- out of primary: the sidearm comes out, maybe for the rest of the round
			if state.reserveAmmo <= 0 then
				bot.primaryDry = true
			end
			bot.held = "Sidearm"
			bot.heldAt = now
			if Scenario.LogCombat then
				print(("[CLUTCH] %6.1fs  SWITCH %s draws the sidearm (dry at %.0f studs)"):format(now, bot.name, distance))
			end
			return false
		end
		-- Both guns dry: this bot is done shooting this round.
		bot.allDry = true
		if Scenario.LogCombat then
			print(("[CLUTCH] %6.1fs  DRY %s is out of everything"):format(now, bot.name))
		end
		return false
	end

	-- Gunfire is a sound event: every enemy in the match hears this burst
	MatchState.lastShot = { by = bot.name, pos = selfRoot.Position, at = now }

	-- CROUCH-SPRAY: spray weapons often drop a crouch at burst start to hold
	-- the pattern. Bolt guns and pistols barely bother.
	if weapon.CrouchAffinity > 0 and not state.crouched then
		local chance = weapon.CrouchAffinity * (0.5 + attributes.Aim / 200)
		if rng:NextNumber() < chance then
			Combat.setCrouch(bot, state, true)
			if Scenario.LogCombat then
				print(("[CLUTCH] %6.1fs  CROUCH %s drops to control the spray"):format(now, bot.name))
			end
		end
	end

	-- Reaction delay, paid once per fresh engagement. THE EYES MOVE FIRST: the
	-- bot turns toward the target THROUGH the delay instead of freezing and
	-- then flicking.
	if state.engagedSince == nil then
		state.engagedSince = now
		local span = SimConfig.ReactionDelayBaseSeconds - SimConfig.ReactionDelayMinSeconds
		local delay = SimConfig.ReactionDelayBaseSeconds - (attributes.Reactions / 100) * span
		if Scenario.LogCombat then
			print(("[CLUTCH] %6.1fs  AIM %s reacts in %.2fs"):format(now, bot.name, delay))
		end
		local turnStarted = clock()
		while clock() - turnStarted < delay do
			if targetHumanoid.Health <= 0 or not targetModel.Parent then
				Combat.setCrouch(bot, state, false)
				return false
			end
			Combat.faceTargetSmooth(bot, selfRoot, targetRoot.Position, 0.05)
			task.wait(0.05)
		end
	end

	for shot = 1, weapon.BurstShots do
		if targetHumanoid.Health <= 0 or not targetModel.Parent then
			break
		end
		local humanoid = selfModel:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			Combat.setCrouch(bot, state, false)
			return false
		end
		if state.magAmmo <= 0 then
			break -- the dry handler catches it next call
		end

		-- Turn toward the target FIRST; whatever error remains widens the cone.
		local aimError = Combat.faceTargetSmooth(bot, selfRoot, targetRoot.Position, weapon.FireInterval)

		local sprayIndex = state.shotsSinceReset % RECOIL_RESET_SHOTS

		-- Head is only attempted on a settled crosshair: no head-hunting while
		-- still turning, and never mid-spray.
		local headshotIntent = HEADSHOT_INTENT_FLOOR + (attributes.Aim / 100) ^ 2 * HEADSHOT_INTENT_RANGE
		local settled = aimError < math.rad(6)
		local goingForHead = settled and sprayIndex == 0 and targetHead ~= nil and rng:NextNumber() < headshotIntent

		-- EXPOSED-PART AIMING: the first part with clear LOS wins. Nothing
		-- exposed: the shot doesn't exist — UNLESS the fight is forced, in
		-- which case suppression through the cover is the honest answer.
		local aimPart = pickAimPart(selfHead.Position, targetModel, selfModel, goingForHead)
		if aimPart == nil then
			if not (state.lastSuppressedAt > now - SUPPRESS_MEMORY_SECONDS or state.lastDamagedAt > now - 2.5) then
				task.wait(weapon.FireInterval) -- hold the trigger; the cone stays home
				continue
			end
			aimPart = targetRoot -- forced: spray the cover, loudly
		end

		state.magAmmo -= 1 -- a shot consumes a round

		local origin = selfHead.Position
		local toTarget = aimPart.Position - origin
		local distance = toTarget.Magnitude
		local direction = toTarget.Unit

		local spreadDeg = spreadFor(weapon, attributes, distance, sprayIndex, state.crouched)
		-- Off-target penalty: every 45° of remaining error doubles the cone.
		spreadDeg *= 1 + (math.deg(aimError) / 45) * TURN_INACCURACY_PER_45DEG

		local perpA = direction:Cross(Vector3.yAxis)
		if perpA.Magnitude < 0.01 then
			perpA = direction:Cross(Vector3.xAxis)
		end
		perpA = perpA.Unit
		local perpB = direction:Cross(perpA).Unit
		local angle = rng:NextNumber(0, math.pi * 2)
		local radius = math.tan(math.rad(spreadDeg)) * math.sqrt(rng:NextNumber())
		local aimDir = (direction + perpA * math.cos(angle) * radius + perpB * math.sin(angle) * radius).Unit

		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { selfModel }
		local reach = math.max(weapon.MaxEffectiveRangeStuds * 1.5, distance + 20)
		local result = workspace:Raycast(origin, aimDir * reach, params)

		state.shotsFired += 1
		state.shotsSinceReset += 1
		state.lastShotAt = clock()

		local endPoint = if result then result.Position else origin + aimDir * reach
		tracer(origin, endPoint)

		if result and result.Instance:IsDescendantOf(targetModel) then
			local isHead = result.Instance.Name == "Head"
			local multiplier = Combat.damageMultiplier(weapon, distance)
			local damage = weapon.DamageBody * multiplier
			if isHead then
				damage *= weapon.HeadshotMultiplier
				state.headshots += 1
				bot.headshots = (bot.headshots or 0) + 1 -- lifetime stat, dashboard-bound
			end
			state.hits += 1
			hitSpark(result.Position)
			targetHumanoid:TakeDamage(damage)

			if Scenario.LogCombat then
				print(("[CLUTCH] %6.1fs  SHOT %s -> %s | %s %.0f dmg (x%.2f at %.0f studs) | %s HP %.0f"):format(
					clock(),
					bot.name,
					targetModel.Name,
					if isHead then "HEADSHOT" else "body",
					damage,
					multiplier,
					distance,
					targetModel.Name,
					math.max(targetHumanoid.Health, 0)
				))
			end

			if targetHumanoid.Health <= 0 then
				bot.kills = (bot.kills or 0) + 1
				targetModel:SetAttribute("LastKilledBy", bot.name)
				targetModel:SetAttribute("LastKillHeadshot", isHead)
				targetModel:SetAttribute("LastKillDistance", math.floor(distance))
				targetModel:SetAttribute("LastKillWeapon", weapon.DisplayName)
				print(("[CLUTCH] %6.1fs  DOWN %s killed by %s | %d/%d shots hit, %d headshots"):format(
					clock(),
					targetModel.Name,
					bot.name,
					state.hits,
					state.shotsFired,
					state.headshots
				))
				Combat.setCrouch(bot, state, false)
				return true
			end
		else
			-- SUPPRESSION: the miss was information. A bullet cracking past the
			-- target's ears marks them as shot AT — they react even unhurt.
			local reference = if targetHead then targetHead else targetRoot
			local toRef = reference.Position - origin
			local along = math.clamp(toRef:Dot(aimDir), 0, reach)
			local closest = origin + aimDir * along
			if (closest - reference.Position).Magnitude <= SUPPRESS_RADIUS then
				local targetState = Combat.states[targetModel.Name]
				if targetState then
					targetState.lastSuppressedAt = clock()
				end
			end
			if Scenario.LogCombat then
				print(("[CLUTCH] %6.1fs  MISS %s -> %s | %.1f deg cone at %.0f studs"):format(
					clock(),
					bot.name,
					targetModel.Name,
					spreadDeg,
					distance
				))
			end
		end

		task.wait(weapon.FireInterval)
	end

	Combat.setCrouch(bot, state, false) -- the burst ends standing
	return false
end

-- Called when a bot breaks contact: the next engagement pays reaction cost
-- again, the recoil pattern resets, and the crouch comes off.
function Combat.disengage(state: State)
	state.engagedSince = nil
	state.shotsSinceReset = 0
end

return Combat
