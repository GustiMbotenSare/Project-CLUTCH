--!strict
-- Project CLUTCH — server bootstrap.
--
-- Brain v1. The map is greyboxed, every area has a name, and bots decide where
-- to go by scoring intents against what they can actually perceive.
--
-- Boots into Duel1v1 by default (see Shared/Constants/Scenario). Ten bots at
-- once produced a log nobody could read; two produce an auditable transcript.
-- Flip Scenario.Mode to "Full5v5" once the decisions look sane.
--
-- Retired from the default path: Patrol (random POI wandering, scaffolding for
-- proving the navmesh worked) and ShootingRange (proved the duel maths). Both
-- still exist; the range can be switched back on via Scenario.RunShootingRange.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Greybox = require(Shared.MapData.Greybox)
local Zones = require(Shared.MapData.Zones)
local Scenario = require(Shared.Constants.Scenario)

local MapBuilder = require(script.MapBuilder)
local BotSpawner = require(script.BotSpawner)
local Telemetry = require(script.Telemetry)
local Brain = require(script.Brain)
local ShootingRange = require(script.ShootingRange)

print(("[CLUTCH] server online — brain v1 (%s)"):format(Scenario.Mode))

MapBuilder.build(Greybox)
print(("[CLUTCH] %d named zones loaded"):format(#Zones.list))

-- Structural audit, every boot. Attacker and defender routes to each site
-- should be comparable in length. In a real tac shooter defenders arrive on
-- site FIRST; if these numbers say otherwise, the greybox needs a connector,
-- not the brain. Cheap to run, catches map regressions immediately.
local function hopAudit(spawnKey: string)
	local zone = Zones.byKey[spawnKey]
	local label = if zone then zone.callout else spawnKey
	local toA = Zones.hops(spawnKey, "A_SITE")
	local toB = Zones.hops(spawnKey, "B_SITE")
	print(("[CLUTCH] route audit: %s -> A Site %s hops, B Site %s hops"):format(
		label,
		if toA == math.huge then "UNREACHABLE" else tostring(toA),
		if toB == math.huge then "UNREACHABLE" else tostring(toB)
	))
end
hopAudit("ATK_SPAWN")
hopAudit("DEF_SPAWN")

-- Let the navmesh bake before anyone asks it for a path
task.wait(1.5)

local rng = Random.new()
local teams = BotSpawner.spawnTeams(Greybox, rng)

local attackers = teams.attack
local defenders = teams.defense
print(("[CLUTCH] spawned %d attackers, %d defenders"):format(#attackers, #defenders))

-- Both rosters now. Previously only attackers were printed, which made it
-- impossible to reason about defender behaviour from the log alone.
local function printRoster(label: string, roster: { any })
	for _, bot in roster do
		print(("[CLUTCH] %s %s (%s) — Aim %d / Rct %d / GS %d / Agg %d"):format(
			label,
			bot.name,
			bot.role,
			bot.attributes.Aim,
			bot.attributes.Reactions,
			bot.attributes.GameSense,
			bot.attributes.Aggression
		))
	end
end

-- Duel mode: keep one bot per side, remove the rest.
local function keepOnly(roster: { any }, wanted: string): { any }
	local chosen = nil
	for _, bot in roster do
		if bot.name == wanted then
			chosen = bot
			break
		end
	end
	if not chosen then
		chosen = roster[1]
		if chosen then
			warn(("[CLUTCH] duel bot %q not found, falling back to %s"):format(wanted, chosen.name))
		end
	end
	for _, bot in roster do
		if bot ~= chosen then
			(bot.model :: Model):Destroy()
		end
	end
	return if chosen then { chosen } else {}
end

if Scenario.Mode == "Duel1v1" then
	attackers = keepOnly(attackers, Scenario.DuelAttacker)
	defenders = keepOnly(defenders, Scenario.DuelDefender)
	print("[CLUTCH] duel mode — everyone else sent home")
end

printRoster("ATK", attackers)
printRoster("DEF", defenders)

-- Telemetry first, so the brain's opening decisions already have a track to
-- write their intent into.
for _, bot in attackers do
	Telemetry.attach(bot, "Attack")
end
for _, bot in defenders do
	Telemetry.attach(bot, "Defense")
end

for _, bot in attackers do
	Brain.start(bot, "Attack", defenders, attackers, rng, Telemetry.clock)
end
for _, bot in defenders do
	Brain.start(bot, "Defense", attackers, defenders, rng, Telemetry.clock)
end

Telemetry.startReporting()
print("[CLUTCH] brains online — watch for THINK / MOVE / SPOT lines")

if Scenario.RunShootingRange and #attackers > 0 then
	task.wait(2)
	ShootingRange.run(attackers[1])
end
