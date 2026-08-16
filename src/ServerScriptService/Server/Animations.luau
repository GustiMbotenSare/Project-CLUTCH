--!strict
-- Animations: REAL AnimationTracks with zero asset uploads. Every clip is a
-- runtime-built KeyframeSequence, registered in-session via
-- KeyframeSequenceProvider:RegisterKeyframeSequence — the ids it returns are
-- session-local, which is fine: the sim lives and dies in one session.
--
--   idle   (Idle, loop)      — a subtle breathe. LOWEST priority: walk owns
--                              Movement, so idle never fights it for joints.
--   walk   (Movement, loop)  — legs/left arm swing; playback speed scales
--                              with ground speed.
--   crouch (Movement, hold)  — knees bent, torso forward; Combat toggles it
--                              alongside the HipHeight drop.
--   aim    (Action, hold)    — the gun arm held forward, over everything.
--
-- THE SPARSE RULE (playtest #22 → #23): EVERY clip poses only the joints it
-- means to move. The phase-1 bug was the aim clip's FULL pose tree stomping
-- locomotion at Action priority; #23's "still rigid" showed the mirror
-- failure — full-tree Movement clips (idle AND walk both posing every joint
-- at the same priority) left the legs' ownership ambiguous. Now: sparse
-- chains everywhere, and priorities are a ladder (Idle < Movement < Action)
-- instead of a fistfight. The aim clip (proven: the arms went up in #23) is
-- the shape every clip follows.
--
-- attach(model) per body — playing tracks don't survive a Clone, so the
-- round machine re-attaches every round. The default Animate script is
-- destroyed where present: it would fight our tracks for the joints.
--
-- Cosmetic layer: if registration fails, attach() no-ops with a warn and the
-- sim runs on unanimated rigs — animation never gates behavior.

local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")

local Animations = {}

-- The R15 Motor6D hierarchy. Pose trees must mirror it: the Animator matches
-- Poses to joints BY NAME, parented the same way.
local R15_TREE: { [string]: string? } = {
	HumanoidRootPart = nil,
	LowerTorso = "HumanoidRootPart",
	UpperTorso = "LowerTorso",
	Head = "UpperTorso",
	LeftUpperArm = "UpperTorso",
	LeftLowerArm = "LeftUpperArm",
	LeftHand = "LeftLowerArm",
	RightUpperArm = "UpperTorso",
	RightLowerArm = "RightUpperArm",
	RightHand = "RightLowerArm",
	LeftUpperLeg = "LowerTorso",
	LeftLowerLeg = "LeftUpperLeg",
	LeftFoot = "LeftLowerLeg",
	RightUpperLeg = "LowerTorso",
	RightLowerLeg = "RightUpperLeg",
	RightFoot = "RightLowerLeg",
}

local function deg(x: number, y: number?, z: number?): CFrame
	return CFrame.Angles(math.rad(x), math.rad(y or 0), math.rad(z or 0))
end

local function makePose(name: string, cf: CFrame?): Pose
	local p = Instance.new("Pose")
	p.Name = name
	p.CFrame = cf or CFrame.new()
	p.EasingStyle = Enum.PoseEasingStyle.Linear
	p.EasingDirection = Enum.PoseEasingDirection.InOut
	return p
end

-- SPARSE keyframes ONLY: pose the listed joints plus the ancestor chain
-- needed to connect them to the root. A track overrides exactly the joints
-- it poses — nothing more. (The full-tree keyframe builder is gone: it was
-- the source of both the bind-pose glide and the joint-ownership ambiguity.)
local function keyframeSparse(time: number, joints: { [string]: CFrame }): Keyframe
	local kf = Instance.new("Keyframe")
	kf.Time = time
	local include: { [string]: boolean } = {}
	for name in joints do
		local current: string? = name
		while current and not include[current] do
			include[current] = true
			current = R15_TREE[current]
		end
	end
	local poses: { [string]: Pose } = {}
	for name in include do
		poses[name] = makePose(name, joints[name])
	end
	for name in include do
		local parentName = R15_TREE[name]
		if parentName and poses[parentName] then
			poses[name].Parent = poses[parentName]
		else
			poses[name].Parent = kf
		end
	end
	return kf
end

local function buildClip(name: string, looped: boolean, frames: { Keyframe }): Animation?
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = name
	sequence.Loop = looped
	for _, kf in frames do
		kf.Parent = sequence
	end
	local ok, assetId = pcall(function()
		return KeyframeSequenceProvider:RegisterKeyframeSequence(sequence)
	end)
	if not ok then
		warn(("[CLUTCH] animation %s failed to register: %s"):format(name, tostring(assetId)))
		return nil
	end
	local animation = Instance.new("Animation")
	animation.Name = name
	animation.AnimationId = assetId
	return animation
end

-- ---------------------------------------------------------------- CLIPS
-- Sign convention: +X on a limb joint pitches it forward/down (matches the
-- old GUN_ARM_RAISED shoulder pose that already read correctly).
local LEG_SWING = 40 -- big enough to read at spectator distance
local ARM_SWING = 25

local clips: { [string]: Animation? } = {}
do
	clips.walk = buildClip("ClutchWalk", true, {
		keyframeSparse(0, {
			LeftUpperLeg = deg(-LEG_SWING),
			RightUpperLeg = deg(LEG_SWING),
			LeftLowerLeg = deg(28), -- the trailing knee bends
			RightLowerLeg = deg(8),
			LeftUpperArm = deg(ARM_SWING),
			LeftLowerArm = deg(-6),
			UpperTorso = deg(3),
		}),
		keyframeSparse(0.25, {
			LeftUpperLeg = deg(LEG_SWING),
			RightUpperLeg = deg(-LEG_SWING),
			LeftLowerLeg = deg(8),
			RightLowerLeg = deg(28),
			LeftUpperArm = deg(-ARM_SWING),
			LeftLowerArm = deg(-6),
			UpperTorso = deg(3),
		}),
		keyframeSparse(0.5, {
			LeftUpperLeg = deg(-LEG_SWING),
			RightUpperLeg = deg(LEG_SWING),
			LeftLowerLeg = deg(28),
			RightLowerLeg = deg(8),
			LeftUpperArm = deg(ARM_SWING),
			LeftLowerArm = deg(-6),
			UpperTorso = deg(3),
		}),
	})

	clips.idle = buildClip("ClutchIdle", true, {
		keyframeSparse(0, { UpperTorso = deg(1.5), LeftUpperArm = deg(1), LeftLowerArm = deg(-3) }),
		keyframeSparse(1.1, { UpperTorso = deg(-1), LeftUpperArm = deg(-1), LeftLowerArm = deg(-5) }),
		keyframeSparse(2.2, { UpperTorso = deg(1.5), LeftUpperArm = deg(1), LeftLowerArm = deg(-3) }),
	})

	-- The crouch is a HELD pose: one keyframe, looped. Combat's HipHeight
	-- drop lowers the rig; this bends the legs so it READS as a crouch.
	clips.crouch = buildClip("ClutchCrouch", true, {
		keyframeSparse(0, {
			LeftUpperLeg = deg(-52),
			RightUpperLeg = deg(-52),
			LeftLowerLeg = deg(74),
			RightLowerLeg = deg(74),
			UpperTorso = deg(14),
		}),
	})

	-- The gun-carry pose at ACTION priority: only the right-arm chain, so it
	-- rides over walk/idle/crouch instead of freezing the rig (proven in #23).
	clips.aim = buildClip("ClutchAim", true, {
		keyframeSparse(0, {
			RightUpperArm = deg(78), -- shoulder: arm forward
			RightLowerArm = deg(-12), -- slight elbow bend
		}),
	})

	-- Boot-log truth: which clips actually registered this session.
	local registered = {}
	for name, clip in clips do
		if clip then
			table.insert(registered, name)
		end
	end
	table.sort(registered)
	print(("[CLUTCH] animations registered: %s"):format(table.concat(registered, " ")))
end

-- ------------------------------------------------------------- PLAYBACK
type Rig = {
	animator: Animator,
	walk: AnimationTrack?,
	idle: AnimationTrack?,
	crouch: AnimationTrack?,
	aim: AnimationTrack?,
	crouched: boolean,
}

local rigs: { [Model]: Rig } = {}

local function loadTrack(animator: Animator, clip: Animation?, priority: Enum.AnimationPriority): AnimationTrack?
	if not clip then
		return nil
	end
	local ok, track = pcall(function()
		return animator:LoadAnimation(clip)
	end)
	if not ok then
		warn(("[CLUTCH] animation track failed to load: %s"):format(clip.Name))
		return nil
	end
	track.Priority = priority
	track.Looped = true
	return track
end

-- Attach the animation set to a body. Idempotent per model; called per round
-- because playing tracks don't survive a Clone.
function Animations.attach(model: Model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	-- The stock Animate script would fight our tracks for the joints.
	local stock = model:FindFirstChild("Animate")
	if stock then
		stock:Destroy()
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	-- The priority ladder: Idle (lowest) < Movement (walk/crouch) < Action (aim).
	local rig: Rig = {
		animator = animator,
		walk = loadTrack(animator, clips.walk, Enum.AnimationPriority.Movement),
		idle = loadTrack(animator, clips.idle, Enum.AnimationPriority.Idle),
		crouch = loadTrack(animator, clips.crouch, Enum.AnimationPriority.Movement),
		aim = loadTrack(animator, clips.aim, Enum.AnimationPriority.Action),
		crouched = false,
	}
	rigs[model] = rig

	-- The gun arm is always up; the idle always breathes.
	if rig.aim then
		rig.aim:Play(0.1)
	end
	if rig.idle then
		rig.idle:Play(0.1)
	end

	-- The locomotion driver: swap walk in/out with ground speed, scale its
	-- playback rate to match. Dies with the body or the health.
	task.spawn(function()
		while model.Parent do
			local humanoidNow = model:FindFirstChildOfClass("Humanoid")
			if not humanoidNow or humanoidNow.Health <= 0 then
				break
			end
			local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			local speed = if root then root.AssemblyLinearVelocity.Magnitude else 0
			local moving = speed > 2
			if rig.walk and moving and not rig.crouched then
				if not rig.walk.IsPlaying then
					rig.walk:Play(0.12)
				end
				rig.walk:AdjustSpeed(math.clamp(speed / 16, 0.6, 1.6))
				if rig.idle and rig.idle.IsPlaying then
					rig.idle:Stop(0.12)
				end
			else
				if rig.walk and rig.walk.IsPlaying then
					rig.walk:Stop(0.12)
				end
				if rig.idle and not rig.idle.IsPlaying and not rig.crouched then
					rig.idle:Play(0.12)
				end
			end
			task.wait(0.15)
		end
		for _, track in { rig.walk, rig.idle, rig.crouch, rig.aim } do
			if track and track.IsPlaying then
				track:Stop(0)
			end
		end
		if rigs[model] == rig then
			rigs[model] = nil
		end
	end)
end

-- Combat calls this alongside the HipHeight drop: the legs bend so the
-- spread-discipline crouch READS as a crouch.
function Animations.setCrouched(model: Model, crouched: boolean)
	local rig = rigs[model]
	if not rig then
		return
	end
	rig.crouched = crouched
	if crouched then
		if rig.walk and rig.walk.IsPlaying then
			rig.walk:Stop(0.1)
		end
		if rig.idle and rig.idle.IsPlaying then
			rig.idle:Stop(0.1)
		end
		if rig.crouch then
			rig.crouch:Play(0.1)
		end
	else
		if rig.crouch and rig.crouch.IsPlaying then
			rig.crouch:Stop(0.15)
		end
		-- the driver loop resumes idle/walk on its next tick
	end
end

return Animations
