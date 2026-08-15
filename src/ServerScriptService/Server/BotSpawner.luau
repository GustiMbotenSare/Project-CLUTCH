--!strict
-- Spawns bot players as real humanoid rigs (no rig assets needed —
-- CreateHumanoidModelFromDescription gives us a clean R6 dummy per bot).
-- Each bot gets attributes rolled from its role's weight template.
--
-- Bots never body-block EACH OTHER: they live in a collision group that
-- doesn't self-collide (the playtest #11 B-door jam).
--
-- THE VISUAL LAYER (playtest #16):
--   * RIG_STYLE is the single source for every cosmetic choice — body tint
--     per side, visor color, gun color/lengths. The reskin pass touches this
--     table and the part names (Visor / Gun / NameTag), nothing else.
--   * Team body tints: attackers warm, defenders cool. The "all black"
--     default rigs read as one identical crowd; sides must read at a glance.
--   * THE GUN is a real physical part (a block, deliberately) welded at the
--     right hand — named, attributed with the weapon's name, and sized by
--     class, because the "dropped gun" phase will detach exactly this part.
--     CanQuery=false: it adds zero hitbox.
--   * THE VISOR: a neon strip on the head's front face — which way a bot is
--     LOOKING is half the broadcast. CanQuery=false as well.
--   * AUTOROTATE IS OFF: the legs no longer own the eyes. The brain's facing
--     loop turns the root toward what matters (a contact, the watch line,
--     the route ahead) while the feet path independently — a bot can watch
--     the flank while it crosses the lane, like a player would.
--   * PROCEDURAL WALK: R6 shoulder/hip motors swing out of phase with speed
--     (arms counter the same-side leg). Cheap, reskin-safe, and enough to
--     read movement at spectator distance.

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
-- is named (Visor, Gun, NameTag). Polish phase = edit this table.
local RIG_STYLE = {
	Body = {
		Attack = Color3.fromRGB(140, 95, 65), -- warm
		Defense = Color3.fromRGB(75, 100, 135), -- cool
	},
	Visor = Color3.fromRGB(255, 230, 120),
	Gun = Color3.fromRGB(35, 35, 40),
	GunLength = { Pistol = 0.8, Rifle = 1.4, Sniper = 1.9 },
}

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

-- THE GUN: a block at the right hand, long axis forward, named and
-- attributed — the dropped-gun phase detaches exactly this part.
local function addGun(model: Model)
	local torso = model:WaitForChild("Torso", 5) :: BasePart?
	if not torso then
		return
	end
	local gun = Instance.new("Part")
	gun.Name = "Gun"
	gun.Size = Vector3.new(0.25, 0.25, RIG_STYLE.GunLength.Pistol)
	gun.Color = RIG_STYLE.Gun
	gun.Material = Enum.Material.SmoothPlastic
	gun.CanCollide = false
	gun.CanQuery = false -- zero hitbox, like the visor
	gun.CanTouch = false
	gun.CastShadow = false
	gun.Massless = true
	gun.CollisionGroup = BOT_COLLISION_GROUP
	gun:SetAttribute("WeaponName", "Sidearm")
	gun.CFrame = torso.CFrame * CFrame.new(0.6, -0.7, -0.6)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = torso
	weld.Part1 = gun
	weld.Parent = gun

	gun.Parent = model
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

-- PROCEDURAL WALK: swing R6 shoulders/hips out of phase with ground speed.
-- Arms counter the same-side leg; amplitude follows velocity; idle relaxes.
local function startProceduralWalk(model: Model)
	local humanoid = model:WaitForChild("Humanoid", 5)
	local torso = model:WaitForChild("Torso", 5)
	if not humanoid or not torso then
		return
	end
	local leftShoulder = torso:FindFirstChild("Left Shoulder") :: Motor6D?
	local rightShoulder = torso:FindFirstChild("Right Shoulder") :: Motor6D?
	local leftHip = torso:FindFirstChild("Left Hip") :: Motor6D?
	local rightHip = torso:FindFirstChild("Right Hip") :: Motor6D?

	task.spawn(function()
		local t = 0
		while model.Parent and humanoid.Health > 0 do
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
				rightShoulder.Transform = rightShoulder.Transform:Lerp(CFrame.Angles(-swing, 0, 0), 0.35)
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
	-- decides what the bot looks at; the feet path independently.
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
	startProceduralWalk(model)

	model.Parent = workspace
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
