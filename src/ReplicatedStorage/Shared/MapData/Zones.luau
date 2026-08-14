--!strict
-- Named map areas — the CLUTCH equivalent of Counter-Strike's nav-mesh place
-- names ("Long A", "Catwalk", "Mid Doors").
--
-- Why this module exists:
--   * Bots should reason about SPACE, not coordinates. "Rotate to B Site" is a
--     decision a caster can narrate; "walk to 50, 1, -30" is a side effect.
--   * Callouts, the kill feed and the future TTS caster all need real names.
--   * Movement logs collapse from 4Hz coordinate spam into a zone timeline.
--   * Public esports datasets express player position as map regions, so
--     region occupancy is the unit we can calibrate our sim against later.
--
-- Zones are semantic labels over space, NOT collision volumes. They overlap
-- freely; the SMALLEST containing zone wins, so "A Door" beats "A Site".
-- Floor zones occupy y 0..5.5 and decks y 4.2..9, resolved against a bot's
-- GROUND position (feet). The bands OVERLAP 4.2..5.5: a ramp's top end sits
-- at y ~5 while still inside the ramp zone's footprint, and the smallest-
-- zone-wins rule keeps decks correct anyway (heaven is smaller than site).
--
-- v3: re-derived for the 230x150 5v5 greybox; sites adjoin DEF_LOBBY (the
-- defender back route).
-- v3.1 (playtest #11): sites grow 4 studs south (z -50..-18) — the site read
-- as a corridor next to the lobby. Doors/shorts/lobbies shift to match.

export type ZoneKey = string
export type Control = "Attack" | "Defense" | "Neutral"

export type Zone = {
	id: number,
	key: ZoneKey,
	callout: string,
	min: Vector3,
	max: Vector3,
	elevated: boolean,
	control: Control,
	tags: { string },
	adjacent: { ZoneKey },
}

type ZoneDef = {
	key: string,
	callout: string,
	x: { number },
	z: { number },
	elevated: boolean?,
	control: Control,
	tags: { string },
	adjacent: { string },
}

local FLOOR_MIN, FLOOR_MAX = 0, 5.5 -- overlaps the deck band; ramps span both
local DECK_MIN, DECK_MAX = 4.2, 9

-- Bounds derived from Greybox v3.1 geometry. Attackers south (+z), defenders
-- north (-z), Site A west (-x), Site B east (+x).
local defs: { ZoneDef } = {
	{
		key = "ATK_SPAWN", callout = "Attacker Spawn",
		x = { -115, 115 }, z = { 55, 70 },
		control = "Attack", tags = { "spawn" },
		adjacent = { "ATK_LOBBY" },
	},
	{
		key = "ATK_LOBBY", callout = "Attacker Lobby",
		x = { -115, 115 }, z = { 28, 55 },
		control = "Attack", tags = { "lobby" },
		adjacent = { "ATK_SPAWN", "A_MAIN", "B_MAIN", "MID_COURT", "A_LOBBY", "B_LOBBY" },
	},

	-- A side (corridor x -94..-72 between the lane walls)
	{
		key = "A_MAIN", callout = "A Main",
		x = { -94, -72 }, z = { -2, 55 },
		control = "Neutral", tags = { "lane", "flank" },
		adjacent = { "A_ELBOW" },
	},
	{
		key = "A_ELBOW", callout = "A Elbow",
		x = { -94, -72 }, z = { -26, -2 },
		control = "Neutral", tags = { "lane", "choke", "flank" },
		adjacent = { "A_LOBBY" },
	},
	{
		key = "A_LOBBY", callout = "A Lobby",
		x = { -72, -26 }, z = { -18, 28 },
		control = "Neutral", tags = { "lobby" },
		adjacent = { "A_DOOR", "A_SHORT" },
	},
	{
		key = "A_DOOR", callout = "A Door",
		x = { -66, -54 }, z = { -20, -14 },
		control = "Neutral", tags = { "choke" },
		adjacent = { "A_SITE" },
	},
	{
		key = "A_SITE", callout = "A Site",
		x = { -95, -48 }, z = { -50, -18 }, -- v3.1: four studs deeper south
		control = "Defense", tags = { "site", "plant" },
		-- DEF_LOBBY: the back route. Sites open north; defenders arrive first.
		adjacent = { "A_RAMP", "A_SHORT", "A_HEAVEN", "DEF_LOBBY" },
	},
	{
		key = "A_RAMP", callout = "A Ramp",
		x = { -80, -66 }, z = { -48, -38 },
		control = "Defense", tags = { "connector" },
		adjacent = { "A_HEAVEN" },
	},
	{
		key = "A_HEAVEN", callout = "A Heaven",
		x = { -92, -80 }, z = { -48, -38 }, elevated = true,
		control = "Defense", tags = { "heaven", "site" },
		adjacent = { "A_RAMP" },
	},
	{
		key = "A_SHORT", callout = "A Short",
		x = { -48, -26 }, z = { -50, -18 },
		control = "Neutral", tags = { "connector", "choke" },
		adjacent = { "MID_BACK" },
	},

	-- Mid
	{
		key = "MID_COURT", callout = "Mid Courtyard",
		x = { -26, 26 }, z = { 12, 28 },
		control = "Attack", tags = { "mid" },
		adjacent = { "MID" },
	},
	{
		key = "MID", callout = "Mid",
		x = { -26, 26 }, z = { -32, 12 },
		control = "Neutral", tags = { "mid" },
		adjacent = { "MID_LEDGE", "MID_WINDOW" },
	},
	{
		key = "MID_LEDGE", callout = "Mid Ledge",
		x = { -8, 8 }, z = { -24, -12 }, elevated = true,
		control = "Neutral", tags = { "mid", "heaven" },
		adjacent = { "MID" },
	},
	{
		key = "MID_WINDOW", callout = "Mid Window",
		x = { -8, 8 }, z = { -38, -26 },
		control = "Neutral", tags = { "mid", "choke" },
		adjacent = { "MID_BACK" },
	},
	{
		key = "MID_BACK", callout = "Mid Back",
		x = { -26, 26 }, z = { -45, -32 },
		control = "Defense", tags = { "mid" },
		adjacent = { "B_SHORT", "DEF_LOBBY" },
	},

	-- B side (mirror)
	{
		key = "B_SHORT", callout = "B Short",
		x = { 26, 48 }, z = { -50, -18 },
		control = "Neutral", tags = { "connector", "choke" },
		adjacent = { "B_SITE", "B_LOBBY" },
	},
	{
		key = "B_SITE", callout = "B Site",
		x = { 48, 95 }, z = { -50, -18 }, -- v3.1: four studs deeper south
		control = "Defense", tags = { "site", "plant" },
		adjacent = { "B_RAMP", "B_HEAVEN", "B_DOOR", "DEF_LOBBY" },
	},
	{
		key = "B_RAMP", callout = "B Ramp",
		x = { 66, 80 }, z = { -48, -38 },
		control = "Defense", tags = { "connector" },
		adjacent = { "B_HEAVEN" },
	},
	{
		key = "B_HEAVEN", callout = "B Heaven",
		x = { 80, 92 }, z = { -48, -38 }, elevated = true,
		control = "Defense", tags = { "heaven", "site" },
		adjacent = { "B_RAMP" },
	},
	{
		key = "B_DOOR", callout = "B Door",
		x = { 54, 66 }, z = { -20, -14 },
		control = "Neutral", tags = { "choke" },
		adjacent = { "B_LOBBY" },
	},
	{
		key = "B_LOBBY", callout = "B Lobby",
		x = { 26, 72 }, z = { -18, 28 },
		control = "Neutral", tags = { "lobby" },
		adjacent = { "B_ELBOW" },
	},
	{
		key = "B_ELBOW", callout = "B Elbow",
		x = { 72, 94 }, z = { -26, -2 },
		control = "Neutral", tags = { "lane", "choke", "flank" },
		adjacent = { "B_MAIN" },
	},
	{
		key = "B_MAIN", callout = "B Main",
		x = { 72, 94 }, z = { -2, 55 },
		control = "Neutral", tags = { "lane", "flank" },
		adjacent = { "ATK_LOBBY" },
	},

	-- Defender side
	{
		key = "DEF_LOBBY", callout = "Defender Lobby",
		x = { -115, 115 }, z = { -55, -45 },
		control = "Defense", tags = { "lobby" },
		adjacent = { "DEF_SPAWN" },
	},
	{
		key = "DEF_SPAWN", callout = "Defender Spawn",
		x = { -115, 115 }, z = { -70, -55 },
		control = "Defense", tags = { "spawn" },
		adjacent = {},
	},
}

local Zones = {}

local list: { Zone } = {}
local byKey: { [ZoneKey]: Zone } = {}

for index, def in defs do
	local elevated = def.elevated == true
	local zone: Zone = {
		id = index,
		key = def.key,
		callout = def.callout,
		min = Vector3.new(
			math.min(def.x[1], def.x[2]),
			if elevated then DECK_MIN else FLOOR_MIN,
			math.min(def.z[1], def.z[2])
		),
		max = Vector3.new(
			math.max(def.x[1], def.x[2]),
			if elevated then DECK_MAX else FLOOR_MAX,
			math.max(def.z[1], def.z[2])
		),
		elevated = elevated,
		control = def.control,
		tags = def.tags,
		adjacent = table.clone(def.adjacent),
	}
	table.insert(list, zone)
	byKey[zone.key] = zone
end

-- Adjacency is declared one-directionally for brevity, then mirrored. A
-- one-sided typo would otherwise create a one-way corridor, which is the kind
-- of bug that only shows up as a bot pacing a wall twenty minutes in.
for _, zone in list do
	for _, otherKey in zone.adjacent do
		local other = byKey[otherKey]
		if not other then
			warn(("[CLUTCH] Zones: %s lists unknown neighbour %s"):format(zone.key, otherKey))
			continue
		end
		if not table.find(other.adjacent, zone.key) then
			table.insert(other.adjacent, zone.key)
		end
	end
end

Zones.list = list
Zones.byKey = byKey
Zones.VOID = "VOID"

local function volumeOf(zone: Zone): number
	local span = zone.max - zone.min
	return span.X * span.Y * span.Z
end

local function contains(zone: Zone, p: Vector3): boolean
	return p.X >= zone.min.X
		and p.X <= zone.max.X
		and p.Y >= zone.min.Y
		and p.Y <= zone.max.Y
		and p.Z >= zone.min.Z
		and p.Z <= zone.max.Z
end

-- Smallest containing zone wins, so specific callouts beat broad ones.
function Zones.at(groundPos: Vector3): Zone?
	local best: Zone? = nil
	local bestVolume = math.huge
	for _, zone in list do
		if contains(zone, groundPos) then
			local volume = volumeOf(zone)
			if volume < bestVolume then
				best = zone
				bestVolume = volume
			end
		end
	end
	return best
end

function Zones.calloutAt(groundPos: Vector3): string
	local zone = Zones.at(groundPos)
	return if zone then zone.callout else "Off-map"
end

function Zones.keyAt(groundPos: Vector3): ZoneKey
	local zone = Zones.at(groundPos)
	return if zone then zone.key else Zones.VOID
end

-- A bot's feet, not its root part. Falls back to the raw position so callers
-- never have to nil-check.
function Zones.groundOf(model: Model): Vector3
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return model:GetPivot().Position
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -12, 0), params)
	if hit then
		return Vector3.new(root.Position.X, hit.Position.Y + 0.5, root.Position.Z)
	end
	return root.Position
end

function Zones.center(key: ZoneKey): Vector3?
	local zone = byKey[key]
	if not zone then
		return nil
	end
	local mid = (zone.min + zone.max) / 2
	-- Aim at the walking surface, not the middle of the height band
	return Vector3.new(mid.X, if zone.elevated then 5.5 else 1, mid.Z)
end

function Zones.samplePoint(key: ZoneKey, rng: Random): Vector3?
	local zone = byKey[key]
	if not zone then
		return nil
	end
	-- Inset so samples never land exactly on a boundary wall
	local inset = 3
	local x1, x2 = zone.min.X + inset, zone.max.X - inset
	local z1, z2 = zone.min.Z + inset, zone.max.Z - inset
	if x2 < x1 or z2 < z1 then
		return Zones.center(key)
	end
	return Vector3.new(
		rng:NextNumber(x1, x2),
		if zone.elevated then 5.5 else 1,
		rng:NextNumber(z1, z2)
	)
end

function Zones.hasTag(key: ZoneKey, tag: string): boolean
	local zone = byKey[key]
	return zone ~= nil and table.find(zone.tags, tag) ~= nil
end

function Zones.withTag(tag: string): { ZoneKey }
	local found = {}
	for _, zone in list do
		if table.find(zone.tags, tag) then
			table.insert(found, zone.key)
		end
	end
	return found
end

-- Breadth-first hop counts over the adjacency graph. Memoised per source —
-- the graph is 25 nodes, so this is effectively free after first use.
local hopCache: { [ZoneKey]: { [ZoneKey]: number } } = {}

local function hopsFrom(source: ZoneKey): { [ZoneKey]: number }
	local cached = hopCache[source]
	if cached then
		return cached
	end

	local dist: { [ZoneKey]: number } = { [source] = 0 }
	local queue = { source }
	local head = 1
	while head <= #queue do
		local current = queue[head]
		head += 1
		local zone = byKey[current]
		if not zone then
			continue
		end
		for _, neighbour in zone.adjacent do
			if dist[neighbour] == nil then
				dist[neighbour] = dist[current] + 1
				table.insert(queue, neighbour)
			end
		end
	end

	hopCache[source] = dist
	return dist
end

function Zones.hops(from: ZoneKey, to: ZoneKey): number
	if from == to then
		return 0
	end
	local dist = hopsFrom(from)[to]
	return if dist then dist else math.huge
end

-- The neighbour of `from` that actually makes progress toward `to`.
function Zones.nextHop(from: ZoneKey, to: ZoneKey): ZoneKey?
	if from == to then
		return nil
	end
	local zone = byKey[from]
	if not zone then
		return nil
	end
	local best: ZoneKey? = nil
	local bestDist = math.huge
	for _, neighbour in zone.adjacent do
		local dist = Zones.hops(neighbour, to)
		if dist < bestDist then
			best = neighbour
			bestDist = dist
		end
	end
	return best
end

return Zones
