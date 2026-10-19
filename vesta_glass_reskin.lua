print("[Vesta Glass Reskin] loading...")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local SHOT_WINDOW = 1.0          -- seconds after you fire during which new effects count as your shot
local SHOT_RADIUS = 30           -- studs from you within which a new effect counts as your shot
local BUBBLY_FONT = Enum.Font.GothamBold   -- menu font (try Enum.Font.GothamBlack for even bolder)
local MENU_OUTLINE = Color3.fromRGB(80, 60, 130)
local BUTTON_OUTLINE = Color3.fromRGB(70, 70, 70)
local BUTTON_SELECTED = Color3.fromRGB(0, 170, 255)
local BUTTON_NAME = "VESTA GLASS RESKIN"
local GLASS_TRANSPARENCY = 0.55  -- higher = more see-through
local CHROME_REFLECTANCE = 0.45  -- shininess of the gun

-- MINIMISED ICON
-- To use your orb picture as the minimised icon:
--   1) upload the picture to Roblox (Creator Hub > Assets > Decals/Images)
--   2) paste its id below, e.g. "rbxassetid://1234567890"
-- OR paste a base64 string of the PNG into ICON_PNG_B64 (executors with writefile + getcustomasset only).
-- If both are empty, a black-and-white orb drawn in code is used.
local MINI_ICON_ASSET = ""
local ICON_SIZE = 52
local ICON_PNG_B64 = [=[
]=]

local env = (getgenv and getgenv()) or _G
local wasActive = env.VestaGlassActive == true -- running the script again keeps the reskin on
if env.VoidscopeRecolorCleanup then
	pcall(env.VoidscopeRecolorCleanup) -- also removes the older recolor menu if it is still open
end

local active = false -- true while the glass reskin is on
local shotUntil = 0
local shotCount = 0
local conns = {}
local originals = setmetatable({}, { __mode = "k" }) -- inst -> { prop = originalValue }
local hooked = setmetatable({}, { __mode = "k" })    -- tools we've hooked
local guarded = setmetatable({}, { __mode = "k" })   -- effects / sounds we already listen to
local texWatched = setmetatable({}, { __mode = "k" })
local watchedTargets = setmetatable({}, { __mode = "k" })
local pearlT = setmetatable({}, { __mode = "k" })    -- part -> 0..1, where it sits along the gun
local flatSpread = setmetatable({}, { __mode = "k" }) -- parts of a gun that is a single piece
local glassed = setmetatable({}, { __mode = "k" })   -- parts currently showing the glass look
local glassGuarded = setmetatable({}, { __mode = "k" })
local chromed = setmetatable({}, { __mode = "k" })   -- meshes currently showing the chrome look
local unglassing = false
local hipQueued = false
local gui, noteLabel, glassBtn

local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(conns, c)
	return c
end
local function setNote(text)
	if noteLabel then noteLabel.Text = text or "" end
end
local function set(inst, prop, value)
	local saved = originals[inst]
	if not saved then
		saved = {}
		originals[inst] = saved
	end
	if saved[prop] == nil then
		local ok, v = pcall(function() return inst[prop] end)
		if ok then saved[prop] = v end
	end
	return (pcall(function() inst[prop] = value end))
end
local function colorsClose(a, b)
	return math.abs(a.R - b.R) < 0.01 and math.abs(a.G - b.G) < 0.01 and math.abs(a.B - b.B) < 0.01
end
local function seqIsColor(seq, color)
	for _, kp in ipairs(seq.Keypoints) do
		if not colorsClose(kp.Value, color) then return false end
	end
	return true
end
local function isEffect(inst)
	return inst:IsA("Beam") or inst:IsA("Trail") or inst:IsA("ParticleEmitter")
end
local function partsUnder(root)
	local list = {}
	if root:IsA("BasePart") then table.insert(list, root) end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then table.insert(list, d) end
	end
	return list
end

-- works out where each part sits along the gun (0 = one end, 1 = the other) for the pearly tint
local function mapPearl(parts)
	if not active then return end
	local seen = {}
	for _, p in ipairs(parts) do
		if p.Transparency < 1 then table.insert(seen, p) end
	end
	if #seen == 0 then return end
	local ref = seen[1]
	for _, p in ipairs(seen) do
		if p.Size.Magnitude > ref.Size.Magnitude then ref = p end
	end
	local pts = {}
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = Vector3.new(-math.huge, -math.huge, -math.huge)
	for i, p in ipairs(seen) do
		local v = ref.CFrame:PointToObjectSpace(p.Position)
		pts[i] = v
		lo = Vector3.new(math.min(lo.X, v.X), math.min(lo.Y, v.Y), math.min(lo.Z, v.Z))
		hi = Vector3.new(math.max(hi.X, v.X), math.max(hi.Y, v.Y), math.max(hi.Z, v.Z))
	end
	local ext = hi - lo
	local axis = "X"
	if ext.Y > ext[axis] then axis = "Y" end
	if ext.Z > ext[axis] then axis = "Z" end
	local range = ext[axis]
	for i, p in ipairs(seen) do
		if range > 0.05 then
			pearlT[p] = (pts[i][axis] - lo[axis]) / range
			flatSpread[p] = nil
		else
			pearlT[p] = 0.5
			flatSpread[p] = true
		end
	end
end
local function colorFor(inst)
	local t = pearlT[inst]
	if not t or flatSpread[inst] then return Color3.fromRGB(238, 238, 244) end
	return Color3.fromHSV(0.5 + t * 0.42, 0.16, 0.95)
end

local function chromeMesh(mp, color)
	set(mp, "TextureID", "")
	set(mp, "Material", glassed[mp] and Enum.Material.Glass or Enum.Material.Metal)
	set(mp, "Reflectance", CHROME_REFLECTANCE)
	set(mp, "Color", color)
	chromed[mp] = true
end

local function glassify(inst)
	set(inst, "Transparency", GLASS_TRANSPARENCY)
	set(inst, "Material", Enum.Material.Glass)
	glassed[inst] = true
end
local function applyGlass(inst)
	if not glassGuarded[inst] then
		glassGuarded[inst] = true
		connect(inst:GetPropertyChangedSignal("Transparency"), function()
			if not unglassing and active and inst.Transparency < GLASS_TRANSPARENCY - 0.01 then
				glassify(inst)
			end
		end)
	end
	if inst.Transparency < GLASS_TRANSPARENCY - 0.01 then
		glassify(inst)
	elseif glassed[inst] and inst.Material ~= Enum.Material.Glass then
		set(inst, "Material", Enum.Material.Glass)
	end
end
local function unglassAll()
	unglassing = true
	for inst in pairs(glassed) do
		local saved = originals[inst]
		if saved then
			pcall(function()
				if saved.Transparency ~= nil and inst.Transparency < 0.95 then
					inst.Transparency = saved.Transparency
				end
				if saved.Material ~= nil then inst.Material = saved.Material end
			end)
			saved.Transparency = nil
			saved.Material = nil
		end
		glassed[inst] = nil
	end
	unglassing = false
end
local function restoreAll()
	unglassAll()
	for mp in pairs(chromed) do chromed[mp] = nil end
	for inst, saved in pairs(originals) do
		for prop, v in pairs(saved) do
			pcall(function() inst[prop] = v end)
		end
	end
	for k in pairs(originals) do
		originals[k] = nil
	end
end

local function watchTexture(mp)
	if texWatched[mp] then return end
	texWatched[mp] = true
	connect(mp:GetPropertyChangedSignal("TextureID"), function()
		if active and mp.TextureID ~= "" then chromeMesh(mp, colorFor(mp)) end
	end)
end

local function paint(inst, color, isShot)
	if inst:IsA("MeshPart") and not isShot then
		set(inst, "Color", color)
		watchTexture(inst)
		chromeMesh(inst, color)
		applyGlass(inst)
		return true
	elseif inst:IsA("BasePart") then
		set(inst, "Color", color)
		if not isShot then applyGlass(inst) end
		if isShot then
			if inst:IsA("MeshPart") then set(inst, "TextureID", "") end
			set(inst, "MaterialVariant", "")
			if colorsClose(color, Color3.new(0, 0, 0)) then
				set(inst, "Material", Enum.Material.SmoothPlastic)
			else
				set(inst, "Material", Enum.Material.Neon)
			end
		end
		return true
	elseif isEffect(inst) then
		set(inst, "Color", ColorSequence.new(color))
		return true
	elseif inst:IsA("SpecialMesh") then
		if isShot then set(inst, "TextureId", "") end
		set(inst, "VertexColor", Vector3.new(color.R, color.G, color.B))
		return true
	elseif inst:IsA("SurfaceAppearance") then
		set(inst, "ColorMap", "")
		set(inst, "Color", color)
		return true
	elseif inst:IsA("Decal") or inst:IsA("Texture") then
		set(inst, "Color3", color)
		return true
	elseif inst:IsA("Light") then -- PointLight / SpotLight / SurfaceLight
		set(inst, "Color", color)
		return true
	elseif inst:IsA("Fire") then
		set(inst, "Color", color)
		set(inst, "SecondaryColor", color)
		return true
	elseif inst:IsA("Sparkles") then
		set(inst, "SparkleColor", color)
		return true
	elseif inst:IsA("Highlight") then
		set(inst, "FillColor", color)
		set(inst, "OutlineColor", color)
		return true
	end
	return false
end

local function guardEffect(inst)
	if not isEffect(inst) or guarded[inst] then return end
	guarded[inst] = true
	connect(inst:GetPropertyChangedSignal("Color"), function()
		if not active then return end
		if not seqIsColor(inst.Color, colorFor(inst)) then
			paint(inst, colorFor(inst), false)
		end
	end)
end
local function paintGun(tool)
	if not active then return 0 end
	mapPearl(partsUnder(tool))
	local effects = 0
	for _, d in ipairs(tool:GetDescendants()) do
		if paint(d, colorFor(d), false) and isEffect(d) then
			effects += 1
		end
		guardEffect(d)
	end
	return effects
end

-- the gun on your hip / back
local function gunAssetIds()
	local ids = {}
	for tool in pairs(hooked) do
		for _, d in ipairs(tool:GetDescendants()) do
			if d:IsA("MeshPart") then
				local okt, tex = pcall(function() return d.TextureID end)
				if okt and type(tex) == "string" and tex ~= "" then ids[tex] = true end
				local okm, mesh = pcall(function() return d.MeshId end)
				if okm and type(mesh) == "string" and mesh ~= "" then ids[mesh] = true end
			end
		end
	end
	return ids
end
local function hipTarget(char)
	local ref = char:FindFirstChild("DisplayRefGun")
	if not (ref and ref:IsA("ObjectValue")) then return nil end
	local t = ref.Value
	if not t then return nil end
	if t == char or char:IsDescendantOf(t) then return nil end
	if t:IsA("Humanoid") or t:FindFirstChildOfClass("Humanoid") then return nil end
	return t
end
local function watchTarget(target)
	if watchedTargets[target] then return end
	watchedTargets[target] = true
	connect(target.DescendantAdded, function(d)
		task.defer(function()
			if active and d.Parent then
				paint(d, colorFor(d), false)
			end
		end)
	end)
end
local function paintHip()
	local char = LocalPlayer.Character
	if not (active and char) then return 0 end
	local done, count = {}, 0
	local function paintOne(d)
		if done[d] then return end
		done[d] = true
		if paint(d, colorFor(d), false) and d:IsA("BasePart") then
			count += 1
		end
	end
	local target = hipTarget(char)
	if target then
		watchTarget(target)
		mapPearl(partsUnder(target))
		paintOne(target)
		for _, d in ipairs(target:GetDescendants()) do
			paintOne(d)
		end
	end
	local ids = gunAssetIds()
	local matched = {}
	for _, d in ipairs(char:GetDescendants()) do
		if d:IsA("MeshPart") and not done[d] and not d:FindFirstAncestorOfClass("Tool") then
			local okt, tex = pcall(function() return d.TextureID end)
			local okm, mesh = pcall(function() return d.MeshId end)
			if (okt and tex ~= "" and ids[tex]) or (okm and mesh ~= "" and ids[mesh]) then
				table.insert(matched, d)
			end
		end
	end
	mapPearl(matched)
	for _, d in ipairs(matched) do
		paintOne(d)
	end
	return count
end
local function refreshHip()
	if active then paintHip() end
end
local function queueHipRefresh()
	if hipQueued then return end
	hipQueued = true
	task.defer(function()
		hipQueued = false
		refreshHip()
	end)
end
local function hookRef(ref)
	if guarded[ref] then return end
	guarded[ref] = true
	connect(ref:GetPropertyChangedSignal("Value"), queueHipRefresh)
end
local function watchCharacter(char)
	if not char then return end
	connect(char.DescendantAdded, function(d)
		if d.Name == "DisplayRefGun" and d:IsA("ObjectValue") then
			hookRef(d)
			queueHipRefresh()
		elseif active and d:IsA("MeshPart") then
			queueHipRefresh()
		end
	end)
	local ref = char:FindFirstChild("DisplayRefGun")
	if ref and ref:IsA("ObjectValue") then hookRef(ref) end
end

-- finding the gun and your shots
local function isGun(inst)
	if not inst:IsA("Tool") then return false end
	local n = string.lower(inst.Name)
	return n == "gun" or string.find(n, "voidscope", 1, true) ~= nil
end
local function openShotWindow()
	local now = os.clock()
	if now > shotUntil then shotCount = 0 end
	shotUntil = now + SHOT_WINDOW
end
local function watchSound(inst)
	if not inst:IsA("Sound") or guarded[inst] then return end
	local n = string.lower(inst.Name)
	if string.find(n, "shot", 1, true) or string.find(n, "shoot", 1, true)
		or string.find(n, "fire", 1, true) or string.find(n, "alt", 1, true) then
		guarded[inst] = true
		connect(inst.Played, openShotWindow)
	end
end
local function hookGun(tool)
	if hooked[tool] then return end
	hooked[tool] = true
	print("[Vesta Glass Reskin] found gun: " .. tool:GetFullName())
	paintGun(tool)
	if active then refreshHip() end
	for _, d in ipairs(tool:GetDescendants()) do
		watchSound(d)
	end
	connect(tool.DescendantAdded, function(d)
		guardEffect(d)
		watchSound(d)
		task.defer(function()
			if active and d.Parent then
				paint(d, colorFor(d), false)
			end
		end)
	end)
	connect(tool.Activated, openShotWindow)
end
local function scan(container)
	if not container then return end
	for _, child in ipairs(container:GetChildren()) do
		if isGun(child) then hookGun(child) end
	end
	connect(container.ChildAdded, function(child)
		if isGun(child) then hookGun(child) end
	end)
end
scan(LocalPlayer.Character)
scan(LocalPlayer:FindFirstChildOfClass("Backpack"))
connect(LocalPlayer.CharacterAdded, scan)
watchCharacter(LocalPlayer.Character)
connect(LocalPlayer.CharacterAdded, watchCharacter)
connect(LocalPlayer.ChildAdded, function(c)
	if c:IsA("Backpack") then scan(c) end
end)
connect(UserInputService.InputBegan, function(input, processed)
	if processed then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		local char = LocalPlayer.Character
		if char then
			for _, child in ipairs(char:GetChildren()) do
				if isGun(child) then
					openShotWindow()
					break
				end
			end
		end
	end
end)
local function characterOf(inst)
	local m = inst:FindFirstAncestorOfClass("Model")
	while m do
		if m:FindFirstChildOfClass("Humanoid") then return m end
		m = m:FindFirstAncestorOfClass("Model")
	end
	return nil
end
local function partOf(inst)
	if inst:IsA("BasePart") then return inst end
	local p = inst.Parent
	if p and p:IsA("Attachment") then p = p.Parent end
	if p and p:IsA("BasePart") then return p end
	return nil
end
local function nearYou(d)
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then return true end
	local points = {}
	local part = partOf(d)
	if part then table.insert(points, part.Position) end
	if d:IsA("Beam") then
		local a0, a1 = d.Attachment0, d.Attachment1
		if a0 then table.insert(points, a0.WorldPosition) end
		if a1 then table.insert(points, a1.WorldPosition) end
	end
	if #points == 0 then return true end -- can't tell where it is, so don't skip it
	for _, p in ipairs(points) do
		if (p - root.Position).Magnitude <= SHOT_RADIUS then return true end
	end
	return false
end
connect(Workspace.DescendantAdded, function(d)
	if not active then return end
	if os.clock() > shotUntil then return end
	local char = characterOf(d)
	if char then
		if char ~= LocalPlayer.Character then return end
		if not (isEffect(d) or d:IsA("Light")) then return end
	end
	task.defer(function()
		if not d.Parent or not active then return end
		if not nearYou(d) then return end
		if paint(d, colorFor(d), true) then
			guardEffect(d)
			shotCount += 1
		end
	end)
end)

-- switching the reskin on / off
local function updateStatus()
	if glassBtn then
		local stroke = glassBtn:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = active and BUTTON_SELECTED or BUTTON_OUTLINE
			stroke.Thickness = active and 3 or 1
		end
	end
end
local function activate()
	active = true
	env.VestaGlassActive = true
	local found = 0
	for tool in pairs(hooked) do
		if tool.Parent then
			found += 1
			paintGun(tool)
		end
	end
	if found == 0 then
		setNote("No gun found yet. Equip your gun and it will be reskinned.")
	else
		setNote("Glass reskin on. Press again to turn it off.")
	end
	refreshHip() -- the gun on your hip / back too
	updateStatus()
end
local function deactivate()
	active = false
	env.VestaGlassActive = false
	restoreAll()
	setNote("")
	updateStatus()
end

-- menu
local function label(frame, order, text, size, color, height)
	local l = Instance.new("TextLabel")
	l.LayoutOrder = order
	l.Size = UDim2.new(1, 0, 0, height)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.Gotham
	l.TextSize = size
	l.TextColor3 = color
	l.TextWrapped = true
	l.Text = text
	l.Parent = frame
	return l
end
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64decode(data)
	local lookup = {}
	for i = 1, 64 do
		lookup[string.byte(B64_CHARS, i)] = i - 1
	end
	data = string.gsub(data, "[^%w%+/=]", "")
	local chunks = {}
	for i = 1, #data, 4 do
		local c1, c2, c3, c4 = string.byte(data, i, i + 3)
		local v3 = (c3 and c3 ~= 61) and lookup[c3] or nil
		local v4 = (c4 and c4 ~= 61) and lookup[c4] or nil
		local n = lookup[c1] * 262144 + lookup[c2] * 4096 + (v3 or 0) * 64 + (v4 or 0)
		local b1 = math.floor(n / 65536)
		local b2 = math.floor(n / 256) % 256
		local b3 = n % 256
		if v4 then
			table.insert(chunks, string.char(b1, b2, b3))
		elseif v3 then
			table.insert(chunks, string.char(b1, b2))
		else
			table.insert(chunks, string.char(b1))
		end
	end
	return table.concat(chunks)
end
local function loadIconImage()
	if MINI_ICON_ASSET ~= "" then return MINI_ICON_ASSET end
	if string.gsub(ICON_PNG_B64, "%s", "") == "" then return nil end
	local toAsset = getcustomasset or getsynasset
	if not (writefile and toAsset) then return nil end
	local ok, asset = pcall(function()
		local name = "VoidscopeOrb.png"
		writefile(name, b64decode(ICON_PNG_B64))
		return toAsset(name)
	end)
	if ok and type(asset) == "string" and asset ~= "" then
		return asset
	end
	return nil
end

local guiConns = {} -- connections that belong to the menu only
local function guiConnect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(guiConns, c)
	return c
end
-- closing the menu only removes the menu: the reskin keeps running (re-run the script to get the menu back)
local function closeMenu()
	for _, c in ipairs(guiConns) do
		pcall(function() c:Disconnect() end)
	end
	guiConns = {}
	if gui then gui:Destroy() end
	gui, glassBtn, noteLabel = nil, nil, nil
	print("[Vesta Glass Reskin] menu closed, the reskin stays on")
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "VoidscopeRecolor"
	gui.ResetOnSpawn = false
	local ok = pcall(function()
		gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
	end)
	if not ok or not gui.Parent then
		gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end

	local WIDTH = 280

	local function photoText(b, size)
		b.Font = BUBBLY_FONT
		b.TextSize = size or 15
		b.TextColor3 = Color3.new(1, 1, 1)
		b.TextStrokeColor3 = Color3.new(0, 0, 0)
		b.TextStrokeTransparency = 0.45
	end

	local frame = Instance.new("Frame")
	frame.Name = "Main"
	frame.Size = UDim2.new(0, WIDTH, 0, 200) -- the height follows the content, see syncHeight below
	frame.Position = UDim2.new(0, 20, 0.3, 0)
	frame.BackgroundColor3 = Color3.new(1, 1, 1)
	frame.BorderSizePixel = 0
	frame.Active = true
	pcall(function() frame.Draggable = true end)
	frame.Parent = gui
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 14)
	local frameStroke = Instance.new("UIStroke")
	frameStroke.Color = MENU_OUTLINE
	frameStroke.Thickness = 1.5
	frameStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	frameStroke.Parent = frame

	-- black galaxy background
	local galaxyOk, galaxyErr = pcall(function()
		local sky = Instance.new("UIGradient")
		sky.Rotation = 60
		sky.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0.00, Color3.fromRGB(0, 0, 0)),
			ColorSequenceKeypoint.new(0.35, Color3.fromRGB(22, 5, 44)),
			ColorSequenceKeypoint.new(0.70, Color3.fromRGB(6, 12, 44)),
			ColorSequenceKeypoint.new(1.00, Color3.fromRGB(0, 0, 0)),
		})
		sky.Parent = frame

		local stars = Instance.new("Frame")
		stars.Name = "Stars"
		stars.Size = UDim2.new(1, 0, 1, 0)
		stars.BackgroundTransparency = 1
		stars.ClipsDescendants = true
		stars.ZIndex = 1
		stars.Parent = frame
		Instance.new("UICorner", stars).CornerRadius = UDim.new(0, 14)

		local rng = Random.new(1234)
		for i = 1, 60 do
			local size = 1
			local roll = rng:NextNumber()
			if roll < 0.15 then
				size = 3
			elseif roll < 0.5 then
				size = 2
			end
			local star = Instance.new("Frame")
			star.Size = UDim2.new(0, size, 0, size)
			star.Position = UDim2.new(rng:NextNumber(0.03, 0.97), 0, rng:NextNumber(0.02, 0.98), 0)
			star.BorderSizePixel = 0
			if i % 5 == 0 then
				star.BackgroundColor3 = Color3.fromRGB(190, 170, 255)
			elseif i % 7 == 0 then
				star.BackgroundColor3 = Color3.fromRGB(170, 215, 255)
			else
				star.BackgroundColor3 = Color3.new(1, 1, 1)
			end
			star.BackgroundTransparency = rng:NextNumber(0.05, 0.65)
			star.ZIndex = 1
			star.Parent = stars
			if size > 1 then
				Instance.new("UICorner", star).CornerRadius = UDim.new(1, 0)
			end
		end
	end)
	if not galaxyOk then
		warn("[Vesta Glass Reskin] galaxy background skipped: " .. tostring(galaxyErr))
		frame.BackgroundColor3 = Color3.fromRGB(4, 2, 12)
	end

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.BackgroundTransparency = 1
	content.ZIndex = 2
	content.Parent = frame
	local pad = Instance.new("UIPadding", content)
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	local list = Instance.new("UIListLayout", content)
	list.Padding = UDim.new(0, 8)
	list.SortOrder = Enum.SortOrder.LayoutOrder

	local function syncHeight()
		frame.Size = UDim2.new(0, WIDTH, 0, math.max(content.AbsoluteSize.Y, 40))
	end
	guiConnect(content:GetPropertyChangedSignal("AbsoluteSize"), syncHeight)
	task.defer(syncHeight)

	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	-- header: title + minimise + close
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.LayoutOrder = nextOrder()
	header.Size = UDim2.new(1, 0, 0, 30)
	header.BackgroundTransparency = 1
	header.Parent = content

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -70, 1, 0)
	title.BackgroundTransparency = 1
	title.Font = BUBBLY_FONT
	title.Text = "VESTA RECOLOR"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextStrokeColor3 = Color3.new(0, 0, 0)
	title.TextStrokeTransparency = 0.45
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = header
	local titleLimit = Instance.new("UITextSizeConstraint")
	titleLimit.MaxTextSize = 19
	titleLimit.Parent = title

	local function headerButton(text, xOffset, bg)
		local b = Instance.new("TextButton")
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, xOffset, 0.5, 0)
		b.Size = UDim2.new(0, 28, 0, 28)
		b.BackgroundColor3 = bg
		b.BorderSizePixel = 0
		photoText(b, 18)
		b.Text = text
		b.Parent = header
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
		return b
	end
	local minBtn = headerButton("-", -34, Color3.fromRGB(40, 40, 60))
	local closeBtn = headerButton("X", 0, Color3.fromRGB(170, 40, 40))

	-- the one big button: frosted light-blue glass
	glassBtn = Instance.new("TextButton")
	glassBtn.Name = "GlassReskin"
	glassBtn.LayoutOrder = nextOrder()
	glassBtn.Size = UDim2.new(1, 0, 0, 90)
	glassBtn.BackgroundColor3 = Color3.fromRGB(170, 220, 255)
	glassBtn.BackgroundTransparency = 0.45
	glassBtn.BorderSizePixel = 0
	glassBtn.TextWrapped = true
	photoText(glassBtn, 24)
	glassBtn.Text = BUTTON_NAME
	glassBtn.Parent = content
	Instance.new("UICorner", glassBtn).CornerRadius = UDim.new(0, 12)
	local glassStroke = Instance.new("UIStroke")
	glassStroke.Color = BUTTON_OUTLINE
	glassStroke.Thickness = 1
	glassStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	glassStroke.Parent = glassBtn
	glassBtn.MouseButton1Click:Connect(function()
		if active then
			deactivate()
		else
			activate()
		end
	end)

	noteLabel = label(content, nextOrder(), "", 11, Color3.fromRGB(200, 190, 255), 28)
	noteLabel.TextXAlignment = Enum.TextXAlignment.Left
	label(content, nextOrder(), "RightShift = hide / show", 11, Color3.fromRGB(130, 130, 150), 14)

	-- footer
	local handle = label(content, nextOrder(), "insp:kudo", 15, Color3.new(1, 1, 1), 22)
	handle.Font = BUBBLY_FONT
	handle.TextWrapped = false
	handle.TextStrokeColor3 = Color3.new(0, 0, 0)
	handle.TextStrokeTransparency = 0.45

	-- "Are you sure?" popup for the close button
	local confirm = Instance.new("Frame")
	confirm.Name = "ConfirmClose"
	confirm.Size = UDim2.new(1, 0, 1, 0)
	confirm.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	confirm.BackgroundTransparency = 0.15
	confirm.BorderSizePixel = 0
	confirm.Active = true -- stops clicks going through to the buttons underneath
	confirm.Visible = false
	confirm.ZIndex = 20
	confirm.Parent = frame
	Instance.new("UICorner", confirm).CornerRadius = UDim.new(0, 14)

	local confirmText = Instance.new("TextLabel")
	confirmText.AnchorPoint = Vector2.new(0.5, 0.5)
	confirmText.Position = UDim2.new(0.5, 0, 0.38, 0)
	confirmText.Size = UDim2.new(1, -24, 0, 50)
	confirmText.BackgroundTransparency = 1
	confirmText.Font = BUBBLY_FONT
	confirmText.TextSize = 18
	confirmText.TextWrapped = true
	confirmText.TextColor3 = Color3.new(1, 1, 1)
	confirmText.TextStrokeColor3 = Color3.new(0, 0, 0)
	confirmText.TextStrokeTransparency = 0.45
	confirmText.Text = "ARE YOU SURE?"
	confirmText.ZIndex = 21
	confirmText.Parent = confirm

	local function confirmButton(text, xScale, bg)
		local b = Instance.new("TextButton")
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		b.Position = UDim2.new(xScale, 0, 0.7, 0)
		b.Size = UDim2.new(0.4, 0, 0, 32)
		b.BackgroundColor3 = bg
		b.BorderSizePixel = 0
		photoText(b, 15)
		b.Text = text
		b.ZIndex = 21
		b.Parent = confirm
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
		return b
	end
	local yesBtn = confirmButton("YES", 0.28, Color3.fromRGB(170, 40, 40))
	local noBtn = confirmButton("NO", 0.72, Color3.fromRGB(45, 45, 70))

	-- minimise
	local minimised = false
	local imageId = loadIconImage()
	local icon
	if imageId then
		icon = Instance.new("ImageButton")
		icon.Image = imageId
		icon.ScaleType = Enum.ScaleType.Fit
		icon.BackgroundColor3 = Color3.new(0, 0, 0)
		icon.AutoButtonColor = false
	else
		-- drawn-in-code "V": a glowing chrome V on a dark galaxy tile
		icon = Instance.new("TextButton")
		icon.Text = ""
		icon.AutoButtonColor = false
		icon.BackgroundColor3 = Color3.new(1, 1, 1)
		local tile = Instance.new("UIGradient")
		tile.Rotation = 60
		tile.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(6, 4, 20)),
			ColorSequenceKeypoint.new(0.6, Color3.fromRGB(34, 10, 70)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(4, 20, 50)),
		})
		tile.Parent = icon

		local glowColors = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 230, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 70, 255)),
		})
		local chromeColors = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(235, 252, 255)),
			ColorSequenceKeypoint.new(0.55, Color3.fromRGB(120, 205, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(175, 95, 255)),
		})
		local function arm(rotation, cx, width, length, colors, transparency, z)
			local bar = Instance.new("Frame")
			bar.AnchorPoint = Vector2.new(0.5, 0.5)
			bar.Position = UDim2.new(0, cx, 0, 27)
			bar.Size = UDim2.new(0, width, 0, length)
			bar.Rotation = rotation
			bar.BorderSizePixel = 0
			bar.BackgroundColor3 = Color3.new(1, 1, 1)
			bar.BackgroundTransparency = transparency
			bar.ZIndex = z
			bar.Parent = icon
			Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)
			local g = Instance.new("UIGradient")
			g.Rotation = 90
			g.Color = colors
			g.Parent = bar
			return bar
		end
		-- soft glow behind, then the two sharp arms of the V on top
		arm(-25, 19.7, 16, 40, glowColors, 0.8, 1)
		arm(25, 32.3, 16, 40, glowColors, 0.8, 1)
		arm(-25, 19.7, 8, 30, chromeColors, 0, 2)
		arm(25, 32.3, 8, 30, chromeColors, 0, 2)

		local specks = { { 0.12, 0.16 }, { 0.84, 0.14 }, { 0.16, 0.82 }, { 0.86, 0.8 }, { 0.5, 0.06 }, { 0.5, 0.9 } }
		for i, sp in ipairs(specks) do
			local dot = Instance.new("Frame")
			dot.Size = UDim2.new(0, 2, 0, 2)
			dot.Position = UDim2.new(sp[1], 0, sp[2], 0)
			dot.BorderSizePixel = 0
			dot.BackgroundColor3 = (i % 2 == 0) and Color3.fromRGB(170, 235, 255) or Color3.new(1, 1, 1)
			dot.ZIndex = 3
			dot.Parent = icon
		end
	end
	icon.Name = "MiniIcon"
	icon.Size = UDim2.new(0, ICON_SIZE, 0, ICON_SIZE)
	icon.Position = frame.Position
	icon.BorderSizePixel = 0
	icon.Active = true
	icon.Visible = false
	pcall(function() icon.Draggable = true end)
	icon.Parent = gui
	Instance.new("UICorner", icon).CornerRadius = UDim.new(0, 12)
	local iconStroke = Instance.new("UIStroke")
	iconStroke.Color = MENU_OUTLINE
	iconStroke.Thickness = 1
	iconStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	iconStroke.Parent = icon
	if not imageId then
		iconStroke.Thickness = 2
		iconStroke.Color = Color3.new(1, 1, 1)
		local strokeGradient = Instance.new("UIGradient")
		strokeGradient.Rotation = 45
		strokeGradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 230, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 70, 255)),
		})
		strokeGradient.Parent = iconStroke
	end

	minBtn.MouseButton1Click:Connect(function()
		minimised = true
		confirm.Visible = false
		icon.Position = frame.Position -- the icon appears where the menu was
		frame.Visible = false
		icon.Visible = true
	end)

	local pressedAt
	icon.MouseButton1Down:Connect(function()
		pressedAt = icon.AbsolutePosition
	end)
	icon.MouseButton1Click:Connect(function()
		if pressedAt and (icon.AbsolutePosition - pressedAt).Magnitude > 6 then return end -- it was a drag, not a tap
		minimised = false
		frame.Position = icon.Position -- the menu opens where the icon is
		icon.Visible = false
		frame.Visible = true
	end)

	-- close: X asks first, YES closes for real, NO goes back
	closeBtn.MouseButton1Click:Connect(function()
		confirm.Visible = true
	end)
	noBtn.MouseButton1Click:Connect(function()
		confirm.Visible = false
	end)
	yesBtn.MouseButton1Click:Connect(closeMenu)

	guiConnect(UserInputService.InputBegan, function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.RightShift then
			local target = minimised and icon or frame -- hides / shows whichever one is out right now
			target.Visible = not target.Visible
		end
	end)
end

local built, buildErr = pcall(buildGui)
if not built then
	warn("[Vesta Glass Reskin] the menu failed to build: " .. tostring(buildErr))
end
local pre = env.VoidscopeColor
if wasActive or (type(pre) == "string" and string.lower(pre) == "glass") then
	activate()
end
env.VoidscopeRecolorCleanup = function()
	for _, c in ipairs(conns) do
		pcall(function() c:Disconnect() end)
	end
	for _, c in ipairs(guiConns) do
		pcall(function() c:Disconnect() end)
	end
	restoreAll()
	if gui then gui:Destroy() end
	env.VoidscopeRecolorCleanup = nil
end
print("[Vesta Glass Reskin] loaded")
