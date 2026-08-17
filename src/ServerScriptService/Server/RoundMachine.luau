--!strict
-- Round machine: turns the sandbox into a match.
--
-- Buy → Live (100s, brains on) → resolution by elimination, explosion, defuse
-- or clock → PostRound (score, credits) → again.
--
-- THE ARSENAL SHOP (playtest #23): autoBuy is role-flavored with honest eco
-- fallbacks. Snipers save for the Longshot ritual; rich anchors buy the
-- Havoc belt; the lurker rides the cheap Bandit; everyone else wants the
-- Falcon — and a broke Entry/Support flips a coin between the Bandit and
-- the Judge. Nobody downgrades a real primary.
--
-- THE BARRIER PHASE (batch E, playtest #21): during Buy the barrier line is
-- UP and BOTH sides' brains run — Valorant's rule, replacing the old
-- attacker freeze. Defenders deploy to their holds; attackers stage behind
-- the barriers in their own half (BrainCore caps their targets). Nobody
-- sees or touches the attacker spawn before the whistle; at LIVE the line
-- drops. Round 5's 3.2-second spawn-camp wipe is the bug this buries.
--
-- AGGRO HOLDS SKIP THE LEDGE (playtest #24): Mid Ledge deck samples PATH
-- FAILED from spawn (the ramp climb isn't on the navmesh — tracked for
-- batch B phase 2), and an Aggro pair assigned it idled 45 seconds in spawn
-- while the attack walked in. The ledge still gets held via cover points
-- when a rotation passes through it — just never as a spawn-side assignment.
--
-- OUTCOME LOGGING + THE TUNER HOOK: every round prints a parseable
-- ROUND_RESULT line, every match a MATCH_RESULT with the metrics the tuner
-- scores. With Scenario.TuningMode on, each match feeds the in-game CEM and
-- the next plays under a perturbed BrainTuning set.
--
-- Deaths are FINAL inside a round and cost the victim its PRIMARY. THE DEAD
-- LEAVE: corpses ghost instantly (no collision), linger one beat for the
-- kill feed, then are removed. THE CARRIER'S DEATH IS RADIO: the moment the
-- carrier falls, every living attacker gets the spike mark where it dropped
-- (they heard it happen). Defenders must EARN the mark with their eyes.
-- (Playtest #18: this radio silently NEVER FIRED — the watcher wrote
-- `at = clock()` with no clock in scope and the error ate the mark every
-- time. It's `ctx.clock()` now; retrieval has been dead since it shipped.)
--
-- ADAPTATION (batch C): kills feed MatchMemory (who kills from where, who
-- dies where), and the plan roller reads the ledger — attack stops calling
-- the site that keeps killing it, the defense stack follows the attack's
-- proven favorite. Match end prints the SCOUT readout and decays the ledger
-- by half: lessons fade between matches, they don't vanish.
--
-- THE GUN READS ITS CLASS: after every buy, the welded block gun is restyled
-- to the carried weapon (pistol stub, SMG compact, shotgun wide, heavy
-- long, Longshot longest) — the broadcast can show loadouts before the
-- inventory line is read.
--
-- CLONES ARE NOT SELF-SUFFICIENT (playtest #17): a fresh body inherits the
-- template's parts but not its LOOPS — the ANIMATOR re-attaches per body
-- (batch D; playing tracks don't survive Clone), and AimAlign's target
-- re-seeds to the spawn facing.
--
-- TEAM PLANS: every round opens with a CALL (Rush/Default/Split ×
-- Standard/Stack/Aggro) — the seed of the M2 tactics board.
--
-- FUSE WATCHDOG: a planted phase running past the fuse resolves to the spike
-- rather than hanging the match.
--
-- PLAYTEST #19: publish the LIVE HEADCOUNTS on MatchState every publish tick
-- (the ALL-CLEAR read), and reset the held-item/dry flags on every fresh
-- body (they live on the bot RECORD, which survives the body swap).
--
-- (Also: a from-memory rewrite of this file once renamed start→run and the
-- bootstrap died at the handoff — this module's interface IS its callers.
-- Change start() and you change init.server.luau too, or nobody plays.)
--
-- Deliberately NOT here: halftime side swaps (needs team identity), overtime,
-- armor/shields, weapon drops on death. All tracked in the build doc.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Scenario = require(Shared.Constants.Scenario)
local RoundConfig = require(Shared.Constants.RoundConfig)
local Weapons = require(Shared.Constants.Weapons)
local Zones = require(Shared.MapData.Zones)

local Brain = require(script.Parent.Brain)
local Objective = require(script.Parent.Objective)
local MatchState = require(script.Parent.MatchState)
local MatchMemory = require(script.Parent.MatchMemory)
local Tuner = require(script.Parent.Tuner)
local BotSpawner = require(script.Parent.BotSpawner)
local MapBuilder = require(script.Parent.MapBuilder)
local Animations = require(script.Parent.Animations)

local RoundMachine = {}

local DEFAULT_WALK_SPEED = 16
local DEFAULT_JUMP_POWER = 50
local CORPSE_LINGER_SECONDS = 1.25 -- enough for the kill to read, then gone

local SITES = { "A_SITE", "B_SITE" }
-- MID_LEDGE left the Aggro pool (playtest #24): its deck samples PATH FAILED
-- from spawn (the ramp climb isn't on the navmesh — tracked for batch B
-- phase 2), and an Aggro pair assigned it idled 45s in spawn. The ledge
-- still gets held via cover points when a rotation passes through it.
local DEF_FORWARD = { "MID", "MID_WINDOW", "A_SHORT", "B_SHORT" }
local FUSE_WATCHDOG_GRACE = 5 -- seconds past the fuse before we call it dead

type Ctx = {
	roster: { any },
	attackers: { any },
	defenders: { any },
	rng: Random,
	clock: () -> number,
	remotes: Folder,
	killFeed: RemoteEvent,
}

local function aliveCount(list: { any }): number
	local count = 0
	for _, bot in list do
		local humanoid = bot.model and bot.model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			count += 1
		end
	end
	return count
end

local function findBot(roster: { any }, name: string): any?
	for _, bot in roster do
		if bot.name == name then
			return bot
		end
	end
	return nil
end

local function clampCredits(credits: number): number
	return math.clamp(credits, 0, RoundConfig.MaxCredits)
end

local function setFrozen(bot: any, frozen: boolean)
	local humanoid = bot.model and bot.model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = if frozen then 0 else DEFAULT_WALK_SPEED
		humanoid.JumpPower = if frozen then 0 else DEFAULT_JUMP_POWER
	end
end

local function markBot(bot: any, side: string)
	local model = bot.model :: Model
	model:SetAttribute("ClutchBot", true)
	model:SetAttribute("BotName", bot.name)
	model:SetAttribute("Side", side)
	model:SetAttribute("Role", bot.role)
	model:SetAttribute("Weapon", if bot.weapon then bot.weapon.DisplayName else "?")
end

-- The dead ghost instantly (zero collision, anchored in place)...
local function ghostCorpse(model: Model)
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			inst.CanCollide = false
		end
	end
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
end

-- ...then leave the map entirely. The dashboard keeps the bot's card (greyed)
-- from its last attributes; the world stops pretending they're standing there.
local function removeCorpseLater(model: Model)
	task.delay(CORPSE_LINGER_SECONDS, function()
		if model.Parent then
			model:Destroy()
		end
	end)
end

-- THE ARSENAL SHOP (playtest #23): role-flavored wants with honest eco
-- fallbacks. Snipers save for the Longshot ritual; rich anchors buy the
-- Havoc belt; the lurker rides the cheap Bandit; everyone else wants the
-- Falcon — and a broke Entry/Support flips a coin between the Bandit and
-- the Judge. Nobody downgrades a real primary.
local function autoBuy(bot: any, rng: Random)
	local desired = Weapons.FalconAR
	if bot.role == "Sniper" then
		desired = Weapons.Longshot
	elseif bot.role == "Anchor" and bot.credits >= Weapons.HavocLMG.Price + 800 then
		desired = Weapons.HavocLMG -- rich anchors buy the belt
	elseif bot.role == "Lurker" and bot.credits < Weapons.FalconAR.Price then
		desired = Weapons.BanditSMG -- the cheap flanker
	end

	if bot.weapon == desired then
		return -- already owns it; keep saving
	end
	if bot.credits >= desired.Price then
		bot.credits -= desired.Price
		bot.weapon = desired
		bot.inventory = (bot.inventory or Weapons.Sidearm.DisplayName) .. " + " .. desired.DisplayName
		print(("[CLUTCH] BUY %s buys %s (-%d, %d cr left)"):format(
			bot.name,
			desired.DisplayName,
			desired.Price,
			bot.credits
		))
		return
	end

	-- Can't afford the want. Snipers keep saving for the ritual; anyone
	-- holding a real primary keeps IT; the pistol-only can buy down.
	if bot.role == "Sniper" or bot.weapon.Class ~= "Pistol" then
		print(("[CLUTCH] BUY %s saves with %s (%d cr)"):format(bot.name, bot.weapon.DisplayName, bot.credits))
		return
	end
	local eco = Weapons.BanditSMG
	if (bot.role == "Entry" or bot.role == "Support") and rng:NextNumber() < 0.4 then
		eco = Weapons.JudgeSG -- forty percent of eco rounds, someone brings the boom
	end
	if bot.credits >= eco.Price then
		bot.credits -= eco.Price
		bot.weapon = eco
		bot.inventory = (bot.inventory or Weapons.Sidearm.DisplayName) .. " + " .. eco.DisplayName
		print(("[CLUTCH] BUY %s eco-buys %s (-%d, %d cr left)"):format(
			bot.name,
			eco.DisplayName,
			eco.Price,
			bot.credits
		))
	else
		print(("[CLUTCH] BUY %s saves with %s (%d cr)"):format(bot.name, bot.weapon.DisplayName, bot.credits))
	end
end

-- Every round starts with pristine rigs at spawn. Old bodies (and the brains,
-- perception loops and death watchers riding them) are destroyed; Telemetry
-- tracks survive because they re-read bot.model every tick. Per-round brain
-- picks AND cover claims are cleared so the plan can reassign them.
-- A clone inherits PARTS but not LOOPS: the Animator re-attaches here
-- (batch D), and AimAlign gets re-seeded to the spawn facing. The bot RECORD
-- survives the body swap — so the held-item and dry flags reset HERE.
local function resetBodies(ctx: Ctx)
	for _, bot in ctx.roster do
		bot.siteChoice = nil
		bot.holdChoice = nil
		bot.claimedCover = nil
		bot.facePoint = nil -- last round's stare dies with the body
		bot.moveDir = nil
		bot.faceMode = nil
		-- Held-item state lives on the record, not the body: gun out, both
		-- weapons live, no dry flags carried into the new round.
		bot.held = "Primary"
		bot.heldAt = 0
		bot.primaryDry = nil
		bot.allDry = nil
		local old = bot.model :: Model?
		local fresh = (bot.template :: Model):Clone()
		if old then
			old:Destroy()
		end
		fresh:PivotTo(bot.spawnPivot)
		local humanoid = fresh:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.BreakJointsOnDeath = false
			humanoid.AutoRotate = false -- clones of an old template must not re-lock the eyes to the legs
		end
		fresh.Parent = workspace
		bot.model = fresh
		-- The clone's AimAlign still points wherever the template faced — re-seed
		-- it so the round doesn't open with ten bots snapping around.
		local root = fresh:FindFirstChild("HumanoidRootPart") :: BasePart?
		local align = if root then root:FindFirstChild("AimAlign") :: AlignOrientation? else nil
		if align then
			align.CFrame = CFrame.new(Vector3.zero) * (bot.spawnPivot :: CFrame).Rotation
		end
		Animations.attach(fresh) -- playing tracks don't survive a clone
	end
end

local function publish(ctx: Ctx)
	-- Live headcounts: the brains' ALL-CLEAR read (playtest #19). Every
	-- publish tick, every phase — a stale 0 from last round must not linger.
	MatchState.atkAlive = aliveCount(ctx.attackers)
	MatchState.defAlive = aliveCount(ctx.defenders)
	ctx.remotes:SetAttribute("Phase", MatchState.phase)
	ctx.remotes:SetAttribute("TimeLeft", math.max(0, math.floor(MatchState.timeLeft + 0.5)))
	ctx.remotes:SetAttribute("Round", MatchState.roundNumber)
	ctx.remotes:SetAttribute("AtkScore", MatchState.atkScore)
	ctx.remotes:SetAttribute("DefScore", MatchState.defScore)
	ctx.remotes:SetAttribute("Planted", MatchState.planted)
	ctx.remotes:SetAttribute(
		"SpikeDown",
		MatchState.spikePart ~= nil and MatchState.spikeCarrier == nil and not MatchState.planted
	)
end

-- ---------------------------------------------------------------------------
-- TEAM PLANS. One coin per team per round, not five. Assignments land in
-- bot.siteChoice / bot.holdChoice before brains start, so the brain's own
-- roll only fires for freelancers a plan deliberately leaves open.
-- ADAPTATION: the coins flip first, then MatchMemory argues.
-- ---------------------------------------------------------------------------
local function otherSite(site: string): string
	return if site == "A_SITE" then "B_SITE" else "A_SITE"
end

local function heavenOf(site: string): string
	return if site == "A_SITE" then "A_HEAVEN" else "B_HEAVEN"
end

local function siteLetter(site: string): string
	return if site == "A_SITE" then "A" else "B"
end

local function rollTeamPlans(ctx: Ctx)
	local rng = ctx.rng
	local site = SITES[rng:NextInteger(1, 2)]

	local atkRoll = rng:NextNumber()
	local attackKind = if atkRoll < 0.30 then "Rush" elseif atkRoll < 0.80 then "Default" else "Split"
	local defRoll = rng:NextNumber()
	local defenseKind = if defRoll < 0.50 then "Standard" elseif defRoll < 0.75 then "Stack" else "Aggro"

	MatchState.plan = {
		attackKind = attackKind,
		defenseKind = defenseKind,
		site = site,
		otherSite = otherSite(site),
	}

	-- ADAPTATION. Attack: a site that keeps KILLING you stops getting called
	-- (the same mistake every round was playtest #18's report). Defense: a
	-- proven attacker favorite is where the stack goes.
	if attackKind ~= "Rush" then -- a rush is a rush; you don't adapt a coin you committed to
		local deathsHere = MatchMemory.deathsAt("Attack", site)
		local deathsThere = MatchMemory.deathsAt("Attack", otherSite(site))
		if deathsHere >= 2 and deathsHere - deathsThere >= 2 then
			print(("[CLUTCH] CALL ATK adapts: %s has been a graveyard — the call moves to %s"):format(
				siteLetter(site),
				siteLetter(otherSite(site))
			))
			site = otherSite(site)
			MatchState.plan.site = site
			MatchState.plan.otherSite = otherSite(site)
		end
	end
	local stackSite = site
	if defenseKind == "Stack" then
		local hot = MatchMemory.preferredSite("Attack")
		if hot and hot ~= site then
			stackSite = hot
			print(("[CLUTCH] CALL DEF adapts: they keep showing at %s — the stack moves with the heat"):format(
				siteLetter(hot)
			))
		end
	end

	-- ATTACK assignments
	for _, bot in ctx.attackers do
		if attackKind == "Rush" then
			bot.siteChoice = site -- everyone, same door, right now
		elseif attackKind == "Default" then
			-- The core hits the called site; sniper holds mid angles and the
			-- lurker freelances (their own rolls are the point of those roles).
			if bot.role ~= "Sniper" and bot.role ~= "Lurker" then
				bot.siteChoice = site
			end
		else -- Split
			-- Carrier's group takes the called site; the rest pressure the other.
			local withCarrier = MatchState.spikeCarrier == bot or bot.role == "Entry" or bot.role == "Support"
			bot.siteChoice = if withCarrier then site else otherSite(site)
		end
	end

	-- DEFENSE assignments
	if defenseKind == "Standard" then
		-- 2-1-2: anchors split A/B, IGL holds the window, sniper + support take
		-- the two heavens.
		local anchorIndex = 0
		local sniperHeaven: string? = nil
		for _, bot in ctx.defenders do
			if bot.role == "Anchor" then
				anchorIndex += 1
				bot.holdChoice = if anchorIndex == 1 then "A_SITE" else "B_SITE"
			elseif bot.role == "IGL" then
				bot.holdChoice = "MID_WINDOW"
			elseif bot.role == "Sniper" then
				sniperHeaven = heavenOf(SITES[rng:NextInteger(1, 2)])
				bot.holdChoice = sniperHeaven
			end
		end
		for _, bot in ctx.defenders do
			if bot.role == "Support" then
				bot.holdChoice = if sniperHeaven == "A_HEAVEN" then "B_HEAVEN" else "A_HEAVEN"
			end
		end
	elseif defenseKind == "Stack" then
		for _, bot in ctx.defenders do
			bot.holdChoice = if bot.role == "Sniper" then heavenOf(stackSite) else stackSite
		end
	else -- Aggro
		for _, bot in ctx.defenders do
			bot.holdChoice = DEF_FORWARD[rng:NextInteger(1, #DEF_FORWARD)]
		end
	end

	-- The CALL lines: the broadcast-readable version of the plan
	if attackKind == "Rush" then
		print(("[CLUTCH] CALL ATK: RUSH %s — everyone, same door, right now"):format(siteLetter(site)))
	elseif attackKind == "Default" then
		print(("[CLUTCH] CALL ATK: default — core hits %s, sniper holds mid, lurker freelances"):format(siteLetter(site)))
	else
		print(("[CLUTCH] CALL ATK: split — carrier group %s, pressure %s"):format(siteLetter(site), siteLetter(otherSite(site))))
	end
	if defenseKind == "Standard" then
		print("[CLUTCH] CALL DEF: standard 2-1-2 — anchors split, IGL on the window")
	elseif defenseKind == "Stack" then
		print(("[CLUTCH] CALL DEF: STACK %s — four bodies on one site"):format(siteLetter(stackSite)))
	else
		print("[CLUTCH] CALL DEF: aggressive — forward holds, contest mid")
	end
end

-- One watcher per bot per round. A death is final: kill feed, killer's kill
-- reward, spike drop if the carrier fell, the victim drops to the free pistol
-- (bought primaries die with the body), the corpse ghosts then leaves — and
-- the ledger remembers who killed whom from where.
local function watchDeaths(ctx: Ctx, roundId: number)
	for _, bot in ctx.roster do
		task.spawn(function()
			local model = bot.model :: Model
			while MatchState.roundNumber == roundId do
				if not model.Parent then
					return
				end
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health <= 0 then
					bot.deaths = (bot.deaths or 0) + 1
					ghostCorpse(model) -- never block a path, even for the linger beat
					removeCorpseLater(model)
					local killerName = model:GetAttribute("LastKilledBy")
					if killerName then
						ctx.killFeed:FireAllClients({
							killer = killerName,
							victim = bot.name,
							headshot = model:GetAttribute("LastKillHeadshot") == true,
							distance = model:GetAttribute("LastKillDistance") or 0,
							weapon = model:GetAttribute("LastKillWeapon") or "?",
						})
						local killer = findBot(ctx.roster, killerName)
						if killer then
							killer.credits = clampCredits((killer.credits or 0) + RoundConfig.KillReward)
							-- Match memory: who kills from where, who dies where.
							MatchMemory.recordKill(
								killer.side,
								Zones.keyAt(Zones.groundOf(killer.model)),
								bot.side,
								Zones.keyAt(Zones.groundOf(model))
							)
						end
					end
					-- Death costs the primary. The corpse keeps nothing; the next
					-- round starts on the standard pistol like every tac shooter.
					if bot.weapon and bot.weapon.Class ~= "Pistol" then
						print(("[CLUTCH] %s loses the %s"):format(bot.name, bot.weapon.DisplayName))
						bot.weapon = Weapons.Sidearm
						bot.inventory = Weapons.Sidearm.DisplayName
					end
					if MatchState.spikeCarrier == bot then
						Objective.dropSpike(bot)
						-- THE CARRIER'S DEATH IS RADIO: every living attacker knew
						-- where their teammate fell — the mark is free for the attack,
						-- earned with eyes for the defense.
						-- (Playtest #18: a bare clock() here was nil and the error ate
						-- the mark every time. ctx.clock(). Always ctx.clock().)
						local spike = MatchState.spikePart
						if spike then
							MatchState.spikeMarkAtk = {
								pos = spike.Position,
								zoneKey = Zones.keyAt(spike.Position),
								at = ctx.clock(),
							}
						end
					end
					return
				end
				task.wait(0.2)
			end
		end)
	end
end

function RoundMachine.start(ctx: Ctx)
	local clock = ctx.clock

	for _, bot in ctx.roster do
		bot.credits = RoundConfig.StartCredits
		bot.weapon = Weapons[Scenario.DuelWeapon] or Weapons.Sidearm
		bot.inventory = bot.weapon.DisplayName
	end

	local atkLossStreak = 0
	local defLossStreak = 0

	-- Match-level accumulators: what the tuner scores, and the parseable
	-- record of how this meta actually plays.
	local matchRounds = 0
	local matchAtkWins = 0
	local matchDefWins = 0
	local matchPlants = 0
	local matchRoundSeconds = 0

	print(("[CLUTCH] round machine online — %d to win, %d rounds max, %ds buy / %ds round / %ds fuse"):format(
		RoundConfig.WinsNeeded,
		RoundConfig.MaxRoundsRegulation,
		RoundConfig.BuyPhaseSeconds,
		RoundConfig.RoundSeconds,
		RoundConfig.SpikeFuseSeconds
	))
	if Scenario.TuningMode then
		print("[CLUTCH] TUNING MODE — each match plays under one candidate weight set; TUNING lines track the search")
	end

	while true do
		MatchState.roundNumber += 1
		local roundId = MatchState.roundNumber

		resetBodies(ctx)
		for _, bot in ctx.attackers do
			markBot(bot, "Attack")
		end
		for _, bot in ctx.defenders do
			markBot(bot, "Defense")
		end
		Objective.reset()
		MapBuilder.setBarriersUp(true) -- the barrier line seals the attacker half
		if #ctx.attackers > 0 then
			-- A random attacker carries, not the same nameplate every round
			Objective.assignCarrier(ctx.attackers[ctx.rng:NextInteger(1, #ctx.attackers)])
		end
		rollTeamPlans(ctx) -- writes bot.siteChoice / bot.holdChoice before brains wake

		-- BUY — THE BARRIER PHASE (batch E): nobody freezes. Defenders deploy
		-- to their holds; attackers stage behind the barrier line in their own
		-- half (their brains run too — BrainCore caps their targets).
		MatchState.phase = "Buy"
		MatchState.timeLeft = RoundConfig.BuyPhaseSeconds
		print(("[CLUTCH] ===== ROUND %d ====="):format(roundId))
		for _, bot in ctx.attackers do
			setFrozen(bot, false)
			autoBuy(bot, ctx.rng)
			BotSpawner.styleGun(bot.model, bot.weapon)
			BotSpawner.styleHeld(bot.model, "Gun") -- the knife goes away at spawn
			Brain.start(bot, "Attack", ctx.defenders, ctx.attackers, ctx.rng, clock, bot.weapon)
		end
		for _, bot in ctx.defenders do
			setFrozen(bot, false) -- free to deploy
			autoBuy(bot, ctx.rng)
			BotSpawner.styleGun(bot.model, bot.weapon)
			BotSpawner.styleHeld(bot.model, "Gun")
			Brain.start(bot, "Defense", ctx.attackers, ctx.defenders, ctx.rng, clock, bot.weapon)
		end
		local buyEnds = clock() + RoundConfig.BuyPhaseSeconds
		while clock() < buyEnds do
			MatchState.timeLeft = buyEnds - clock()
			publish(ctx)
			task.wait(0.25)
		end

		-- LIVE — the barrier drops, the round begins
		MatchState.phase = "Live"
		MapBuilder.setBarriersUp(false)
		print(("[CLUTCH] LIVE — %ds on the clock"):format(RoundConfig.RoundSeconds))
		for _, bot in ctx.attackers do
			setFrozen(bot, false) -- idempotent; brains already running
		end
		for _, bot in ctx.defenders do
			setFrozen(bot, false)
		end
		watchDeaths(ctx, roundId)

		local liveStartedAt = clock()
		local liveEnds = liveStartedAt + RoundConfig.RoundSeconds
		local sawPlant = false
		local winner: string? = nil
		local reason = ""
		while winner == nil do
			if MatchState.planted then
				sawPlant = true
				MatchState.timeLeft = math.max(0, MatchState.plantedAt + RoundConfig.SpikeFuseSeconds - clock())
			else
				MatchState.timeLeft = math.max(0, liveEnds - clock())
			end
			publish(ctx)

			if MatchState.exploded then
				winner, reason = "Attack", "the spike"
			elseif MatchState.defused then
				winner, reason = "Defense", "the defuse"
			elseif aliveCount(ctx.defenders) == 0 then
				winner, reason = "Attack", "elimination"
			elseif aliveCount(ctx.attackers) == 0 and not MatchState.planted then
				winner, reason = "Defense", "elimination"
			elseif not MatchState.planted and clock() > liveEnds then
				winner, reason = "Defense", "the clock"
			elseif MatchState.planted
				and not MatchState.defused
				and clock() > MatchState.plantedAt + RoundConfig.SpikeFuseSeconds + FUSE_WATCHDOG_GRACE
			then
				-- The fuse thread owns the explosion — but if it ever dies silently
				-- (playtest #12's self-cancel crash), the match must not hang.
				warn("[CLUTCH] FUSE WATCHDOG: spike overstayed its fuse — calling it")
				MatchState.exploded = true
			else
				task.wait(0.25)
			end
		end

		-- RESOLUTION
		local roundSeconds = clock() - liveStartedAt
		local atkAlive = aliveCount(ctx.attackers)
		local defAlive = aliveCount(ctx.defenders)

		local winners = if winner == "Attack" then ctx.attackers else ctx.defenders
		local losers = if winner == "Attack" then ctx.defenders else ctx.attackers
		local loserStreak: number
		if winner == "Attack" then
			MatchState.atkScore += 1
			atkLossStreak = 0
			defLossStreak += 1
			loserStreak = defLossStreak
		else
			MatchState.defScore += 1
			defLossStreak = 0
			atkLossStreak += 1
			loserStreak = atkLossStreak
		end
		local lossPay = math.min(
			RoundConfig.LossRewardBase + (loserStreak - 1) * RoundConfig.LossRewardStep,
			RoundConfig.LossRewardMax
		)
		for _, bot in winners do
			bot.credits = clampCredits(bot.credits + RoundConfig.WinReward)
		end
		for _, bot in losers do
			bot.credits = clampCredits(bot.credits + lossPay)
		end
		if winner == "Defense" and sawPlant then
			for _, bot in ctx.attackers do
				bot.credits = clampCredits(bot.credits + RoundConfig.PlantBonusLoss)
			end
		end
		print(("[CLUTCH] ROUND %d: %s wins by %s — ATK %d : %d DEF"):format(
			roundId,
			string.upper(winner),
			reason,
			MatchState.atkScore,
			MatchState.defScore
		))
		-- Parseable one-liner for the log-mining toolchain and the tuner
		print(("[CLUTCH] ROUND_RESULT | r%d | %s | %s | plant=%s | %.1fs | alive %dv%d"):format(
			roundId,
			string.upper(winner),
			reason,
			tostring(sawPlant),
			roundSeconds,
			atkAlive,
			defAlive
		))

		matchRounds += 1
		matchRoundSeconds += roundSeconds
		if sawPlant then
			matchPlants += 1
		end
		if winner == "Attack" then
			matchAtkWins += 1
		else
			matchDefWins += 1
		end

		-- POST ROUND
		MatchState.phase = "PostRound"
		MatchState.timeLeft = RoundConfig.PostRoundSeconds
		for _, bot in ctx.roster do
			setFrozen(bot, true)
		end
		local postEnds = clock() + RoundConfig.PostRoundSeconds
		while clock() < postEnds do
			MatchState.timeLeft = postEnds - clock()
			publish(ctx)
			task.wait(0.25)
		end

		if roundId == RoundConfig.HalftimeAfterRound then
			for _, bot in ctx.roster do
				bot.credits = RoundConfig.StartCredits
			end
			atkLossStreak = 0
			defLossStreak = 0
			print("[CLUTCH] HALFTIME — credits reset (side swap lands with team identity)")
		end

		if MatchState.atkScore >= RoundConfig.WinsNeeded
			or MatchState.defScore >= RoundConfig.WinsNeeded
			or roundId >= RoundConfig.MaxRoundsRegulation
		then
			local champion = if MatchState.atkScore > MatchState.defScore then "ATTACK" else "DEFENSE"
			print(("[CLUTCH] MATCH: %s takes it %d — %d. Resetting for the next one."):format(
				champion,
				MatchState.atkScore,
				MatchState.defScore
			))
			print(("[CLUTCH] MATCH_RESULT | %s %d-%d | rounds %d | plants %d | avgRound %.1fs"):format(
				champion,
				MatchState.atkScore,
				MatchState.defScore,
				matchRounds,
				matchPlants,
				if matchRounds > 0 then matchRoundSeconds / matchRounds else 0
			))
			-- The scouting readout, then the half-life: what the match taught the
			-- bots, printed for us; lessons fade between matches, they don't vanish.
			print(('[CLUTCH] SCOUT %s'):format(MatchMemory.scoutLine("Attack")))
			print(('[CLUTCH] SCOUT %s'):format(MatchMemory.scoutLine("Defense")))
			MatchMemory.decay()

			if Scenario.TuningMode then
				Tuner.onMatchEnd({
					rounds = matchRounds,
					atkWins = matchAtkWins,
					defWins = matchDefWins,
					plants = matchPlants,
					avgRoundSeconds = if matchRounds > 0 then matchRoundSeconds / matchRounds else 0,
				})
			end

			MatchState.atkScore = 0
			MatchState.defScore = 0
			MatchState.roundNumber = 0
			for _, bot in ctx.roster do
				bot.credits = RoundConfig.StartCredits
			end
			atkLossStreak = 0
			defLossStreak = 0
			matchRounds = 0
			matchAtkWins = 0
			matchDefWins = 0
			matchPlants = 0
			matchRoundSeconds = 0
		end
	end
end

return RoundMachine
