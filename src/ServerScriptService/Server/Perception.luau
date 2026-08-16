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
--   * SOUND   — footsteps and gunfire. Footsteps only exist if the target is
--               MOVING, and their radius follows the target's own speed:
--               sprinting is loud (40 studs), shift-walking is nearly silent
--               (12). Gunfire is global (GunshotSoundGlobal): Combat stamps
--               MatchState.lastShot per burst and this module turns it into a
--               sound contact. Sound gives position, never LOS.
--   * MEMORY  — a stale contact, decaying over MemoryDecaySeconds. This is what
--              makes a bot re-check a last-known position instead of tracking
--              an enemy perfectly through walls.
--
-- SIGHT IS DEBOUNCED. One raycast at one body part flickers constantly at long
-- range: a grazed divider edge or a swinging limb reads as "lost". An earlier
-- run logged twenty SPOT/LOST pairs during a single continuous sighting, some
-- 0.2s apart, which made the log useless and starved the brain of stable input.
-- We now try several aim points and require a run of failures before a bot
-- admits it lost someone. v4 map note: partial-cover duels graze LOS on every
-- peek, so the tolerance grew 4 -> 6 sweeps (~0.9s).
--
-- THE CONE IS YAW-ONLY (playtest #18): our facing has no pitch, so the cone
-- tests the FLAT delta and the vertical gets its own allowance. The old 3D
-- dot product made height differences eat the cone budget — a bot on heaven
-- literally could not see the floor it was guarding.
--
-- FIRST SIGHTINGS GO TO MATCH MEMORY: every fresh spot is recorded by zone,
-- so the plan roller and approach caution can read habits (batch C).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local SimConfig = require(Shared.Constants.SimConfig)
local Scenario = require(Shared.Constants.Scenario)
local Zones = require(Shared.MapData.Zones)

local MatchState = require(script.Parent.MatchState)
local MatchMemory = require(script.Parent.MatchMemory)

local LOS_MISS_TOLERANCE = 6 -- failed sweeps before a sighting counts as lost
local AIM_PARTS = { "Head", "HumanoidRootPart", "UpperTorso", "Torso" }
local VISION_PITCH_LIMIT_DEG = 75 -- vertical allowance; the cone is yaw-only

export type Source = "sight" | "sound"

export type Contact = {
	name: string,
	pos: Vector3,
	zoneKey: string,
	zoneCallout: string,
	seenAt: number,
	source: Source,
	distance: number,
}

export type State = {
	visible: { [string]: boolean },
	missStreak: { [string]: number },
	memory: { [string]: Contact },
	lastContactAt: number,
	running: boolean,
}

local Perception = {}

local COS_HALF_CONE = math.cos(math.rad(SimConfig.VisionConeDeg / 2))

function Perception.new(): State
	return {
		visible = {},
		missStreak = {},
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

local function eyesOf(model: Model, root: BasePart): Vector3
	local head = model:FindFirstChild("Head") :: BasePart?
	return if head then head.Position else root.Position
end

-- Yaw-only cone + a vertical allowance. The flat angle decides "in front of
-- me"; pitch just has to stay inside a generous band. (The old 3D dot let
-- height differences eat the cone budget — heaven couldn't see the floor.)
local function coneAllows(facing: Vector3, delta: Vector3, distance: number): boolean
	if distance < 0.1 then
		return false
	end
	local pitchDeg = math.deg(math.asin(math.clamp(delta.Y / distance, -1, 1)))
	if math.abs(pitchDeg) > VISION_PITCH_LIMIT_DEG then
		return false -- nearly straight overhead/underfoot: outside any gaze
	end
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < 0.5 then
		return true -- directly above/below: yaw is meaningless, pitch passed
	end
	local flatFacing = Vector3.new(facing.X, 0, facing.Z)
	if flatFacing.Magnitude < 0.1 then
		return true
	end
	return flatFacing.Unit:Dot(flat.Unit) >= COS_HALF_CONE
end

-- Try several body parts. A single ray at one part clips geometry edges and
-- limbs constantly at range, which is what caused the SPOT/LOST flapping.
local function hasClearShot(fromPos: Vector3, targetModel: Model, selfModel: Model): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { selfModel }

	for _, partName in AIM_PARTS do
		local part = targetModel:FindFirstChild(partName) :: BasePart?
		if not part then
			continue
		end
		local result = workspace:Raycast(fromPos, part.Position - fromPos, params)
		if result and result.Instance:IsDescendantOf(targetModel) then
			return true
		end
	end
	return false
end

-- Is `observer` looking at `target` right now? Used for the forced-engagement
-- case: a bot that has been seen should shoot back even from a bad range.
function Perception.hasEyesOn(observer: Model, target: Model): boolean
	local observerRoot = aliveRoot(observer)
	local targetRoot = aliveRoot(target)
	if not observerRoot or not targetRoot then
		return false
	end

	local eyes = eyesOf(observer, observerRoot)
	local delta = targetRoot.Position - eyes
	local distance = delta.Magnitude
	if distance > SimConfig.VisionRangeStuds or distance < 0.1 then
		return false
	end
	if not coneAllows(observerRoot.CFrame.LookVector, delta, distance) then
		return false
	end
	return hasClearShot(eyes, target, observer)
end

-- One sweep. Returns the strongest current contact, or nil.
function Perception.sweep(state: State, bot: any, enemies: { any }, now: number): Contact?
	local selfModel = bot.model :: Model
	local selfRoot = aliveRoot(selfModel)
	if not selfRoot then
		return nil
	end

	local eyePos = eyesOf(selfModel, selfRoot)
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

		local sighted = false
		if distance <= SimConfig.VisionRangeStuds and distance > 0.1 then
			if coneAllows(facing, delta, distance) then
				sighted = hasClearShot(eyePos, enemyModel, selfModel)
			end
		end

		-- Footsteps: only a MOVING enemy makes them, and the radius follows
		-- THEIR speed — sprinting carries 40 studs, shift-walking barely 12.
		local enemyHumanoid = enemyModel:FindFirstChildOfClass("Humanoid")
		local enemySpeed = if enemyHumanoid then enemyHumanoid.WalkSpeed else 16
		local moving = enemyRoot.AssemblyLinearVelocity.Magnitude > 2
		local stepRadius = if enemySpeed > 10
			then SimConfig.FootstepSoundRadiusStuds
			else SimConfig.WalkFootstepRadiusStuds
		local heard = not sighted and moving and distance <= stepRadius

		if sighted or heard then
			local ground = Zones.groundOf(enemyModel)
			local zone = Zones.at(ground)
			state.memory[enemy.name] = {
				name = enemy.name,
				pos = enemyRoot.Position,
				zoneKey = if zone then zone.key else Zones.VOID,
				zoneCallout = if zone then zone.callout else "Off-map",
				seenAt = now,
				source = if sighted then "sight" else "sound",
				distance = distance,
			}
			state.lastContactAt = now

			local contact = state.memory[enemy.name]
			if best == nil or (sighted and best.source == "sound") then
				best = contact
			end
		end

		if sighted then
			state.missStreak[enemy.name] = 0
			state.visible[enemy.name] = true
			if not wasVisible then
				-- First sighting: the match remembers where they keep showing up.
				local contact = state.memory[enemy.name]
				if contact then
					MatchMemory.recordSpot(bot.side, contact.zoneKey)
				end
				if Scenario.LogPerception then
					print(("[CLUTCH] %6.1fs  SPOT %s sees %s in %s (%.0f studs)"):format(
						now,
						bot.name,
						enemy.name,
						if contact then contact.zoneCallout else "?",
						distance
					))
				end
			end
		elseif wasVisible then
			-- Grace period. Do not drop a sighting on a single clipped ray.
			local streak = (state.missStreak[enemy.name] or 0) + 1
			state.missStreak[enemy.name] = streak
			if streak >= LOS_MISS_TOLERANCE then
				state.visible[enemy.name] = false
				if Scenario.LogPerception then
					local remembered = state.memory[enemy.name]
					print(("[CLUTCH] %6.1fs  LOST %s loses %s (last seen %s)"):format(
						now,
						bot.name,
						enemy.name,
						if remembered then remembered.zoneCallout else "nowhere"
					))
				end
			end
		end
	end

	-- GUNFIRE. Combat stamps MatchState.lastShot every burst; any enemy shooter
	-- becomes a fresh SOUND contact. Never overrides fresher eyes.
	local lastShot = MatchState.lastShot
	if SimConfig.GunshotSoundGlobal and lastShot and now - lastShot.at <= 1.0 then
		for _, enemy in enemies do
			if enemy.name == lastShot.by then
				local existing = state.memory[enemy.name]
				local sightFresher = existing ~= nil
					and existing.source == "sight"
					and existing.seenAt >= lastShot.at
				if not sightFresher then
					local zone = Zones.at(lastShot.pos)
					state.memory[enemy.name] = {
						name = enemy.name,
						pos = lastShot.pos,
						zoneKey = if zone then zone.key else Zones.VOID,
						zoneCallout = if zone then zone.callout else "Off-map",
						seenAt = now,
						source = "sound",
						distance = (lastShot.pos - eyePos).Magnitude,
					}
					state.lastContactAt = now
				end
				break
			end
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

-- A contact we can see RIGHT NOW. Shooting requires this; remembering does not.
function Perception.visibleContact(state: State): Contact?
	local best: Contact? = nil
	for name, isVisible in state.visible do
		if not isVisible then
			continue
		end
		local contact = state.memory[name]
		if contact and (best == nil or contact.distance < best.distance) then
			best = contact -- nearest visible enemy is the one that matters
		end
	end
	return best
end

function Perception.anyVisible(state: State): boolean
	return Perception.visibleContact(state) ~= nil
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
