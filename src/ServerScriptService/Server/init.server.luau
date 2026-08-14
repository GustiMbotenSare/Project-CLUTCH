--!strict
-- Project CLUTCH — server bootstrap.
--
-- Round machine era. The map is greyboxed, every area has a name, bots decide
-- where to go by scoring intents against what they can actually perceive,
-- they shoot each other with weapons that have opinions about range, and the
-- whole thing now runs in ROUNDS: buy, live, plant/defuse, post-round, score,
-- credits. The client shows a live match dashboard fed by replicated
-- attributes (Telemetry + RoundMachine) and a kill-feed RemoteEvent.
--
-- Boots into Duel1v1 by default (see Shared/Constants/Scenario). Ten bots at
-- once produced a log nobody could read; two produce an auditable transcript.
-- Flip Scenario.Mode to "Full5v5" once the decisions look sane.
--
-- UniformStats is on by default. Every bot gets identical attributes, which
-- makes this a controlled experiment: any difference in behaviour between the
-- two duelists must come from role, side or situation, not from a stat roll.
-- Turn it off to watch attributes reassert themselves.
--
-- Retired: Patrol (random POI wandering, scaffolding for proving the navmesh
-- worked), ShootingRange (proved the duel maths against a dummy), and the
-- watchForDeath respawn stopgap — deaths are final inside a round now, and
-- RoundMachine owns resets between rounds.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Greybox = require(Shared.MapData.Greybox)
local Zones = require(Shared.MapData.Zones)
local Scenario = require(Shared.Constants.Scenario)
local Weapons = require(Shared.Constants.Weapons)

local MapBuilder = require(script.MapBuilder)
local BotSpawner = require(script.BotSpawner)
local Telemetry = require(script.Telemetry)
local RoundMachine = require(script.RoundMachine)
local ShootingRange = require(script.ShootingRange)

print(("[CLUTCH] server online — round machine + spectator HUD (%s)"):format(Scenario.Mode))

MapBuilder.build(Greybox)
print(("[CLUTCH] %d named zones loaded"):format(#Zones.list))

-- Client contract. The dashboard finds this folder by name; keep it stable.
local remotes = Instance.new("Folder")
remotes.Name = "CLUTCH"
remotes.Parent = ReplicatedStorage
local killFeed = Instance.new("RemoteEvent")
killFeed.Name = "KillFeed"
killFeed.Parent = remotes

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

-- Everyone starts on the same pistol with the same wallet; the economy decides
-- what they carry two rounds from now. Printing it keeps the log honest.
local startWeapon = Weapons[Scenario.DuelWeapon] or Weapons.Sidearm
print(("[CLUTCH] starting weapon: %s (%s) — everyone opens with it"):format(
	startWeapon.DisplayName,
	startWeapon.Class
))

-- Let the navmesh bake before anyone asks it for a path
task.wait(1.5)

local rng = Random.new()
local teams = BotSpawner.spawnTeams(Greybox, rng)

local attackers = teams.attack
local defenders = teams.defense
print(("[CLUTCH] spawned %d attackers, %d defenders"):format(#attackers, #defenders))

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

local roster: { any } = {}
for _, bot in attackers do
	table.insert(roster, bot)
end
for _, bot in defenders do
	table.insert(roster, bot)
end

-- CONTROLLED EXPERIMENT. Overwrite the rolled attributes with one identical
-- block. Two bots differing on six axes at once make it impossible to say which
-- attribute caused which behaviour.
if Scenario.UniformStats then
	for _, bot in roster do
		for stat, value in Scenario.UniformStatBlock do
			bot.attributes[stat] = value
		end
	end
	print(("[CLUTCH] UNIFORM STATS: every attribute forced to %d — differences are role/side/situation only"):format(
		Scenario.UniformStatBlock.Aim
	))
end

-- Pristine template + spawn pivot per bot. The round machine clones a fresh
-- body from this every round; a dead humanoid cannot be revived, and the
-- template never sees combat.
for _, bot in roster do
	local humanoid = (bot.model :: Model):FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.BreakJointsOnDeath = false
	end
	bot.spawnPivot = (bot.model :: Model):GetPivot()
	bot.template = (bot.model :: Model):Clone()
end

-- Both rosters, with every attribute that feeds a shot.
local function printRoster(label: string, side: { any })
	for _, bot in side do
		print(("[CLUTCH] %s %s (%s) — Aim %d / Rct %d / GS %d / Agg %d / Cons %d — %s"):format(
			label,
			bot.name,
			bot.role,
			bot.attributes.Aim,
			bot.attributes.Reactions,
			bot.attributes.GameSense,
			bot.attributes.Aggression,
			bot.attributes.Consistency,
			startWeapon.DisplayName
		))
	end
end
printRoster("ATK", attackers)
printRoster("DEF", defenders)

-- Telemetry first, so every round already has tracks to write into. Tracks
-- survive body swaps because they re-read bot.model every tick.
for _, bot in attackers do
	Telemetry.attach(bot, "Attack")
end
for _, bot in defenders do
	Telemetry.attach(bot, "Defense")
end

if Scenario.RunShootingRange and #attackers > 0 then
	task.wait(2)
	ShootingRange.run(attackers[1])
end

Telemetry.startReporting()
print("[CLUTCH] handing off to the round machine — watch for ROUND / BUY / PLANT / DEFUSE lines")

-- Blocks forever: Buy -> Live -> resolution -> PostRound, on loop.
RoundMachine.start({
	roster = roster,
	attackers = attackers,
	defenders = defenders,
	rng = rng,
	clock = Telemetry.clock,
	remotes = remotes,
	killFeed = killFeed,
})
