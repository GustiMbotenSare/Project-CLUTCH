--!strict
-- Bot attribute model (1–100 scale).
-- Pillar #2: every attribute must map to VISIBLE, scoutable behavior.

export type Attribute =
	"Aim"
	| "Reactions"
	| "GameSense"
	| "Aggression"
	| "UtilityUsage"
	| "Clutch"
	| "Consistency"

export type AttributeSet = { [Attribute]: number }

-- What each attribute controls on screen:
--   Aim          -> accuracy, spray control, headshot rate
--   Reactions    -> time-to-first-shot after seeing an enemy
--   GameSense    -> rotations, timing, reading fakes, flank awareness, intel inference
--   Aggression   -> peek frequency, entry willingness, push tendency
--   UtilityUsage -> how well and how often abilities are used (M1+)
--   Clutch       -> performance modifier in 1vX and high-pressure rounds
--   Consistency  -> variance; low = star one map, ghost the next

local ATTRIBUTE_LIST: { Attribute } = {
	"Aim",
	"Reactions",
	"GameSense",
	"Aggression",
	"UtilityUsage",
	"Clutch",
	"Consistency",
}

-- Role weight templates (0–1). Used twice:
--   1. Bot generation biases attributes by role
--   2. Utility-AI intent scoring multiplies by these weights
-- The weights ARE the transfer market: a great Entry and a great Anchor
-- are different animals, and a manager has to know the difference.
local ROLE_WEIGHTS: { [string]: { [Attribute]: number } } = {
	Entry = {
		Aim = 1.0,
		Reactions = 0.9,
		GameSense = 0.5,
		Aggression = 1.0,
		UtilityUsage = 0.4,
		Clutch = 0.6,
		Consistency = 0.5,
	},
	Support = {
		Aim = 0.6,
		Reactions = 0.6,
		GameSense = 0.8,
		Aggression = 0.4,
		UtilityUsage = 1.0,
		Clutch = 0.5,
		Consistency = 0.8,
	},
	IGL = {
		Aim = 0.5,
		Reactions = 0.5,
		GameSense = 1.0,
		Aggression = 0.4,
		UtilityUsage = 0.7,
		Clutch = 0.6,
		Consistency = 0.8,
	},
	Sniper = {
		Aim = 1.0,
		Reactions = 0.8,
		GameSense = 0.7,
		Aggression = 0.5,
		UtilityUsage = 0.3,
		Clutch = 0.7,
		Consistency = 0.6,
	},
	Anchor = {
		Aim = 0.7,
		Reactions = 0.6,
		GameSense = 0.9,
		Aggression = 0.2,
		UtilityUsage = 0.6,
		Clutch = 0.7,
		Consistency = 0.8,
	},
	Lurker = {
		Aim = 0.7,
		Reactions = 0.6,
		GameSense = 0.9,
		Aggression = 0.3,
		UtilityUsage = 0.4,
		Clutch = 0.8,
		Consistency = 0.6,
	},
}

return {
	List = ATTRIBUTE_LIST,
	Min = 1,
	Max = 100,
	RoleWeights = ROLE_WEIGHTS,
}
