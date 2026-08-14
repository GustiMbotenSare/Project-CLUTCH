--!strict
-- Spawns bot players as real humanoid rigs (no rig assets needed —
-- CreateHumanoidModelFromDescription gives us a clean R6 dummy per bot).
-- Each bot gets attributes rolled from its role's weight template.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Attributes = require(Shared.Constants.Attributes)

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

	local tagColor = if side == "Attack"
		then Color3.fromRGB(255, 150, 60)
		else Color3.fromRGB(80, 200, 255)
	addNameTag(model, name, tagColor)

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
