--!strict
-- Animations: REAL AnimationTracks with zero asset uploads. Every clip is a
-- runtime-built KeyframeSequence, registered in-session via
-- KeyframeSequenceProvider:RegisterKeyframeSequence — the ids it returns are
-- session-local, which is fine: the sim lives and dies in one session.
--
-- This is batch D phase 1 (playtest #21's "walk animation not to be found").
-- The old procedural Motor6D.Transform loop is RETIRED — it was fighting the
-- rig's joint updates and never read. Now the Animator owns the joints, the
-- way real FPS rigs work:
--
--   idle   (Movement, loop)  — a subtle breathe.
--   walk   (Movement, loop)  — legs/arms swing; playback speed scales with
--                              ground speed.
--   crouch (Movement, hold)  — knees bent, torso forward; Combat toggles it
--                              alongside the HipHeight drop.
--   aim    (Action, hold)    — the gun arm held forward. ACTION priority rides
--                              OVER locomotion, so the arm never swings wild
--                              mid-stride. This is the trick that makes
--                              gun-carry readable on a moving rig.
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

-- One keyframe = a full pose tree (identity where unset, so joints never
-- drift between keyframes).
local function keyframe(time: number, joints: { [string]: CFrame }): Keyframe
	local kf = Instance.new("Keyframe")
	kf.Time = time
	local poses: { [string]: Pose } = {}
	for name in R15_TREE do
		local p = Instance.new("Pose")
		p.Name = name
		p.CFrame = joints[name] or CFrame.new()
		p.EasingStyle = Enum.PoseEasingStyle.Linear
		p.EasingDirection = Enum.PoseEasingDirection.InOut
		poses[name] = p
	end
	for name, parentName in R15_TREE do
		if parentName then
			poses[name].Parent = poses[parentName]
		else
			poses[name].Parent = kf -- the root pose rides the keyframe
		end
	end
	return kf
end

local function buildClip(name: string, looped: boolean, frames: { Keyframe }): Animation?
	local sequence = Instance.new("KeyframeSequence")
	sequence.Name = name
	sequence.Loop = looped
	sequence.Priority = Enum.AnimationPriority.Movement -- track priority is set on the TRACK; this is a fallback
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
local LEG_SWING = 32
local ARM_SWING = 22

local clips: { [string]: Animation? } = {}
do
	clips.walk = buildClip("ClutchWalk", true, {
		keyframe(0, {
			LeftUpperLeg = deg(-LEG_SWING),
			RightUpperLeg = deg(LEG_SWING),
			LeftLowerLeg = deg(24), -- the trailing knee bends
			RightLowerLeg = deg(6),
			LeftUpperArm = deg(ARM_SWING),
			RightUpperArm = deg(-ARM_SWING),
			UpperTorso = deg(2),
		}),
		keyframe(0.25, {
			LeftUpperLeg = deg(LEG_SWING),
			RightUpperLeg = deg(-LEG_SWING),
			LeftLowerLeg = deg(6),
			RightLowerLeg = deg(24),
			LeftUpperArm = deg(-ARM_SWING),
			RightUpperArm = deg(ARM_SWING),
			UpperTorso = deg(2),
		}),
		keyframe(0.5, {
			LeftUpperLeg = deg(-LEG_SWING),
			RightUpperLeg = deg(LEG_SWING),
			LeftLowerLeg = deg(24),
			RightLowerLeg = deg(6),
			LeftUpperArm = deg(ARM_SWING),
			RightUpperArm = deg(-ARM_SWING),
			UpperTorso = deg(2),
		}),
	})

	clips.idle = buildClip("ClutchIdle", true, {
		keyframe(0, { UpperTorso = deg(1.5), LeftUpperArm = deg(1), LeftLowerArm = deg(-3) }),
		keyframe(1.1, { UpperTorso = deg(-1), LeftUpperArm = deg(-1), LeftLowerArm = deg(-5) }),
		keyframe(2.2, { UpperTorso = deg(1.5), LeftUpperArm = deg(1), LeftLowerArm = deg(-3) }),
	})

	-- The crouch is a HELD pose: one keyframe, looped. Combat's HipHeight
	-- drop lowers the rig; this bends the legs so it READS as a crouch.
	clips.crouch = buildClip("ClutchCrouch", true, {
		keyframe(0, {
			LeftUpperLeg = deg(-52),
			RightUpperLeg = deg(-52),
			LeftLowerLeg = deg(74),
			RightLowerLeg = deg(74),
			UpperTorso = deg(14),
		}),
	})

	-- The gun-carry pose at ACTION priority: rides over walk/idle/crouch on
	-- the right arm chain only. The arm stays up no matter what the legs do.
	clips.aim = buildClip("ClutchAim", true, {
		keyframe(0, {
			RightUpperArm = deg(78), -- shoulder: arm forward
			RightLowerArm = deg(-12), -- slight elbow bend
		}),
	})
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

	local rig: Rig = {
		animator = animator,
		walk = loadTrack(animator, clips.walk, Enum.AnimationPriority.Movement),
		idle = loadTrack(animator, clips.idle, Enum.AnimationPriority.Movement),
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
