--!strict
-- Greybox v4.1 — the de-labyrinthed 5v5 map + spawn sight seals.
--
-- v4 → v4.1 (playtest #14):
--   * DEFENDER SPAWN SCREENS (z=-58). The site→lobby back route left a clean
--     sightline from A Site INTO the defender spawn — Echo killed Jinx there
--     at 52 studs while she was still deploying. Screens span the spawn face
--     with one mid gap (x -25..25); defenders exit around it.
--
-- v3.1 → v4 (playtest #13 — the "claustrophobic rat maze" review):
--   * Trench lanes removed — open boulevards with cover islands.
--   * Sites opened up — 20-wide main doors, no bunker clutter, and heavens
--     are real overlook decks (rail over the door + plant zone).
--   * Shorts connect straight into Mid via single divider gaps.
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

export type CoverPoint = {
	name: string,
	pos: Vector3, -- standing spot, on the PROTECTED side
	face: Vector3, -- unit-ish direction the angle watches
	kind: "partial" | "full",
	zone: string,
}

export type MapSpec = {
	parts: { PartSpec },
	attackSpawns: { Vector3 },
	defenseSpawns: { Vector3 },
	plantZones: { PlantZone },
	pois: { POI },
	coverPoints: { CoverPoint },
}

local FLOOR = Color3.fromRGB(48, 48, 54)
local WALL = Color3.fromRGB(110, 110, 120)
local CRATE = Color3.fromRGB(150, 120, 80)
local DECK = Color3.fromRGB(90, 90, 100)
local RAMP = Color3.fromRGB(120, 120, 132)
local SITE_A = Color3.fromRGB(255, 170, 60)
local SITE_B = Color3.fromRGB(60, 200, 200)
local COVER_FULL = Color3.fromRGB(70, 78, 92)

local RAMP_ANGLE = 15.95
local RAMP_Y = 2.35
local PARTIAL = 4.5 -- chest-high to a 5-stud rig

local parts: { PartSpec } = {
	-- Floor
	{ name = "Floor", pos = Vector3.new(0, 0, 0), size = Vector3.new(230, 2, 150), color = FLOOR },

	-- Boundary
	{ name = "WallN", pos = Vector3.new(0, 7, -75), size = Vector3.new(230, 12, 2), color = WALL },
	{ name = "WallS", pos = Vector3.new(0, 7, 75), size = Vector3.new(230, 12, 2), color = WALL },
	{ name = "WallW", pos = Vector3.new(-115, 7, 0), size = Vector3.new(2, 12, 150), color = WALL },
	{ name = "WallE", pos = Vector3.new(115, 7, 0), size = Vector3.new(2, 12, 150), color = WALL },

	-- SPAWN SCREEN SOUTH (z=32). Gaps: lane mouths (open boulevards now),
	-- lobby mouths (x -60..-46, 46..60), mid (x -16..16).
	{ name = "ScrS1", pos = Vector3.new(-65, 7, 32), size = Vector3.new(10, 12, 2), color = WALL },
	{ name = "ScrS2", pos = Vector3.new(-31, 7, 32), size = Vector3.new(30, 12, 2), color = WALL },
	{ name = "ScrS3", pos = Vector3.new(31, 7, 32), size = Vector3.new(30, 12, 2), color = WALL },
	{ name = "ScrS4", pos = Vector3.new(65, 7, 32), size = Vector3.new(10, 12, 2), color = WALL },

	-- SPAWN SCREEN NORTH (z=-46): seals Mid Back's north face only; the sites'
	-- defender entrances stay open.
	{ name = "ScrN1", pos = Vector3.new(-32, 7, -46), size = Vector3.new(32, 12, 2), color = WALL },
	{ name = "ScrN2", pos = Vector3.new(32, 7, -46), size = Vector3.new(32, 12, 2), color = WALL },

	-- DEFENDER SPAWN SCREENS (z=-58): the back route left spawn visible from
	-- the sites (playtest #14: Echo killed Jinx in spawn from A Site at 52
	-- studs). One mid gap (x -25..25); defenders deploy around it.
	{ name = "DefScreenL", pos = Vector3.new(-70, 7, -58), size = Vector3.new(90, 12, 2), color = WALL },
	{ name = "DefScreenR", pos = Vector3.new(70, 7, -58), size = Vector3.new(90, 12, 2), color = WALL },

	-- A LANE: no inner wall. The outer wall + two cover islands make the
	-- space, not a corridor. Full block mid-lane is the S-bend anchor.
	{ name = "LaneWestOuter", pos = Vector3.new(-105, 7, 17.5), size = Vector3.new(2, 12, 79), color = WALL },
	{ name = "ALaneFull", pos = Vector3.new(-88, 7, 8), size = Vector3.new(8, 12, 8), color = COVER_FULL },
	{ name = "ALaneHalf", pos = Vector3.new(-88, 3.25, 30), size = Vector3.new(6, PARTIAL, 3), color = CRATE },

	-- B LANE (mirror)
	{ name = "LaneEastOuter", pos = Vector3.new(105, 7, 17.5), size = Vector3.new(2, 12, 79), color = WALL },
	{ name = "BLaneFull", pos = Vector3.new(88, 7, 8), size = Vector3.new(8, 12, 8), color = COVER_FULL },
	{ name = "BLaneHalf", pos = Vector3.new(88, 3.25, 30), size = Vector3.new(6, PARTIAL, 3), color = CRATE },

	-- A SITE (x -95..-45, z -52..-20). 20-wide main door (x -75..-55) on the
	-- south face; west wall; pocket wall (x=-45) with an 8-wide short door
	-- (z -38..-30); heaven deck + ramp on the north edge; defender entrance
	-- between the ramp and the pocket wall.
	{ name = "SiteSouthA1", pos = Vector3.new(-85, 7, -20), size = Vector3.new(20, 12, 2), color = WALL },
	{ name = "SiteSouthA2", pos = Vector3.new(-50, 7, -20), size = Vector3.new(10, 12, 2), color = WALL },
	{ name = "SiteWestA", pos = Vector3.new(-95, 7, -36), size = Vector3.new(2, 12, 32), color = WALL },
	{ name = "PocketEastA1", pos = Vector3.new(-45, 7, -25), size = Vector3.new(2, 12, 10), color = WALL },
	{ name = "PocketEastA2", pos = Vector3.new(-45, 7, -45), size = Vector3.new(2, 12, 14), color = WALL },
	{ name = "ShortCapA", pos = Vector3.new(-35.5, 7, -46), size = Vector3.new(19, 12, 2), color = WALL },
	-- Heaven overlook: long deck (top y=5) + ramp up its east face + rail
	{ name = "HeavenPlinthA", pos = Vector3.new(-80, 3, -47), size = Vector3.new(22, 4, 10), color = DECK },
	{
		name = "HeavenRampA",
		pos = Vector3.new(-62, RAMP_Y, -47),
		size = Vector3.new(14, 1.5, 6),
		color = RAMP,
		rot = Vector3.new(0, 0, -RAMP_ANGLE),
	},
	{ name = "HeavenRailA", pos = Vector3.new(-80, 6, -42.5), size = Vector3.new(22, 2, 1), color = DECK },
	-- Site cover: default crate near the plant, mid crate on the approach
	{ name = "ADefaultCrate", pos = Vector3.new(-66, 3.25, -36), size = Vector3.new(6, PARTIAL, 6), color = CRATE },
	{ name = "AMidCrate", pos = Vector3.new(-60, 3.25, -26), size = Vector3.new(5, PARTIAL, 4), color = CRATE },
	{ name = "AShortCrate", pos = Vector3.new(-36, 3.25, -40), size = Vector3.new(6, PARTIAL, 4), color = CRATE },

	-- B SITE (mirror)
	{ name = "SiteSouthB1", pos = Vector3.new(85, 7, -20), size = Vector3.new(20, 12, 2), color = WALL },
	{ name = "SiteSouthB2", pos = Vector3.new(50, 7, -20), size = Vector3.new(10, 12, 2), color = WALL },
	{ name = "SiteEastB", pos = Vector3.new(95, 7, -36), size = Vector3.new(2, 12, 32), color = WALL },
	{ name = "PocketWestB1", pos = Vector3.new(45, 7, -25), size = Vector3.new(2, 12, 10), color = WALL },
	{ name = "PocketWestB2", pos = Vector3.new(45, 7, -45), size = Vector3.new(2, 12, 14), color = WALL },
	{ name = "ShortCapB", pos = Vector3.new(35.5, 7, -46), size = Vector3.new(19, 12, 2), color = WALL },
	{ name = "HeavenPlinthB", pos = Vector3.new(80, 3, -47), size = Vector3.new(22, 4, 10), color = DECK },
	{
		name = "HeavenRampB",
		pos = Vector3.new(62, RAMP_Y, -47),
		size = Vector3.new(14, 1.5, 6),
		color = RAMP,
		rot = Vector3.new(0, 0, RAMP_ANGLE),
	},
	{ name = "HeavenRailB", pos = Vector3.new(80, 6, -42.5), size = Vector3.new(22, 2, 1), color = DECK },
	{ name = "BDefaultCrate", pos = Vector3.new(66, 3.25, -36), size = Vector3.new(6, PARTIAL, 6), color = CRATE },
	{ name = "BMidCrate", pos = Vector3.new(60, 3.25, -26), size = Vector3.new(5, PARTIAL, 4), color = CRATE },
	{ name = "BShortCrate", pos = Vector3.new(36, 3.25, -40), size = Vector3.new(6, PARTIAL, 4), color = CRATE },

	-- MID. Dividers at x ±26 with one clean 8-wide gap (z -30..-22) into each
	-- short — mid control converts to a split without a maze. Window wall at
	-- z=-32 with the 16-wide crossing (x -8..8) watched by the ledge.
	{ name = "DividerW1", pos = Vector3.new(-26, 7, -1), size = Vector3.new(2, 12, 42), color = WALL },
	{ name = "DividerW2", pos = Vector3.new(-26, 7, -36), size = Vector3.new(2, 12, 12), color = WALL },
	{ name = "DividerW3", pos = Vector3.new(-26, 7, -47), size = Vector3.new(2, 12, 10), color = WALL },
	{ name = "DividerE1", pos = Vector3.new(26, 7, -1), size = Vector3.new(2, 12, 42), color = WALL },
	{ name = "DividerE2", pos = Vector3.new(26, 7, -36), size = Vector3.new(2, 12, 12), color = WALL },
	{ name = "DividerE3", pos = Vector3.new(26, 7, -47), size = Vector3.new(2, 12, 10), color = WALL },
	{ name = "MidWinL", pos = Vector3.new(-16, 7, -32), size = Vector3.new(16, 12, 2), color = WALL },
	{ name = "MidWinR", pos = Vector3.new(16, 7, -32), size = Vector3.new(16, 12, 2), color = WALL },

	-- MID LEDGE: plinth + ramp from the attacker side + rail to head-glitch
	{ name = "MidLedgePlinth", pos = Vector3.new(0, 3, -17), size = Vector3.new(12, 4, 8), color = DECK },
	{
		name = "MidLedgeRamp",
		pos = Vector3.new(0, RAMP_Y, -6),
		size = Vector3.new(6, 1.5, 14),
		color = RAMP,
		rot = Vector3.new(RAMP_ANGLE, 0, 0),
	},
	{ name = "MidLedgeRail", pos = Vector3.new(0, 6, -20.5), size = Vector3.new(12, 2, 1), color = DECK },

	-- MID PILLAR (full cover centerpiece) + partials
	{ name = "MidPillar", pos = Vector3.new(0, 7, 4), size = Vector3.new(6, 12, 6), color = COVER_FULL },
	{ name = "MidBoxW", pos = Vector3.new(-14, 3.25, 8), size = Vector3.new(6, PARTIAL, 4), color = CRATE },
	{ name = "MidBoxE", pos = Vector3.new(14, 3.25, 8), size = Vector3.new(6, PARTIAL, 4), color = CRATE },

	-- Lobby cover (partial; shoot over, walk around)
	{ name = "HalfCoverDefL", pos = Vector3.new(-12, 3.25, -52), size = Vector3.new(10, PARTIAL, 2), color = CRATE },
	{ name = "HalfCoverDefR", pos = Vector3.new(12, 3.25, -52), size = Vector3.new(10, PARTIAL, 2), color = CRATE },
	{ name = "HalfCoverAtkL", pos = Vector3.new(-34, 3.25, 40), size = Vector3.new(10, PARTIAL, 2), color = CRATE },
	{ name = "HalfCoverAtkR", pos = Vector3.new(34, 3.25, 40), size = Vector3.new(10, PARTIAL, 2), color = CRATE },
}

local Greybox: MapSpec = {
	parts = parts,

	attackSpawns = {
		Vector3.new(24, 3, 64),
		Vector3.new(28, 3, 64),
		Vector3.new(32, 3, 64),
		Vector3.new(36, 3, 64),
		Vector3.new(40, 3, 64),
	},
	defenseSpawns = {
		Vector3.new(-40, 3, -64),
		Vector3.new(-36, 3, -64),
		Vector3.new(-32, 3, -64),
		Vector3.new(-28, 3, -64),
		Vector3.new(-24, 3, -64),
	},

	plantZones = {
		{ name = "SiteA", pos = Vector3.new(-68, 1.15, -36), size = Vector3.new(18, 0.3, 18), color = SITE_A },
		{ name = "SiteB", pos = Vector3.new(68, 1.15, -36), size = Vector3.new(18, 0.3, 18), color = SITE_B },
	},

	pois = {
		{ name = "SiteA", pos = Vector3.new(-68, 1, -36) },
		{ name = "HeavenA", pos = Vector3.new(-80, 5.5, -47) },
		{ name = "RampA", pos = Vector3.new(-62, 1, -47) },
		{ name = "DoorA", pos = Vector3.new(-65, 1, -18) },
		{ name = "ShortA", pos = Vector3.new(-36, 1, -36) },
		{ name = "ElbowA", pos = Vector3.new(-88, 1, -12) },
		{ name = "LobbyA", pos = Vector3.new(-50, 1, 4) },
		{ name = "SiteB", pos = Vector3.new(68, 1, -36) },
		{ name = "HeavenB", pos = Vector3.new(80, 5.5, -47) },
		{ name = "RampB", pos = Vector3.new(62, 1, -47) },
		{ name = "DoorB", pos = Vector3.new(65, 1, -18) },
		{ name = "ShortB", pos = Vector3.new(36, 1, -36) },
		{ name = "ElbowB", pos = Vector3.new(88, 1, -12) },
		{ name = "LobbyB", pos = Vector3.new(50, 1, 4) },
		{ name = "MidLedge", pos = Vector3.new(0, 5.5, -17) },
		{ name = "MidWindow", pos = Vector3.new(0, 1, -32) },
		{ name = "MidPillar", pos = Vector3.new(0, 1, 4) },
		{ name = "AtkLobby", pos = Vector3.new(0, 1, 44) },
		{ name = "DefLobby", pos = Vector3.new(0, 1, -52) },
	},

	-- Where bots stand to HOLD ANGLES. pos = protected side; face = watch
	-- direction (attackers post-plant flip it). partial = shoot over / jiggle
	-- peek; full = break LOS, peek around the edge.
	coverPoints = {
		-- A Site: default crate and mid crate watch the door; heaven rail
		-- overlooks everything; short watch faces the mid gap.
		{ name = "A_Default", pos = Vector3.new(-66, 1, -40.5), face = Vector3.new(0.1, 0, 0.99), kind = "partial", zone = "A_SITE" },
		{ name = "A_MidCrate", pos = Vector3.new(-60, 1, -30), face = Vector3.new(0.1, 0, 0.99), kind = "partial", zone = "A_SITE" },
		{ name = "A_HeavenRail", pos = Vector3.new(-80, 5.5, -43.5), face = Vector3.new(0.15, 0, 0.99), kind = "partial", zone = "A_HEAVEN" },
		{ name = "A_ShortWatch", pos = Vector3.new(-36, 1, -43), face = Vector3.new(1, 0, 0.25), kind = "partial", zone = "A_SHORT" },
		-- B Site (mirror)
		{ name = "B_Default", pos = Vector3.new(66, 1, -40.5), face = Vector3.new(-0.1, 0, 0.99), kind = "partial", zone = "B_SITE" },
		{ name = "B_MidCrate", pos = Vector3.new(60, 1, -30), face = Vector3.new(-0.1, 0, 0.99), kind = "partial", zone = "B_SITE" },
		{ name = "B_HeavenRail", pos = Vector3.new(80, 5.5, -43.5), face = Vector3.new(-0.15, 0, 0.99), kind = "partial", zone = "B_HEAVEN" },
		{ name = "B_ShortWatch", pos = Vector3.new(36, 1, -43), face = Vector3.new(-1, 0, 0.25), kind = "partial", zone = "B_SHORT" },
		-- Mid
		{ name = "Mid_PillarAtk", pos = Vector3.new(0, 1, 9), face = Vector3.new(0, 0, -1), kind = "full", zone = "MID" },
		{ name = "Mid_PillarDef", pos = Vector3.new(0, 1, -1), face = Vector3.new(0, 0, 1), kind = "full", zone = "MID" },
		{ name = "MidLedgeRail", pos = Vector3.new(0, 5.5, -18), face = Vector3.new(0, 0, -1), kind = "partial", zone = "MID_LEDGE" },
		-- Lane holds (defenders watch the lane mouths, south)
		{ name = "A_LaneFull", pos = Vector3.new(-88, 1, 1), face = Vector3.new(0, 0, 1), kind = "full", zone = "A_ELBOW" },
		{ name = "A_LaneHalf", pos = Vector3.new(-88, 1, 34), face = Vector3.new(0, 0, 1), kind = "partial", zone = "A_MAIN" },
		{ name = "B_LaneFull", pos = Vector3.new(88, 1, 1), face = Vector3.new(0, 0, 1), kind = "full", zone = "B_ELBOW" },
		{ name = "B_LaneHalf", pos = Vector3.new(88, 1, 34), face = Vector3.new(0, 0, 1), kind = "partial", zone = "B_MAIN" },
	},
}

return Greybox
