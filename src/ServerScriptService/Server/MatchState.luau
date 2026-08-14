--!strict
-- Shared match state. Written by RoundMachine and Objective, read by Brain and
-- the client (via attributes on the CLUTCH remotes folder that RoundMachine
-- maintains). Pure data: requires nothing, so nothing can require-cycle it.
--
-- lastShot is the gunfire bus: Combat stamps it at every burst, Perception
-- reads it so bots HEAR gunfire (GunshotSoundGlobal). Sound has to come from
-- somewhere real, not from bots polling each other's triggers.

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

	-- Most recent gunfire: { by = shooter name, pos = Vector3, at = clock() }
	lastShot = nil :: any,
}

return MatchState
