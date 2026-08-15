--!strict
-- Combat: whether to shoot, and what happens when you do.
--
-- The decision is deliberately split from the act. `assess` produces a score
-- the brain can compare against Hold/Push/Rotate like any other intent, so
-- "take this fight" competes with "reposition first" instead of overriding it.
--
-- RANGE DISCIPLINE is the interesting part. Every weapon has an optimal band.
-- Whether a bot RESPECTS that band is what Game Sense buys. Three situations
-- override discipline entirely: the enemy has eyes on it, it is contesting a
-- site, or it is taking damage.
--
-- SMOOTH AIM (playtest #14's request). Bots no longer snap to target: the
-- model's facing rotates toward it at a turn rate driven by Reactions, and
-- while the crosshair is off the target the cone is WIDE — the "flick and
-- shoot too early" look is real inaccuracy, not a cosmetic. A 90° swing at
-- Reactions 70 takes ~0.3s; the first bullets of a panic 180 land anywhere.
-- This is what ends the cowboy instant-headshot duels.
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
local Zones = require(Shared.MapData.Zones)
local Perception = require(script.Parent.Perception)
local MatchState = require(script.Parent.MatchState)

local Combat = {}

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
	shotsFired: number,
	hits: number,
	headshots: number,
}

function Combat.newState(startHealth: number): State
	return {
		shotsSinceReset = 0,
		lastShotAt = -math.huge,
		engagedSince = nil,
		lastHealth = startHealth,
		lastDamagedAt = -math.huge,
		shotsFired = 0,
		hits = 0,
		headshots = 0,
	}
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

local function spreadFor(weapon: any, attributes: any, distance: number, sprayIndex: number): number
	local spread = weapon.FirstBulletSpreadDeg + sprayIndex * weapon.SprayErrorGrowthDeg
	spread = math.min(spread, math.max(weapon.MaxSprayErrorDeg, weapon.FirstBulletSpreadDeg))

	if distance > weapon.OptimalRangeStuds then
		local over = (distance - weapon.OptimalRangeStuds) / 10
		spread += over * weapon.RangeSpreadPer10Studs
	end

	spread *= 1.35 - (attributes.Aim / 100) * 0.7
	spread *= 1 + (100 - attributes.Consistency) / 100 * 0.25
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

-- SMOOTH AIM. Rotate the model toward the target, yaw-limited by Reactions,
-- and return the angular error REMAINING after this step (radians) — the
-- shooter pays for it in spread. A 90° swing at Reactions 70 takes ~0.3s.
local function yawOf(look: Vector3): number
	return math.atan2(-look.X, -look.Z)
end

local function shortestAngle(from: number, to: number): number
	return (to - from + math.pi) % (math.pi * 2) - math.pi
end

function Combat.faceTargetSmooth(bot: any, root: BasePart, targetPos: Vector3, dt: number): number
	local flat = Vector3.new(targetPos.X, root.Position.Y, targetPos.Z)
	local toTarget = flat - root.Position
	if toTarget.Magnitude < 0.1 then
		return 0
	end
	local currentYaw = yawOf(root.CFrame.LookVector)
	local desiredYaw = yawOf(toTarget.Unit)
	local delta = shortestAngle(currentYaw, desiredYaw)

	local rateDeg = TURN_BASE_DEG_PER_SEC + bot.attributes.Reactions * TURN_REACTION_DEG_PER_SEC
	local maxStep = math.rad(rateDeg) * math.clamp(dt, 0, 0.5)
	local step = math.clamp(delta, -maxStep, maxStep)
	root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, currentYaw + step, 0)
	return math.abs(delta - step)
end

-- Fires one burst. Returns true if the target died.
function Combat.fireBurst(
	bot: any,
	weapon: any,
	targetModel: Model,
	state: State,
	rng: Random,
	clock: () -> number
): boolean
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

	-- Gunfire is a sound event: every enemy in the match hears this burst
	MatchState.lastShot = { by = bot.name, pos = selfRoot.Position, at = clock() }

	-- Reaction delay, paid once per fresh engagement rather than per shot
	local reactionDelay = 0
	if state.engagedSince == nil then
		state.engagedSince = clock()
		local span = SimConfig.ReactionDelayBaseSeconds - SimConfig.ReactionDelayMinSeconds
		reactionDelay = SimConfig.ReactionDelayBaseSeconds - (attributes.Reactions / 100) * span
		if Scenario.LogCombat then
			print(("[CLUTCH] %6.1fs  AIM %s reacts in %.2fs"):format(clock(), bot.name, reactionDelay))
		end
		task.wait(reactionDelay)
	end

	for shot = 1, weapon.BurstShots do
		if targetHumanoid.Health <= 0 or not targetModel.Parent then
			break
		end
		local humanoid = selfModel:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return false
		end

		-- Turn toward the target FIRST; whatever error remains widens the cone.
		-- The first shot after the reaction delay has had that whole window to
		-- swing — the classic peeker's-advantage trade.
		local dt = weapon.FireInterval + (if shot == 1 then reactionDelay else 0)
		local aimError = Combat.faceTargetSmooth(bot, selfRoot, targetRoot.Position, dt)

		local sprayIndex = state.shotsSinceReset % RECOIL_RESET_SHOTS

		-- Head is only attempted on a settled crosshair: no head-hunting while
		-- still turning, and never mid-spray.
		local headshotIntent = HEADSHOT_INTENT_FLOOR + (attributes.Aim / 100) ^ 2 * HEADSHOT_INTENT_RANGE
		local settled = aimError < math.rad(6)
		local goingForHead = settled and sprayIndex == 0 and targetHead ~= nil and rng:NextNumber() < headshotIntent
		local aimPart = if goingForHead and targetHead then targetHead else targetRoot

		local origin = selfHead.Position
		local toTarget = aimPart.Position - origin
		local distance = toTarget.Magnitude
		local direction = toTarget.Unit

		local spreadDeg = spreadFor(weapon, attributes, distance, sprayIndex)
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
				return true
			end
		elseif Scenario.LogCombat then
			print(("[CLUTCH] %6.1fs  MISS %s -> %s | %.1f deg cone at %.0f studs"):format(
				clock(),
				bot.name,
				targetModel.Name,
				spreadDeg,
				distance
			))
		end

		task.wait(weapon.FireInterval)
	end

	return false
end

-- Called when a bot breaks contact: the next engagement pays reaction cost
-- again and the recoil pattern resets.
function Combat.disengage(state: State)
	state.engagedSince = nil
	state.shotsSinceReset = 0
end

return Combat
