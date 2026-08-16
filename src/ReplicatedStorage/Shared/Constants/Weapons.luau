--!strict
-- Weapon definitions. M0 ships a pistol, a rifle and a sniper.
-- Fictional names — Valorant-flavored balance, IP-safe.
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
-- v2 (playtest #19): the loadout layer deepens —
--   * AMMO IS REAL: Magazine already existed; ReserveMags joins it, and the
--     brain now owns reload-vs-switch decisions.
--   * CROUCH AFFINITY: how much a weapon wants to be sprayed from a crouch.
--   * THE KNIFE: equipping it is the sprint modifier. No melee combat yet.
--
-- v2.1 (playtest #20): DRAW TIMES PER WEAPON, the way tac shooters price
-- them — the knife snaps out (0.2s), the pistol is quick (0.5s), the rifle
-- is a commitment (1.0s), the sniper is a ritual (1.25s). The price of a
-- switch is what makes switch-vs-reload a real decision instead of a reflex.

export type WeaponClass = "Pistol" | "Rifle" | "Sniper" | "Melee"

export type WeaponDef = {
	Id: string,
	DisplayName: string,
	Class: WeaponClass,
	Price: number,
	DamageBody: number,
	HeadshotMultiplier: number,
	FireInterval: number, -- seconds between shots
	Magazine: number,
	ReserveMags: number, -- how many magazines beyond the loaded one
	ReloadSeconds: number,
	EquipSeconds: number, -- the DRAW time when switching TO this weapon
	FirstBulletSpreadDeg: number, -- standing, unscoped where applicable
	SprayErrorGrowthDeg: number, -- added spread per consecutive shot
	MaxSprayErrorDeg: number,
	BurstShots: number, -- how many rounds a bot commits per trigger pull
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
		MinDamageMultiplier = 0.55, -- 14 damage per body shot at the far edge
		RangeSpreadPer10Studs = 0.35,
	},

	-- The workhorse. Most rounds are won or lost on Falcon fights.
	FalconAR = {
		Id = "FalconAR",
		DisplayName = "Falcon AR",
		Class = "Rifle",
		Price = 2900,
		DamageBody = 40,
		HeadshotMultiplier = 4.0, -- 160 to the head: one-tap fantasy lives here
		FireInterval = 0.1, -- ~10 rounds/sec full auto
		Magazine = 25,
		ReserveMags = 3,
		ReloadSeconds = 2.5,
		EquipSeconds = 1.0, -- a full second: switching TO the rifle is a commitment
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

	-- THE KNIFE. Not a weapon yet — a movement tool. Equipping it is the
	-- sprint modifier; drawing a real gun back out costs THAT gun's
	-- EquipSeconds (Combat gates on the active weapon's draw time).
	Knife = {
		Id = "Knife",
		DisplayName = "Knife",
		Class = "Melee",
		Price = 0,
		DamageBody = 0,
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
