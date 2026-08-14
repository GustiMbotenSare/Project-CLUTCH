--!strict
-- Project CLUTCH — server bootstrap.
--
-- Brain v2 + spectator dashboard. The map is greyboxed, every area has a name,
-- bots decide where to go by scoring intents against what they can actually
-- perceive, and they shoot each other with a weapon that has an opinion about
-- range. The client shows a live match dashboard fed by replicated attributes
-- (Telemetry) and a kill-feed RemoteEvent (here).
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
-- Retired from the default path: Patrol (random POI wandering, scaffolding for
-- proving the navmesh worked) and ShootingRange (proved the duel maths against a
-- dummy). Both still exist; the range can be re-enabled via Scenario.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Greybox = require(Shared.MapData.Greybox)
local Zones = require(Shared.MapData.Zones)
local Scenario = require(Shared.Constants.Scenario)
local Weapons = require(Shared.Constants.Weapons)

local MapBuilder = require(script.MapBuilder)
local BotSpawner = require(script.BotSpawner)
local Telemetry = require(script.Telemetry)
local Brain = require(script.Brain)
local Combat = require(script.Combat)
local ShootingRange = require(script.ShootingRange)

local RESPAWN_DELAY = 3

print(("[CLUTCH] server online — brain v2 + spectator HUD (%s)"):format(Scenario.Mode))

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

-- Which weapon everyone is holding, and the thresholds its carrier reasons
-- about. Printing this means the log explains its own engagement decisions.
local weapon = Weapons[Scenario.DuelWeapon]
if not weapon then
	warn(("[CLUTCH] unknown weapon %q, falling back to Sidearm"):format(tostring(Scenario.DuelWeapon)))
	weapon = Weapons.Sidearm
end
print(("[CLUTCH] weapon: %s (%s) — %d body / %d head, optimal to %d studs, effective to %d studs"):format(
	weapon.DisplayName,
	weapon.Class,
	weapon.DamageBody,
	math.floor(weapon.DamageBody * weapon.HeadshotMultiplier),
	weapon.OptimalRangeStuds,
	weapon.MaxEffectiveRangeStuds
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

-- Survive death with the rig intact long enough to CLONE it. A dead humanoid
-- cannot be revived — setting Health on a dead rig never sticks (playtest #6:
-- one kill produced an endless RESET metronome because the "revived" bot was
-- still dead). Respawn replaces the body wholesale from this pristine copy.
for _, bot in roster do
	local humanoid = (bot.model :: Model):FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.BreakJointsOnDeath = false
	end
	bot.spawnPivot = (bot.model :: Model):GetPivot()
	bot.template = (bot.model :: Model):Clone()
	bot.weapon = weapon
end

-- Static dashboard identity. Telemetry adds the live state (zone, intent,
-- alive, K/D/HS) as attributes on the same model at 4Hz.
local function markBot(bot: any, side: string)
	local model = bot.model :: Model
	model:SetAttribute("ClutchBot", true)
	model:SetAttribute("BotName", bot.name)
	model:SetAttribute("Side", side)
	model:SetAttribute("Role", bot.role)
	model:SetAttribute("Weapon", weapon.DisplayName)
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
			weapon.DisplayName
		))
	end
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

-- A dead bot is replaced from its pristine template, returns to spawn and gets
-- a fresh brain, so a single Studio session produces repeated engagements
-- instead of one kill and silence. Deliberately crude: real respawn logic
-- belongs to the round state machine, along with buy phases and the score.
--
-- handledModel gates the corpse, not a boolean: the watcher re-reads bot.model
-- every poll because respawn swaps it.
local function watchForDeath(bot: any, side: string, enemies: { any }, allies: { any })
	task.spawn(function()
		local handledModel: Model? = nil
		while true do
			local model = bot.model :: Model?
			if model and model.Parent then
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health <= 0 and handledModel ~= model then
					handledModel = model
					bot.deaths = (bot.deaths or 0) + 1

					-- Combat stamped the corpse with who did it; read before destroying.
					local killerName = model:GetAttribute("LastKilledBy")
					if killerName then
						killFeed:FireAllClients({
							killer = killerName,
							victim = bot.name,
							headshot = model:GetAttribute("LastKillHeadshot") == true,
							distance = model:GetAttribute("LastKillDistance") or 0,
							weapon = model:GetAttribute("LastKillWeapon") or "?",
						})
					end

					print(("[CLUTCH] %6.1fs  RESET %s respawning in %ds"):format(
						Telemetry.clock(),
						bot.name,
						RESPAWN_DELAY
					))
					task.wait(RESPAWN_DELAY)

					local fresh = (bot.template :: Model):Clone()
					model:Destroy() -- ends the old brain/perception loops too
					fresh:PivotTo(bot.spawnPivot)
					local freshHumanoid = fresh:FindFirstChildOfClass("Humanoid")
					if freshHumanoid then
						freshHumanoid.BreakJointsOnDeath = false
					end
					fresh.Parent = workspace
					bot.model = fresh
					markBot(bot, side)
					task.wait(0.5)
					Brain.start(bot, side, enemies, allies, rng, Telemetry.clock, weapon)
					print(("[CLUTCH] %6.1fs  RESET %s back at spawn with a fresh brain"):format(
						Telemetry.clock(),
						bot.name
					))
				end
			end
			task.wait(0.25)
		end
	end)
end

for _, bot in attackers do
	markBot(bot, "Attack")
	Brain.start(bot, "Attack", defenders, attackers, rng, Telemetry.clock, weapon)
	watchForDeath(bot, "Attack", defenders, attackers)
end
for _, bot in defenders do
	markBot(bot, "Defense")
	Brain.start(bot, "Defense", attackers, defenders, rng, Telemetry.clock, weapon)
	watchForDeath(bot, "Defense", attackers, defenders)
end

Telemetry.startReporting()
print("[CLUTCH] brains online — watch for THINK / ENGAGE / SHOT / MOVE lines")

if Scenario.RunShootingRange and #attackers > 0 then
	task.wait(2)
	ShootingRange.run(attackers[1])
end
