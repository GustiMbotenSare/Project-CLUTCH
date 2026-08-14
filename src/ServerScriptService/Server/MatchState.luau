--!strict
-- Shared match state. Written by RoundMachine and Objective, read by Brain
-- (so intents can react to the round) and mirrored to the client as attributes
-- on the CLUTCH remotes folder (phase, clock, score, spike).
--
-- Pure data. It requires nothing, so nothing can require-cycle through it.

local MatchState = {
	-- "Buy" | "Live" | "Planted" | "PostRound"
	phase = "Buy" :: string,
	roundNumber = 0,
	timeLeft = 0, -- seconds remaining in the current phase/fuse

	atkScore = 0,
	defScore = 0,

	-- Spike
	planted = false,
	plantedZoneKey = nil :: string?,
	plantedAt = 0,
	spikePart = nil :: BasePart?,
	spikeCarrier = nil :: any, -- bot record while carried; nil while dropped
	defused = false,
	exploded = false,
}

return MatchState
