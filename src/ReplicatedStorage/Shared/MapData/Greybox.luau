--!strict
-- Greybox v2.1 — still data, still no Studio work.
--
-- v2 → v2.1 (playtest #2 — nothing climbed):
--   * Vertical access was broken by construction: staircases sat UNDER their
--     own platforms, leaving ~2 studs of headroom for a 5-stud humanoid.
--     Replaced with SOLID plinths (no ambiguous crawl space for the navmesh)
--     plus shallow ~16-degree ramps on a clear face. No jumping required.
--   * Mid ledge relocated to sit in line with the mid window crossing, so
--     holding height actually controls the mid duel.
--   * Defender half-cover moved off the spawn line — bots were spawning
--     inside it and the pathfinder tried to route over the top.
--   * Crates moved out of ramp footprints.
--
-- Coordinates: y up. Attackers south (+z), defenders north (-z).
-- Site A west (-x), Site B east (+x). Floor top y = 1.

export type PartSpec = {
	name: string,
	pos: Vector3,
	size: Vector3,
	color: Color3?,
	rot: Vector3?, -- optional Euler degrees (used by ramps)
}

export type PlantZone = {
	name: string,
	pos: Vector3,
	size: Vector3,
	color: Color3,
}

export type POI = {
	name: string,
	pos: Vector3,
}

export type MapSpec = {
	parts: { PartSpec },
	attackSpawns: { Vector3 },
	defenseSpawns: { Vector3 },
	plantZones: { PlantZone },
	pois: { POI },
}

local FLOOR = Color3.fromRGB(48, 48, 54)
local WALL = Color3.fromRGB(110, 110, 120)
local CRATE = Color3.fromRGB(150, 120, 80)
local DECK = Color3.fromRGB(90, 90, 100)
local RAMP = Color3.fromRGB(120, 120, 132)
local SITE_A = Color3.fromRGB(255, 170, 60) -- orange
local SITE_B = Color3.fromRGB(60, 200, 200) -- teal

-- Ramp geometry: rise 4 studs over 14 studs of run.
-- atan(4/14) = 15.95deg. Centre y 2.35 aligns the ramp's TOP face with the
-- floor at the low end and the plinth deck at the high end.
local RAMP_ANGLE = 15.95
local RAMP_Y = 2.35

local parts: { PartSpec } = {
	-- Floor
	{ name = "Floor", pos = Vector3.new(0, 0, 0), size = Vector3.new(170, 2, 110), color = FLOOR },

	-- Boundary
	{ name = "WallN", pos = Vector3.new(0, 7, -55), size = Vector3.new(170, 12, 2), color = WALL },
	{ name = "WallS", pos = Vector3.new(0, 7, 55), size = Vector3.new(170, 12, 2), color = WALL },
	{ name = "WallW", pos = Vector3.new(-85, 7, 0), size = Vector3.new(2, 12, 110), color = WALL },
	{ name = "WallE", pos = Vector3.new(85, 7, 0), size = Vector3.new(2, 12, 110), color = WALL },

	-- A / B main lanes (14 wide: one smoke chokes a door, never a whole site)
	{ name = "LaneWestOuter", pos = Vector3.new(-70, 7, 12), size = Vector3.new(2, 12, 64), color = WALL },
	{ name = "LaneWestPocket", pos = Vector3.new(-70, 7, -30), size = Vector3.new(2, 12, 20), color = WALL },
	{ name = "LaneEastOuter", pos = Vector3.new(70, 7, 12), size = Vector3.new(2, 12, 64), color = WALL },
	{ name = "LaneEastPocket", pos = Vector3.new(70, 7, -30), size = Vector3.new(2, 12, 20), color = WALL },
	{ name = "LaneAInner", pos = Vector3.new(-56, 7, 17.5), size = Vector3.new(2, 12, 45), color = WALL },
	{ name = "LaneBInner", pos = Vector3.new(56, 7, 17.5), size = Vector3.new(2, 12, 45), color = WALL },

	-- Elbows: you cannot see a site from the lane entrance
	{ name = "ElbowWallA", pos = Vector3.new(-63, 7, -20), size = Vector3.new(14, 12, 2), color = WALL },
	{ name = "ElbowWallB", pos = Vector3.new(63, 7, -20), size = Vector3.new(14, 12, 2), color = WALL },

	-- Site pocket north walls
	{ name = "SiteNorthA", pos = Vector3.new(-50, 7, -40), size = Vector3.new(40, 12, 2), color = WALL },
	{ name = "SiteNorthB", pos = Vector3.new(50, 7, -40), size = Vector3.new(40, 12, 2), color = WALL },

	-- Site pocket south walls, ~11-wide main doors (A: x -55..-44, B: 44..55)
	{ name = "SiteSouthA1", pos = Vector3.new(-62.5, 7, -16), size = Vector3.new(15, 12, 2), color = WALL },
	{ name = "SiteSouthA2", pos = Vector3.new(-37, 7, -16), size = Vector3.new(14, 12, 2), color = WALL },
	{ name = "SiteSouthB1", pos = Vector3.new(62.5, 7, -16), size = Vector3.new(15, 12, 2), color = WALL },
	{ name = "SiteSouthB2", pos = Vector3.new(37, 7, -16), size = Vector3.new(14, 12, 2), color = WALL },

	-- Pocket inner walls, 6-wide short doors (A: x -30, B: x 30)
	{ name = "PocketEastA1", pos = Vector3.new(-30, 7, -20.5), size = Vector3.new(2, 12, 9), color = WALL },
	{ name = "PocketEastA2", pos = Vector3.new(-30, 7, -35.5), size = Vector3.new(2, 12, 9), color = WALL },
	{ name = "PocketWestB1", pos = Vector3.new(30, 7, -20.5), size = Vector3.new(2, 12, 9), color = WALL },
	{ name = "PocketWestB2", pos = Vector3.new(30, 7, -35.5), size = Vector3.new(2, 12, 9), color = WALL },

	-- Mid dividers with 8-wide short-door gaps (z -34..-26)
	{ name = "DividerW1", pos = Vector3.new(-20, 7, -2.5), size = Vector3.new(2, 12, 35), color = WALL },
	{ name = "DividerW2", pos = Vector3.new(-20, 7, -23), size = Vector3.new(2, 12, 6), color = WALL },
	{ name = "DividerW3", pos = Vector3.new(-20, 7, -37), size = Vector3.new(2, 12, 6), color = WALL },
	{ name = "DividerE1", pos = Vector3.new(20, 7, -2.5), size = Vector3.new(2, 12, 35), color = WALL },
	{ name = "DividerE2", pos = Vector3.new(20, 7, -23), size = Vector3.new(2, 12, 6), color = WALL },
	{ name = "DividerE3", pos = Vector3.new(20, 7, -37), size = Vector3.new(2, 12, 6), color = WALL },

	-- Mid window wall (12-wide crossing at x -6..6)
	{ name = "MidWinL", pos = Vector3.new(-9.5, 7, -20), size = Vector3.new(7, 12, 2), color = WALL },
	{ name = "MidWinR", pos = Vector3.new(9.5, 7, -20), size = Vector3.new(7, 12, 2), color = WALL },

	-- HEAVEN A: solid plinth (deck y = 5) + ramp up its east face
	{ name = "HeavenPlinthA", pos = Vector3.new(-62, 3, -34), size = Vector3.new(12, 4, 10), color = DECK },
	{
		name = "HeavenRampA",
		pos = Vector3.new(-49, RAMP_Y, -34),
		size = Vector3.new(14, 1.5, 6),
		color = RAMP,
		rot = Vector3.new(0, 0, -RAMP_ANGLE),
	},
	{ name = "HeavenRailA", pos = Vector3.new(-62, 6, -38.5), size = Vector3.new(12, 2, 1), color = DECK },

	-- HEAVEN B: mirror
	{ name = "HeavenPlinthB", pos = Vector3.new(62, 3, -34), size = Vector3.new(12, 4, 10), color = DECK },
	{
		name = "HeavenRampB",
		pos = Vector3.new(49, RAMP_Y, -34),
		size = Vector3.new(14, 1.5, 6),
		color = RAMP,
		rot = Vector3.new(0, 0, RAMP_ANGLE),
	},
	{ name = "HeavenRailB", pos = Vector3.new(62, 6, -38.5), size = Vector3.new(12, 2, 1), color = DECK },

	-- MID LEDGE: solid plinth in line with the window crossing + ramp from
	-- the attacker side. Holding this height controls the mid duel.
	{ name = "MidLedgePlinth", pos = Vector3.new(0, 3, -12), size = Vector3.new(12, 4, 8), color = DECK },
	{
		name = "MidLedgeRamp",
		pos = Vector3.new(0, RAMP_Y, -1),
		size = Vector3.new(6, 1.5, 14),
		color = RAMP,
		rot = Vector3.new(RAMP_ANGLE, 0, 0),
	},

	-- Default-plant cover (on the pads, off the walls, clear of ramps)
	{ name = "CrateA1", pos = Vector3.new(-46, 3, -27), size = Vector3.new(4, 4, 4), color = CRATE },
	{ name = "CrateA2", pos = Vector3.new(-62, 3, -24), size = Vector3.new(4, 4, 4), color = CRATE },
	{ name = "CrateB1", pos = Vector3.new(46, 3, -27), size = Vector3.new(4, 4, 4), color = CRATE },
	{ name = "CrateB2", pos = Vector3.new(62, 3, -24), size = Vector3.new(4, 4, 4), color = CRATE },

	-- Mid + lane cover
	{ name = "MidBox", pos = Vector3.new(0, 3, 14), size = Vector3.new(8, 4, 4), color = CRATE },
	{ name = "LaneCoverA", pos = Vector3.new(-63, 3, 20), size = Vector3.new(6, 4, 2), color = CRATE },
	{ name = "LaneCoverB", pos = Vector3.new(63, 3, 20), size = Vector3.new(6, 4, 2), color = CRATE },

	-- 4-tall lineup walls (shoot over, walk around). Kept well clear of spawns.
	{ name = "HalfCoverDefL", pos = Vector3.new(-10, 3, -44), size = Vector3.new(10, 4, 2), color = CRATE },
	{ name = "HalfCoverDefR", pos = Vector3.new(10, 3, -44), size = Vector3.new(10, 4, 2), color = CRATE },
	{ name = "HalfCoverAtkL", pos = Vector3.new(-30, 3, 25), size = Vector3.new(10, 4, 2), color = CRATE },
	{ name = "HalfCoverAtkR", pos = Vector3.new(30, 3, 25), size = Vector3.new(10, 4, 2), color = CRATE },
}

local Greybox: MapSpec = {
	parts = parts,

	attackSpawns = {
		Vector3.new(-8, 3, 44),
		Vector3.new(-4, 3, 44),
		Vector3.new(0, 3, 44),
		Vector3.new(4, 3, 44),
		Vector3.new(8, 3, 44),
	},

	-- Pulled back to z -49: v2 spawns sat inside the defender half-cover
	defenseSpawns = {
		Vector3.new(-8, 3, -49),
		Vector3.new(-4, 3, -49),
		Vector3.new(0, 3, -49),
		Vector3.new(4, 3, -49),
		Vector3.new(8, 3, -49),
	},

	plantZones = {
		{ name = "SiteA", pos = Vector3.new(-50, 1.15, -30), size = Vector3.new(16, 0.3, 16), color = SITE_A },
		{ name = "SiteB", pos = Vector3.new(50, 1.15, -30), size = Vector3.new(16, 0.3, 16), color = SITE_B },
	},

	-- Named positions the patrol + future intent AI navigate between.
	-- Plinth POIs sit on the deck surface (y 5.5) so paths resolve on top.
	pois = {
		{ name = "SiteA", pos = Vector3.new(-50, 1, -30) },
		{ name = "HeavenA", pos = Vector3.new(-62, 5.5, -34) },
		{ name = "RampA", pos = Vector3.new(-44, 1, -34) },
		{ name = "DoorA", pos = Vector3.new(-49.5, 1, -13) },
		{ name = "ShortA", pos = Vector3.new(-25, 1, -30) },
		{ name = "ElbowA", pos = Vector3.new(-63, 1, -8) },
		{ name = "LobbyA", pos = Vector3.new(-45, 1, -8) },
		{ name = "SiteB", pos = Vector3.new(50, 1, -30) },
		{ name = "HeavenB", pos = Vector3.new(62, 5.5, -34) },
		{ name = "RampB", pos = Vector3.new(44, 1, -34) },
		{ name = "DoorB", pos = Vector3.new(49.5, 1, -13) },
		{ name = "ShortB", pos = Vector3.new(25, 1, -30) },
		{ name = "ElbowB", pos = Vector3.new(63, 1, -8) },
		{ name = "LobbyB", pos = Vector3.new(45, 1, -8) },
		{ name = "MidLedge", pos = Vector3.new(0, 5.5, -12) },
		{ name = "MidWindow", pos = Vector3.new(0, 1, -25) },
		{ name = "MidBox", pos = Vector3.new(0, 1, 18) },
		{ name = "AtkLobby", pos = Vector3.new(0, 1, 32) },
		{ name = "DefLobby", pos = Vector3.new(0, 1, -46) },
	},
}

return Greybox
