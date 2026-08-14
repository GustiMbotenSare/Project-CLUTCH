--!strict
-- Which scenario the server boots into, and how loudly it reports itself.
--
-- Ten bots patrolling at once produced a log nobody could read. Two bots
-- produce a transcript. Duel1v1 exists so the brain can be AUDITED: every
-- perception event and every intent switch for exactly two actors, in order.
-- Switch to Full5v5 once the decisions look sane.

export type Mode = "Duel1v1" | "Full5v5"

return {
	Mode = "Duel1v1" :: Mode,

	-- Who fights in Duel1v1. Ace is the high-Aim/high-Aggression Entry and Onyx
	-- is a defensive Anchor, so their intent scores should diverge hard — if
	-- both bots behave identically, the scorer is not reading attributes.
	DuelAttacker = "Ace",
	DuelDefender = "Onyx",

	-- Brain logging
	VerboseBrain = true, -- every intent switch, with the score that won
	LogPerception = true, -- first sighting and loss of contact
	LogZoneTransitions = true, -- "Ace | A Lobby -> A Door"

	-- Movement telemetry. Samples are buffered at full rate for analysis but
	-- only ZONE CHANGES are printed — 4Hz coordinate spam is unreadable and
	-- hides the thing we actually want to see.
	TelemetrySampleSeconds = 0.25,
	TelemetryMaxSamples = 20000,
	TelemetryReportSeconds = 60, -- periodic dwell-time summary

	-- The shooting-range spike is off by default now: bots that maneuver
	-- without shooting produce a pure decision log. Combat lands next.
	RunShootingRange = false,

	-- Anti-stall. With no round timer yet, decisiveness ramps on time since a
	-- bot last made progress or saw an enemy, rather than round time left.
	StallRampSeconds = 25,
}
