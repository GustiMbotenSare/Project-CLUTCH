--!strict
-- Greybox v5 — the reference rebuild. Layout grammar borrowed from the most
-- balanced map in FPS history (Dust2's three-lane skeleton), proportions,
-- names and verticality entirely ours.
--
-- v4.2 → v5 (batch B, phase 1):
--   * A LONG IS A REAL LONG: the west lane becomes an enclosed corridor with
--     an inner wall, a 10-wide DOORS choke partway down, and the S-bend
--     block behind it. "Outside Long" is the staging strip before the doors.
--   * B TUNNELS: the east lane becomes an enclosed tunnel run with a jog
--     block — two reads, not one boulevard.
--   * MID DOORS: a full-width wall across mid at z=9 with a pair of 5.5-wide
--     doors split by a center box. Mid control is now a GATE, not a plain —
--     defenders cross it ~3s in, attackers pay to open it.
--   * The stretched routes pace attackers at ~12s spawn-to-site while
--     defenders keep the 2-hop arrive-first timing (the audit proves it).
--   * Heavens stay — the overlook decks are our signature, not the
--     reference's. So do both ledge ramps.
--
-- v4 lineage: de-labyrinth boulevards (v4), spawn sight seals (v4.1),
-- both-ways ledge (v4.2). Coordinates: y up. Attackers south (+z),
-- defenders north (-z). Site A west (-x), Site B east (+x). Floor top y = 1.

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
	-- the sites (playtest #14). One mid gap (x -25..25); defenders deploy around it.
	{ name = "DefScreenL", pos = Vector3.new(-70, 7, -58), size = Vector3.new(90, 12, 2), color = WALL },
	{ name = "DefScreenR", pos = Vector3.new(70, 7, -58), size = Vector3.new(90, 12, 2), color = WALL },

	-- A LONG (west): an enclosed corridor, not a boulevard. Inner wall splits
	-- it from the lobby; the DOORS WALL crosses at z=14 with a 10-wide gap;
	-- the S-bend full block sits right behind the doors.
	{ name = "LaneWestOuter", pos = Vector3.new(-105, 7, 17.5), size = Vector3.new(2, 12, 79), color = WALL },
	{ name = "ALongInnerS", pos = Vector3.new(-70, 7, 42.5), size = Vector3.new(2, 12, 25), color = WALL },
	{ name = "ALongInnerN", pos = Vector3.new(-70, 7, -1), size = Vector3.new(2, 12, 42), color = WALL },
	{ name = "LongDoorWallW", pos = Vector3.new(-99, 7, 14), size = Vector3.new(12, 12, 2), color = WALL },
	{ name = "LongDoorWallE", pos = Vector3.new(-76.5, 7, 14), size = Vector3.new(13, 12, 2), color = WALL },
	{ name = "ALaneFull", pos = Vector3.new(-88, 7, 4), size = Vector3.new(8, 12, 8), color = COVER_FULL },
	{ name = "ALaneHalf", pos = Vector3.new(-88, 3.25, 30), size = Vector3.new(6, PARTIAL, 3), color = CRATE },

	-- B TUNNELS (east, mirror philosophy): inner walls make the run, the jog
	-- block bends it. Entry gap from the lobby at z 22..30.
	{ name = "LaneEastOuter", pos = Vector3.new(105, 7, 17.5), size = Vector3.new(2, 12, 79), color = WALL },
	{ name = "BTunInnerS", pos = Vector3.new(70, 7, 42.5), size = Vector3.new(2, 12, 25), color = WALL },
	{ name = "BTunInnerN", pos = Vector3.new(70, 7, 8), size = Vector3.new(2, 12, 20), color = WALL },
	{ name = "BTunJog", pos = Vector3.new(88, 7, 24), size = Vector3.new(10, 12, 8), color = COVER_FULL },
	{ name = "BLaneFull", pos = Vector3.new(88, 7, 0), size = Vector3.new(8, 12, 8), color = COVER_FULL },
	{ name = "BLaneHalf", pos = Vector3.new(88, 3.25, 38), size = Vector3.new(6, PARTIAL, 3), color = CRATE },

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

	-- MID. MID DOORS at z=9: a full-width wall (x -26..26) with two 5.5-wide
	-- doors split by a center box — mid is a gate now, not a plain. Dividers
	-- keep the 8-wide short gaps; window wall and ledge stay as before.
	{ name = "MidDoorWallW", pos = Vector3.new(-16.5, 7, 9), size = Vector3.new(19, 12, 2), color = WALL },
	{ name = "MidDoorWallE", pos = Vector3.new(16.5, 7, 9), size = Vector3.new(19, 12, 2), color = WALL },
	{ name = "MidDoorBox", pos = Vector3.new(0, 3.25, 9), size = Vector3.new(3, PARTIAL, 3), color = CRATE },
	{ name = "DividerW1", pos = Vector3.new(-26, 7, -1), size = Vector3.new(2, 12, 42), color = WALL },
	{ name = "DividerW2", pos = Vector3.new(-26, 7, -36), size = Vector3.new(2, 12, 12), color = WALL },
	{ name = "DividerW3", pos = Vector3.new(-26, 7, -47), size = Vector3.new(2, 12, 10), color = WALL },
	{ name = "DividerE1", pos = Vector3.new(26, 7, -1), size = Vector3.new(2, 12, 42), color = WALL },
	{ name = "DividerE2", pos = Vector3.new(26, 7, -36), size = Vector3.new(2, 12, 12), color = WALL },
	{ name = "DividerE3", pos = Vector3.new(26, 7, -47), size = Vector3.new(2, 12, 10), color = WALL },
	{ name = "MidWinL", pos = Vector3.new(-16, 7, -32), size = Vector3.new(16, 12, 2), color = WALL },
	{ name = "MidWinR", pos = Vector3.new(16, 7, -32), size = Vector3.new(16, 12, 2), color = WALL },

	-- MID LEDGE: plinth + ramps BOTH ways + rail to head-glitch.
	{ name = "MidLedgePlinth", pos = Vector3.new(0, 3, -17), size = Vector3.new(12, 4, 8), color = DECK },
	{
		name = "MidLedgeRamp",
		pos = Vector3.new(0, RAMP_Y, -6),
		size = Vector3.new(6, 1.5, 14),
		color = RAMP,
		rot = Vector3.new(RAMP_ANGLE, 0, 0),
	},
	{
		name = "MidLedgeRampN",
		pos = Vector3.new(0, RAMP_Y, -28),
		size = Vector3.new(6, 1.5, 14),
		color = RAMP,
		rot = Vector3.new(-RAMP_ANGLE, 0, 0),
	},
	{ name = "MidLedgeRail", pos = Vector3.new(0, 6, -20.5), size = Vector3.new(12, 2, 1), color = DECK },

	-- MID PILLAR (full cover centerpiece) + partials
	{ name = "MidPillar", pos = Vector3.new(0, 7, 4), size = Vector3.new(6, 12, 6), color = COVER_FULL },
	{ name = "MidBoxW", pos = Vector3.new(-14, 3.25, 16), size = Vector3.new(6, PARTIAL, 4), color = CRATE },
	{ name = "MidBoxE", pos = Vector3.new(14, 3.25, 16), size = Vector3.new(6, PARTIAL, 4), color = CRATE },

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
		{ name = "LongCornerA", pos = Vector3.new(-88, 1, -6) },
		{ name = "LongDoorsA", pos = Vector3.new(-88, 1, 14) },
		{ name = "OutsideLongA", pos = Vector3.new(-88, 1, 34) },
		{ name = "SiteB", pos = Vector3.new(68, 1, -36) },
		{ name = "HeavenB", pos = Vector3.new(80, 5.5, -47) },
		{ name = "RampB", pos = Vector3.new(62, 1, -47) },
		{ name = "DoorB", pos = Vector3.new(65, 1, -18) },
		{ name = "ShortB", pos = Vector3.new(36, 1, -36) },
		{ name = "TunJogB", pos = Vector3.new(88, 1, 24) },
		{ name = "MidLedge", pos = Vector3.new(0, 5.5, -17) },
		{ name = "MidWindow", pos = Vector3.new(0, 1, -32) },
		{ name = "MidDoors", pos = Vector3.new(0, 1, 9) },
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
		{ name = "Mid_PillarAtk", pos = Vector3.new(0, 1, 13), face = Vector3.new(0, 0, -1), kind = "full", zone = "MID_COURT" },
		{ name = "Mid_PillarDef", pos = Vector3.new(0, 1, -1), face = Vector3.new(0, 0, 1), kind = "full", zone = "MID" },
		{ name = "MidLedgeRail", pos = Vector3.new(0, 5.5, -18), face = Vector3.new(0, 0, -1), kind = "partial", zone = "MID_LEDGE" },
		-- The new chokes get their holds: long corner (defenders watch the
		-- doors), the tunnel jog (defenders watch the tunnel mouth), and the
		-- door box (attackers watch the crossing).
		{ name = "A_LongCorner", pos = Vector3.new(-88, 1, -2), face = Vector3.new(0, 0, 1), kind = "full", zone = "A_MAIN" },
		{ name = "A_OutsideLong", pos = Vector3.new(-88, 1, 34), face = Vector3.new(0, 0, -1), kind = "partial", zone = "A_MAIN" },
		{ name = "B_TunJog", pos = Vector3.new(95, 1, 22), face = Vector3.new(0, 0, 1), kind = "full", zone = "B_MAIN" },
		{ name = "B_TunMouth", pos = Vector3.new(88, 1, 40), face = Vector3.new(0, 0, -1), kind = "partial", zone = "B_MAIN" },
		{ name = "A_ShortGap", pos = Vector3.new(-30, 1, -26), face = Vector3.new(-1, 0, -0.2), kind = "partial", zone = "A_SHORT" },
		{ name = "B_ShortGap", pos = Vector3.new(30, 1, -26), face = Vector3.new(1, 0, -0.2), kind = "partial", zone = "B_SHORT" },
	},
}

return Greybox
