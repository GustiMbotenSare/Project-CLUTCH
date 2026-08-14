-- Project CLUTCH — server bootstrap
-- M0 spike v2: builds the greybox arena from data, spawns 5v5 bots, puts
-- everyone on patrol orders (navmesh stress test across stairs, door chokes,
-- and the window ledge), then runs the shooting-range duel with Ace.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Greybox = require(Shared.MapData.Greybox)
local MapBuilder = require(script.MapBuilder)
local BotSpawner = require(script.BotSpawner)
local ShootingRange = require(script.ShootingRange)
local Patrol = require(script.Patrol)

print("[CLUTCH] server online — M0 spike v2")

MapBuilder.build(Greybox)

-- The navmesh needs a beat to bake after runtime geometry spawns —
-- pathing before this can silently fail (playtest bug C).
task.wait(1.5)

local rng = Random.new()
local teams = BotSpawner.spawnTeams(Greybox, rng)
print(("[CLUTCH] spawned %d attackers, %d defenders"):format(#teams.attack, #teams.defense))
for _, bot in ipairs(teams.attack) do
	print(("[CLUTCH] ATK %s (%s) — Aim %d / Rct %d / GS %d / Agg %d"):format(
		bot.name,
		bot.role,
		bot.attributes.Aim,
		bot.attributes.Reactions,
		bot.attributes.GameSense,
		bot.attributes.Aggression
	))
end

-- Everyone patrols except Ace — he's on range duty.
for _, bot in ipairs(teams.defense) do
	Patrol.start(bot, rng)
end
for i = 2, #teams.attack do
	Patrol.start(teams.attack[i], rng)
end

task.wait(2)
ShootingRange.run(teams.attack[1]) -- Ace, the Entry
