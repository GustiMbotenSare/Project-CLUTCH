--!strict
-- Greybox v2 — still data, still no Studio work. Now with actual tactics.
--
-- v1 → v2 (playtest feedback):
--   1. Verticality: heaven platforms + stairs on both sites, window ledge at mid
--   2. Angle isolation: elbow-bent lanes, doorway chokes, cover pockets
--   3. Ability economy: 14-wide lanes (one smoke chokes a door, not a site),
--      plant pads pulled off the walls, 4-tall lineup walls mixed with 12-tall
--   4. Mid control: A-short / B-short door connectors + window-ledge drop into B
--   5. Post-plant: pocket sites with two retake routes each (main + short/heaven)
--
-- Coordinates: y up. Attackers south (+z), defenders north (-z).
-- Site A west (-x), Site B east (+x).

export type PartSpec = {
	name: string,
	pos: Vector3,
	size: Vector3,
	color: Color3?,
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
local SITE_A = Color3.fromRGB(255, 170, 60) -- orange
local SITE_B = Color3.fromRGB(60, 200, 200) -- teal

local parts: { PartSpec } = {
	-- Floor (top surface y = 1)
	{ name = "Floor", pos = Vector3.new(0, 0, 0), size = Vector3.new(170, 2, 110), color = FLOOR },

	-- Boundary
	{ name = "WallN", pos = Vector3.new(0, 7, -55), size = Vector3.new(170, 12, 2), color = WALL },
	{ name = "WallS", pos = Vector3.new(0, 7, 55), size = Vector3.new(170, 12, 2), color = WALL },
	{ name = "WallW", pos = Vector3.new(-85, 7, 0), size = Vector3.new(2, 12, 110), color = WALL },
	{ name = "WallE", pos = Vector3.new(85, 7, 0), size = Vector3.new(2, 12, 110), color = WALL },

	-- A main lane (x -70..-56, 14 wide) + B main lane mirror
	{ name = "LaneWestOuter", pos = Vector3.new(-70, 7, 12), size = Vector3.new(2, 12, 64), color = WALL },
	{ name = "LaneWestPocket", pos = Vector3.new(-70, 7, -30), size = Vector3.new(2, 12, 20), color = WALL },
	{ name = "LaneEastOuter", pos = Vector3.new(70, 7, 12), size = Vector3.new(2, 12, 64), color = WALL },
	{ name = "LaneEastPocket", pos = Vector3.new(70, 7, -30), size = Vector3.new(2, 12, 20), color = WALL },
	{ name = "LaneAInner", pos = Vector3.new(-56, 7, 17.5), size = Vector3.new(2, 12, 45), color = WALL },
	{ name = "LaneBInner", pos = Vector3.new(56, 7, 17.5), size = Vector3.new(2, 12, 45), color = WALL },

	-- Elbow walls: lanes dead-end visually, path turns east into the site door
	{ name = "ElbowWallA", pos = Vector3.new(-63, 7, -20), size = Vector3.new(14, 12, 2), color = WALL },
	{ name = "ElbowWallB", pos = Vector3.new(63, 7, -20), size = Vector3.new(14, 12, 2), color = WALL },

	-- Site pocket north walls (defender side)
	{ name = "SiteNorthA", pos = Vector3.new(-50, 7, -40), size = Vector3.new(40, 12, 2), color = WALL },
	{ name = "SiteNorthB", pos = Vector3.new(50, 7, -40), size = Vector3.new(40, 12, 2), color = WALL },

	-- Site pocket south walls with ~10-wide main doors (A: x -55..-44, B: x 44..55)
	{ name = "SiteSouthA1", pos = Vector3.new(-62.5, 7, -16), size = Vector3.new(15, 12, 2), color = WALL },
	{ name = "SiteSouthA2", pos = Vector3.new(-37, 7, -16), size = Vector3.new(14, 12, 2), color = WALL },
	{ name = "SiteSouthB1", pos = Vector3.new(62.5, 7, -16), size = Vector3.new(15, 12, 2), color = WALL },
	{ name = "SiteSouthB2", pos = Vector3.new(37, 7, -16), size = Vector3.new(14, 12, 2), color = WALL },

	-- Pocket inner walls with 6-wide short doors (A: x=-30, B: x=30)
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

	-- Mid window wall (12-wide crossing)
	{ name = "MidWinL", pos = Vector3.new(-9.5, 7, -20), size = Vector3.new(7, 12, 2), color = WALL },
	{ name = "MidWinR", pos = Vector3.new(9.5, 7, -20), size = Vector3.new(7, 12, 2), color = WALL },

	-- Heaven A: platform + stairs + railing
	{ name = "HeavenPlatA", pos = Vector3.new(-62, 6.5, -34), size = Vector3.new(12, 1, 10), color = DECK },
	{ name = "HeavenRailA", pos = Vector3.new(-62, 8, -29), size = Vector3.new(12, 2, 1), color = DECK },
	{ name = "HeavenStairsA0", pos = Vector3.new(-64, 1.5, -27), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "HeavenStairsA1", pos = Vector3.new(-64, 2.5, -29), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "HeavenStairsA2", pos = Vector3.new(-64, 3.5, -31), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "HeavenStairsA3", pos = Vector3.new(-64, 4.5, -33), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "HeavenStairsA4", pos = Vector3.new(-64, 5.5, -35), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "HeavenStairsA5", pos = Vector3.new(-64, 6.5, -37), size = Vector3.new(4, 1, 2), color = DECK },

	-- Heaven B: mirror
	{ name = "HeavenPlatB", pos = Vector3.new(62, 6.5, -34), size = Vector3.new(12, 1, 10), color = DECK },
	{ name = "HeavenRailB", pos = Vector3.new(62, 8, -29), size = Vector3.new(12, 2, 1), color = DECK },
	{ name = "HeavenStairsB0", pos = Vector3.new(64, 1.5, -27), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "HeavenStairsB1", pos = Vector3.new(64, 2.5, -29), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "HeavenStairsB2", pos = Vector3.new(64, 3.5, -31), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "HeavenStairsB3", pos = Vector3.new(64, 4.5, -33), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "HeavenStairsB4", pos = Vector3.new(64, 5.5, -35), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "HeavenStairsB5", pos = Vector3.new(64, 6.5, -37), size = Vector3.new(4, 1, 2), color = DECK },

	-- Window ledge (mid → B): elevated platform, stairs from mid, drop into B short
	{ name = "LedgePlat", pos = Vector3.new(24, 6.5, -14), size = Vector3.new(8, 1, 12), color = DECK },
	{ name = "LedgeRail", pos = Vector3.new(24, 8, -19.5), size = Vector3.new(8, 2, 1), color = DECK },
	{ name = "LedgeStairs0", pos = Vector3.new(24, 1.5, -6), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "LedgeStairs1", pos = Vector3.new(24, 2.5, -8), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "LedgeStairs2", pos = Vector3.new(24, 3.5, -10), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "LedgeStairs3", pos = Vector3.new(24, 4.5, -12), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "LedgeStairs4", pos = Vector3.new(24, 5.5, -14), size = Vector3.new(4, 1, 2), color = DECK },
	{ name = "LedgeStairs5", pos = Vector3.new(24, 6.5, -16), size = Vector3.new(4, 1, 2), color = DECK },

	-- Default-plant cover (on the pads, off the walls)
	{ name = "CrateA1", pos = Vector3.new(-46, 3, -27), size = Vector3.new(4, 4, 4), color = CRATE },
	{ name = "CrateA2", pos = Vector3.new(-55, 3, -35), size = Vector3.new(4, 4, 4), color = CRATE },
	{ name = "CrateB1", pos = Vector3.new(46, 3, -27), size = Vector3.new(4, 4, 4), color = CRATE },
	{ name = "CrateB2", pos = Vector3.new(55, 3, -35), size = Vector3.new(4, 4, 4), color = CRATE },

	-- Mid + lane cover
	{ name = "MidBox", pos = Vector3.new(0, 3, 0), size = Vector3.new(8, 4, 4), color = CRATE },
	{ name = "LaneCoverA", pos = Vector3.new(-63, 3, 20), size = Vector3.new(6, 4, 2), color = CRATE },
	{ name = "LaneCoverB", pos = Vector3.new(63, 3, 20), size = Vector3.new(6, 4, 2), color = CRATE },

	-- 4-tall lineup walls (shoot over, can't walk through)
	{ name = "HalfCoverDefL", pos = Vector3.new(-10, 3, -47), size = Vector3.new(10, 4, 2), color = CRATE },
	{ name = "HalfCoverDefR", pos = Vector3.new(10, 3, -47), size = Vector3.new(10, 4, 2), color = CRATE },
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

	defenseSpawns = {
		Vector3.new(-8, 3, -48),
		Vector3.new(-4, 3, -48),
		Vector3.new(0, 3, -48),
		Vector3.new(4, 3, -48),
		Vector3.new(8, 3, -48),
	},

	-- Pads pulled off the walls: one molly denies a corner, not the whole site
	plantZones = {
		{ name = "SiteA", pos = Vector3.new(-50, 1.15, -30), size = Vector3.new(16, 0.3, 16), color = SITE_A },
		{ name = "SiteB", pos = Vector3.new(50, 1.15, -30), size = Vector3.new(16, 0.3, 16), color = SITE_B },
	},

	-- Named positions the patrol + future intent AI navigate between
	pois = {
		{ name = "SiteA", pos = Vector3.new(-50, 1, -30) },
		{ name = "HeavenA", pos = Vector3.new(-62, 7.5, -34) },
		{ name = "DoorA", pos = Vector3.new(-49.5, 1, -13) },
		{ name = "ShortA", pos = Vector3.new(-25, 1, -30) },
		{ name = "ElbowA", pos = Vector3.new(-63, 1, -8) },
		{ name = "LobbyA", pos = Vector3.new(-45, 1, -8) },
		{ name = "SiteB", pos = Vector3.new(50, 1, -30) },
		{ name = "HeavenB", pos = Vector3.new(62, 7.5, -34) },
		{ name = "DoorB", pos = Vector3.new(49.5, 1, -13) },
		{ name = "ShortB", pos = Vector3.new(25, 1, -30) },
		{ name = "ElbowB", pos = Vector3.new(63, 1, -8) },
		{ name = "LobbyB", pos = Vector3.new(45, 1, -8) },
		{ name = "MidBox", pos = Vector3.new(0, 1, 4) },
		{ name = "MidWindow", pos = Vector3.new(0, 1, -14) },
		{ name = "WindowLedge", pos = Vector3.new(24, 7.5, -14) },
		{ name = "AtkLobby", pos = Vector3.new(0, 1, 30) },
		{ name = "DefConnector", pos = Vector3.new(0, 1, -48) },
	},
}

return Greybox
