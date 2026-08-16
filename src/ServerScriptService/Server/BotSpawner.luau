--!strict
-- Spawns bot players as real humanoid rigs (no rig assets needed —
-- CreateHumanoidModelFromDescription gives us a clean R6 dummy per bot).
-- Each bot gets attributes rolled from its role's weight template.
--
-- Bots never body-block EACH OTHER: they live in a collision group that
-- doesn't self-collide (the playtest #11 B-door jam).
--
-- THE VISUAL LAYER (playtest #16 + #17 + #19):
--   * RIG_STYLE is the single source for every cosmetic choice — body tint
--     per side, visor color, gun color/lengths, the knife. The reskin pass
--     touches this table and the part names (Visor / Gun / Knife / NameTag),
--     nothing else.
--   * Team body tints: attackers warm, defenders cool.
--   * AIM ALIGN (playtest #17's catastrophe): every rig carries an
--     AlignOrientation ("AimAlign") on the root — the physics-safe facing
--     channel. Nobody writes a walking root's CFrame.
--   * THE GUN rides the raised right hand; THE KNIFE (#19) shares that hand —
--     a stub blade, hidden while the gun is out. styleHeld swaps which prop
--     reads, so the broadcast can SEE the sprint-for-knife trade.
--   * PROCEDURAL WALK: starts AFTER the model is parented and is PUBLIC:
--     the round machine restarts it on every clone.
--   * AUTOROTATE IS OFF: the legs no longer own the eyes.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Constants.Attributes)

local BOT_COLLISION_GROUP = "ClutchBots"
pcall(function()
	PhysicsService:RegisterCollisionGroup(BOT_COLLISION_GROUP)
end)
PhysicsService:CollisionGroupSetCollidable(BOT_COLLISION_GROUP, BOT_COLLISION_GROUP, false)

-- THE RESKIN CONTRACT. Every cosmetic choice lives here; every cosmetic part
-- is named (Visor, Gun, Knife, NameTag). Polish phase = edit this table.
local RIG_STYLE = {
	Body = {
		Attack = Color3.fromRGB(140, 95, 65), -- warm
		Defense = Color3.fromRGB(75, 100, 135), -- cool
	},
	Visor = Color3.fromRGB(255, 230, 120),
	Gun = Color3.fromRGB(35, 35, 40),
	GunLength = { Pistol = 0.8, Rifle = 1.4, Sniper = 1.9 },
	Knife = Color3.fromRGB(200, 200, 215),
	KnifeLength = 0.6,
}

-- The raised gun-arm pose: the right shoulder held forward (~80°), with the
-- walk swing layered small on top so the gun doesn't wave around.
local GUN_ARM_RAISED = CFrame.Angles(math.rad(80), 0, 0)
local GUN_ARM_SWING_SCALE = 0.25

export type BotRecord = {
	name: string,
	role: string,
	side: string,
	attributes: Attributes.AttributeSet,
	model: Model,
}

-- M0 test rosters. Names become personalities once the storyline engine exists.
local ROSTER = {
	attack = {
		{ name = "Ace", role = "Entry" },
		{ name = "Volt", role = "Support" },
		{ name = "Echo", role = "IGL" },
		{ name = "Rook", role = "Sniper" },
		{ name = "Drift", role = "Lurker" },
	},
	defense = {
		{ name = "Onyx", role = "Anchor" },
		{ name = "Pixel", role = "Anchor" },
		{ name = "Surge", role = "Support" },
		{ name = "Havoc", role = "IGL" },
		{ name = "Jinx", role = "Sniper" },
	},
}

local BotSpawner = {}

-- Roll 1-100 attributes biased by role weights: base 35 + weight*55 + noise.
-- A 1.0-weight attribute lands ~82-98; a 0.2-weight lands ~38-54.
function BotSpawner.rollAttributes(role: string, rng: Random): Attributes.AttributeSet
	local weights = Attributes.RoleWeights[role] or {}
	local set: { [string]: number } = {}
	for _, attr in ipairs(Attributes.List) do
		local w = weights[attr] or 0.5
		local value = 35 + w * 55 + rng:NextNumber(-8, 8)
		set[attr] = math.clamp(math.round(value), Attributes.Min, Attributes.Max)
	end
	return set :: Attributes.AttributeSet
end

local function addNameTag(model: Model, text: string, color: Color3)
	local head = model:WaitForChild("Head", 5)
	if not head then
		return
	end
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameTag"
	billboard.Size = UDim2.fromOffset(140, 32)
	billboard.StudsOffset = Vector3.new(0, 2.6, 0)
	billboard.AlwaysOnTop = true
	billboard.Adornee = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = billboard

	billboard.Parent = head
end

-- A bright strip on the head's FRONT face (−Z is look direction). Welded,
-- massless, and CanQuery=false so it never widens a hitbox.
local function addVisor(model: Model)
	local head = model:WaitForChild("Head", 5) :: BasePart?
	if not head then
		return
	end
	local visor = Instance.new("Part")
	visor.Name = "Visor"
	visor.Size = Vector3.new(head.Size.X * 0.7, head.Size.Y * 0.35, 0.12)
	visor.Color = RIG_STYLE.Visor
	visor.Material = Enum.Material.Neon
	visor.CanCollide = false
	visor.CanQuery = false -- enemy aim raycasts pass straight through it
	visor.CanTouch = false
	visor.CastShadow = false
	visor.Massless = true
	visor.CollisionGroup = BOT_COLLISION_GROUP
	visor.CFrame = head.CFrame * CFrame.new(0, 0, -(head.Size.Z / 2 + 0.06))

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = head
	weld.Part1 = visor
	weld.Parent = visor

	visor.Parent = model
end

-- AIM ALIGN: the physics-safe facing channel. One attachment on the root,
-- one AlignOrientation — turnToward points it, torque turns the body, the
-- humanoid mover is never touched.
local function addAimAlign(model: Model)
	local root = model:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	if not root then
		return
	end
	local attachment = root:FindFirstChild("RootAttachment") :: Attachment?
	if not attachment then
		attachment = Instance.new("Attachment")
		attachment.Name = "RootAttachment"
		attachment.Parent = root
	end
	local align = Instance.new("AlignOrientation")
	align.Name = "AimAlign"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = false
	align.Responsiveness = 30
	align.MaxAngularVelocity = math.rad(360)
	-- Hold the spawn facing until the brain points somewhere.
	align.CFrame = CFrame.new(Vector3.zero) * root.CFrame.Rotation
	align.Parent = root
end

-- A hand prop welded to the raised right hand, long axis down the arm.
local function addHandProp(model: Model, name: string, length: number, color: Color3, visible: boolean): BasePart?
	local arm = model:WaitForChild("Right Arm", 5) :: BasePart?
	if not arm then
		return nil
	end
	local prop = Instance.new("Part")
	prop.Name = name
	prop.Size = Vector3.new(0.25, 0.25, length)
	prop.Color = color
	prop.Material = Enum.Material.SmoothPlastic
	prop.CanCollide = false
	prop.CanQuery = false -- zero hitbox, like the visor
	prop.CanTouch = false
	prop.CastShadow = false
	prop.Massless = true
	prop.Transparency = if visible then 0 else 1
	prop.CollisionGroup = BOT_COLLISION_GROUP
	prop.CFrame = arm.CFrame * CFrame.new(0, -1.15, 0) * CFrame.Angles(math.rad(90), 0, 0)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = arm
	weld.Part1 = prop
	weld.Parent = prop

	prop.Parent = model
	return prop
end

local function addGun(model: Model)
	local gun = addHandProp(model, "Gun", RIG_STYLE.GunLength.Pistol, RIG_STYLE.Gun, true)
	if gun then
		gun:SetAttribute("WeaponName", "Sidearm")
	end
end

local function addKnife(model: Model)
	addHandProp(model, "Knife", RIG_STYLE.KnifeLength, RIG_STYLE.Knife, false)
end

-- Re-style the carried gun after a buy (the round machine clones fresh rigs
-- each round; this is what makes the Longshot READ as a Longshot).
function BotSpawner.styleGun(model: Model, weapon: any)
	local gun = model:FindFirstChild("Gun") :: BasePart?
	if not gun then
		return
	end
	gun.Size = Vector3.new(0.25, 0.25, RIG_STYLE.GunLength[weapon.Class] or 0.8)
	gun:SetAttribute("WeaponName", weapon.DisplayName)
end

-- The held-item read: gun out, or knife out. The broadcast should be able to
-- SEE the sprint-for-knife trade before it reads a stat line.
function BotSpawner.styleHeld(model: Model, holding: string)
	local gun = model:FindFirstChild("Gun") :: BasePart?
	local knife = model:FindFirstChild("Knife") :: BasePart?
	if gun then
		gun.Transparency = if holding == "Knife" then 1 else 0
	end
	if knife then
		knife.Transparency = if holding == "Knife" then 0 else 1
	end
end

-- PROCEDURAL WALK. PUBLIC: the round machine restarts this on every cloned
-- body (task loops don't survive a clone). Right shoulder holds the gun arm
-- up (GUN_ARM_RAISED) with a small layered swing; left arm and both legs
-- swing against it with ground speed. Call AFTER the model is parented —
-- starting it earlier exited instantly (the "they still slide" bug).
function BotSpawner.startProceduralWalk(model: Model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local torso = model:FindFirstChild("Torso")
	if not humanoid or not torso then
		return
	end
	local leftShoulder = torso:FindFirstChild("Left Shoulder") :: Motor6D?
	local rightShoulder = torso:FindFirstChild("Right Shoulder") :: Motor6D?
	local leftHip = torso:FindFirstChild("Left Hip") :: Motor6D?
	local rightHip = torso:FindFirstChild("Right Hip") :: Motor6D?

	task.spawn(function()
		local t = 0
		while model.Parent do
			local humanoidNow = model:FindFirstChildOfClass("Humanoid")
			if not humanoidNow or humanoidNow.Health <= 0 then
				break -- the dead stop mid-stride; the round machine retires the body
			end
			local dt = 0.05
			t += dt
			local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			local speed = if root then root.AssemblyLinearVelocity.Magnitude else 0
			local amp = math.clamp(speed / 16, 0, 1) * 0.7
			local swing = math.sin(t * 11) * amp
			if leftShoulder then
				leftShoulder.Transform = leftShoulder.Transform:Lerp(CFrame.Angles(swing, 0, 0), 0.35)
			end
			if rightShoulder then
				local target = GUN_ARM_RAISED * CFrame.Angles(-swing * GUN_ARM_SWING_SCALE, 0, 0)
				rightShoulder.Transform = rightShoulder.Transform:Lerp(target, 0.35)
			end
			if leftHip then
				leftHip.Transform = leftHip.Transform:Lerp(CFrame.Angles(-swing, 0, 0), 0.35)
			end
			if rightHip then
				rightHip.Transform = rightHip.Transform:Lerp(CFrame.Angles(swing, 0, 0), 0.35)
			end
			task.wait(dt)
		end
	end)
end

function BotSpawner.spawnBot(
	name: string,
	role: string,
	side: string,
	position: Vector3,
	rng: Random
): BotRecord
	local description = Instance.new("HumanoidDescription")
	-- Team body tints — sides must read at spectator distance.
	local body = RIG_STYLE.Body[side] or Color3.fromRGB(120, 120, 120)
	description.HeadColor = body
	description.TorsoColor = body
	description.LeftArmColor = body
	description.RightArmColor = body
	description.LeftLegColor = body
	description.RightLegColor = body

	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
	model.Name = name
	-- Face the map, not the wall behind you: attackers spawn south facing −z,
	-- defenders spawn north facing +z.
	if side == "Attack" then
		model:PivotTo(CFrame.new(position))
	else
		model:PivotTo(CFrame.lookAt(position, position + Vector3.zAxis))
	end

	-- No bot-on-bot collision (see header). Clones made by the round machine
	-- inherit the group.
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			inst.CollisionGroup = BOT_COLLISION_GROUP
		end
	end

	-- AUTOROTATE OFF: the legs no longer own the eyes. The brain's facing loop
	-- (through AimAlign) decides what the bot looks at.
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.AutoRotate = false
	end

	local tagColor = if side == "Attack"
		then Color3.fromRGB(255, 150, 60)
		else Color3.fromRGB(80, 200, 255)
	addNameTag(model, name, tagColor)
	addVisor(model)
	addGun(model)
	addKnife(model)
	addAimAlign(model)

	model.Parent = workspace
	-- Walk swing starts AFTER parenting (starting earlier exited instantly).
	BotSpawner.startProceduralWalk(model)
	return {
		name = name,
		role = role,
		side = side,
		attributes = BotSpawner.rollAttributes(role, rng),
		model = model,
	}
end

function BotSpawner.spawnTeams(mapSpec: any, rng: Random): { attack: { BotRecord }, defense: { BotRecord } }
	local teams = { attack = {}, defense = {} } :: { attack: { BotRecord }, defense: { BotRecord } }
	for i, entry in ipairs(ROSTER.attack) do
		table.insert(teams.attack, BotSpawner.spawnBot(entry.name, entry.role, "Attack", mapSpec.attackSpawns[i], rng))
	end
	for i, entry in ipairs(ROSTER.defense) do
		table.insert(teams.defense, BotSpawner.spawnBot(entry.name, entry.role, "Defense", mapSpec.defenseSpawns[i], rng))
	end
	return teams
end

return BotSpawner
