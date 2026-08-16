--!strict
-- Round machine: freeze, buy, live, planted, post — and the economy tying
-- rounds into a match.
--
-- The death watch catches everything: bullets, spike blasts, future utility.
-- First kill and scoreline both live here; the kill feed reads stamps
-- (LastKilledBy etc.) that Combat and the explosion set.
--
-- THE KILL FEED IS A CHANNEL: one RemoteEvent, every client relays locally.
--
-- The buy phase spends per-budget. AI is the second pass — a list of
-- personalities priced against a budget, which is exactly the self-play
-- harness's shopping list.
--
-- Bots freeze in place during Buy (Valo barrier phase) — except DEFENDERS:
-- they live through Buy so their holds are real positions when the wall
-- drops.
--
-- Every round, brains restart on FRESH bodies: the fallback revive is gone
-- (bots properly died at round end — including the living, because the spike
-- credits kill-feed style) and leftover brains killed by name. Deaths and
-- kills RESET per round; headshots stay lifetime.
--
-- THE DEATH WATCH NEVER SAMPLES ITSELF (playtest #18's match-deciding bug):
-- watchDeaths' main loop tried to call a `clock()` local that only existed
-- inside its own event closure — every carrier death crashed the handler
-- with "attempt to call a nil value", and with it the spike-radio mark that
-- the whole retrieval system keys off. `at = ctx.clock()` now.
--
-- Batch C (playtest #18): kills feed MATCH MEMORY (the enemy's habits);
-- plan rolls read the ledger (graveyard-flip on attack, site-stack reads on
-- defense); the match end prints the scout report and the memory decays.
--
-- Playtest #19: the round machine PUBLISHES the live headcounts every tick
-- (MatchState.atkAlive/defAlive) so brains can read the ALL-CLEAR — and
-- resets the new per-bot fields (held item, dry flags, crouch height) on
-- every fresh body, because the clone inherits whatever the template wore.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local RoundConfig = require(Shared.Constants.RoundConfig)
local Weapons = require(Shared.Constants.Weapons)
local Zones = require(Shared.MapData.Zones)

local BotSpawner = require(script.Parent.BotSpawner)
local Brain = require(script.Parent.Brain)
local Objective = require(script.Parent.Objective)
local MatchState = require(script.Parent.MatchState)
local MatchMemory = require(script.Parent.MatchMemory)

local RoundMachine = {}

local DEFAULT_HIP_HEIGHT = 2 -- the crouch is round-scoped like everything else

local function rootOf(model: Model): BasePart?
	return model:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function anchor(model: Model, anchored: boolean)
	local root = rootOf(model)
	if root then
		root.Anchored = anchored
	end
end

local function aliveCount(roster: { any }): number
	local count = 0
	for _, bot in roster do
		local humanoid = bot.model and bot.model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			count += 1
		end
	end
	return count
end

local function holderParts(model: Model): { BasePart }
	local parts = {}
	for _, inst in model:GetDescendants() do
		if inst:IsA("BasePart") then
			table.insert(parts, inst)
		end
	end
	return parts
end

-- Fresh bodies each round. The old corpse lingers (it's a ragdoll now);
-- startProceduralWalk restarts on the clone — task loops don't survive Clone.
local function resetBodies(roster: { any })
	for _, bot in roster do
		if bot.template == nil then
			bot.template = bot.model
		end
		local fresh = bot.template:Clone()
		fresh.Name = bot.name .. "_r" .. tostring(math.floor(os.clock()))
		bot.model = fresh
		bot.held = "Primary"
		bot.heldAt = 0
		bot.primaryDry = nil
		bot.allDry = nil
		local humanoid = fresh:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = 100
			humanoid.HipHeight = DEFAULT_HIP_HEIGHT
		end
		for _, part in holderParts(fresh) do
			part.Anchored = false
		end
		fresh.Parent = workspace
		BotSpawner.startProceduralWalk(fresh)
	end
end

type Context = {
	attackers: { any },
	defenders: { any },
	attackSpawns: { Vector3 },
	defenseSpawns: { Vector3 },
	publish: (string, number) -> (),
	onFirstKill: (string, string, boolean) -> (),
	onMatchEnd: (winner: string, atkScore: number, defScore: number) -> (),
	clock: () -> number,
	_rng: Random,
}

-- THE PLAN ROLL — and its ADAPTATION (batch C): the ledger from last match
-- tilts the coin. Attack: an executed call the enemy keeps farming gets
-- flipped to the other site (never Rush — the rush is the rush). Defense:
-- Stack reads the enemy's preferred plant site; Standard reads it for the
-- window pick. The coin still rolls — adaptation tilts, never dictates.
local function rollTeamPlans(ctx: Context, rng: Random)
	local plan: any = {}

	-- Attack: Rush 30%, else Default (core+pressure) or Split (both sites).
	local roll = rng:NextNumber()
	local site = if rng:NextNumber() < 0.5 then "A_SITE" else "B_SITE"
	local other = if site == "A_SITE" then "B_SITE" else "A_SITE"
	if roll < 0.30 then
		plan.attackKind = "Rush"
		plan.site = site
	elseif roll < 0.65 then
		plan.attackKind = "Default"
		plan.site = site
		plan.pressureSite = other
	else
		plan.attackKind = "Split"
		plan.site = site
		plan.otherSite = other
	end

	-- The graveyard read: if last match the enemy stacked kills in this
	-- call's approach zones, take the hint (Rush exempt — see header).
	if plan.attackKind ~= "Rush" then
		local siteLanes = if plan.site == "A_SITE"
			then { "A_MAIN", "A_SHORT", "OUTSIDE_LONG", "LONG_DOORS" }
			else { "B_MAIN", "B_SHORT" }
		local otherLanes = if plan.site == "A_SITE"
			then { "B_MAIN", "B_SHORT" }
			else { "A_MAIN", "A_SHORT", "OUTSIDE_LONG", "LONG_DOORS" }
		local deathsHere = 0
		for _, lane in siteLanes do
			deathsHere += MatchMemory.deathsAt("Attack", lane)
		end
		local deathsThere = 0
		for _, lane in otherLanes do
			deathsThere += MatchMemory.deathsAt("Attack", lane)
		end
		if deathsHere >= 2 and deathsHere - deathsThere >= 2 then
			plan.site, plan.otherSite = plan.otherSite or other, plan.site
			plan.pressureSite = plan.site
			print(("[CLUTCH] MATCH %d | attack adapts — the graveyard at %s flips the call"):format(
				MatchState.roundNumber,
				if Zones.byKey[site] then Zones.byKey[site].callout else site
			))
			site = plan.site
			other = plan.otherSite or other
		end
	end

	-- Defense: Stack 30%, Aggro 25%, else Standard. THE READ: Stack follows
	-- the enemy's preferred plant site when the ledger knows one.
	local stackSite = site
	if rng:NextNumber() < 0.30 then
		plan.defenseKind = "Stack"
		local preferred = MatchMemory.preferredSite("Attack")
		if preferred and Zones.byKey[preferred] then
			stackSite = preferred
		end
		plan.site = stackSite
	elseif rng:NextNumber() < 0.55 then
		plan.defenseKind = "Aggro"
		plan.site = nil
	else
		plan.defenseKind = "Standard"
		plan.site = nil
	end

	-- Per-bot assignments. Attack: the carrier (and its group, on Split) get
	-- siteChoice; the plan leaves the sniper to freelance mid.
	local carrier = ctx.attackers[1]
	for _, bot in ctx.attackers do
		if plan.attackKind == "Rush" then
			bot.siteChoice = plan.site
		elseif plan.attackKind == "Default" then
			if bot.role == "Sniper" then
				bot.siteChoice = nil -- the sniper holds mid, open choice
			elseif bot.role == "Lurker" then
				bot.siteChoice = if plan.pressureSite then plan.pressureSite else nil
			else
				bot.siteChoice = plan.site
			end
		else -- Split
			if bot == carrier or bot.role == "Entry" or bot.role == "Support" then
				bot.siteChoice = plan.site
			else
				bot.siteChoice = plan.otherSite
			end
		end
	end

	-- Defense: on Standard, anchors split, support takes the weaker side —
	-- tilted by the ledger's preferred-site read when it has one.
	if plan.defenseKind == "Standard" then
		local supportSite = "B_SITE"
		local preferred = MatchMemory.preferredSite("Attack")
		if preferred == "B_SITE" then
			supportSite = "A_SITE"
		end
		for _, bot in ctx.defenders do
			if bot.role == "Anchor" then
				if bot.holdChoice == nil then
					bot.holdChoice = if rng:NextNumber() < 0.5 then "A_SITE" else "B_SITE"
				end
			elseif bot.role == "Sniper" then
				bot.holdChoice = if rng:NextNumber() < 0.5 then "A_HEAVEN" else "B_HEAVEN"
			elseif bot.role == "Support" then
				bot.holdChoice = supportSite
			else
				bot.holdChoice = nil -- IGL floats mid/window
			end
		end
	elseif plan.defenseKind == "Stack" then
		for _, bot in ctx.defenders do
			bot.holdChoice = if stackSite == "A_SITE"
				then (if rng:NextNumber() < 0.5 then "A_SITE" else "A_HEAVEN")
				else (if rng:NextNumber() < 0.5 then "B_SITE" else "B_HEAVEN")
		end
	else -- Aggro: nobody anchors; Push scorers carry them forward
		for _, bot in ctx.defenders do
			bot.holdChoice = nil
		end
	end

	MatchState.plan = plan

	-- The broadcast read: what did the coach call?
	local atkText
	if plan.attackKind == "Rush" then
		atkText = ("RUSH %s — everyone, same door, right now"):format(if plan.site == "A_SITE" then "A" else "B")
	elseif plan.attackKind == "Default" then
		atkText = ("default — core hits %s, sniper holds mid, lurker freelances"):format(if plan.site == "A_SITE" then "A" else "B")
	else
		atkText = ("split — carrier group %s, pressure %s"):format(
			if plan.site == "A_SITE" then "A" else "B",
			if plan.otherSite == "A_SITE" then "A" else "B"
		)
	end
	local defText
	if plan.defenseKind == "Stack" then
		defText = ("STACK %s — four bodies on one site"):format(if stackSite == "A_SITE" then "A" else "B")
	elseif plan.defenseKind == "Aggro" then
		defText = "aggressive — forward holds, contest mid"
	else
		defText = "standard 2-1-2 — anchors split, IGL on the window"
	end
	print(("[CLUTCH] CALL ATK: %s"):format(atkText))
	print(("[CLUTCH] CALL DEF: %s"):format(defText))

	return carrier
end

function RoundMachine.run(ctx: Context)
	local killFeed = ReplicatedStorage:WaitForChild("CLUTCH"):WaitForChild("KillFeed")

	local function teleportRoster(roster: { any }, spawns: { Vector3 })
		for i, bot in roster do
			local root = rootOf(bot.model)
			if root then
				local facing = if bot.side == "Attack"
					then CFrame.new(spawns[i])
					else CFrame.lookAt(spawns[i], spawns[i] + Vector3.zAxis)
				bot.model:PivotTo(facing)
			end
		end
	end

	-- The kill feed reads stamps set by whoever landed the blow. THE SPIKE
	-- earns its own kills (LastKilledBy == THE SPIKE) — including the living,
	-- when the blast ends the round early.
	local function watchDeaths(onKill: (killer: string, victim: string, headshot: boolean) -> ())
		local watched: { [Model]: boolean } = {}
		for _, roster in { ctx.attackers, ctx.defenders } do
			for _, bot in roster do
				local model = bot.model
				if watched[model] then
					continue
				end
				watched[model] = true
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				if not humanoid then
					continue
				end
				local dyingBot = bot -- the closure's own bot, not the loop's ghost
				humanoid.Died:Connect(function()
					local killer = model:GetAttribute("LastKilledBy") or "the void"
					local headshot = model:GetAttribute("LastKillHeadshot") == true
					local weapon = model:GetAttribute("LastKillWeapon") or "?"
					local distance = model:GetAttribute("LastKillDistance") or 0
					local at = ctx.clock() -- the round machine's OWN clock (see header)

					-- Deaths RESET per round (scoreboard-style); kills accumulate in
					-- the round and reset too. Headshots are the lifetime stat.
					dyingBot.deaths = (dyingBot.deaths or 0) + 1
					if killer ~= "the void" and killer ~= "THE SPIKE" then
						for _, roster in { ctx.attackers, ctx.defenders } do
							for _, candidate in roster do
								if candidate.name == killer then
									MatchMemory.recordKill(candidate.side, Zones.keyAt(Zones.groundOf(candidate.model)))
								end
							end
						end
					end

					print(("[CLUTCH] %6.1fs  DOWN %s | by %s (%s)%s"):format(
						at,
						dyingBot.name,
						tostring(killer),
						tostring(weapon),
						if headshot then " HEADSHOT" else ""
					))

					-- THE SPIKE RADIO. A carrier death is FACT to everyone; the
				-- KILLER's side also saw where it happened, so they hold the mark
				-- from second one. Everyone else earns it with their own eyes.
					if MatchState.spikeCarrier == dyingBot then
						Objective.dropSpike(dyingBot)
						if MatchState.spikePart then
							local dropZoneKey = Zones.keyAt(MatchState.spikePart.Position)
							if dyingBot.side == "Attack" then
								MatchState.spikeMarkAtk = { pos = MatchState.spikePart.Position, zoneKey = dropZoneKey, at = at }
							else
								MatchState.spikeMarkDef = { pos = MatchState.spikePart.Position, zoneKey = dropZoneKey, at = at }
							end
							local killerSide: string? = nil
							for _, roster in { ctx.attackers, ctx.defenders } do
								for _, candidate in roster do
									if candidate.name == killer then
										killerSide = candidate.side
									end
								end
							end
							if killerSide == "Attack" then
								MatchState.spikeMarkAtk = { pos = MatchState.spikePart.Position, zoneKey = dropZoneKey, at = at }
							elseif killerSide == "Defense" then
								MatchState.spikeMarkDef = { pos = MatchState.spikePart.Position, zoneKey = dropZoneKey, at = at }
							end
						end
					end

					onKill(tostring(killer), dyingBot.name, headshot)

					local victimSide = if dyingBot.side == "Attack" then "ATK" else "DEF"
					local killerSideShort = if dyingBot.side == "Attack" then "DEF" else "ATK"
					killFeed:FireAllClients({
						killer = tostring(killer),
						killerSide = killerSideShort,
						victim = dyingBot.name,
						victimSide = victimSide,
						weapon = tostring(weapon),
						headshot = headshot,
						distance = distance,
					})
				end)
			end
		end
	end

	local function killEveryone(roster: { any }, byName: string)
		for _, bot in roster do
			local humanoid = bot.model and bot.model:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				bot.model:SetAttribute("LastKilledBy", byName)
				bot.model:SetAttribute("LastKillHeadshot", false)
				bot.model:SetAttribute("LastKillDistance", 0)
				bot.model:SetAttribute("LastKillWeapon", "Spike")
				humanoid:TakeDamage(500)
			end
		end
	end

	while true do
		MatchState.roundNumber += 1
		Objective.reset()
		resetBodies(ctx.attackers)
		resetBodies(ctx.defenders)
		teleportRoster(ctx.attackers, ctx.attackSpawns)
		teleportRoster(ctx.defenders, ctx.defenseSpawns)

		for _, bot in ctx.attackers do
			bot.kills = 0
			bot.deaths = 0
			bot.siteChoice = nil
		end
		for _, bot in ctx.defenders do
			bot.kills = 0
			bot.deaths = 0
			bot.holdChoice = nil
		end

		local carrier = rollTeamPlans(ctx, ctx._rng)
		Objective.assignCarrier(carrier)

		-- BUY. Budgets pay for guns; the losers get what they can afford.
		local buyBrain = function(bot: any)
			local credits = bot.credits or 0
			local wanted
			if bot.role == "Sniper" and credits >= Weapons.Longshot.Price then
				wanted = Weapons.Longshot
			elseif credits >= Weapons.FalconAR.Price then
				wanted = Weapons.FalconAR
			else
				wanted = Weapons.Sidearm
			end
			credits -= wanted.Price
			bot.credits = credits
			bot.weapon = wanted
			BotSpawner.styleGun(bot.model, wanted)
			BotSpawner.styleHeld(bot.model, "Gun") -- the knife goes away at spawn
		end
		for _, bot in ctx.attackers do
			buyBrain(bot)
		end
		for _, bot in ctx.defenders do
			buyBrain(bot)
		end

		-- Freeze attackers; defenders deploy DURING the buy phase.
		for _, bot in ctx.attackers do
			anchor(bot.model, true)
		end

		local firstKillFired = false
		local stopWatching = false
		local watchThread = task.spawn(function()
			watchDeaths(function(killer, victim, headshot)
				if not firstKillFired and killer ~= "the void" and killer ~= "THE SPIKE" then
					firstKillFired = true
					ctx.onFirstKill(killer, victim, headshot)
				end
			end)
			while not stopWatching do
				task.wait(0.5)
			end
		end)

		-- LIVE
		ctx.publish("Buy", RoundConfig.BuyPhaseSeconds)
		local buyUntil = ctx.clock() + RoundConfig.BuyPhaseSeconds
		while ctx.clock() < buyUntil do
			ctx.publish("Buy", math.max(buyUntil - ctx.clock(), 0))
			task.wait(0.25)
		end
		for _, bot in ctx.attackers do
			anchor(bot.model, false)
		end

		print(("[CLUTCH] ===== ROUND %d ====="):format(MatchState.roundNumber))

		local roundEndsAt = ctx.clock() + RoundConfig.RoundSeconds
		local result: string? = nil
		local resultReason = ""

		while ctx.clock() < roundEndsAt do
			ctx.publish(
				if MatchState.planted then "Planted" else "Live",
				math.max(roundEndsAt - ctx.clock(), 0)
			)
			MatchState.atkAlive = aliveCount(ctx.attackers)
			MatchState.defAlive = aliveCount(ctx.defenders)

			if MatchState.defused then
				result = "Defense"
				resultReason = "the defuse"
				break
			end
			if MatchState.exploded then
				result = "Attack"
				resultReason = "the spike"
				break
			end
			local atkAlive = MatchState.atkAlive
			local defAlive = MatchState.defAlive
			if defAlive == 0 then
				result = "Attack"
				resultReason = "elimination"
				break
			end
			-- A wipe with the spike DOWN ends it; a wipe with the spike UP is
			-- the defuse race — the clock (and the fuse) decide it now.
			if atkAlive == 0 and not MatchState.planted then
				result = "Defense"
				resultReason = "elimination"
				break
			end
			task.wait(0.25)
		end

		if result == nil then
			-- Time expired. Planted: the fuse owns the ending. Not planted:
			-- defense holds.
			if MatchState.planted then
				result = "Attack"
				resultReason = "the fuse"
			else
				result = "Defense"
				resultReason = "the clock"
			end
		end

		-- Score, pay, log.
		if result == "Attack" then
			MatchState.atkScore += 1
			for _, bot in ctx.attackers do
				bot.credits = (bot.credits or 0) + RoundConfig.CreditsWin
			end
			for _, bot in ctx.defenders do
				bot.credits = (bot.credits or 0) + RoundConfig.CreditsLoss
			end
		else
			MatchState.defScore += 1
			for _, bot in ctx.defenders do
				bot.credits = (bot.credits or 0) + RoundConfig.CreditsWin
			end
			for _, bot in ctx.attackers do
				bot.credits = (bot.credits or 0) + RoundConfig.CreditsLoss
			end
		end
		for _, bot in ctx.attackers do
			bot.credits = (bot.credits or 0) + (bot.kills or 0) * RoundConfig.CreditsPerKill
		end
		for _, bot in ctx.defenders do
			bot.credits = (bot.credits or 0) + (bot.kills or 0) * RoundConfig.CreditsPerKill
		end

		print(("[CLUTCH] ROUND_RESULT | r%d | %s | %s | plant=%s | %.1fs | alive %dv%d"):format(
			MatchState.roundNumber,
			string.upper(result),
			resultReason,
			tostring(MatchState.planted or MatchState.exploded or MatchState.defused),
			task.wait() * 0 + (RoundConfig.RoundSeconds - math.max(roundEndsAt - ctx.clock(), 0)),
			aliveCount(ctx.attackers),
			aliveCount(ctx.defenders)
		))

		-- POST ROUND. Stop the watch, retire the brains, freeze what's left.
		stopWatching = true
		task.cancel(watchThread)
		for _, roster in { ctx.attackers, ctx.defenders } do
			for _, bot in roster do
				anchor(bot.model, true)
				local humanoid = bot.model:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 then
					if result == "Attack" and MatchState.exploded then
						-- The spike doesn't care who won the round on paper.
						if bot.side == "Defense" then
							humanoid:TakeDamage(500)
						end
					end
				end
			end
		end

		ctx.publish("PostRound", RoundConfig.PostRoundSeconds)
		task.wait(RoundConfig.PostRoundSeconds)

		if MatchState.atkScore >= RoundConfig.RoundsToWin or MatchState.defScore >= RoundConfig.RoundsToWin then
			local winner = if MatchState.atkScore > MatchState.defScore then "Attack" else "Defense"
			-- THE SCOUT REPORT: what the memory learned, before it decays.
			for _, line in MatchMemory.scoutLines() do
				print(("[CLUTCH] SCOUT %s"):format(line))
			end
			print(("[CLUTCH] MATCH_RESULT | %s | %d-%d"):format(
				string.upper(winner),
				MatchState.atkScore,
				MatchState.defScore
			))
			ctx.onMatchEnd(winner, MatchState.atkScore, MatchState.defScore)
			MatchMemory.decay() -- the ledger halves; old intel fades across matches
			MatchState.atkScore = 0
			MatchState.defScore = 0
			MatchState.roundNumber = 0
		end
	end
end

return RoundMachine
