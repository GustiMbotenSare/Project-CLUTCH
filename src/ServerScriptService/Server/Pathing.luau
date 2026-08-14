--!strict
-- Shared pathing helpers. Every bot movement goes through here.
--
-- Hard-won lessons from playtests #1-#8:
--   * The navmesh needs a beat to bake after the arena builds at runtime —
--     ComputeAsync can fail on frame one. Retry with a short wait.
--   * AgentCanJump must stay FALSE. With jumping enabled the pathfinder
--     happily routes over 4-stud half-cover, which is both tactically wrong
--     and a guaranteed stall unless Humanoid.Jump is driven manually.
--   * Never wait for MoveToFinished per waypoint — that full-stops the bot at
--     every node and reads as janky. Advance on proximity instead.
--   * Never RE-ISSUE MoveTo for the waypoint we are already walking to. Every
--     MoveTo call re-plans the humanoid's immediate motion; spamming it every
--     tick is what made movement look like a laggy stop-motion puppet even
--     after proximity advance landed. MoveTo fires when the target CHANGES.
--   * Measure progress on the horizontal plane. Ramps move bots vertically,
--     and 3D distance to a waypoint on a deck above reads as "no progress".
--   * AgentRadius 2.5 was too fat for the 6-stud short doors: the path
--     computed fine, but the rig scraped the doorframe until the stuck timer
--     gave up (the playtest #8 BLOCKED spam at the A Short door). 2.2 still
--     keeps paths off corners without demanding centimeter-perfect threading.
--   * Ten bots crowding one stud body-block each other. Sidestep + repath.
--   * A walk must be INTERRUPTIBLE. Blocking until arrival meant a bot that
--     spotted an enemy could not react until it finished walking, which is why
--     bots looked oblivious even with working line of sight.

local PathfindingService = game:GetService("PathfindingService")

local Pathing = {}

local MAX_COMPUTE_RETRIES = 3
local MAX_REPATHS = 1
local ARRIVE_RADIUS = 4.0 -- advance to the next waypoint when this close (XZ)
local FINAL_RADIUS = 3.0 -- "close enough" for the destination (XZ)
local STUCK_WINDOW = 1.5 -- seconds without progress before we call it stuck
local STUCK_EPSILON = 1.2 -- studs of movement that counts as progress
local TICK = 0.05

local AGENT_PARAMS = {
	AgentHeight = 5,
	AgentRadius = 2.2, -- 2.5 scraped the 6-stud short doors into stuck-loops
	AgentCanJump = false, -- walk around cover, never hop it
	WaypointSpacing = 4,
}

export type WalkResult = "arrived" | "aborted" | "failed"

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

local function planarDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Walks the bot to `target`.
--
-- `shouldAbort` is polled every tick; return true from it to stop the walk
-- immediately. This is how combat interrupts movement.
function Pathing.walkToWithResult(bot: Model, target: Vector3, shouldAbort: (() -> boolean)?): WalkResult
	local humanoid = bot:FindFirstChildOfClass("Humanoid")
	local root = bot:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not humanoid or not root or humanoid.Health <= 0 then
		return "failed"
	end

	local function aborting(): boolean
		return shouldAbort ~= nil and shouldAbort()
	end

	-- Check before spending a ComputeAsync on a walk we are about to cancel
	if aborting() then
		return "aborted"
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
				return "failed"
			end
		else
			local waypoints = path:GetWaypoints()
			local index = 2 -- waypoint 1 is where we already stand
			local lastPos = root.Position
			local lastProgress = os.clock()
			local issuedTo: Vector3? = nil
			local blocked = false

			while index <= #waypoints do
				if humanoid.Health <= 0 or not bot.Parent then
					return "failed"
				end

				if aborting() then
					humanoid:MoveTo(root.Position) -- plant feet where they are
					return "aborted"
				end

				local waypoint = waypoints[index]

				-- Corner cutting: close enough to a mid-path waypoint means we can
				-- already aim for the next one. The bot never decelerates for nodes
				-- it is merely passing.
				local radius = if index == #waypoints then FINAL_RADIUS else ARRIVE_RADIUS
				if planarDistance(root.Position, waypoint.Position) <= radius then
					index += 1
					lastPos = root.Position
					lastProgress = os.clock()
					continue
				end

				-- The whole smoothness fix: only re-issue MoveTo when the TARGET
				-- changes. Re-issuing every tick made the humanoid stutter.
				if issuedTo ~= waypoint.Position then
					humanoid:MoveTo(waypoint.Position)
					issuedTo = waypoint.Position
					if waypoint.Action == Enum.PathWaypointAction.Jump then
						humanoid.Jump = true -- only fires if jumping is ever re-enabled
					end
				end

				if planarDistance(root.Position, lastPos) > STUCK_EPSILON then
					lastPos = root.Position
					lastProgress = os.clock()
				elseif os.clock() - lastProgress > STUCK_WINDOW then
					blocked = true
					break
				end

				task.wait(TICK)
			end

			if not blocked then
				return "arrived"
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
	return "failed"
end

-- Returns true only if the bot actually arrived. Kept for callers that do not
-- care why a walk ended (Patrol, ShootingRange).
function Pathing.walkTo(bot: Model, target: Vector3, shouldAbort: (() -> boolean)?): boolean
	return Pathing.walkToWithResult(bot, target, shouldAbort) == "arrived"
end

return Pathing
