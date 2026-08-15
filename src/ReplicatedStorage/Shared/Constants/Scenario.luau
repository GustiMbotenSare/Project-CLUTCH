--!strict
-- Which scenario the server boots into, and how loudly it reports itself.
--
-- Full5v5 is the default as of map v3: the duel produced a clean, auditable
-- transcript (plants, defuses, economy, walk/sprint, angle holding) and the
-- map is now built for ten. Duel1v1 remains the audit rig — flip Mode back
-- whenever a change needs a two-actor transcript.

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
	Mode = "Full5v5" :: Mode,

	-- Who fights in Duel1v1 (unused in Full5v5).
	DuelAttacker = "Ace",
	DuelDefender = "Onyx",

	-- Everyone opens with this; the economy decides what they carry later. A
	-- pistol is the right test weapon: its 40-stud optimal band is well inside
	-- the distances this map produces, so range discipline gets exercised.
	DuelWeapon = "Sidearm",

	-- SELF-PLAY TUNING (the in-game CEM). OFF by default: with this on, the
	-- Tuner perturbs BrainTuning's scalar weights between matches — each match
	-- plays under one candidate set, gets scored (attacker win rate -> 50%,
	-- plant rate -> 30%, round pace -> 75s), and every 4 matches the search
	-- refits toward the elites. Leave Studio running and harvest the TUNING
	-- lines; paste the best-ever values back into BrainTuning.luau when a
	-- generation converges. Keep it OFF for playtests — you want to judge ONE
	-- behavior build at a time.
	TuningMode = false,

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
