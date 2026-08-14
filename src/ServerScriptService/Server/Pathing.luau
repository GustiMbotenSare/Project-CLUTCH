--!strict
-- Shared pathing helpers. Every bot movement goes through here.
--
-- Hard-won lessons from playtests #1 and #2:
--   * The navmesh needs a beat to bake after the arena builds at runtime —
--     ComputeAsync can fail on frame one. Retry with a short wait.
--   * AgentCanJump must stay FALSE. With jumping enabled the pathfinder
--     happily routes over 4-stud half-cover, which is both tactically wrong
--     and a guaranteed stall unless Humanoid.Jump is driven manually.
--   * Never wait for MoveToFinished per waypoint — that full-stops the bot at
--     every node and reads as janky. Advance on proximity instead.
--   * Ten bots crowding one stud body-block each other. Sidestep + repath.

local PathfindingService = game:GetService("PathfindingService")

local Pathing = {}

local MAX_COMPUTE_RETRIES = 3
local MAX_REPATHS = 1
local ARRIVE_RADIUS = 4.5 -- advance to the next waypoint when this close
local FINAL_RADIUS = 3.5 -- "close enough" for the destination
local STUCK_WINDOW = 1.5 -- seconds without progress before we call it stuck
local STUCK_EPSILON = 1.2 -- studs of movement that counts as progress
local TICK = 0.1

local AGENT_PARAMS = {
	AgentHeight = 5,
	AgentRadius = 2.5, -- a touch wider than the rig: keeps paths off corners
	AgentCanJump = false, -- walk around cover, never hop it
	WaypointSpacing = 4,
}

local function compute(fromPos: Vector3, target: Vector3): Path?
	local path = PathfindingService:CreatePath(AGENT_PARAMS)
	for attempt = 1, MAX_COMPUTE_RETRIES do
		local ok = pcall(function()
			path:ComputeAsync(fromPos, target)
		end)
		if ok and path.Status == Enum.PathStatus.Success then
			return path
		end
		task.wait(0.25 * attempt) -- navmesh warmup / transient geometry
	end
	return nil
end

-- Walks the bot to `target`. Returns true only if it actually arrived.
function Pathing.walkTo(bot: Model, target: Vector3): boolean
	local humanoid = bot:FindFirstChildOfClass("Humanoid")
	local root = bot:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root or humanoid.Health <= 0 then
		return false
	end

	for attempt = 0, MAX_REPATHS do
		local path = compute(root.Position, target)

		if not path then
			if attempt == MAX_REPATHS then
				warn(("[CLUTCH] PATH FAILED: %s -> %.0f, %.0f, %.0f"):format(
					bot.Name,
					target.X,
					target.Y,
					target.Z
				))
				return false
			end
		else
			local waypoints = path:GetWaypoints()
			local index = 2 -- waypoint 1 is where we already stand
			local lastPos = root.Position
			local lastProgress = os.clock()
			local blocked = false

			while index <= #waypoints do
				if humanoid.Health <= 0 or not bot.Parent then
					return false
				end

				local waypoint = waypoints[index]
				humanoid:MoveTo(waypoint.Position)
				if waypoint.Action == Enum.PathWaypointAction.Jump then
					humanoid.Jump = true -- only fires if jumping is ever re-enabled
				end

				local radius = if index == #waypoints then FINAL_RADIUS else ARRIVE_RADIUS
				if (root.Position - waypoint.Position).Magnitude <= radius then
					-- Advance without stopping: this is what makes movement smooth
					index += 1
					lastPos = root.Position
					lastProgress = os.clock()
				elseif (root.Position - lastPos).Magnitude > STUCK_EPSILON then
					lastPos = root.Position
					lastProgress = os.clock()
				elseif os.clock() - lastProgress > STUCK_WINDOW then
					blocked = true
					break
				end

				task.wait(TICK)
			end

			if not blocked then
				return true
			end

			-- Crowding is the usual culprit: sidestep, then try a fresh path
			local sidestep = Vector3.new(math.random(-6, 6), 0, math.random(-6, 6))
			humanoid:MoveTo(root.Position + sidestep)
			task.wait(0.4)
		end
	end

	warn(("[CLUTCH] BLOCKED: %s gave up en route to %.0f, %.0f, %.0f"):format(
		bot.Name,
		target.X,
		target.Y,
		target.Z
	))
	return false
end

return Pathing
