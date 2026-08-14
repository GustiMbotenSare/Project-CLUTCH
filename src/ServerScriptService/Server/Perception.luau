--!strict
-- Perception: what a bot could plausibly know.
--
-- This module is the honesty layer. Everything the brain decides has to be
-- justified by a contact that came from here — no reading enemy positions off
-- the server. That constraint is what makes the sim watchable: bots walk into
-- rooms because they heard something, not because they were told.
--
-- Three senses, ranked by reliability:
--   * SIGHT   — inside the vision cone, within range, clear raycast. Exact.
--   * SOUND   — footsteps inside a short radius. Position known, no LOS needed.
--   * MEMORY  — a stale contact, decaying over MemoryDecaySeconds. This is what
--              makes a bot re-check a last-known position instead of tracking
--              an enemy perfectly through walls.
--
-- Runs on its own loop (PerceptionTickSeconds) which is faster than the
-- decision loop, so a bot keeps sensing while it walks.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local SimConfig = require(Shared.Constants.SimConfig)
local Scenario = require(Shared.Constants.Scenario)
local Zones = require(Shared.MapData.Zones)

export type Source = "sight" | "sound"

export type Contact = {
	name: string,
	pos: Vector3,
	zoneKey: string,
	zoneCallout: string,
	seenAt: number,
	source: Source,
}

export type State = {
	visible: { [string]: boolean },
	memory: { [string]: Contact },
	lastContactAt: number,
	running: boolean,
}

local Perception = {}

local COS_HALF_CONE = math.cos(math.rad(SimConfig.VisionConeDeg / 2))

function Perception.new(): State
	return {
		visible = {},
		memory = {},
		lastContactAt = -math.huge,
		running = true,
	}
end

local function aliveRoot(model: Model): BasePart?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return nil
	end
	return model:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function clearLineOfSight(fromPos: Vector3, targetModel: Model, selfModel: Model, targetRoot: BasePart): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { selfModel }
	local result = workspace:Raycast(fromPos, targetRoot.Position - fromPos, params)
	return result ~= nil and result.Instance:IsDescendantOf(targetModel)
end

-- One sweep. Returns the strongest current contact, or nil.
function Perception.sweep(state: State, bot: any, enemies: { any }, now: number): Contact?
	local selfModel = bot.model :: Model
	local selfRoot = aliveRoot(selfModel)
	if not selfRoot then
		return nil
	end

	local head = selfModel:FindFirstChild("Head") :: BasePart?
	local eyePos = if head then head.Position else selfRoot.Position
	local facing = selfRoot.CFrame.LookVector

	local best: Contact? = nil

	for _, enemy in enemies do
		local enemyModel = enemy.model :: Model
		if not enemyModel.Parent then
			continue
		end
		local enemyRoot = aliveRoot(enemyModel)
		if not enemyRoot then
			state.visible[enemy.name] = false
			continue
		end

		local delta = enemyRoot.Position - eyePos
		local distance = delta.Magnitude
		local wasVisible = state.visible[enemy.name] == true
		local source: Source? = nil

		if distance <= SimConfig.VisionRangeStuds and distance > 0.1 then
			local inCone = facing:Dot(delta.Unit) >= COS_HALF_CONE
			if inCone and clearLineOfSight(eyePos, enemyModel, selfModel, enemyRoot) then
				source = "sight"
			end
		end

		-- Footsteps leak position regardless of where you are looking
		if source == nil and distance <= SimConfig.FootstepSoundRadiusStuds then
			source = "sound"
		end

		if source then
			local ground = Zones.groundOf(enemyModel)
			local zone = Zones.at(ground)
			local contact: Contact = {
				name = enemy.name,
				pos = enemyRoot.Position,
				zoneKey = if zone then zone.key else Zones.VOID,
				zoneCallout = if zone then zone.callout else "Off-map",
				seenAt = now,
				source = source,
			}
			state.memory[enemy.name] = contact
			state.lastContactAt = now

			local isSight = source == "sight"
			state.visible[enemy.name] = isSight

			if Scenario.LogPerception and isSight and not wasVisible then
				print(("[CLUTCH] %6.1fs  SPOT %s sees %s in %s (%.0f studs)"):format(
					now,
					bot.name,
					enemy.name,
					contact.zoneCallout,
					distance
				))
			end

			-- Sight beats sound when both are available this tick
			if best == nil or (isSight and best.source == "sound") then
				best = contact
			end
		else
			if Scenario.LogPerception and wasVisible then
				local remembered = state.memory[enemy.name]
				print(("[CLUTCH] %6.1fs  LOST %s loses %s (last seen %s)"):format(
					now,
					bot.name,
					enemy.name,
					if remembered then remembered.zoneCallout else "nowhere"
				))
			end
			state.visible[enemy.name] = false
		end
	end

	-- Expire stale intel. A bot acting on a 30-second-old contact looks psychic
	-- in the wrong direction.
	for name, contact in state.memory do
		if now - contact.seenAt > SimConfig.MemoryDecaySeconds then
			state.memory[name] = nil
		end
	end

	return best
end

-- Freshest surviving contact, sight preferred over sound.
function Perception.bestContact(state: State, now: number): Contact?
	local best: Contact? = nil
	for _, contact in state.memory do
		if now - contact.seenAt > SimConfig.MemoryDecaySeconds then
			continue
		end
		if best == nil then
			best = contact
			continue
		end
		local betterSource = contact.source == "sight" and best.source == "sound"
		local sameSourceFresher = contact.source == best.source and contact.seenAt > best.seenAt
		if betterSource or sameSourceFresher then
			best = contact
		end
	end
	return best
end

function Perception.anyVisible(state: State): boolean
	for _, isVisible in state.visible do
		if isVisible then
			return true
		end
	end
	return false
end

-- Background sense loop, faster than the decision loop.
function Perception.startLoop(state: State, bot: any, enemies: { any }, clock: () -> number)
	task.spawn(function()
		local model = bot.model :: Model
		while state.running and model.Parent do
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health <= 0 then
				break
			end
			Perception.sweep(state, bot, enemies, clock())
			task.wait(SimConfig.PerceptionTickSeconds)
		end
	end)
end

return Perception
