--!strict
-- Shared pathing helpers. Every bot movement goes through here.
--
-- Hard-won lessons from the first playtest:
--   * The navmesh needs a beat to bake after the arena builds at runtime —
--     ComputeAsync can fail on frame one. Retry with a short wait.
--   * NEVER fail silently. A bot that can't path is a bug we want loud.

local PathfindingService = game:GetService("PathfindingService")

local Pathing = {}

local MAX_RETRIES = 3
local WAYPOINT_TIMEOUT = 4 -- seconds before we call a waypoint "stuck"

function Pathing.walkTo(bot: Model, target: Vector3): boolean
	local humanoid = bot:FindFirstChildOfClass("Humanoid")
	local root = bot:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return false
	end

	local path = PathfindingService:CreatePath({
		AgentHeight = 5,
		AgentRadius = 2,
		AgentCanJump = true,
		WaypointSpacing = 4,
	})

	local computed = false
	for attempt = 1, MAX_RETRIES do
		local ok = pcall(function()
			path:ComputeAsync(root.Position, target)
		end)
		if ok and path.Status == Enum.PathStatus.Success then
			computed = true
			break
		end
		task.wait(0.4 * attempt) -- navmesh warmup / transient geometry
	end

	if not computed then
		warn(("[CLUTCH] PATH FAILED: %s -> %s"):format(bot.Name, tostring(target)))
		return false
	end

	for _, waypoint in ipairs(path:GetWaypoints()) do
		if humanoid.Health <= 0 then
			return false
		end
		humanoid:MoveTo(waypoint.Position)
		local reached = humanoid.MoveToFinished:Wait(WAYPOINT_TIMEOUT)
		if not reached then
			warn(("[CLUTCH] STUCK: %s en route to waypoint %s"):format(bot.Name, tostring(waypoint.Position)))
			return false
		end
	end
	return true
end

return Pathing
