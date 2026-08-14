-- Project CLUTCH — server bootstrap
-- M0 spike: builds the greybox arena from data, spawns 5v5 bots with
-- role-rolled attributes, then runs the shooting-range spike — the entry bot
-- paths out and duels a target dummy using the v0 duel model.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Greybox = require(Shared.MapData.Greybox)
local MapBuilder = require(script.MapBuilder)
local BotSpawner = require(script.BotSpawner)
local ShootingRange = require(script.ShootingRange)

print("[CLUTCH] server online — M0 spike")

MapBuilder.build(Greybox)

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

task.wait(2)
ShootingRange.run(teams.attack[1]) -- Ace, the Entry
