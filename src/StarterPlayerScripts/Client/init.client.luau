-- Project CLUTCH — spectator dashboard v0.7
--
-- The first piece of the M1 broadcast package: what a real esports observer
-- sees, reduced to what the sim can honestly report right now.
--
--   * Top bar     — team names with alive counts, ROUND number, phase and
--                   clock, the score, and a SPIKE DOWN callout when planted.
--   * Player cards — name, role, INVENTORY (every weapon they own), live HP
--                    bar, current zone callout WITH walk/sprint mode (the
--                    shift-walk is a decision; show it), the bot's CURRENT
--                    INTENT, K / D / HS and credits. Attackers left,
--                    defenders right. Click a card to put the camera on it.
--   * Kill feed   — killer, victim, headshot flag, distance, weapon.
--
-- Controls: click a card to spectate it · C releases the camera ·
-- Tab or the CLUTCH button toggles the overlay.
--
-- Data path: Telemetry stamps every bot model with replicated attributes at
-- 4Hz (Zone, Intent, Alive, Kills, Deaths, Headshots, Credits, Inventory,
-- Speed), RoundMachine mirrors match state as attributes on the CLUTCH folder
-- (Phase, TimeLeft, Round, AtkScore, DefScore, Planted), and KillFeed fires
-- per death. The client polls plain attributes — no per-frame remote traffic,
-- no desync.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local remotes = ReplicatedStorage:WaitForChild("CLUTCH")
local killFeed = remotes:WaitForChild("KillFeed")

print("[CLUTCH] client online — spectator dashboard v0.7")

local ATK_COLOR = Color3.fromRGB(255, 150, 60)
local DEF_COLOR = Color3.fromRGB(80, 200, 255)
local PANEL = Color3.fromRGB(16, 18, 24)
local PANEL_DEAD = Color3.fromRGB(40, 40, 46)
local TEXT = Color3.fromRGB(232, 232, 238)
local SUBTEXT = Color3.fromRGB(150, 152, 162)
local HP_GREEN = Color3.fromRGB(90, 210, 110)
local HP_RED = Color3.fromRGB(235, 70, 70)
local SPIKE_COLOR = Color3.fromRGB(255, 85, 85)

local INTENT_COLORS = {
	Hold = Color3.fromRGB(120, 130, 150),
	Push = Color3.fromRGB(255, 170, 80),
	Rotate = Color3.fromRGB(180, 130, 255),
	Lurk = Color3.fromRGB(90, 200, 200),
	FallBack = Color3.fromRGB(240, 120, 80),
	Engage = Color3.fromRGB(255, 85, 85),
	Plant = Color3.fromRGB(255, 210, 90),
	Defuse = Color3.fromRGB(120, 180, 255),
}

local gui = Instance.new("ScreenGui")
gui.Name = "ClutchHUD"
gui.ResetOnSpawn = false
gui.Parent = playerGui

local function round(frame: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = frame
end

local function makeText(parent: GuiObject, name: string, text: string, size: number, bold: boolean, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextSize = size
	label.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = parent
	return label
end

-- ---------------------------------------------------------------- TOP BAR
local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.fromOffset(560, 44)
topBar.Position = UDim2.new(0.5, -280, 0, 8)
topBar.BackgroundColor3 = PANEL
topBar.BackgroundTransparency = 0.2
topBar.BorderSizePixel = 0
topBar.Parent = gui
round(topBar, 8)

local atkTitle = makeText(topBar, "AtkTitle", "ATTACK", 16, true, ATK_COLOR)
atkTitle.Size = UDim2.fromOffset(120, 20)
atkTitle.Position = UDim2.fromOffset(16, 5)
local atkAlive = makeText(topBar, "AtkAlive", "", 12, false, SUBTEXT)
atkAlive.Size = UDim2.fromOffset(120, 16)
atkAlive.Position = UDim2.fromOffset(16, 24)

local title = makeText(topBar, "Title", "PROJECT CLUTCH", 14, true, TEXT)
title.Size = UDim2.fromOffset(240, 20)
title.Position = UDim2.new(0.5, -120, 0, 5)
title.TextXAlignment = Enum.TextXAlignment.Center
local subtitle = makeText(topBar, "Subtitle", "", 11, false, SUBTEXT)
subtitle.Size = UDim2.fromOffset(240, 16)
subtitle.Position = UDim2.new(0.5, -120, 0, 24)
subtitle.TextXAlignment = Enum.TextXAlignment.Center

local defTitle = makeText(topBar, "DefTitle", "DEFENSE", 16, true, DEF_COLOR)
defTitle.Size = UDim2.fromOffset(120, 20)
defTitle.Position = UDim2.new(1, -136, 0, 5)
defTitle.TextXAlignment = Enum.TextXAlignment.Right
local defAlive = makeText(topBar, "DefAlive", "", 12, false, SUBTEXT)
defAlive.Size = UDim2.fromOffset(120, 16)
defAlive.Position = UDim2.new(1, -136, 0, 24)
defAlive.TextXAlignment = Enum.TextXAlignment.Right

-- ------------------------------------------------------------ TOGGLE BUTTON
local toggle = Instance.new("TextButton")
toggle.Name = "HudToggle"
toggle.Size = UDim2.fromOffset(96, 30)
toggle.Position = UDim2.new(0, 12, 0, 8)
toggle.BackgroundColor3 = PANEL
toggle.BackgroundTransparency = 0.2
toggle.Text = "CLUTCH"
toggle.TextColor3 = TEXT
toggle.TextSize = 13
toggle.Font = Enum.Font.GothamBold
toggle.BorderSizePixel = 0
toggle.Parent = gui
round(toggle, 8)

-- ----------------------------------------------------------- CARD COLUMNS
local atkColumn = Instance.new("Frame")
atkColumn.Name = "Attackers"
atkColumn.BackgroundTransparency = 1
atkColumn.Size = UDim2.fromOffset(232, 500)
atkColumn.Position = UDim2.new(0, 12, 0, 64)
atkColumn.Parent = gui
local atkLayout = Instance.new("UIListLayout")
atkLayout.SortOrder = Enum.SortOrder.Name
atkLayout.Padding = UDim.new(0, 8)
atkLayout.Parent = atkColumn

local defColumn = Instance.new("Frame")
defColumn.Name = "Defenders"
defColumn.BackgroundTransparency = 1
defColumn.Size = UDim2.fromOffset(232, 500)
defColumn.Position = UDim2.new(1, -244, 0, 64)
defColumn.Parent = gui
local defLayout = Instance.new("UIListLayout")
defLayout.SortOrder = Enum.SortOrder.Name
defLayout.Padding = UDim.new(0, 8)
defLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
defLayout.Parent = defColumn

-- -------------------------------------------------------------- KILL FEED
local feedFrame = Instance.new("Frame")
feedFrame.Name = "KillFeed"
feedFrame.BackgroundTransparency = 1
feedFrame.Size = UDim2.fromOffset(560, 160)
feedFrame.Position = UDim2.new(0.5, -280, 0, 60)
feedFrame.Parent = gui
local feedLayout = Instance.new("UIListLayout")
feedLayout.SortOrder = Enum.SortOrder.LayoutOrder
feedLayout.Padding = UDim.new(0, 4)
feedLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
feedLayout.Parent = feedFrame

local feedEntries: { { label: TextLabel, expiresAt: number } } = {}
local feedSerial = 0

local function addFeedEntry(text: string, color: Color3)
	feedSerial += 1
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 22)
	label.BackgroundColor3 = PANEL
	label.BackgroundTransparency = 0.35
	label.BorderSizePixel = 0
	label.Text = text
	label.TextSize = 13
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = color
	label.LayoutOrder = -feedSerial -- newest on top
	label.Parent = feedFrame
	round(label, 6)
	table.insert(feedEntries, { label = label, expiresAt = os.clock() + 6 })
end

killFeed.OnClientEvent:Connect(function(data)
	local text = ("%s   →   %s"):format(tostring(data.killer), tostring(data.victim))
	if data.headshot then
		text ..= "    [HEADSHOT]"
	end
	text ..= ("    ·  %s studs · %s"):format(tostring(data.distance), tostring(data.weapon))
	addFeedEntry(text, TEXT)
end)

-- ---------------------------------------------------------- SPECTATE CAM
local spectating: string? = nil

local function releaseSpectate()
	spectating = nil
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
	end
end

-- ------------------------------------------------------------- BOT CARDS
local cards: { [string]: {
	button: TextButton,
	badge: TextLabel,
	sub: TextLabel,
	hpFill: Frame,
	hpText: TextLabel,
	zone: TextLabel,
	kd: TextLabel,
	stroke: UIStroke,
} } = {}

local function ensureCard(name: string, side: string)
	if cards[name] then
		return cards[name]
	end
	local teamColor = if side == "Attack" then ATK_COLOR else DEF_COLOR

	local button = Instance.new("TextButton")
	button.Name = name -- UIListLayout sorts by Name
	button.Size = UDim2.new(1, 0, 0, 88)
	button.BackgroundColor3 = PANEL
	button.BackgroundTransparency = 0.2
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = true
	button.Parent = if side == "Attack" then atkColumn else defColumn
	round(button, 8)

	local stroke = Instance.new("UIStroke")
	stroke.Color = teamColor
	stroke.Thickness = 2
	stroke.Transparency = 1 -- shown while spectating this bot
	stroke.Parent = button

	local nameLabel = makeText(button, "BotName", name, 15, true, teamColor)
	nameLabel.Size = UDim2.fromOffset(120, 20)
	nameLabel.Position = UDim2.fromOffset(10, 6)

	local badge = makeText(button, "Intent", "-", 11, true, TEXT)
	badge.Size = UDim2.fromOffset(64, 18)
	badge.Position = UDim2.new(1, -74, 0, 7)
	badge.TextXAlignment = Enum.TextXAlignment.Center
	badge.BackgroundTransparency = 0.35
	badge.BackgroundColor3 = PANEL_DEAD
	round(badge, 6)

	local sub = makeText(button, "Sub", "", 11, false, SUBTEXT)
	sub.Size = UDim2.fromOffset(212, 14)
	sub.Position = UDim2.fromOffset(10, 26)

	local hpBack = Instance.new("Frame")
	hpBack.Name = "HPBack"
	hpBack.Size = UDim2.fromOffset(150, 10)
	hpBack.Position = UDim2.fromOffset(10, 44)
	hpBack.BackgroundColor3 = PANEL_DEAD
	hpBack.BorderSizePixel = 0
	hpBack.Parent = button
	round(hpBack, 4)

	local hpFill = Instance.new("Frame")
	hpFill.Name = "Fill"
	hpFill.Size = UDim2.fromScale(1, 1)
	hpFill.BackgroundColor3 = HP_GREEN
	hpFill.BorderSizePixel = 0
	hpFill.Parent = hpBack
	round(hpFill, 4)

	local hpText = makeText(button, "HPText", "100", 11, true, TEXT)
	hpText.Size = UDim2.fromOffset(46, 12)
	hpText.Position = UDim2.fromOffset(166, 43)

	local zone = makeText(button, "Zone", "", 12, false, TEXT)
	zone.Size = UDim2.fromOffset(212, 15)
	zone.Position = UDim2.fromOffset(10, 58)

	local kd = makeText(button, "KD", "", 11, false, SUBTEXT)
	kd.Size = UDim2.fromOffset(212, 13)
	kd.Position = UDim2.fromOffset(10, 72)

	button.MouseButton1Click:Connect(function()
		if spectating == name then
			releaseSpectate()
		else
			spectating = name
		end
	end)

	cards[name] = {
		button = button,
		badge = badge,
		sub = sub,
		hpFill = hpFill,
		hpText = hpText,
		zone = zone,
		kd = kd,
		stroke = stroke,
	}
	return cards[name]
end

-- -------------------------------------------------------------- MAIN LOOP
local function formatClock(seconds: number): string
	local s = math.max(0, math.floor(seconds + 0.5))
	return ("%d:%02d"):format(s // 60, s % 60)
end

local function refresh()
	local bots: { [string]: Model } = {}
	for _, inst in workspace:GetDescendants() do
		if inst:IsA("Model") and inst:GetAttribute("ClutchBot") == true then
			local botName = inst:GetAttribute("BotName")
			if typeof(botName) == "string" then
				bots[botName] = inst
			end
		end
	end

	local atkAliveCount, atkTotal = 0, 0
	local defAliveCount, defTotal = 0, 0

	for botName, model in bots do
		local side = model:GetAttribute("Side") or "Attack"
		local alive = model:GetAttribute("Alive") == true
		local card = ensureCard(botName, side)

		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local hp = if humanoid then math.max(humanoid.Health, 0) else 0
		local maxHp = if humanoid then math.max(humanoid.MaxHealth, 1) else 100
		local frac = math.clamp(hp / maxHp, 0, 1)

		card.hpFill.Size = UDim2.fromScale(frac, 1)
		card.hpFill.BackgroundColor3 = HP_RED:Lerp(HP_GREEN, frac)
		card.hpText.Text = tostring(math.floor(hp + 0.5))
		-- Inventory lists everything they own; falls back to the carried weapon
		-- for any session started before the round machine tracked inventories.
		local inventory = tostring(model:GetAttribute("Inventory") or model:GetAttribute("Weapon") or "?")
		card.sub.Text = ("%s · %s"):format(tostring(model:GetAttribute("Role") or "?"), inventory)
		-- Zone plus the speed mode: shift-walking is a decision, so show it
		local speed = tostring(model:GetAttribute("Speed") or "")
		local zoneText = tostring(model:GetAttribute("Zone") or "")
		if speed ~= "" then
			zoneText ..= ("  ·  %s"):format(if speed == "walk" then "walking" else "SPRINTING")
		end
		card.zone.Text = zoneText
		card.kd.Text = ("K %d  D %d  HS %d   ·   %d cr"):format(
			tonumber(model:GetAttribute("Kills")) or 0,
			tonumber(model:GetAttribute("Deaths")) or 0,
			tonumber(model:GetAttribute("Headshots")) or 0,
			tonumber(model:GetAttribute("Credits")) or 0
		)

		local intent = tostring(model:GetAttribute("Intent") or "-")
		card.badge.Text = string.upper(intent)
		card.badge.BackgroundColor3 = INTENT_COLORS[intent] or PANEL_DEAD

		card.button.BackgroundColor3 = if alive then PANEL else PANEL_DEAD
		card.button.BackgroundTransparency = if alive then 0.2 else 0.55
		card.stroke.Transparency = if spectating == botName then 0 else 1

		if side == "Attack" then
			atkTotal += 1
			if alive then atkAliveCount += 1 end
		else
			defTotal += 1
			if alive then defAliveCount += 1 end
		end
	end

	atkAlive.Text = ("alive %d/%d"):format(atkAliveCount, atkTotal)
	defAlive.Text = ("alive %d/%d"):format(defAliveCount, defTotal)

	-- Match state from the round machine
	local phase = tostring(remotes:GetAttribute("Phase") or "")
	local timeLeft = tonumber(remotes:GetAttribute("TimeLeft")) or 0
	local roundNumber = tonumber(remotes:GetAttribute("Round")) or 0
	local atkScore = tonumber(remotes:GetAttribute("AtkScore")) or 0
	local defScore = tonumber(remotes:GetAttribute("DefScore")) or 0
	local planted = remotes:GetAttribute("Planted") == true

	if phase ~= "" then
		title.Text = ("ROUND %d · %s %s"):format(roundNumber, string.upper(phase), formatClock(timeLeft))
	else
		title.Text = "PROJECT CLUTCH"
	end
	subtitle.Text = ("ATK %d — %d DEF%s"):format(atkScore, defScore, if planted then "   ·   SPIKE DOWN" else "")
	subtitle.TextColor3 = if planted then SPIKE_COLOR else SUBTEXT

	-- Spectate cam: follow the chosen bot; release if it is gone or dead
	if spectating then
		local model = bots[spectating]
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.Health > 0 then
			camera.CameraType = Enum.CameraType.Custom
			camera.CameraSubject = humanoid
		else
			releaseSpectate()
		end
	end

	-- Expire kill-feed entries
	local now = os.clock()
	for index = #feedEntries, 1, -1 do
		local entry = feedEntries[index]
		if now > entry.expiresAt then
			entry.label:Destroy()
			table.remove(feedEntries, index)
		end
	end
end

-- -------------------------------------------------------------- CONTROLS
local function setHudVisible(visible: boolean)
	topBar.Visible = visible
	atkColumn.Visible = visible
	defColumn.Visible = visible
	feedFrame.Visible = visible
	if not visible then
		releaseSpectate()
	end
end

toggle.MouseButton1Click:Connect(function()
	setHudVisible(not topBar.Visible)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Tab then
		setHudVisible(not topBar.Visible)
	elseif input.KeyCode == Enum.KeyCode.C then
		releaseSpectate()
	end
end)

task.spawn(function()
	while true do
		refresh()
		task.wait(0.25)
	end
end)
