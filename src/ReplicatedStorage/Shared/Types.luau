--!strict
-- Shared types for the match sim. Server orchestrator, bot brains, the event
-- recorder, and the spectator client all speak these.

local Attributes = require(script.Parent.Constants.Attributes)

export type AttributeSet = Attributes.AttributeSet

export type Role = "Entry" | "Support" | "IGL" | "Sniper" | "Anchor" | "Lurker"

export type TeamSide = "Attack" | "Defense"

-- Strategic-layer round plans (team brain, set once per round + on big events)
export type RoundPlan = "Rush" | "Default" | "Split" | "LateCrunch" | "SaveRound" | "ForceBuy"

-- Tactical-layer intents (per-bot, utility-AI scored every decision tick).
-- M0 uses Hold / Push / Plant / Defuse / Rotate only.
export type Intent = "Hold" | "Push" | "Lurk" | "Rotate" | "Plant" | "Defuse" | "Retake" | "Save"

export type RoundPhase = "Buy" | "Live" | "Planted" | "PostRound"

-- A bot's snapshot the duel model consumes.
export type BotSimState = {
	botId: string,
	role: Role,
	attributes: AttributeSet,
	consistencySwing: number, -- rolled once per match
	tilt: number, -- 0..1 morale slider
	intent: Intent,
	alive: boolean,
}

-- Event recorder: every meaningful thing that happens, in order.
-- This is the replay file, the highlight detector, and the storyline feed.
export type MatchEvent = {
	t: number, -- seconds since match start
	round: number,
	kind: string, -- "kill" | "plant" | "defuse" | "roundEnd" | "buy" | ...
	actorBotId: string?,
	targetBotId: string?,
	data: { [string]: any }?,
}

return nil
