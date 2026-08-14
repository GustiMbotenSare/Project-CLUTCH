--!strict
-- Round machine: turns the sandbox into a match.
--
-- Buy (frozen, bots auto-spend) → Live (100s, brains on) → resolution by
-- elimination, explosion, defuse or clock → PostRound (score, credits) →
-- again. Deaths are FINAL inside a round: no respawns, so a kill costs the
-- victim the round, not three seconds. And per playtest #9, death also costs
-- the victim its PRIMARY: die and you come back on the free Sidearm, like
-- every tac shooter ever. Weapon drops on death are the tracked follow-up.
--
-- Also owns the economy (win/loss ladders, kill rewards, plant bonus), the
-- body swapper (every round starts with pristine rigs at spawn), per-round
-- brain picks (site/anchor choices are cleared here so routes vary round to
-- round), and each bot's INVENTORY string for the dashboard. The spike
-- carrier is a random attacker each round — Ace does not have to carry every
-- single time.
--
-- Deliberately NOT here: halftime side swaps (needs team identity), overtime,
-- armor/shields, weapon drops on death. All tracked in the build doc.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Scenario = require(Shared.Constants.Scenario)
local RoundConfig = require(Shared.Constants.RoundConfig)
local Weapons = require(Shared.Constants.Weapons)

local Brain = require(script.Parent.Brain)
local Objective = require(script.Parent.Objective)
local MatchState = require(script.Parent.MatchState)

local RoundMachine = {}

local DEFAULT_WALK_SPEED = 16
local DEFAULT_JUMP_POWER = 50

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

-- v1 buy logic: the best primary you can afford, or the free Sidearm. Snipers
-- save for the Longshot; everyone else wants the Falcon. No armor, no utility,
-- no selling — those land with the real roster/economy pass.
local function autoBuy(bot: any)
	local desired = if bot.role == "Sniper" then Weapons.Longshot else Weapons.FalconAR
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
	else
		print(("[CLUTCH] BUY %s saves with %s (%d cr)"):format(
			bot.name,
			bot.weapon.DisplayName,
			bot.credits
		))
	end
end

-- Every round starts with pristine rigs at spawn. Old bodies (and the brains,
-- perception loops and death watchers riding them) are destroyed; Telemetry
-- tracks survive because they re-read bot.model every tick. Per-round brain
-- picks (siteChoice/holdChoice) are cleared so routes vary round to round.
local function resetBodies(ctx: Ctx)
	for _, bot in ctx.roster do
		bot.siteChoice = nil
		bot.holdChoice = nil
		local old = bot.model :: Model?
		local fresh = (bot.template :: Model):Clone()
		if old then
			old:Destroy()
		end
		fresh:PivotTo(bot.spawnPivot)
		local humanoid = fresh:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.BreakJointsOnDeath = false
		end
		fresh.Parent = workspace
		bot.model = fresh
	end
end

local function publish(ctx: Ctx)
	ctx.remotes:SetAttribute("Phase", MatchState.phase)
	ctx.remotes:SetAttribute("TimeLeft", math.max(0, math.floor(MatchState.timeLeft + 0.5)))
	ctx.remotes:SetAttribute("Round", MatchState.roundNumber)
	ctx.remotes:SetAttribute("AtkScore", MatchState.atkScore)
	ctx.remotes:SetAttribute("DefScore", MatchState.defScore)
	ctx.remotes:SetAttribute("Planted", MatchState.planted)
end

-- One watcher per bot per round. A death is final: kill feed, killer's kill
-- reward, spike drop if the carrier fell, the victim drops to the free pistol
-- (bought primaries die with the body), and that's it until next round.
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

	print(("[CLUTCH] round machine online — %d to win, %d rounds max, %ds buy / %ds round / %ds fuse"):format(
		RoundConfig.WinsNeeded,
		RoundConfig.MaxRoundsRegulation,
		RoundConfig.BuyPhaseSeconds,
		RoundConfig.RoundSeconds,
		RoundConfig.SpikeFuseSeconds
	))

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
		if #ctx.attackers > 0 then
			-- A random attacker carries, not the same nameplate every round
			Objective.assignCarrier(ctx.attackers[ctx.rng:NextInteger(1, #ctx.attackers)])
		end

		-- BUY
		MatchState.phase = "Buy"
		MatchState.timeLeft = RoundConfig.BuyPhaseSeconds
		print(("[CLUTCH] ===== ROUND %d ====="):format(roundId))
		for _, bot in ctx.roster do
			setFrozen(bot, true)
			autoBuy(bot)
		end
		local buyEnds = clock() + RoundConfig.BuyPhaseSeconds
		while clock() < buyEnds do
			MatchState.timeLeft = buyEnds - clock()
			publish(ctx)
			task.wait(0.25)
		end

		-- LIVE
		MatchState.phase = "Live"
		print(("[CLUTCH] LIVE — %ds on the clock"):format(RoundConfig.RoundSeconds))
		for _, bot in ctx.roster do
			setFrozen(bot, false)
		end
		for _, bot in ctx.attackers do
			Brain.start(bot, "Attack", ctx.defenders, ctx.attackers, ctx.rng, clock, bot.weapon)
		end
		for _, bot in ctx.defenders do
			Brain.start(bot, "Defense", ctx.attackers, ctx.defenders, ctx.rng, clock, bot.weapon)
		end
		watchDeaths(ctx, roundId)

		local liveEnds = clock() + RoundConfig.RoundSeconds
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
			else
				task.wait(0.25)
			end
		end

		-- RESOLUTION
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
			MatchState.atkScore = 0
			MatchState.defScore = 0
			MatchState.roundNumber = 0
			for _, bot in ctx.roster do
				bot.credits = RoundConfig.StartCredits
			end
			atkLossStreak = 0
			defLossStreak = 0
		end
	end
end

return RoundMachine
