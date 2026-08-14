--!strict
-- Greybox v3 — the 5v5 map. Still data, still no Studio work.
--
-- v2.4 → v3 (playtest #10 was clean; time to scale):
--   * Canvas grows 170×110 → 230×150. Lanes widen 12 → 22, sites grow into
--     proper pockets, and both lobbies breathe. Ten bots need room to not
--     body-block each other at chokes (the ElbowB problem).
--   * REAL COVER, in two flavors, sized against a 5-stud rig:
--       partial (4.5 tall — shoot over it, head-glitch behind it)
--       full    (12 tall — breaks line of sight outright)
--     Every site, both lanes, the shorts and mid get deliberate pieces.
--   * COVER POINTS: the map now declares where a bot should STAND to use each
--     piece and which way to FACE. The brain holds these as angles and
--     jiggle-peeks the partials — peeking and angle holding, as requested.
--   * DEFENDER BACK ROUTE: sites are open to the Defender Lobby on their
--     north edge. Defenders finally arrive before attackers (the route audit
--     has said 4/4 since v2 — real tac shooters are defender-sided on
--     rotation timing). The shorts are capped so attackers can't free-flank
--     into the defender lobby in exchange.
--   * Spawn screens segment: gaps at mid, both lobby mouths, and both lane
--     mouths — v2's single mid gap silently walled off the lane↔lobby
--     crossings and bots detoured through mid without knowing why.
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

-- Where a bot stands to use a piece of cover, which way it watches, and
-- whether it can shoot over it (partial) or has to peek around (full).
export type CoverPoint = {
	name: string,
	pos: Vector3, -- standing spot, on the PROTECTED side
	face: Vector3, -- unit-ish direction the angle watches
	kind: "partial" | "full",
	zone: string, -- zone key this point belongs to
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
local SITE_A = Color3.fromRGB(255, 170, 60) -- orange
local SITE_B = Color3.fromRGB(60, 200, 200) -- teal
local COVER_FULL = Color3.fromRGB(70, 78, 92) -- reads as structure

-- Ramp geometry: rise 4 studs over 14 studs of run.
local RAMP_ANGLE = 15.95
local RAMP_Y = 2.35

local PARTIAL = 4.5 -- chest-high to a 5-stud rig: shoot over, head-glitch behind

local parts: { PartSpec } = {
	-- Floor
	{ name = "Floor", pos = Vector3.new(0, 0, 0), size = Vector3.new(230, 2, 150), color = FLOOR },

	-- Boundary
	{ name = "WallN", pos = Vector3.new(0, 7, -75), size = Vector3.new(230, 12, 2), color = WALL },
	{ name = "WallS", pos = Vector3.new(0, 7, 75), size = Vector3.new(230, 12, 2), color = WALL },
	{ name = "WallW", pos = Vector3.new(-115, 7, 0), size = Vector3.new(2, 12, 150), color = WALL },
	{ name = "WallE", pos = Vector3.new(115, 7, 0), size = Vector3.new(2, 12, 150), color = WALL },

	-- SPAWN SCREEN SOUTH (z=28). Segmented: gaps at the lane mouths
	-- (x -95..-72, 72..95), the lobby mouths (x -60..-46, 46..60) and mid
	-- (x -16..16). v2's single-gap screen silently walled the lane crossings.
	{ name = "ScrS1", pos = Vector3.new(-105, 7, 28), size = Vector3.new(20, 12, 2), color = WALL },
	{ name = "ScrS2", pos = Vector3.new(-66, 7, 28), size = Vector3.new(12, 12, 2), color = WALL },
	{ name = "ScrS3", pos = Vector3.new(-31, 7, 28), size = Vector3.new(30, 12, 2), color = WALL },
	{ name = "ScrS4", pos = Vector3.new(31, 7, 28), size = Vector3.new(30, 12, 2), color = WALL },
	{ name = "ScrS5", pos = Vector3.new(66, 7, 28), size = Vector3.new(12, 12, 2), color = WALL },
	{ name = "ScrS6", pos = Vector3.new(105, 7, 28), size = Vector3.new(20, 12, 2), color = WALL },

	-- SPAWN SCREEN NORTH (z=-45). Only seals Mid Back's north face; the sites
	-- stay open to the defender lobby (that's the back route).
	{ name = "ScrN1", pos = Vector3.new(-32, 7, -45), size = Vector3.new(32, 12, 2), color = WALL },
	{ name = "ScrN2", pos = Vector3.new(32, 7, -45), size = Vector3.new(32, 12, 2), color = WALL },

	-- A LANE (corridor x -94..-72, 22 wide): outer wall continuous, inner wall
	-- stops at z=6 so the lane turns east into A Lobby. A full block sits in
	-- the turn — the elbow info game — and a partial mid-lane.
	{ name = "LaneWestOuter", pos = Vector3.new(-95, 7, 15.5), size = Vector3.new(2, 12, 83), color = WALL },
	{ name = "LaneWestPocket", pos = Vector3.new(-95, 7, -38), size = Vector3.new(2, 12, 24), color = WALL },
	{ name = "LaneAInner", pos = Vector3.new(-72, 7, 31.5), size = Vector3.new(2, 12, 51), color = WALL },
	{ name = "ALaneFull", pos = Vector3.new(-80, 7, -10), size = Vector3.new(6, 12, 6), color = COVER_FULL },
	{ name = "ALaneHalf", pos = Vector3.new(-83, 3.25, 20), size = Vector3.new(6, PARTIAL, 3), color = CRATE },

	-- B LANE (mirror)
	{ name = "LaneEastOuter", pos = Vector3.new(95, 7, 15.5), size = Vector3.new(2, 12, 83), color = WALL },
	{ name = "LaneEastPocket", pos = Vector3.new(95, 7, -38), size = Vector3.new(2, 12, 24), color = WALL },
	{ name = "LaneBInner", pos = Vector3.new(72, 7, 31.5), size = Vector3.new(2, 12, 51), color = WALL },
	{ name = "BLaneFull", pos = Vector3.new(80, 7, -10), size = Vector3.new(6, 12, 6), color = COVER_FULL },
	{ name = "BLaneHalf", pos = Vector3.new(83, 3.25, 20), size = Vector3.new(6, PARTIAL, 3), color = CRATE },

	-- A SITE (x -95..-48, z -50..-22). South face has the 12-wide main door
	-- (x -66..-54). NO north wall — the site opens to the defender lobby.
	{ name = "SiteSouthA1", pos = Vector3.new(-80.5, 7, -22), size = Vector3.new(29, 12, 2), color = WALL },
	{ name = "SiteSouthA2", pos = Vector3.new(-51, 7, -22), size = Vector3.new(6, 12, 2), color = WALL },
	-- Pocket wall (x=-48) with an 8-wide short door (z -44..-36)
	{ name = "PocketEastA1", pos = Vector3.new(-48, 7, -29), size = Vector3.new(2, 12, 14), color = WALL },
	{ name = "PocketEastA2", pos = Vector3.new(-48, 7, -47), size = Vector3.new(2, 12, 6), color = WALL },
	-- Short cap: attackers may not walk A Short straight into the defender lobby
	{ name = "ShortCapA", pos = Vector3.new(-37, 7, -45), size = Vector3.new(22, 12, 2), color = WALL },
	-- Site cover: default crate + head-glitch (partial), tower (full)
	{ name = "ADefaultCrate", pos = Vector3.new(-66, 3.25, -36), size = Vector3.new(6, PARTIAL, 6), color = CRATE },
	{ name = "AHeadGlitch", pos = Vector3.new(-80, 3.25, -28), size = Vector3.new(5, PARTIAL, 5), color = CRATE },
	{ name = "ATower", pos = Vector3.new(-54, 7, -41), size = Vector3.new(8, 12, 8), color = COVER_FULL },
	{ name = "AShortCrate", pos = Vector3.new(-36, 3.25, -40), size = Vector3.new(6, PARTIAL, 4), color = CRATE },

	-- B SITE (mirror)
	{ name = "SiteSouthB1", pos = Vector3.new(80.5, 7, -22), size = Vector3.new(29, 12, 2), color = WALL },
	{ name = "SiteSouthB2", pos = Vector3.new(51, 7, -22), size = Vector3.new(6, 12, 2), color = WALL },
	{ name = "PocketWestB1", pos = Vector3.new(48, 7, -29), size = Vector3.new(2, 12, 14), color = WALL },
	{ name = "PocketWestB2", pos = Vector3.new(48, 7, -47), size = Vector3.new(2, 12, 6), color = WALL },
	{ name = "ShortCapB", pos = Vector3.new(37, 7, -45), size = Vector3.new(22, 12, 2), color = WALL },
	{ name = "BDefaultCrate", pos = Vector3.new(66, 3.25, -36), size = Vector3.new(6, PARTIAL, 6), color = CRATE },
	{ name = "BHeadGlitch", pos = Vector3.new(80, 3.25, -28), size = Vector3.new(5, PARTIAL, 5), color = CRATE },
	{ name = "BTower", pos = Vector3.new(54, 7, -41), size = Vector3.new(8, 12, 8), color = COVER_FULL },
	{ name = "BShortCrate", pos = Vector3.new(36, 3.25, -40), size = Vector3.new(6, PARTIAL, 4), color = CRATE },

	-- HEAVEN A: solid plinth (deck y = 5) + ramp up its east face, rail on the
	-- site edge (the rail IS the partial cover up there — a head-glitch).
	{ name = "HeavenPlinthA", pos = Vector3.new(-86, 3, -43), size = Vector3.new(12, 4, 10), color = DECK },
	{
		name = "HeavenRampA",
		pos = Vector3.new(-73, RAMP_Y, -43),
		size = Vector3.new(14, 1.5, 6),
		color = RAMP,
		rot = Vector3.new(0, 0, -RAMP_ANGLE),
	},
	{ name = "HeavenRailA", pos = Vector3.new(-86, 6, -37.5), size = Vector3.new(12, 2, 1), color = DECK },

	-- HEAVEN B: mirror
	{ name = "HeavenPlinthB", pos = Vector3.new(86, 3, -43), size = Vector3.new(12, 4, 10), color = DECK },
	{
		name = "HeavenRampB",
		pos = Vector3.new(73, RAMP_Y, -43),
		size = Vector3.new(14, 1.5, 6),
		color = RAMP,
		rot = Vector3.new(0, 0, RAMP_ANGLE),
	},
	{ name = "HeavenRailB", pos = Vector3.new(86, 6, -37.5), size = Vector3.new(12, 2, 1), color = DECK },

	-- MID. Dividers at x ±26 with the short-door gaps (z -34..-26); the window
	-- wall at z=-32 leaves a 16-wide crossing (x -8..8) watched by the ledge.
	{ name = "DividerW0", pos = Vector3.new(-26, 7, 20), size = Vector3.new(2, 12, 16), color = WALL },
	{ name = "DividerW1", pos = Vector3.new(-26, 7, -2.5), size = Vector3.new(2, 12, 35), color = WALL },
	{ name = "DividerW2", pos = Vector3.new(-26, 7, -23), size = Vector3.new(2, 12, 6), color = WALL },
	{ name = "DividerW3", pos = Vector3.new(-26, 7, -37), size = Vector3.new(2, 12, 6), color = WALL },
	{ name = "DividerE0", pos = Vector3.new(26, 7, 20), size = Vector3.new(2, 12, 16), color = WALL },
	{ name = "DividerE1", pos = Vector3.new(26, 7, -2.5), size = Vector3.new(2, 12, 35), color = WALL },
	{ name = "DividerE2", pos = Vector3.new(26, 7, -23), size = Vector3.new(2, 12, 6), color = WALL },
	{ name = "DividerE3", pos = Vector3.new(26, 7, -37), size = Vector3.new(2, 12, 6), color = WALL },
	{ name = "MidWinL", pos = Vector3.new(-16, 7, -32), size = Vector3.new(16, 12, 2), color = WALL },
	{ name = "MidWinR", pos = Vector3.new(16, 7, -32), size = Vector3.new(16, 12, 2), color = WALL },

	-- MID LEDGE: plinth + ramp from the attacker side + a rail to head-glitch
	-- behind while watching the window.
	{ name = "MidLedgePlinth", pos = Vector3.new(0, 3, -18), size = Vector3.new(12, 4, 8), color = DECK },
	{
		name = "MidLedgeRamp",
		pos = Vector3.new(0, RAMP_Y, -7),
		size = Vector3.new(6, 1.5, 14),
		color = RAMP,
		rot = Vector3.new(RAMP_ANGLE, 0, 0),
	},
	{ name = "MidLedgeRail", pos = Vector3.new(0, 6, -21), size = Vector3.new(12, 2, 1), color = DECK },

	-- MID PILLAR (full cover centerpiece — breaks the long sightline) + partials
	{ name = "MidPillar", pos = Vector3.new(0, 7, 6), size = Vector3.new(6, 12, 6), color = COVER_FULL },
	{ name = "MidBoxW", pos = Vector3.new(-14, 3.25, 10), size = Vector3.new(6, PARTIAL, 4), color = CRATE },
	{ name = "MidBoxE", pos = Vector3.new(14, 3.25, 10), size = Vector3.new(6, PARTIAL, 4), color = CRATE },

	-- Lobby lineup walls (partial; shoot over, walk around)
	{ name = "HalfCoverDefL", pos = Vector3.new(-12, 3.25, -50), size = Vector3.new(10, PARTIAL, 2), color = CRATE },
	{ name = "HalfCoverDefR", pos = Vector3.new(12, 3.25, -50), size = Vector3.new(10, PARTIAL, 2), color = CRATE },
	{ name = "HalfCoverAtkL", pos = Vector3.new(-34, 3.25, 34), size = Vector3.new(10, PARTIAL, 2), color = CRATE },
	{ name = "HalfCoverAtkR", pos = Vector3.new(34, 3.25, 34), size = Vector3.new(10, PARTIAL, 2), color = CRATE },
}

local Greybox: MapSpec = {
	parts = parts,

	-- 5v5 rows: attackers east, defenders west, spread across the big lobbies.
	attackSpawns = {
		Vector3.new(24, 3, 62),
		Vector3.new(28, 3, 62),
		Vector3.new(32, 3, 62),
		Vector3.new(36, 3, 62),
		Vector3.new(40, 3, 62),
	},
	defenseSpawns = {
		Vector3.new(-40, 3, -62),
		Vector3.new(-36, 3, -62),
		Vector3.new(-32, 3, -62),
		Vector3.new(-28, 3, -62),
		Vector3.new(-24, 3, -62),
	},

	plantZones = {
		{ name = "SiteA", pos = Vector3.new(-68, 1.15, -36), size = Vector3.new(18, 0.3, 18), color = SITE_A },
		{ name = "SiteB", pos = Vector3.new(68, 1.15, -36), size = Vector3.new(18, 0.3, 18), color = SITE_B },
	},

	pois = {
		{ name = "SiteA", pos = Vector3.new(-68, 1, -36) },
		{ name = "HeavenA", pos = Vector3.new(-86, 5.5, -43) },
		{ name = "RampA", pos = Vector3.new(-73, 1, -43) },
		{ name = "DoorA", pos = Vector3.new(-60, 1, -18) },
		{ name = "ShortA", pos = Vector3.new(-37, 1, -38) },
		{ name = "ElbowA", pos = Vector3.new(-83, 1, -12) },
		{ name = "LobbyA", pos = Vector3.new(-50, 1, 0) },
		{ name = "SiteB", pos = Vector3.new(68, 1, -36) },
		{ name = "HeavenB", pos = Vector3.new(86, 5.5, -43) },
		{ name = "RampB", pos = Vector3.new(73, 1, -43) },
		{ name = "DoorB", pos = Vector3.new(60, 1, -18) },
		{ name = "ShortB", pos = Vector3.new(37, 1, -38) },
		{ name = "ElbowB", pos = Vector3.new(83, 1, -12) },
		{ name = "LobbyB", pos = Vector3.new(50, 1, 0) },
		{ name = "MidLedge", pos = Vector3.new(0, 5.5, -18) },
		{ name = "MidWindow", pos = Vector3.new(0, 1, -32) },
		{ name = "MidPillar", pos = Vector3.new(0, 1, 6) },
		{ name = "AtkLobby", pos = Vector3.new(0, 1, 42) },
		{ name = "DefLobby", pos = Vector3.new(0, 1, -50) },
	},

	-- Where bots stand to HOLD ANGLES. pos = protected side; face = watch
	-- direction (attackers post-plant flip it). partial = shoot over / jiggle
	-- peek; full = break LOS, peek around the edge.
	coverPoints = {
		-- A Site
		{ name = "A_Default", pos = Vector3.new(-66, 1, -41), face = Vector3.new(0.3, 0, 0.95), kind = "partial", zone = "A_SITE" },
		{ name = "A_HeadGlitch", pos = Vector3.new(-80, 1, -32), face = Vector3.new(0.9, 0, 0.45), kind = "partial", zone = "A_SITE" },
		{ name = "A_TowerCubby", pos = Vector3.new(-54, 1, -48), face = Vector3.new(0.66, 0, 0.75), kind = "full", zone = "A_SITE" },
		{ name = "A_HeavenRail", pos = Vector3.new(-86, 5.5, -39.5), face = Vector3.new(0.83, 0, 0.56), kind = "partial", zone = "A_HEAVEN" },
		{ name = "A_ShortWatch", pos = Vector3.new(-38, 1, -43), face = Vector3.new(1, 0, 0.3), kind = "partial", zone = "A_SHORT" },
		-- B Site (mirror)
		{ name = "B_Default", pos = Vector3.new(66, 1, -41), face = Vector3.new(-0.3, 0, 0.95), kind = "partial", zone = "B_SITE" },
		{ name = "B_HeadGlitch", pos = Vector3.new(80, 1, -32), face = Vector3.new(-0.9, 0, 0.45), kind = "partial", zone = "B_SITE" },
		{ name = "B_TowerCubby", pos = Vector3.new(54, 1, -48), face = Vector3.new(-0.66, 0, 0.75), kind = "full", zone = "B_SITE" },
		{ name = "B_HeavenRail", pos = Vector3.new(86, 5.5, -39.5), face = Vector3.new(-0.83, 0, 0.56), kind = "partial", zone = "B_HEAVEN" },
		{ name = "B_ShortWatch", pos = Vector3.new(38, 1, -43), face = Vector3.new(-1, 0, 0.3), kind = "partial", zone = "B_SHORT" },
		-- Mid
		{ name = "Mid_PillarAtk", pos = Vector3.new(0, 1, 10), face = Vector3.new(0, 0, -1), kind = "full", zone = "MID" },
		{ name = "Mid_PillarDef", pos = Vector3.new(0, 1, 2), face = Vector3.new(0, 0, 1), kind = "full", zone = "MID" },
		{ name = "MidLedgeRail", pos = Vector3.new(0, 5.5, -19), face = Vector3.new(0, 0, -1), kind = "partial", zone = "MID_LEDGE" },
		-- Lane holds (defenders watch the lane mouths, south)
		{ name = "A_LaneFull", pos = Vector3.new(-80, 1, -16), face = Vector3.new(0, 0, 1), kind = "full", zone = "A_ELBOW" },
		{ name = "A_LaneHalf", pos = Vector3.new(-83, 1, 24), face = Vector3.new(0, 0, 1), kind = "partial", zone = "A_MAIN" },
		{ name = "B_LaneFull", pos = Vector3.new(80, 1, -16), face = Vector3.new(0, 0, 1), kind = "full", zone = "B_ELBOW" },
		{ name = "B_LaneHalf", pos = Vector3.new(83, 1, 24), face = Vector3.new(0, 0, 1), kind = "partial", zone = "B_MAIN" },
	},
}

return Greybox
