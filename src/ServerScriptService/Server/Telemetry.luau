--!strict
-- Movement + decision telemetry.
--
-- Two different consumers, two different formats:
--   * HUMANS want a timeline. We print only zone TRANSITIONS, annotated with
--     the intent that caused them. 4Hz coordinate spam is unreadable and
--     buries the behaviour we are trying to inspect.
--   * ANALYSIS wants everything. The full-rate samples stay in memory so we can
--     compute dwell times, coverage, and eventually compare region occupancy
--     against real esports data.
--
-- Dwell time is the first honest diagnostic for "are these bots using the map,
-- or pacing one corner".

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Zones = require(Shared.MapData.Zones)
local Scenario = require(Shared.Constants.Scenario)

export type Sample = {
	t: number,
	x: number,
	y: number,
	z: number,
	zone: string,
	intent: string,
}

export type Track = {
	name: string,
	side: string,
	samples: { Sample },
	zoneKey: string,
	zoneSince: number,
	dwell: { [string]: number },
	transitions: number,
	intent: string,
	dropped: number,
}

local Telemetry = {}

local START = os.clock()
local tracks: { [string]: Track } = {}
local order: { string } = {}

local function now(): number
	return os.clock() - START
end

local function shortSide(side: string): string
	return if side == "Attack" then "ATK" else "DEF"
end

-- The brain calls this so zone transitions can be attributed to a decision.
function Telemetry.setIntent(botName: string, intent: string)
	local track = tracks[botName]
	if track then
		track.intent = intent
	end
end

function Telemetry.note(botName: string, message: string)
	local track = tracks[botName]
	local side = if track then shortSide(track.side) else "???"
	print(("[CLUTCH] %6.1fs  %s (%s) %s"):format(now(), botName, side, message))
end

function Telemetry.attach(bot: any, side: string)
	local model = bot.model :: Model
	local humanoid = model:FindFirstChildOfClass("Humanoid")

	local track: Track = {
		name = bot.name,
		side = side,
		samples = {},
		zoneKey = Zones.VOID,
		zoneSince = now(),
		dwell = {},
		transitions = 0,
		intent = "-",
		dropped = 0,
	}
	tracks[bot.name] = track
	table.insert(order, bot.name)

	task.spawn(function()
		while model.Parent and (not humanoid or humanoid.Health > 0) do
			local ground = Zones.groundOf(model)
			local zone = Zones.at(ground)
			local key = if zone then zone.key else Zones.VOID
			local t = now()

			if #track.samples < Scenario.TelemetryMaxSamples then
				table.insert(track.samples, {
					t = t,
					x = ground.X,
					y = ground.Y,
					z = ground.Z,
					zone = key,
					intent = track.intent,
				})
			else
				track.dropped += 1
			end

			if key ~= track.zoneKey then
				local previous = track.zoneKey
				local held = t - track.zoneSince
				track.dwell[previous] = (track.dwell[previous] or 0) + held
				track.zoneKey = key
				track.zoneSince = t
				track.transitions += 1

				if Scenario.LogZoneTransitions and previous ~= Zones.VOID then
					local fromZone = Zones.byKey[previous]
					local fromName = if fromZone then fromZone.callout else "Off-map"
					local toName = if zone then zone.callout else "Off-map"
					print(("[CLUTCH] %6.1fs  MOVE %s (%s) | %s -> %s | held %.1fs | intent %s"):format(
						t,
						track.name,
						shortSide(track.side),
						fromName,
						toName,
						held,
						track.intent
					))
				end
			end

			task.wait(Scenario.TelemetrySampleSeconds)
		end
	end)
end

local function topZones(track: Track, count: number): string
	-- Fold in the zone currently occupied so the summary is not stale
	local dwell = table.clone(track.dwell)
	dwell[track.zoneKey] = (dwell[track.zoneKey] or 0) + (now() - track.zoneSince)

	local pairsList = {}
	for key, seconds in dwell do
		table.insert(pairsList, { key = key, seconds = seconds })
	end
	table.sort(pairsList, function(a, b)
		return a.seconds > b.seconds
	end)

	local parts = {}
	for index = 1, math.min(count, #pairsList) do
		local entry = pairsList[index]
		local zone = Zones.byKey[entry.key]
		local label = if zone then zone.callout else entry.key
		table.insert(parts, ("%s %.0fs"):format(label, entry.seconds))
	end
	return table.concat(parts, ", ")
end

function Telemetry.report()
	print(("[CLUTCH] ===== telemetry @ %.0fs ====="):format(now()))
	for _, name in order do
		local track = tracks[name]
		if not track then
			continue
		end
		local visited = 0
		for _ in track.dwell do
			visited += 1
		end
		print(("[CLUTCH]   %s (%s) | %d moves, %d zones seen | %s"):format(
			track.name,
			shortSide(track.side),
			track.transitions,
			visited,
			topZones(track, 4)
		))
	end

	-- Coverage: which named areas has NOBODY set foot in? Unvisited chokes are
	-- usually a pathing hole or a zone whose bounds are wrong.
	local touched: { [string]: boolean } = {}
	for _, track in tracks do
		for key in track.dwell do
			touched[key] = true
		end
		touched[track.zoneKey] = true
	end
	local missing = {}
	for _, zone in Zones.list do
		if not touched[zone.key] then
			table.insert(missing, zone.callout)
		end
	end
	if #missing > 0 then
		print(("[CLUTCH]   never visited (%d): %s"):format(#missing, table.concat(missing, ", ")))
	else
		print("[CLUTCH]   full map coverage")
	end
end

function Telemetry.startReporting()
	if Scenario.TelemetryReportSeconds <= 0 then
		return
	end
	task.spawn(function()
		while true do
			task.wait(Scenario.TelemetryReportSeconds)
			Telemetry.report()
		end
	end)
end

-- Raw trace, chunked because Studio's Output truncates very long lines.
-- Paste into a file if you want to plot it.
function Telemetry.dumpTrace(botName: string, chunkSize: number?)
	local track = tracks[botName]
	if not track then
		warn(("[CLUTCH] no telemetry track for %s"):format(botName))
		return
	end
	local size = chunkSize or 40
	print(("[CLUTCH] trace %s: %d samples (%d dropped)"):format(track.name, #track.samples, track.dropped))
	local buffer = {}
	for index, sample in track.samples do
		table.insert(buffer, ("%.2f,%.1f,%.1f,%.1f,%s,%s"):format(
			sample.t,
			sample.x,
			sample.y,
			sample.z,
			sample.zone,
			sample.intent
		))
		if #buffer >= size or index == #track.samples then
			print(table.concat(buffer, " | "))
			buffer = {}
		end
	end
end

function Telemetry.tracks(): { [string]: Track }
	return tracks
end

return Telemetry
