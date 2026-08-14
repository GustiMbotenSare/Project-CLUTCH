--!strict
-- Greybox M0 map as DATA, not Studio parts.
-- The arena is generated at runtime by Server/MapBuilder — nobody hand-builds
-- in Studio. Tune lanes, chokes, and cover by editing numbers here.
--
-- Coordinates: y is up. Attackers spawn south (+z), defenders north (-z).
-- Site A is west (-x), Site B is east (+x).

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

export type MapSpec = {
	parts: { PartSpec },
	attackSpawns: { Vector3 },
	defenseSpawns: { Vector3 },
	plantZones: { PlantZone },
}

local FLOOR = Color3.fromRGB(48, 48, 54)
local WALL = Color3.fromRGB(110, 110, 120)
local CRATE = Color3.fromRGB(150, 120, 80)
local SITE_A = Color3.fromRGB(255, 170, 60) -- orange
local SITE_B = Color3.fromRGB(60, 200, 200) -- teal

local Greybox: MapSpec = {
	parts = {
		-- Floor (top surface at y = 1)
		{ name = "Floor", pos = Vector3.new(0, 0, 0), size = Vector3.new(170, 2, 110), color = FLOOR },

		-- Boundary walls
		{ name = "WallN", pos = Vector3.new(0, 7, -55), size = Vector3.new(170, 12, 2), color = WALL },
		{ name = "WallS", pos = Vector3.new(0, 7, 55), size = Vector3.new(170, 12, 2), color = WALL },
		{ name = "WallW", pos = Vector3.new(-85, 7, 0), size = Vector3.new(2, 12, 110), color = WALL },
		{ name = "WallE", pos = Vector3.new(85, 7, 0), size = Vector3.new(2, 12, 110), color = WALL },

		-- Lane dividers (8-stud gaps create the mid-map crossings)
		{ name = "DividerWestA", pos = Vector3.new(-20, 7, -27), size = Vector3.new(2, 12, 26), color = WALL },
		{ name = "DividerWestB", pos = Vector3.new(-20, 7, 4.5), size = Vector3.new(2, 12, 21), color = WALL },
		{ name = "DividerEastA", pos = Vector3.new(20, 7, -27), size = Vector3.new(2, 12, 26), color = WALL },
		{ name = "DividerEastB", pos = Vector3.new(20, 7, 4.5), size = Vector3.new(2, 12, 21), color = WALL },

		-- Mid wall with a 12-stud window
		{ name = "MidWallL", pos = Vector3.new(-9.5, 7, -20), size = Vector3.new(7, 12, 2), color = WALL },
		{ name = "MidWallR", pos = Vector3.new(9.5, 7, -20), size = Vector3.new(7, 12, 2), color = WALL },

		-- Site cover crates
		{ name = "CrateA1", pos = Vector3.new(-55, 3, -25), size = Vector3.new(4, 4, 4), color = CRATE },
		{ name = "CrateA2", pos = Vector3.new(-45, 3, -35), size = Vector3.new(6, 4, 4), color = CRATE },
		{ name = "CrateA3", pos = Vector3.new(-62, 3, -33), size = Vector3.new(4, 4, 6), color = CRATE },
		{ name = "CrateB1", pos = Vector3.new(55, 3, -25), size = Vector3.new(4, 4, 4), color = CRATE },
		{ name = "CrateB2", pos = Vector3.new(45, 3, -35), size = Vector3.new(6, 4, 4), color = CRATE },
		{ name = "CrateB3", pos = Vector3.new(62, 3, -33), size = Vector3.new(4, 4, 6), color = CRATE },

		-- Lane + mid cover
		{ name = "CoverMid", pos = Vector3.new(0, 3, 12), size = Vector3.new(8, 4, 2), color = CRATE },
		{ name = "CoverALane", pos = Vector3.new(-55, 3, 0), size = Vector3.new(4, 4, 6), color = CRATE },
		{ name = "CoverBLane", pos = Vector3.new(55, 3, 0), size = Vector3.new(4, 4, 6), color = CRATE },

		-- Site entry choke stubs
		{ name = "SiteStubA", pos = Vector3.new(-35, 7, -26), size = Vector3.new(8, 12, 2), color = WALL },
		{ name = "SiteStubB", pos = Vector3.new(35, 7, -26), size = Vector3.new(8, 12, 2), color = WALL },
	},

	attackSpawns = {
		Vector3.new(-8, 3, 44),
		Vector3.new(-4, 3, 44),
		Vector3.new(0, 3, 44),
		Vector3.new(4, 3, 44),
		Vector3.new(8, 3, 44),
	},

	defenseSpawns = {
		Vector3.new(-8, 3, -46),
		Vector3.new(-4, 3, -46),
		Vector3.new(0, 3, -46),
		Vector3.new(4, 3, -46),
		Vector3.new(8, 3, -46),
	},

	plantZones = {
		{ name = "SiteA", pos = Vector3.new(-50, 1.15, -32), size = Vector3.new(14, 0.3, 14), color = SITE_A },
		{ name = "SiteB", pos = Vector3.new(50, 1.15, -32), size = Vector3.new(14, 0.3, 14), color = SITE_B },
	},
}

return Greybox
