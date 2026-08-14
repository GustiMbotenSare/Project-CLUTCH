--!strict
-- Round structure + credit economy.
-- Format decision (FT13 vs FT7) is still open — WinsNeeded/HalftimeAfterRound are the knobs.

return {
	-- Format
	TeamSize = 5,
	WinsNeeded = 13, -- TBD: 13 = full length, 7 = snappy league nights
	MaxRoundsRegulation = 24,
	HalftimeAfterRound = 12, -- sides swap

	-- Timers (seconds)
	BuyPhaseSeconds = 30,
	RoundSeconds = 100,
	SpikeFuseSeconds = 45,
	PlantSeconds = 4,
	DefuseSeconds = 7,
	PostRoundSeconds = 7,

	-- Economy
	StartCredits = 800,
	MaxCredits = 9000,
	WinReward = 3000,
	LossRewardBase = 1900, -- +500 per consecutive loss, capped
	LossRewardStep = 500,
	LossRewardMax = 2900,
	KillReward = 200,
	PlantBonusLoss = 300, -- attackers still paid for a plant in a lost round
}
