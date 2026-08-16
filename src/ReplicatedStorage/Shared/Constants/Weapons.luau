--!strict
-- Weapon definitions. Fictional names — Valorant-flavored balance, IP-safe.
--
-- RANGE BANDS are the important addition. Every weapon declares where it is
-- comfortable and where it stops being useful:
--
--   distance <= OptimalRangeStuds      → "Optimal"  full damage, base spread
--   up to MaxEffectiveRangeStuds       → "Stretch"  damage decays, spread grows
--   beyond that                        → "Extreme"  a bad idea
--
-- This exists so range becomes a real tactical input. A bot holding a pistol at
-- 51 studs is making a genuinely different decision from one holding a rifle at
-- the same distance, and Game Sense is what decides whether it respects that.
--
-- v2 (playtest #19): the loadout layer deepens — real ammo (Magazine +
-- ReserveMags), CROUCH AFFINITY (spray weapons crouch to hold the pattern),
-- THE KNIFE (a movement tool: out = sprint faster, no trigger).
--
-- v2.1 (playtest #20): per-weapon DRAW TIMES — knife 0.2 / pistol 0.5 /
-- rifle 1.0 / sniper 1.25. The price of a switch is what makes
-- switch-vs-reload a real decision.
--
-- v3 (playtest #23): THE ARSENAL OPENS — three new classes, each a
-- personality the behavior layer already knows how to read:
--   * BANDIT (SMG): the eco sprayer. Fast, cheap, high spray growth, HIGH
--     crouch affinity — the crouch-sprayer. Dies past midrange.
--   * JUDGE (Shotgun): pellets, not a bullet — the first multi-ray weapon.
--     Point-blank identity, CrouchAffinity ZERO (no spray, no crouch — the
--     playtester's own rule), pump cadence. Bots holding it should start
--     valuing corners.
--   * HAVOC (Heavy/LMG): the anchor. A 60-round magazine, a slow draw,
--     sustained spray — a hold's silhouette.

export type WeaponClass = "Pistol" | "Rifle" | "Sniper" | "SMG" | "Shotgun" | "Heavy" | "Melee"

export type WeaponDef = {
	Id: string,
	DisplayName: string,
	Class: WeaponClass,
	Price: number,
	DamageBody: number, -- per bullet, or PER PELLET for shotguns
	Pellets: number?, -- shotgun: rays per trigger pull (nil = 1 bullet)
	HeadshotMultiplier: number,
	FireInterval: number, -- seconds between shots
	Magazine: number,
	ReserveMags: number, -- how many magazines beyond the loaded one
	ReloadSeconds: number,
	EquipSeconds: number, -- the DRAW time when switching TO this weapon
	FirstBulletSpreadDeg: number, -- standing, unscoped where applicable
	SprayErrorGrowthDeg: number, -- added spread per consecutive shot
	MaxSprayErrorDeg: number,
	BurstShots: number, -- how many trigger pulls a bot commits per engagement tick
	CrouchAffinity: number, -- 0..1: how much this weapon wants spray-crouching

	-- Range model
	OptimalRangeStuds: number,
	MaxEffectiveRangeStuds: number,
	MinDamageMultiplier: number, -- damage multiplier at MaxEffectiveRange
	RangeSpreadPer10Studs: number, -- extra spread per 10 studs past Optimal
}

local Weapons: { [string]: WeaponDef } = {
	-- Everyone can afford this. Deliberately weak past ~40 studs so that
	-- "should I take this fight" has a real answer during pistol rounds.
	Sidearm = {
		Id = "Sidearm",
		DisplayName = "Sidearm",
		Class = "Pistol",
		Price = 400,
		DamageBody = 26, -- 4 body shots to kill an unarmored 100hp bot
		Pellets = nil,
		HeadshotMultiplier = 3.0, -- 78: two taps to the head
		FireInterval = 0.18,
		Magazine = 12,
		ReserveMags = 4,
		ReloadSeconds = 1.8,
		EquipSeconds = 0.5, -- quick draw: the panic switch is its whole job
		FirstBulletSpreadDeg = 0.4,
		SprayErrorGrowthDeg = 0.6,
		MaxSprayErrorDeg = 5.0,
		BurstShots = 3,
		CrouchAffinity = 0.10, -- a pistol is a tap weapon; crouching is rare
		OptimalRangeStuds = 40,
		MaxEffectiveRangeStuds = 90,
		MinDamageMultiplier = 0.55,
		RangeSpreadPer10Studs = 0.35,
	},

	-- The workhorse. Most rounds are won or lost on Falcon fights.
	FalconAR = {
		Id = "FalconAR",
		DisplayName = "Falcon AR",
		Class = "Rifle",
		Price = 2900,
		DamageBody = 40,
		Pellets = nil,
		HeadshotMultiplier = 4.0, -- 160 to the head: one-tap fantasy lives here
		FireInterval = 0.1, -- ~10 rounds/sec full auto
		Magazine = 25,
		ReserveMags = 3,
		ReloadSeconds = 2.5,
		EquipSeconds = 1.0,
		FirstBulletSpreadDeg = 0.2,
		SprayErrorGrowthDeg = 0.25,
		MaxSprayErrorDeg = 4.0,
		BurstShots = 4,
		CrouchAffinity = 0.65, -- the spray weapon: crouch to hold the pattern
		OptimalRangeStuds = 70,
		MaxEffectiveRangeStuds = 140,
		MinDamageMultiplier = 0.75,
		RangeSpreadPer10Studs = 0.12,
	},

	-- The economy breaker. Expensive, slow, and terrifying in a Sniper-role bot's hands.
	Longshot = {
		Id = "Longshot",
		DisplayName = "Longshot",
		Class = "Sniper",
		Price = 4700,
		DamageBody = 150, -- one-shot body kill
		Pellets = nil,
		HeadshotMultiplier = 1.7, -- 255: overkill, on purpose
		FireInterval = 1.4,
		Magazine = 5,
		ReserveMags = 4,
		ReloadSeconds = 3.7,
		EquipSeconds = 1.25, -- the ritual
		FirstBulletSpreadDeg = 0.02, -- scoped; hipfire is intentionally terrible
		SprayErrorGrowthDeg = 0.0, -- bolt-action: no spray pattern
		MaxSprayErrorDeg = 0.0,
		BurstShots = 1,
		CrouchAffinity = 0.0, -- bolt-action: nothing to spray
		OptimalRangeStuds = 200, -- no realistic falloff on this map
		MaxEffectiveRangeStuds = 320,
		MinDamageMultiplier = 1.0,
		RangeSpreadPer10Studs = 0.0,
	},

	-- THE ARSENAL (v3) ------------------------------------------------------------

	-- BANDIT: the eco sprayer. Buys when the Falcon is out of reach. Fast
	-- hands, fast fire, big pattern — crouch and hose, then die past 60.
	BanditSMG = {
		Id = "BanditSMG",
		DisplayName = "Bandit SMG",
		Class = "SMG",
		Price = 1600,
		DamageBody = 22, -- 5 to the body
		Pellets = nil,
		HeadshotMultiplier = 2.5, -- 55: two taps up close
		FireInterval = 0.075, -- ~13 rounds/sec
		Magazine = 30,
		ReserveMags = 4,
		ReloadSeconds = 2.0,
		EquipSeconds = 0.8,
		FirstBulletSpreadDeg = 0.5,
		SprayErrorGrowthDeg = 0.35,
		MaxSprayErrorDeg = 6.5,
		BurstShots = 6,
		CrouchAffinity = 0.80, -- THE spray-croucher
		OptimalRangeStuds = 30,
		MaxEffectiveRangeStuds = 80,
		MinDamageMultiplier = 0.45,
		RangeSpreadPer10Studs = 0.5,
	},

	-- JUDGE: pellets, not a bullet. Eight rays per trigger pull inside one
	-- cone; each pellet is its own truth. Point-blank identity — and per the
	-- playtester's rule, no spray means NO crouch: the Judge never squats.
	JudgeSG = {
		Id = "JudgeSG",
		DisplayName = "Judge SG",
		Class = "Shotgun",
		Price = 1100,
		DamageBody = 12, -- PER PELLET: 96 point-blank, enough to fear
		Pellets = 8,
		HeadshotMultiplier = 1.5, -- pellet headshots sting but rarely delete
		FireInterval = 0.9, -- the pump
		Magazine = 5,
		ReserveMags = 4,
		ReloadSeconds = 3.0,
		EquipSeconds = 1.0,
		FirstBulletSpreadDeg = 4.0, -- the pellet cone, not inaccuracy
		SprayErrorGrowthDeg = 0.0, -- a pump gun has no pattern to walk
		MaxSprayErrorDeg = 4.0,
		BurstShots = 1,
		CrouchAffinity = 0.0, -- no spray → no crouch (the house rule)
		OptimalRangeStuds = 12,
		MaxEffectiveRangeStuds = 30,
		MinDamageMultiplier = 0.25,
		RangeSpreadPer10Studs = 0.8, -- the cone stops mattering fast
	},

	-- HAVOC: the anchor's LMG. A 60-round belt and the patience to use it.
	-- Slow to draw, slow to reload, impossible to run out mid-hold.
	HavocLMG = {
		Id = "HavocLMG",
		DisplayName = "Havoc LMG",
		Class = "Heavy",
		Price = 3200,
		DamageBody = 34,
		Pellets = nil,
		HeadshotMultiplier = 3.0,
		FireInterval = 0.13,
		Magazine = 60,
		ReserveMags = 2,
		ReloadSeconds = 4.0, -- the belt change is an event
		EquipSeconds = 1.4, -- heaviest draw in the arsenal
		FirstBulletSpreadDeg = 0.5,
		SprayErrorGrowthDeg = 0.30,
		MaxSprayErrorDeg = 5.0,
		BurstShots = 8,
		CrouchAffinity = 0.70, -- plant it and lean on the trigger
		OptimalRangeStuds = 60,
		MaxEffectiveRangeStuds = 120,
		MinDamageMultiplier = 0.70,
		RangeSpreadPer10Studs = 0.15,
	},

	-- THE KNIFE. Not a weapon yet — a movement tool. Equipping it is the
	-- sprint modifier; drawing a real gun back out costs THAT gun's
	-- EquipSeconds (Combat gates on the active weapon's draw time).
	Knife = {
		Id = "Knife",
		DisplayName = "Knife",
		Class = "Melee",
		Price = 0,
		DamageBody = 0,
		Pellets = nil,
		HeadshotMultiplier = 1.0,
		FireInterval = 0.5,
		Magazine = 0,
		ReserveMags = 0,
		ReloadSeconds = 0,
		EquipSeconds = 0.2, -- the knife snaps out — that's why you run with it
		FirstBulletSpreadDeg = 0.0,
		SprayErrorGrowthDeg = 0.0,
		MaxSprayErrorDeg = 0.0,
		BurstShots = 0,
		CrouchAffinity = 0.0,
		OptimalRangeStuds = 0,
		MaxEffectiveRangeStuds = 0,
		MinDamageMultiplier = 0.0,
		RangeSpreadPer10Studs = 0.0,
	},
}

return Weapons
