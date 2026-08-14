--!strict
-- Builds the arena at runtime from a MapSpec. The map lives in data
-- (Shared/MapData), so iterating on the map never touches Studio.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local Greybox = require(Shared.MapData.Greybox)

local MapBuilder = {}

local function buildPart(spec: Greybox.PartSpec): Part
	local part = Instance.new("Part")
	part.Name = spec.name
	part.Anchored = true
	part.Size = spec.size

	-- Rotation is optional and only used by ramps. Euler degrees -> CFrame.
	local cf = CFrame.new(spec.pos)
	if spec.rot then
		cf = cf
			* CFrame.Angles(
				math.rad(spec.rot.X),
				math.rad(spec.rot.Y),
				math.rad(spec.rot.Z)
			)
	end
	part.CFrame = cf

	part.Color = spec.color or Color3.fromRGB(110, 110, 120)
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

function MapBuilder.build(mapSpec: Greybox.MapSpec): Folder
	-- Rebuild cleanly on hot-reload
	local existing = workspace:FindFirstChild("Arena")
	if existing then
		existing:Destroy()
	end

	local arena = Instance.new("Folder")
	arena.Name = "Arena"

	local rampCount = 0
	for _, spec in ipairs(mapSpec.parts) do
		if spec.rot then
			rampCount += 1
		end
		buildPart(spec).Parent = arena
	end

	-- Plant zones as glowing pads (logic hooks come with the round machine)
	for _, zone in ipairs(mapSpec.plantZones) do
		local pad = Instance.new("Part")
		pad.Name = zone.name
		pad.Anchored = true
		pad.CanCollide = false
		pad.Size = zone.size
		pad.CFrame = CFrame.new(zone.pos)
		pad.Color = zone.color
		pad.Material = Enum.Material.Neon
		pad.Transparency = 0.6
		pad.Parent = arena
	end

	arena.Parent = workspace
	print(("[CLUTCH] arena built: %d parts (%d ramps), %d plant zones, %d POIs"):format(
		#mapSpec.parts,
		rampCount,
		#mapSpec.plantZones,
		#mapSpec.pois
	))
	return arena
end

return MapBuilder
