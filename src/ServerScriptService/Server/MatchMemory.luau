--!strict
-- MatchMemory: what the bots LEARN as a match wears on.
--
-- Brains reset every round — perception dies with the body, plans re-roll
-- fresh coins. Without this layer the same mistake that killed them in
-- round 2 repeats in round 9, and in the next match too (playtest #18's
-- "they never adapt"). The ledger is deliberately small and keyed by ZONE
-- KEY: where enemies get seen, where each side kills and dies, where the
-- spike lands and gets defused. The plan roller reads it between rounds;
-- brains read it for approach caution (a zone the enemy keeps owning is
-- worth a peek even without a fresh contact).
--
-- Between MATCHES the ledger decays by half — lessons fade, they don't
-- vanish. And it's the manager era's scouting seed: the SCOUT readout at
-- match end is what a manager would call the VOD review.

local MatchMemory = {}

local SITES = { "A_SITE", "B_SITE" }

type Book = { [string]: { [string]: number } } -- [side][zoneKey] -> count

local function emptyBook(): Book
	return { Attack = {}, Defense = {} }
end

local spots: Book = emptyBook() -- [enemySide][zone]: first-sightings of them there
local killsFrom: Book = emptyBook() -- [killerSide][zone]: kills scored FROM there
local deathsIn: Book = emptyBook() -- [victimSide][zone]: deaths suffered there
local plantsAt: { [string]: number } = {}
local defusesAt: { [string]: number } = {}

function MatchMemory.reset()
	spots = emptyBook()
	killsFrom = emptyBook()
	deathsIn = emptyBook()
	plantsAt = {}
	defusesAt = {}
end

-- Half-life between matches: evidence halves, crumbs under 0.5 drop.
function MatchMemory.decay()
	local function decayZones(book: Book)
		for _, zones in book do
			for key, n in zones do
				local halved = n * 0.5
				zones[key] = if halved >= 0.5 then halved else nil
			end
		end
	end
	decayZones(spots)
	decayZones(killsFrom)
	decayZones(deathsIn)
	for key, n in plantsAt do
		plantsAt[key] = if n * 0.5 >= 0.5 then n * 0.5 else nil
	end
	for key, n in defusesAt do
		defusesAt[key] = if n * 0.5 >= 0.5 then n * 0.5 else nil
	end
end

local function otherSide(side: string): string
	return if side == "Attack" then "Defense" else "Attack"
end

local function bump(book: Book, side: string, zoneKey: string, amount: number)
	if zoneKey == "VOID" or zoneKey == "" then
		return
	end
	local zones = book[side]
	if not zones then
		return
	end
	zones[zoneKey] = (zones[zoneKey] or 0) + amount
end

-- A first-sighting: the OBSERVER's side tells us whose enemy was seen.
function MatchMemory.recordSpot(observerSide: string, enemyZoneKey: string)
	bump(spots, otherSide(observerSide), enemyZoneKey, 1)
end

function MatchMemory.recordKill(killerSide: string, killerZone: string, victimSide: string, victimZone: string)
	bump(killsFrom, killerSide, killerZone, 1)
	bump(deathsIn, victimSide, victimZone, 1)
end

function MatchMemory.recordPlant(zoneKey: string)
	plantsAt[zoneKey] = (plantsAt[zoneKey] or 0) + 1
end

function MatchMemory.recordDefuse(zoneKey: string)
	defusesAt[zoneKey] = (defusesAt[zoneKey] or 0) + 1
end

-- How proven-active a side is in a zone: sightings + kills weighted double.
function MatchMemory.zoneHeat(side: string, zoneKey: string): number
	return (spots[side][zoneKey] or 0) + (killsFrom[side][zoneKey] or 0) * 2
end

function MatchMemory.deathsAt(side: string, zoneKey: string): number
	return deathsIn[side][zoneKey] or 0
end

-- Which site does `side` favor? Nil until the evidence clears the floor.
function MatchMemory.preferredSite(side: string): string?
	local best: string? = nil
	local bestScore = 1.5 -- evidence floor: one kill from there isn't a habit
	for _, site in SITES do
		local score = MatchMemory.zoneHeat(side, site) + (plantsAt[site] or 0) * 3
		if score > bestScore then
			best = site
			bestScore = score
		end
	end
	return best
end

-- The match-end scouting readout. Parseable, one line per side.
function MatchMemory.scoutLine(side: string): string
	local zones = spots[side]
	local parts = {}
	for zoneKey, n in zones do
		table.insert(parts, ("%s x%.1f"):format(zoneKey, n + (killsFrom[side][zoneKey] or 0) * 2))
	end
	table.sort(parts)
	if #parts > 5 then
		while #parts > 5 do
			table.remove(parts)
		end
	end
	local deaths = deathsIn[side]
	local worstZone, worstCount = "none", 0
	for zoneKey, n in deaths do
		if n > worstCount then
			worstZone, worstCount = zoneKey, n
		end
	end
	return ("%s hot zones: %s | graveyard: %s (%.1f deaths)"):format(
		side,
		if #parts > 0 then table.concat(parts, ", ") else "no reads",
		worstZone,
		worstCount
	)
end

return MatchMemory
