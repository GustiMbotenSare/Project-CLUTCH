--!strict
-- Spawns bot players as real humanoid rigs (no rig assets needed —
-- CreateHumanoidModelFromDescription gives us a clean R6 dummy per bot).
-- Each bot gets attributes rolled from its role's weight template.
--
-- Bots never body-block EACH OTHER: they live in a collision group that
-- doesn't self-collide. Five bots funneling one door otherwise jam exactly
-- like players in a doorway, except bots can't negotiate it — that jam was
-- the playtest #11 BLOCKED cluster at the B door throat. Bots still collide
-- with the map, the spike, and the player.
--
-- THE VISOR (playtest #15): a neon strip welded to the head's front face.
-- The all-black rigs were unreadable — which way a bot is LOOKING is half
-- the broadcast. CanQuery is false: enemy raycasts skip it, so the visor
-- adds zero hitbox. Purely a facing indicator.

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
-- massless, and CanQuery=false so it never widens a hitbox. The round
-- machine's per-round clones inherit it like everything else on the rig.
local function addVisor(model: Model)
	local head = model:WaitForChild("Head", 5) :: BasePart?
	if not head then
		return
	end
	local visor = Instance.new("Part")
	visor.Name = "Visor"
	visor.Size = Vector3.new(head.Size.X * 0.7, head.Size.Y * 0.35, 0.12)
	visor.Color = Color3.fromRGB(255, 230, 120)
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

function BotSpawner.spawnBot(
	name: string,
	role: string,
	side: string,
	position: Vector3,
	rng: Random
): BotRecord
	local description = Instance.new("HumanoidDescription")
	local model = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R6)
	model.Name = name
	model:PivotTo(CFrame.new(position))

	-- No bot-on-bot collision (see header). Clones made by the round machine
	-- inherit the group.
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			inst.CollisionGroup = BOT_COLLISION_GROUP
		end
	end

	local tagColor = if side == "Attack"
		then Color3.fromRGB(255, 150, 60)
		else Color3.fromRGB(80, 200, 255)
	addNameTag(model, name, tagColor)
	addVisor(model)

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
