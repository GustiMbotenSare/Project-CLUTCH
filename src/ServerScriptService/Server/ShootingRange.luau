--!strict
-- M0 spike (from the GDD): one bot paths to a target dummy and shoots it.
-- Exercises the full pipeline: navmesh pathing, line-of-sight perception,
-- attribute-driven reaction delay, flick overshoot + spray error, hitscan damage.

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared.Constants.Weapons)
local SimConfig = require(Shared.Constants.SimConfig)

local BotSpawner = require(script.Parent.BotSpawner)

type BotRecord = BotSpawner.BotRecord

local DUMMY_POS = Vector3.new(0, 3, 30)
local ENGAGE_POS = Vector3.new(0, 1, 38)

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

local function pathTo(bot: Model, target: Vector3): boolean
	local humanoid = bot:WaitForChild("Humanoid") :: Humanoid
	local root = bot:WaitForChild("HumanoidRootPart") :: BasePart

	local path = PathfindingService:CreatePath({
		AgentHeight = 5,
		AgentRadius = 2,
		AgentCanJump = true,
	})
	path:ComputeAsync(root.Position, target)
	if path.Status ~= Enum.PathStatus.Success then
		return false
	end
	for _, waypoint in ipairs(path:GetWaypoints()) do
		humanoid:MoveTo(waypoint.Position)
		humanoid.MoveToFinished:Wait()
	end
	return true
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

function ShootingRange.run(shooterBot: BotRecord)
	task.spawn(function()
		local rng = Random.new()
		local weapon = Weapons.FalconAR
		local attrs = shooterBot.attributes

		local dummy = spawnDummy(DUMMY_POS)
		local dummyHumanoid = dummy:WaitForChild("Humanoid") :: Humanoid
		local dummyRoot = dummy:WaitForChild("HumanoidRootPart") :: BasePart

		print(("[CLUTCH] %s (%s) moves to the range — Aim %d, Reactions %d"):format(
			shooterBot.name,
			shooterBot.role,
			attrs.Aim,
			attrs.Reactions
		))

		pathTo(shooterBot.model, ENGAGE_POS)

		local head = shooterBot.model:WaitForChild("Head") :: BasePart

		-- Step closer until line of sight is clear (perception check)
		for _ = 1, 5 do
			if hasLineOfSight(head.Position, dummy, shooterBot.model) then
				break
			end
			local root = shooterBot.model:WaitForChild("HumanoidRootPart") :: BasePart
			local closer = root.Position + (DUMMY_POS - root.Position).Unit * 4
			pathTo(shooterBot.model, closer)
		end

		-- Reaction delay: Reactions=100 -> min delay, Reactions=1 -> base delay
		local reaction = SimConfig.ReactionDelayBaseSeconds
			+ (SimConfig.ReactionDelayMinSeconds - SimConfig.ReactionDelayBaseSeconds)
				* (attrs.Reactions / 100)
		print(("[CLUTCH] %s spots the dummy, reacts in %.2fs"):format(shooterBot.name, reaction))
		task.wait(reaction)

		-- Duel loop: flick overshoot on the opener, then spray with growing error
		local shotIndex = 0
		while dummyHumanoid.Health > 0 do
			shotIndex += 1

			local overshootChance = SimConfig.FlickOvershootBaseChance * (1 - (attrs.Aim / 100) * 0.8)
			local whiffed = shotIndex == 1 and rng:NextNumber() < overshootChance

			local spreadDeg = math.min(
				weapon.FirstBulletSpreadDeg + weapon.SprayErrorGrowthDeg * (shotIndex - 1),
				weapon.MaxSprayErrorDeg
			)

			local aimPoint = dummyRoot.Position
			local dist = (dummyRoot.Position - head.Position).Magnitude
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

			if result and result.Instance:IsDescendantOf(dummy) then
				local headshot = result.Instance.Name == "Head"
				local damage = if headshot
					then weapon.DamageBody * weapon.HeadshotMultiplier
					else weapon.DamageBody
				dummyHumanoid:TakeDamage(damage)
				print(("[CLUTCH] %s hits (%s, %d dmg) — dummy HP %.0f"):format(
					shooterBot.name,
					if headshot then "HEADSHOT" else "body",
					damage,
					math.max(dummyHumanoid.Health, 0)
				))
			else
				print(("[CLUTCH] %s misses%s"):format(shooterBot.name, if whiffed then " (flick overshoot)" else ""))
			end

			task.wait(weapon.FireInterval)
		end

		print(("[CLUTCH] dummy down in %d shots — spike complete ✅"):format(shotIndex))
	end)
end

return ShootingRange
