--!strict
-- Weapon definitions. M0 ships with one rifle + one sniper (GDD M0 acceptance #3).
-- Fictional names — Valorant-flavored balance, IP-safe.

export type WeaponClass = "Rifle" | "Sniper"

export type WeaponDef = {
	Id: string,
	DisplayName: string,
	Class: WeaponClass,
	Price: number,
	DamageBody: number,
	HeadshotMultiplier: number,
	FireInterval: number, -- seconds between shots
	Magazine: number,
	ReloadSeconds: number,
	EquipSeconds: number,
	FirstBulletSpreadDeg: number, -- standing, unscoped where applicable
	SprayErrorGrowthDeg: number, -- added spread per consecutive shot
	MaxSprayErrorDeg: number,
}

local Weapons: { [string]: WeaponDef } = {
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
		ReloadSeconds = 2.5,
		EquipSeconds = 1.0,
		FirstBulletSpreadDeg = 0.2,
		SprayErrorGrowthDeg = 0.25,
		MaxSprayErrorDeg = 4.0,
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
		ReloadSeconds = 3.7,
		EquipSeconds = 1.25,
		FirstBulletSpreadDeg = 0.02, -- scoped; hipfire is intentionally terrible
		SprayErrorGrowthDeg = 0.0, -- bolt-action: no spray pattern
		MaxSprayErrorDeg = 0.0,
	},
}

return Weapons
