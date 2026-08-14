--!strict
-- Sim tuning: perception, the duel model, decisiveness ramp, tilt.
-- These constants are where 'bots feel human' is won or lost. Tune by watching.

return {
	-- Tick rates
	DecisionTickSeconds = 0.25, -- tactical-layer intent re-evaluation
	PerceptionTickSeconds = 0.15, -- vision/hearing sweep

	-- Perception (honest senses: vision cone + LOS raycast + sound radius)
	VisionConeDeg = 120,
	VisionRangeStuds = 120,
	FootstepSoundRadiusStuds = 40,
	GunshotSoundGlobal = true, -- everyone hears shots; GameSense decides what they infer
	MemoryDecaySeconds = 8, -- last-seen intel fades
	CalloutDelaySeconds = 0.5, -- team intel share delay (lower with better IGL)

	-- Duel model
	ReactionDelayBaseSeconds = 0.38, -- at Reactions = 1
	ReactionDelayMinSeconds = 0.12, -- at Reactions = 100
	FlickOvershootBaseChance = 0.35, -- reduced by Aim; overshoot = the whiff you can see
	ConsistencySwingMin = 0.85, -- per-match hidden multiplier range...
	ConsistencySwingMax = 1.15, -- ...rolled at match start ("he's having a game")
	ClutchBuffMax = 0.15, -- accuracy/reaction bonus at Clutch=100 in 1vX

	-- Decisiveness ramp (anti-stall): intent scores drift toward commitment
	-- as round time burns. Boring matches are the silent killer.
	DecisivenessRampStartSeconds = 40, -- round time remaining when the ramp begins
	DecisivenessRampStrength = 1.0, -- multiplier at 0 seconds remaining

	-- Tilt (per-bot morale slider, 0 = ice cold, 1 = full tilt)
	TiltPerRoundLoss = 0.08,
	TiltPerDeathStreak = 0.05, -- per consecutive round died without a kill
	TiltRecoverPerRoundWin = 0.10,
	TiltErrorVarianceMultiplier = 1.6, -- error spread multiplier at full tilt
	TiltEgoPeekBonus = 0.2, -- Aggression drift at full tilt (the ego peek)
}
