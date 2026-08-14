--!strict
-- Which scenario the server boots into, and how loudly it reports itself.
--
-- Ten bots patrolling at once produced a log nobody could read. Two bots
-- produce a transcript. Duel1v1 exists so the brain can be AUDITED: every
-- perception event and every intent switch for exactly two actors, in order.
-- Switch to Full5v5 once the decisions look sane.

export type Mode = "Duel1v1" | "Full5v5"

export type StatBlock = {
	Aim: number,
	Reactions: number,
	GameSense: number,
	Aggression: number,
	UtilityUsage: number,
	Clutch: number,
	Consistency: number,
}

return {
	Mode = "Duel1v1" :: Mode,

	-- Who fights in Duel1v1.
	DuelAttacker = "Ace",
	DuelDefender = "Onyx",

	-- Everyone opens with this; the economy decides what they carry later. A
	-- pistol is the right test weapon: its 40-stud optimal band is well inside
	-- the distances this map produces, so range discipline gets exercised.
	DuelWeapon = "Sidearm",

	-- CONTROLLED EXPERIMENT. With this on, every bot gets identical attributes,
	-- so any behavioural difference must come from role, side or situation — not
	-- from a stat roll. Turn it off to watch attributes reassert themselves.
	--
	-- The block is tuned to a "competent ranked player", not a pro and not a
	-- bot: Game Sense highest (so range discipline and rotations are visible),
	-- Aggression deliberately moderate (75 produced dry ego-peeks), Aim/Reactions
	-- human rather than aimbot. Dumb decisions should be traceable to the
	-- brain's weights, not to a stat handing out free wins.
	UniformStats = true,
	UniformStatBlock = {
		Aim = 70,
		Reactions = 70,
		GameSense = 80,
		Aggression = 60,
		UtilityUsage = 70,
		Clutch = 70,
		Consistency = 75,
	} :: StatBlock,

	-- Brain logging
	VerboseBrain = true, -- every intent switch, with the score that won
	LogPerception = true, -- first sighting and loss of contact
	LogZoneTransitions = true, -- "Ace | A Lobby -> A Door"
	LogCombat = true, -- engage / hold-fire decisions and every shot

	-- A bot locked into one intent used to print nothing at all, because THINK
	-- only fired on CHANGE. Ace produced zero reasoning output for 84 seconds
	-- while visibly doing something wrong. Print the score vector periodically
	-- even when the winner has not moved.
	BrainHeartbeatSeconds = 12,

	-- Movement telemetry. Samples are buffered at full rate for analysis but
	-- only ZONE CHANGES are printed — 4Hz coordinate spam is unreadable and
	-- hides the thing we actually want to see.
	TelemetrySampleSeconds = 0.25,
	TelemetryMaxSamples = 20000,
	TelemetryReportSeconds = 60, -- periodic dwell-time summary

	-- The old shooting-range spike. Superseded by real bot-vs-bot combat.
	RunShootingRange = false,

	-- Anti-stall. With no round timer yet, decisiveness ramps on time since a
	-- bot last saw an enemy or finished what it set out to do. It deliberately
	-- does NOT reset on every footstep — that turned the ramp into a metronome
	-- and produced a 25-second Mid Back / Mid Window ping-pong.
	StallRampSeconds = 25,

	-- Minimum seconds a bot must stay committed to an intent before switching.
	-- Engage/Plant/Defuse are exempt: getting shot at — or a live objective —
	-- is allowed to interrupt anything.
	MinIntentSeconds = 4,
}
