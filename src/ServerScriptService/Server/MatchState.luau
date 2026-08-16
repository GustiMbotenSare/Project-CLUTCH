--!strict
-- Shared match state. Written by RoundMachine and Objective, read by Brain and
-- the client (via attributes on the CLUTCH remotes folder that RoundMachine
-- maintains). Pure data: requires nothing, so nothing can require-cycle it.
--
-- lastShot is the gunfire bus: Combat stamps it at every burst, Perception
-- reads it so bots HEAR gunfire (GunshotSoundGlobal). Sound has to come from
-- somewhere real, not from bots polling each other's triggers.
--
-- plan is the TEAM layer, rolled by the round machine each round and read by
-- every brain: attackKind "Rush"|"Default"|"Split", defenseKind
-- "Standard"|"Stack"|"Aggro", the called site, and per-bot assignments. This
-- is the seed of the player-chosen tactics board — today the coin calls it,
-- later the manager does.
--
-- spikeMarkAtk / spikeMarkDef are the HONEST-intel layer about the dropped
-- spike (playtest #16's joined memory): { pos, zoneKey, at } or nil.
-- Attackers get the mark free — they heard their carrier die on the radio.
-- Defenders must EARN it: a mark exists only once a defender has eyes on the
-- dropped spike (or saw it fall). Neither side acts on a drop it doesn't
-- know about — that honesty is what makes rotations readable.
--
-- atkAlive / defAlive (playtest #19): the round machine publishes the live
-- headcounts so brains can read the ALL-CLEAR — attackers wiped with the
-- spike down means defenders sprint the defuse, not creep.
--
-- clearMarks (playtest #19's "this area is clear"): per-side zone-keyed
-- timestamps. A bot that stands a zone down with no contact marks it clear
-- and calls it out; teammates sprint through proven-safe ground and the
-- rotate bait-gate trusts a lone contact when the OTHER site reads clear.
--
-- defusing (playtest #20): while a defuse channel runs, this is { pos, at }.
-- THE DEFUSE IS LOUD — attackers close enough to hear it get a sound
-- contact at the spike, exactly like the original game's tap.

local MatchState = {
	-- "Buy" | "Live" | "Planted" | "PostRound"
	phase = "Buy" :: string,
	roundNumber = 0,
	timeLeft = 0, -- seconds remaining in the current phase/fuse

	atkScore = 0,
	defScore = 0,

	-- Live headcounts, published by the round machine every tick
	atkAlive = 5,
	defAlive = 5,

	-- Spike
	planted = false,
	plantedZoneKey = nil :: string?,
	plantedAt = 0,
	spikePart = nil :: BasePart?,
	spikeCarrier = nil :: any, -- bot record while carried; nil while dropped
	defused = false,
	exploded = false,

	-- Per-side honest intel about the dropped spike (see header)
	spikeMarkAtk = nil :: any,
	spikeMarkDef = nil :: any,

	-- Per-side area-clear marks: zoneKey -> clock() when cleared (round-scoped)
	clearMarks = { Attack = {} :: { [string]: number }, Defense = {} :: { [string]: number } },

	-- While a defuse channel runs: { pos = Vector3, at = number }. LOUD.
	defusing = nil :: any,

	-- Most recent gunfire: { by = shooter name, pos = Vector3, at = clock() }
	lastShot = nil :: any,

	-- Team plan for the current round:
	-- { attackKind: string, defenseKind: string, site: string?, otherSite: string? }
	plan = nil :: any,
}

return MatchState
