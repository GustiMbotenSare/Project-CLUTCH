--!strict
-- M0 spike: one bot paths out and duels a target dummy.
-- Exercises: navmesh pathing, LOS perception, attribute-driven reaction delay,
-- flick overshoot + spray error, hitscan damage — with VISIBLE tracers.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared.Constants.Weapons)
local SimConfig = require(Shared.Constants.SimConfig)

local Pathing = require(script.Parent.Pathing)

local DUMMY_POS = Vector3.new(0, 3, 30)
local ENGAGE_POS = Vector3.new(0, 1, 38)
local TRACER_LIFETIME = 0.09

-- Aim-height intent. Aim 1 -> ~10% of bursts go for the head, Aim 100 -> ~45%.
-- Squared so the difference between a 60-Aim and a 90-Aim bot is dramatic,
-- which is the whole point of a manager game.
local HEADSHOT_INTENT_FLOOR = 0.10
local HEADSHOT_INTENT_RANGE = 0.35
local RECOIL_RESET_SHOTS = 4 -- bursts, not one endless spray

local ShootingRange = {}

local function spawnDummy(position: Vector3): Model
	local description = Instance.new("HumanoidDescription")
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
	model.Name = "TargetDummy"
	model:PivotTo(CFrame.new(position))

	-- Bigger HP pool so the spray/miss pattern is visible in the log
	local humanoid = model:WaitForChild("Humanoid") :: Humanoid
	humanoid.MaxHealth = 1000
	humanoid.Health = 1000

	local root = model:WaitForChild("HumanoidRootPart") :: BasePart
	root.Anchored = true

	model.Parent = workspace
	return model
end

-- A gunshot you can SEE. Spectate-first means zero invisible damage, even in spikes.
local function tracer(from: Vector3, to: Vector3)
	local dist = (to - from).Magnitude
	if dist < 0.1 then
		return
	end
	local beam = Instance.new("Part")
	beam.Name = "Tracer"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = Color3.fromRGB(255, 220, 120)
	beam.Size = Vector3.new(0.08, 0.08, dist)
	beam.CFrame = CFrame.lookAt((from + to) / 2, to)
	beam.Parent = workspace
	Debris:AddItem(beam, TRACER_LIFETIME)
end

local function hitSpark(at: Vector3)
	local spark = Instance.new("Part")
	spark.Name = "HitSpark"
	spark.Shape = Enum.PartType.Ball
	spark.Anchored = true
	spark.CanCollide = false
	spark.CanQuery = false
	spark.CanTouch = false
	spark.CastShadow = false
	spark.Material = Enum.Material.Neon
	spark.Color = Color3.fromRGB(255, 120, 60)
	spark.Size = Vector3.new(0.4, 0.4, 0.4)
	spark.CFrame = CFrame.new(at)
	spark.Parent = workspace
	Debris:AddItem(spark, 0.12)
end

local function hasLineOfSight(fromPos: Vector3, targetModel: Model, shooter: Model): boolean
	local targetRoot = targetModel:FindFirstChild("HumanoidRootPart")
	if not targetRoot then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { shooter }
	local result = workspace:Raycast(fromPos, targetRoot.Position - fromPos, params)
	return result ~= nil and result.Instance:IsDescendantOf(targetModel)
end

function ShootingRange.run(shooterBot: any)
	task.spawn(function()
		local rng = Random.new()
		local weapon = Weapons.FalconAR
		local attrs = shooterBot.attributes

		local dummy = spawnDummy(DUMMY_POS)
		local dummyHumanoid = dummy:WaitForChild("Humanoid") :: Humanoid
		local dummyRoot = dummy:WaitForChild("HumanoidRootPart") :: BasePart
		local dummyHead = dummy:WaitForChild("Head") :: BasePart

		print(("[CLUTCH] %s (%s) moves to the range — Aim %d, Reactions %d"):format(
			shooterBot.name,
			shooterBot.role,
			attrs.Aim,
			attrs.Reactions
		))

		if not Pathing.walkTo(shooterBot.model, ENGAGE_POS) then
			warn(("[CLUTCH] %s never reached the range — check navmesh!"):format(shooterBot.name))
		end

		local head = shooterBot.model:WaitForChild("Head") :: BasePart

		-- Step closer until line of sight is clear (perception check)
		for _ = 1, 5 do
			if hasLineOfSight(head.Position, dummy, shooterBot.model) then
				break
			end
			local root = shooterBot.model:WaitForChild("HumanoidRootPart") :: BasePart
			local closer = root.Position + (DUMMY_POS - root.Position).Unit * 4
			Pathing.walkTo(shooterBot.model, closer)
		end

		-- Reaction delay: Reactions=100 -> min delay, Reactions=1 -> base delay
		local reaction = SimConfig.ReactionDelayBaseSeconds
			+ (SimConfig.ReactionDelayMinSeconds - SimConfig.ReactionDelayBaseSeconds)
				* (attrs.Reactions / 100)
		print(("[CLUTCH] %s spots the dummy, reacts in %.2fs"):format(shooterBot.name, reaction))
		task.wait(reaction)

		-- Playtest #3: aiming at HumanoidRootPart every shot made headshots an
		-- accident of geometry — 25 straight body shots at one engage distance,
		-- 7 straight headshots at another. Aim height is now an explicit decision.
		local headshotIntent = HEADSHOT_INTENT_FLOOR + (attrs.Aim / 100) ^ 2 * HEADSHOT_INTENT_RANGE

		local shotIndex = 0
		local headshots = 0
		local bodyshots = 0
		local misses = 0

		while dummyHumanoid.Health > 0 do
			shotIndex += 1

			-- Recoil resets between bursts, so spread climbs and falls
			local sprayIndex = (shotIndex - 1) % RECOIL_RESET_SHOTS
			local opener = sprayIndex == 0

			-- Commit to a target height on the opener; hold it through the burst
			local goingForHead = opener and rng:NextNumber() < headshotIntent
			local aimPart = if goingForHead then dummyHead else dummyRoot

			local overshootChance = SimConfig.FlickOvershootBaseChance * (1 - (attrs.Aim / 100) * 0.8)
			local whiffed = opener and rng:NextNumber() < overshootChance

			local spreadDeg = math.min(
				weapon.FirstBulletSpreadDeg + weapon.SprayErrorGrowthDeg * sprayIndex,
				weapon.MaxSprayErrorDeg
			)

			local aimPoint = aimPart.Position
			local dist = (aimPoint - head.Position).Magnitude
			if whiffed then
				aimPoint += Vector3.new(rng:NextNumber(-4, 4), rng:NextNumber(1, 3), 0)
			else
				local err = math.tan(math.rad(spreadDeg)) * dist
				local angle = rng:NextNumber() * math.pi * 2
				local mag = math.sqrt(rng:NextNumber()) * err
				aimPoint += Vector3.new(math.cos(angle) * mag, rng:NextNumber(-0.5, 0.5) * mag, math.sin(angle) * mag)
			end

			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { shooterBot.model }
			local result = workspace:Raycast(head.Position, aimPoint - head.Position, params)

			-- Every shot is visible, hit or miss
			tracer(head.Position, if result then result.Position else aimPoint)

			if result and result.Instance:IsDescendantOf(dummy) then
				hitSpark(result.Position)
				-- What we HIT, not what we aimed at
				local headshot = result.Instance.Name == "Head"
				local damage = if headshot
					then weapon.DamageBody * weapon.HeadshotMultiplier
					else weapon.DamageBody
				if headshot then
					headshots += 1
				else
					bodyshots += 1
				end
				dummyHumanoid:TakeDamage(damage)
				print(("[CLUTCH] %s hits (%s, %d dmg) — dummy HP %.0f"):format(
					shooterBot.name,
					if headshot then "HEADSHOT" else "body",
					damage,
					math.max(dummyHumanoid.Health, 0)
				))
			else
				misses += 1
				print(("[CLUTCH] %s misses%s"):format(shooterBot.name, if whiffed then " (flick overshoot)" else ""))
			end

			task.wait(weapon.FireInterval)
		end

		local landed = headshots + bodyshots
		print(("[CLUTCH] dummy down in %d shots — %d HS / %d body / %d miss (HS rate %.0f%%, intent %.0f%%) — spike complete ✅"):format(
			shotIndex,
			headshots,
			bodyshots,
			misses,
			if landed > 0 then headshots / landed * 100 else 0,
			headshotIntent * 100
		))
	end)
end

return ShootingRange
