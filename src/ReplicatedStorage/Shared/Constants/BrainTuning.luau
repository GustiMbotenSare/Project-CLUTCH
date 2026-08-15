--!strict
-- BrainTuning: every utility weight the brain scores with, in one place and
-- named after what it means.
--
-- Two readers:
--   * Brain.luau reads these fields LIVE at score time, so an in-place edit
--     to this table changes behavior mid-match without a reload.
--   * Server/Tuner.luau (the in-game CEM, active when Scenario.TuningMode is
--     on) perturbs the scalar fields between matches, scores each candidate
--     against the objective metrics (attacker win rate near 50%, plant rate
--     near 30%, round duration in a watchable band), and refits toward the
--     elites. The defaults below are the hand-tuned playtest #1-#14 values;
--     the tuner searches around them.
--
-- Role tables are data too, but the CEM only perturbs scalars for now —
-- multi-dimensional role tuning comes after the scalar search converges.

return {
	Hysteresis = 0.08, -- how much better a rival intent must be to win

	Hold = {
		Base = 0.30,
		DefenseBonus = 0.18,
		AggressionPenalty = -0.22,
		DecisivenessPenalty = -0.30,
		NoContactBonus = 0.10,
		HighGroundBonus = 0.14, -- standing on a site/heaven worth holding
		Role = { Anchor = 0.30, Sniper = 0.23, Support = 0.10, IGL = 0.07, Lurker = 0.03, Entry = 0.00 },
	},

	Push = {
		Base = 0.20,
		AggressionBonus = 0.25,
		AttackBonus = 0.15,
		DecisivenessBonus = 0.30,
		AtObjectivePenalty = -0.65, -- nothing left to push toward
		CarrierBonus = 0.15,
		CarrierAloneHotPenalty = -0.40, -- the spike does not entry-frag alone
		RetrieveBonus = 0.20,
		RetrieveHotBonus = 0.05, -- a spike in a known-hot zone is a trap
		Role = { Entry = 0.25, Support = 0.11, IGL = 0.08, Lurker = 0.06, Sniper = 0.03, Anchor = 0.00 },
	},

	Rotate = {
		Base = 0.25,
		GameSenseBonus = 0.30,
		DistanceBonus = 0.15, -- scales with hops (farther = more worth rotating)
		SoundPenalty = -0.10, -- footsteps are worth less than eyes
		SiteBonus = 0.10, -- they're hitting a site — go
	},

	Lurk = {
		Base = 0.10,
		CalmBonus = 0.18, -- scales with (1 - Aggression)
		DecisivenessPenalty = -0.20,
		CrowdPenalty = -0.12, -- lurking in a group is not lurking
		Role = { Lurker = 0.30, Sniper = 0.09, Support = 0.03, IGL = 0.03, Entry = 0.00, Anchor = 0.00 },
	},

	FallBack = {
		Base = 0.30,
		PerExtraEnemy = 0.25,
		AggressionPenalty = -0.30,
		Role = { Anchor = 0.15, Sniper = 0.10, IGL = 0.05, Support = 0.00, Lurker = -0.05, Entry = -0.20 },
	},

	Plant = {
		Base = 0.45,
		DecisivenessBonus = 0.20,
		OnSiteBonus = 0.55,
		HotSitePenalty = -0.45, -- a contact within 2 hops of the site: clear first
		ContactPenalty = -0.15,
	},

	Defuse = {
		Base = 0.75,
		GameSenseBonus = 0.15,
		SupportWavePenalty = -0.75, -- the two closest defuse; the rest rotate in
		OnSiteBonus = 0.50,
	},
}
