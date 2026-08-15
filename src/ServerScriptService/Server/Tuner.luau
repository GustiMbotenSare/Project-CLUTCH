--!strict
-- Tuner: a tiny in-game CEM (cross-entropy method) over BrainTuning.
--
-- Active only when Scenario.TuningMode is on. The round machine already
-- loops matches forever; with the tuner running, each MATCH plays under one
-- candidate weight set, gets scored against the objective metrics, and every
-- GENERATION_SIZE matches the search refits toward the elites:
--
--   mean' = 0.7 · elite-weighted mean + 0.3 · mean   (momentum)
--   sigma' = sigma · 0.85                            (annealing)
--
-- Objective (higher = better), shaped by the ESTA pro-match distributions we
-- calibrated against:
--   attacker win rate → 50%     (a balanced map/brain meta)
--   plant rate        → 30%     (ESTA: plants in ~30% of pro rounds)
--   avg round seconds → 75      (ESTA: ~94s; we run 100s clocks, so 75 reads
--                                as decisive-but-not-instant)
--
-- The brain reads BrainTuning LIVE at score time, so mutating the table
-- between matches changes the next match's behavior — no reloads. When a
-- generation's best-ever candidate looks right, paste its printed values
-- back into BrainTuning.luau's defaults and flip TuningMode off.
--
-- Scalars only for now (18 weights). Role tables join after the scalar
-- search converges.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local BrainTuning = require(Shared.Constants.BrainTuning)

local Tuner = {}

local GENERATION_SIZE = 4 -- matches per generation
local ELITES = 2
local SIGMA_FRACTION = 0.25 -- of |value|
local SIGMA_FLOOR = 0.03
local SIGMA_ANNEAL = 0.85
local MEAN_MOMENTUM = 0.3

local TARGET_ATK_WINRATE = 0.50
local TARGET_PLANT_RATE = 0.30
local TARGET_ROUND_SECONDS = 75

-- Dot-paths into BrainTuning. Scalars only.
local PATHS = {
	"Hold.Base", "Hold.DefenseBonus", "Hold.NoContactBonus", "Hold.HighGroundBonus",
	"Push.Base", "Push.AggressionBonus", "Push.AttackBonus", "Push.CarrierAloneHotPenalty",
	"Rotate.Base", "Rotate.GameSenseBonus", "Rotate.SiteBonus",
	"Lurk.Base",
	"FallBack.Base", "FallBack.PerExtraEnemy",
	"Plant.Base", "Plant.HotSitePenalty",
	"Defuse.Base", "Defuse.SupportWavePenalty",
}

type MatchStats = {
	rounds: number,
	atkWins: number,
	defWins: number,
	plants: number,
	avgRoundSeconds: number,
}

local rng = Random.new()

local defaults: { [string]: number } = {}
local mean: { [string]: number } = {}
local sigma: { [string]: number } = {}
local captured = false

local function readPath(path: string): number
	local node: any = BrainTuning
	for part in string.gmatch(path, "[^.]+") do
		node = node[part]
	end
	return node
end

local function writePath(path: string, value: number)
	local node: any = BrainTuning
	local parts = {}
	for part in string.gmatch(path, "[^.]+") do
		table.insert(parts, part)
	end
	for i = 1, #parts - 1 do
		node = node[parts[i]]
	end
	node[parts[#parts]] = value
end

local function capture()
	if captured then
		return
	end
	captured = true
	for _, path in PATHS do
		local value = readPath(path)
		defaults[path] = value
		mean[path] = value
		sigma[path] = math.max(math.abs(value) * SIGMA_FRACTION, SIGMA_FLOOR)
	end
end

local function gaussian(): number
	-- Box-Muller
	local u1 = math.max(rng:NextNumber(), 1e-9)
	local u2 = rng:NextNumber()
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

type Candidate = {
	values: { [string]: number },
	score: number?,
}

local generation = 0
local candidates: { Candidate } = {}
local candidateIndex = 0
local bestEver: Candidate? = nil

local function apply(candidate: Candidate)
	for path, value in candidate.values do
		writePath(path, value)
	end
end

local function sampleCandidate(): Candidate
	local values: { [string]: number } = {}
	for _, path in PATHS do
		values[path] = mean[path] + gaussian() * sigma[path]
	end
	return { values = values }
end

local function scoreMatch(stats: MatchStats): number
	local atkWinRate = if stats.rounds > 0 then stats.atkWins / stats.rounds else 0.5
	local plantRate = if stats.rounds > 0 then stats.plants / stats.rounds else 0
	local score = 0
	score -= math.abs(atkWinRate - TARGET_ATK_WINRATE) * 2
	score -= math.abs(plantRate - TARGET_PLANT_RATE)
	score -= math.abs(stats.avgRoundSeconds - TARGET_ROUND_SECONDS) / 150
	return score
end

local function refit()
	table.sort(candidates, function(a, b)
		return (a.score or -math.huge) > (b.score or -math.huge)
	end)
	local elites = { table.unpack(candidates, 1, math.min(ELITES, #candidates)) }
	for _, path in PATHS do
		local eliteSum = 0
		for _, elite in elites do
			eliteSum += elite.values[path]
		end
		local eliteMean = eliteSum / #elites
		mean[path] = eliteMean * (1 - MEAN_MOMENTUM) + mean[path] * MEAN_MOMENTUM
		sigma[path] = math.max(sigma[path] * SIGMA_ANNEAL, SIGMA_FLOOR * 0.5)
	end

	local best = candidates[1]
	if bestEver == nil or (best.score or -math.huge) > (bestEver.score or -math.huge) then
		bestEver = best
	end

	print(("[CLUTCH] TUNING gen %d done — best %.3f (best ever %.3f)"):format(
		generation,
		best.score or 0,
		if bestEver then bestEver.score or 0 else 0
	))
	if bestEver then
		local parts = {}
		for _, path in PATHS do
			table.insert(parts, ("%s=%.3f"):format(path, bestEver.values[path]))
		end
		print(("[CLUTCH] TUNING best-ever weights: %s"):format(table.concat(parts, " ")))
	end
end

-- Called by the round machine after every match (TuningMode only).
function Tuner.onMatchEnd(stats: MatchStats)
	capture()

	-- First candidate of a session is the defaults themselves — the baseline
	-- every perturbation is judged against.
	if candidateIndex == 0 then
		candidateIndex = 1
		generation = 1
		candidates = { { values = table.clone(defaults) } }
		for _ = 2, GENERATION_SIZE do
			table.insert(candidates, sampleCandidate())
		end
		apply(candidates[1])
		print(("[CLUTCH] TUNING gen 1 starts — candidate 1/%d is the DEFAULTS (baseline)"):format(GENERATION_SIZE))
		return -- the match that just ended played pre-tuning weights; next match is the baseline
	end

	local current = candidates[candidateIndex]
	current.score = scoreMatch(stats)
	print(("[CLUTCH] TUNING gen %d candidate %d/%d scored %.3f | atkWR %.2f plantRate %.2f avgRound %.0fs"):format(
		generation,
		candidateIndex,
		GENERATION_SIZE,
		current.score,
		if stats.rounds > 0 then stats.atkWins / stats.rounds else 0,
		if stats.rounds > 0 then stats.plants / stats.rounds else 0,
		stats.avgRoundSeconds
	))

	candidateIndex += 1
	if candidateIndex > GENERATION_SIZE then
		refit()
		generation += 1
		candidateIndex = 1
		candidates = {}
		for _ = 1, GENERATION_SIZE do
			table.insert(candidates, sampleCandidate())
		end
	end
	apply(candidates[candidateIndex])
	print(("[CLUTCH] TUNING gen %d candidate %d/%d applied"):format(generation, candidateIndex, GENERATION_SIZE))
end

return Tuner
