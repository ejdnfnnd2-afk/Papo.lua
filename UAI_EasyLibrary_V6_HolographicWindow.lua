--[[
    UAI Easy Library V6 • HOLOGRAPHIC
    UAI-inspired HOLOGRAPHIC GLASS window + cinematic animations + neon depth.

    API:
      local Library = loadstring(...)()
      local Window = Library:AddWindow("Title", config)
      local Tab = Window:AddTab("Main")
      Tab:AddButton("Button", function() end)
      Tab:AddSwitch("Switch", function(value) end)
      Tab:AddLabel("Text")
      Tab:AddTextBox("Placeholder", function(text) end)
      Tab:AddSlider("Speed", function(value) end, {min=0,max=100,default=50})
      Tab:AddDropdown("Mode", function(value) end):Add("One")
      Tab:AddKeybind("Toggle", function(key) end, {default=Enum.KeyCode.RightShift})
      Tab:AddFolder("Folder")
      Window:Toggle()
      Window:Destroy()

    This is intentionally independent from UAI's agent/runtime modules.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local CoreGui = game:GetService("CoreGui")

local player = Players.LocalPlayer

local function getParent()
    if type(gethui) == "function" then
        local ok, gui = pcall(gethui)
        if ok and gui then return gui end
    end
    return CoreGui
end

local Library = {}
Library.__index = Library

local DEFAULTS = {
    main_color = Color3.fromRGB(100, 180, 255),
    background = Color3.fromRGB(20, 21, 24),
    surface = Color3.fromRGB(27, 29, 33),
    surface2 = Color3.fromRGB(34, 36, 41),
    text = Color3.fromRGB(235, 237, 242),
    muted = Color3.fromRGB(145, 150, 160),
    border = Color3.fromRGB(54, 57, 64),
    min_size = Vector2.new(500, 350),
    size = Vector2.new(720, 500),
    toggle_key = Enum.KeyCode.RightShift,
    can_resize = true,
    tween_time = 0.16,
    title_bar = true,
    transparency = 0,
    click_sound = true,
    click_sound_id = "rbxassetid://113397864512278", -- UI Click 1 (short)
    click_volume = 0.18,
    glow = true,
    animated = true,

    -- Animaciones avanzadas
    entrance_animation = true,
    hover_animation = true,
    tab_animation = true,
    pulse_animation = true,
    card_animation = true,
    animation_speed = 0.22,

    -- Visuales ULTRA
    glass = true,
    particles = true,
    particle_count = 18,
    ambient_glow = true,
    neon_border = true,
    scanline = true,
    floating_orbs = true,
    sidebar_glow = true,
    rounded_ui = true,
    depth_shadow = true,

    -- Ventana holográfica
    holographic_window = true,
    animated_frame = true,
    corner_lights = true,
    top_orb = true,
    energy_line = true,
    inner_glow = true,
    window_breath = true,
    glass_highlight = true,
}

local function merge(a, b)
    local r = {}
    for k,v in pairs(a) do r[k] = v end
    for k,v in pairs(b or {}) do r[k] = v end
    return r
end

local function new(class, props, parent)
    local x = Instance.new(class)
    for k,v in pairs(props or {}) do
        pcall(function() x[k] = v end)
    end
    x.Parent = parent
    return x
end

local function corner(parent, radius)
    return new("UICorner", {CornerRadius = UDim.new(0, radius or 8)}, parent)
end

local function stroke(parent, color, transparency)
    return new("UIStroke", {
        Color = color,
        Transparency = transparency or 0,
        Thickness = 1,
    }, parent)
end

local function pad(parent, l, r, t, b)
    return new("UIPadding", {
        PaddingLeft = UDim.new(0,l or 0),
        PaddingRight = UDim.new(0,r or 0),
        PaddingTop = UDim.new(0,t or 0),
        PaddingBottom = UDim.new(0,b or 0),
    }, parent)
end

local function tween(obj, info, props)
    TweenService:Create(obj, info, props):Play()
end

local function addHoloCorner(parent, config, side)
    if not config.corner_lights then return end
    local holder = new("Frame", {
        Name = "CornerLight_" .. side,
        Size = UDim2.fromOffset(34, 3),
        BackgroundColor3 = config.main_color,
        BackgroundTransparency = .08,
        BorderSizePixel = 0,
        ZIndex = 20,
    }, parent)
    new("UICorner", {CornerRadius = UDim.new(1,0)}, holder)

    local holder2 = new("Frame", {
        Size = UDim2.fromOffset(3, 34),
        BackgroundColor3 = Color3.fromRGB(175,75,255),
        BackgroundTransparency = .08,
        BorderSizePixel = 0,
        ZIndex = 20,
    }, parent)
    new("UICorner", {CornerRadius = UDim.new(1,0)}, holder2)

    if side == "TL" then
        holder.Position = UDim2.fromOffset(10,10)
        holder2.Position = UDim2.fromOffset(10,10)
    elseif side == "TR" then
        holder.AnchorPoint = Vector2.new(1,0)
        holder.Position = UDim2.new(1,-10,0,10)
        holder2.AnchorPoint = Vector2.new(1,0)
        holder2.Position = UDim2.new(1,-10,0,10)
    elseif side == "BL" then
        holder.Position = UDim2.new(0,10,1,-13)
        holder2.Position = UDim2.new(0,10,1,-44)
    else
        holder.AnchorPoint = Vector2.new(1,1)
        holder.Position = UDim2.new(1,-10,1,-13)
        holder2.AnchorPoint = Vector2.new(1,1)
        holder2.Position = UDim2.new(1,-10,1,-44)
    end

    task.spawn(function()
        while holder and holder.Parent do
            tween(holder, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                BackgroundTransparency = .55
            })
            tween(holder2, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                BackgroundTransparency = .65
            })
            task.wait(1.1)
            if not (holder and holder.Parent) then break end
            tween(holder, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                BackgroundTransparency = .08
            })
            tween(holder2, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                BackgroundTransparency = .08
            })
            task.wait(1.1)
        end
    end)
end

local function addWindowEnergyLine(parent, config)
    if not config.energy_line then return end
    local line = new("Frame", {
        Name = "EnergyLine",
        Size = UDim2.new(0, 90, 0, 1),
        Position = UDim2.new(0, -100, 0, 2),
        BackgroundColor3 = config.main_color,
        BackgroundTransparency = .05,
        BorderSizePixel = 0,
        ZIndex = 30,
    }, parent)
    new("UICorner", {CornerRadius = UDim.new(1,0)}, line)

    local glow = new("Frame", {
        Size = UDim2.new(1, 18, 0, 5),
        Position = UDim2.new(0,-9,0,-2),
        BackgroundColor3 = Color3.fromRGB(175,75,255),
        BackgroundTransparency = .82,
        BorderSizePixel = 0,
        ZIndex = 29,
    }, line)
    new("UICorner", {CornerRadius = UDim.new(1,0)}, glow)

    task.spawn(function()
        while line and line.Parent do
            line.Position = UDim2.new(0,-100,0,2)
            tween(line, TweenInfo.new(2.6, Enum.EasingStyle.Linear), {
                Position = UDim2.new(1,10,0,2)
            })
            task.wait(2.7)
        end
    end)
end

local function addGlassHighlight(parent, config)
    if not config.glass_highlight then return end
    local shine = new("Frame", {
        Name = "GlassHighlight",
        Size = UDim2.new(.42,0,1,-20),
        Position = UDim2.new(-.5,0,0,10),
        BackgroundColor3 = Color3.fromRGB(255,255,255),
        BackgroundTransparency = .96,
        BorderSizePixel = 0,
        Rotation = 8,
        ZIndex = 3,
    }, parent)

    task.spawn(function()
        while shine and shine.Parent do
            shine.Position = UDim2.new(-.5,0,0,10)
            tween(shine, TweenInfo.new(3.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                Position = UDim2.new(1.15,0,0,10)
            })
            task.wait(4.2)
        end
    end)
end

local function addWindowBreath(parent, config)
    if not config.window_breath then return end
    local stroke = parent:FindFirstChild("NeonStroke")
    if not stroke then return end

    task.spawn(function()
        while parent and parent.Parent do
            tween(stroke, TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                Transparency = .32
            })
            task.wait(1.8)
            if not (parent and parent.Parent) then break end
            tween(stroke, TweenInfo.new(1.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                Transparency = .08
            })
            task.wait(1.8)
        end
    end)
end

local function addCorner(parent, radius)
    if not parent then return end
    local c = parent:FindFirstChildOfClass("UICorner")
    if not c then
        c = new("UICorner", {CornerRadius = UDim.new(0, radius or 10)}, parent)
    else
        c.CornerRadius = UDim.new(0, radius or 10)
    end
    return c
end

local function addShadow(parent, transparency, blur, offset)
    if not parent then return end
    local shadow = new("ImageLabel", {
        Name = "SoftShadow",
        AnchorPoint = Vector2.new(.5,.5),
        Position = UDim2.new(.5, offset or 8, .5, offset or 10),
        Size = UDim2.new(1, 28, 1, 28),
        BackgroundTransparency = 1,
        Image = "rbxassetid://6014261993",
        ImageTransparency = transparency or .55,
        ScaleType = Enum.ScaleType.Slice,
        SliceCenter = Rect.new(49,49,450,450),
        ZIndex = math.max((parent.ZIndex or 1) - 1, 0),
    }, parent)
    return shadow
end

local function addNeonStroke(parent, color1, color2, thickness)
    if not parent then return end
    local s = parent:FindFirstChild("NeonStroke")
    if not s then
        s = new("UIStroke", {
            Name = "NeonStroke",
            Thickness = thickness or 1,
            Transparency = .12,
            Color = color1 or Color3.fromRGB(0, 200, 255),
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
        }, parent)
    end

    local g = s:FindFirstChildOfClass("UIGradient")
    if not g then
        g = new("UIGradient", {
            Color = ColorSequence.new({
                ColorSequenceKeypoint.new(0, color1 or Color3.fromRGB(0,200,255)),
                ColorSequenceKeypoint.new(.5, color2 or Color3.fromRGB(170,70,255)),
                ColorSequenceKeypoint.new(1, color1 or Color3.fromRGB(0,200,255)),
            })
        }, s)
    end
    return s
end

local function addScanline(parent, config)
    if not config.scanline then return end
    local line = new("Frame", {
        Name = "Scanline",
        Size = UDim2.new(1,0,0,1),
        Position = UDim2.new(0,0,0,-2),
        BackgroundColor3 = config.main_color,
        BackgroundTransparency = .72,
        BorderSizePixel = 0,
        ZIndex = 50,
    }, parent)

    task.spawn(function()
        while line and line.Parent do
            line.Position = UDim2.new(0,0,0,-2)
            tween(line, TweenInfo.new(2.8, Enum.EasingStyle.Linear), {
                Position = UDim2.new(0,0,1,2)
            })
            task.wait(2.9)
        end
    end)
end

local function addFloatingOrbs(parent, config)
    if not config.floating_orbs then return end
    for i = 1, 5 do
        local orb = new("Frame", {
            Name = "Orb"..i,
            Size = UDim2.fromOffset(2 + i%3, 2 + i%3),
            Position = UDim2.new(.12 + i*.15, 0, .18 + (i%3)*.22, 0),
            BackgroundColor3 = i%2 == 0 and config.main_color or Color3.fromRGB(175,75,255),
            BackgroundTransparency = .28,
            BorderSizePixel = 0,
            ZIndex = 1,
        }, parent)
        new("UICorner", {CornerRadius = UDim.new(1,0)}, orb)

        task.spawn(function()
            while orb and orb.Parent do
                local p = orb.Position
                tween(orb, TweenInfo.new(2.2 + i*.25, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                    Position = p + UDim2.fromOffset(0, i%2 == 0 and 12 or -12)
                })
                task.wait(2.2 + i*.25)
                if not (orb and orb.Parent) then break end
                tween(orb, TweenInfo.new(2.2 + i*.25, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                    Position = p
                })
                task.wait(2.2 + i*.25)
            end
        end)
    end
end

local function addParticles(parent, config)
    if not config.particles then return end
    local count = math.clamp(config.particle_count or 18, 1, 40)
    for i = 1, count do
        local dot = new("Frame", {
            Name = "Particle"..i,
            Size = UDim2.fromOffset(math.random(1,3), math.random(1,3)),
            Position = UDim2.new(math.random(),0,math.random(),0),
            BackgroundColor3 = i%2 == 0 and config.main_color or Color3.fromRGB(175,75,255),
            BackgroundTransparency = math.random(35,75)/100,
            BorderSizePixel = 0,
            ZIndex = 2,
        }, parent)
        new("UICorner", {CornerRadius = UDim.new(1,0)}, dot)

        task.spawn(function()
            while dot and dot.Parent do
                local start = dot.Position
                local target = UDim2.new(
                    math.clamp(start.X.Scale + (math.random(-12,12)/100), 0, 1), 0,
                    math.clamp(start.Y.Scale + (math.random(-18,18)/100), 0, 1), 0
                )
                tween(dot, TweenInfo.new(math.random(18,34)/10, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                    Position = target,
                    BackgroundTransparency = math.random(25,80)/100
                })
                task.wait(math.random(18,34)/10)
            end
        end)
    end
end

local function addScale(parent, value)
    local s = parent:FindFirstChildOfClass("UIScale")
    if not s then
        s = new("UIScale", {Scale = value or 1}, parent)
    else
        s.Scale = value or 1
    end
    return s
end

local function animateScale(parent, fromScale, toScale, duration, style, direction)
    local s = addScale(parent, fromScale)
    tween(s, TweenInfo.new(
        duration or 0.22,
        style or Enum.EasingStyle.Quint,
        direction or Enum.EasingDirection.Out
    ), {Scale = toScale or 1})
    return s
end

local function hoverScale(guiObject, config, amount)
    if not config.hover_animation then return end
    local scale = addScale(guiObject, 1)
    guiObject.MouseEnter:Connect(function()
        tween(scale, TweenInfo.new(.13, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Scale = amount or 1.025
        })
    end)
    guiObject.MouseLeave:Connect(function()
        tween(scale, TweenInfo.new(.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Scale = 1
        })
    end)
end

local function pulse(guiObject, config, minScale, maxScale)
    if not config.pulse_animation then return end
    task.spawn(function()
        while guiObject and guiObject.Parent do
            tween(guiObject, TweenInfo.new(.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                TextTransparency = 0.12
            })
            task.wait(.8)
            if not (guiObject and guiObject.Parent) then break end
            tween(guiObject, TweenInfo.new(.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                TextTransparency = 0
            })
            task.wait(.8)
        end
    end)
end

local function animateCardIn(card, delayTime, config)
    if not config.card_animation then return end
    task.delay(delayTime or 0, function()
        if not (card and card.Parent) then return end
        local scale = addScale(card, .965)
        local originalPos = card.Position
        card.Position = originalPos + UDim2.fromOffset(12, 0)
        tween(card, TweenInfo.new(config.animation_speed, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            Position = originalPos
        })
        tween(scale, TweenInfo.new(config.animation_speed, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Scale = 1
        })
    end)
end

local function sweepGlow(frame, config)
    if not config.animated then return end
    task.spawn(function()
        local gradient = frame:FindFirstChildOfClass("UIGradient")
        if not gradient then return end
        while frame and frame.Parent do
            gradient.Offset = Vector2.new(-1.2, 0)
            tween(gradient, TweenInfo.new(1.8, Enum.EasingStyle.Linear), {
                Offset = Vector2.new(1.2, 0)
            })
            task.wait(2.0)
        end
    end)
end

local function makeDraggable(handle, target)
    local dragging, dragStart, startPos
    handle.InputBegan:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and
           input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragging = true
        dragStart = input.Position
        startPos = target.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then dragging = false end
        end)
    end)
    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        if input.UserInputType ~= Enum.UserInputType.MouseMovement and
           input.UserInputType ~= Enum.UserInputType.Touch then return end
        local delta = input.Position - dragStart
        target.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y
        )
    end)
end


local function playClick(config)
    if not config or not config.click_sound or tostring(config.click_sound_id or "") == "" then return end
    local ok, sound = pcall(function()
        local s = Instance.new("Sound")
        s.SoundId = tostring(config.click_sound_id)
        s.Volume = tonumber(config.click_volume) or 0.18
        s.PlayOnRemove = false
        s.Parent = SoundService
        return s
    end)
    if not ok or not sound then return end
    sound:Play()
    task.delay(2, function() pcall(function() sound:Destroy() end) end)
end

local function addGradient(parent, color1, color2, rotation)
    local g = Instance.new("UIGradient")
    g.Color = ColorSequence.new(color1, color2)
    g.Rotation = rotation or 0
    g.Parent = parent
    return g
end

local function addGlow(parent, color, transparency)
    local s = Instance.new("UIStroke")
    s.Color = color
    s.Transparency = transparency or 0.55
    s.Thickness = 2
    s.Parent = parent
    return s
end

local function addText(parent, text, size, color, font)
    return new("TextLabel", {
        BackgroundTransparency = 1,
        Text = tostring(text or ""),
        TextColor3 = color,
        TextSize = size or 14,
        Font = font or Enum.Font.Gotham,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        ClipsDescendants = true,
    }, parent)
end

local function bindCommon(control, callback)
    control.MouseButton1Click:Connect(function()
        if callback then callback() end
    end)
end

function Library:AddWindow(title, config)
    config = merge(DEFAULTS, config)
    local window = {
        Library = self,
        Config = config,
        Tabs = {},
        ActiveTab = nil,
        Visible = true,
    }
    setmetatable(window, {__index = Library.WindowMethods})

    local gui = new("ScreenGui", {
        Name = "UAI_EasyLibrary",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 2147480000,
    }, getParent())
    window.Gui = gui

    local root = new("Frame", {
        Name = "Window",
        AnchorPoint = Vector2.new(.5,.5),
        Position = UDim2.fromScale(.5,.5),
        Size = UDim2.fromOffset(config.size.X, config.size.Y),
        BackgroundColor3 = config.background,
        BackgroundTransparency = config.transparency,
        BorderSizePixel = 0,
    }, gui)
    addCorner(root, 14)
    if config.depth_shadow then addShadow(root, .48, 24, 7) end
    if config.neon_border then addNeonStroke(root, config.main_color, Color3.fromRGB(175,75,255), 1.2) end
    addParticles(root, config)
    addFloatingOrbs(root, config)
    addScanline(root, config)
    addGlassHighlight(root, config)
    addWindowBreath(root, config)
    addWindowEnergyLine(root, config)
    addHoloCorner(root, config, "TL")
    addHoloCorner(root, config, "TR")
    addHoloCorner(root, config, "BL")
    addHoloCorner(root, config, "BR")

    if config.top_orb then
        local orb = new("Frame", {
            Name = "TopOrb",
            Size = UDim2.fromOffset(8,8),
            AnchorPoint = Vector2.new(.5,.5),
            Position = UDim2.new(.5,0,0,0),
            BackgroundColor3 = config.main_color,
            BorderSizePixel = 0,
            ZIndex = 40,
        }, root)
        new("UICorner", {CornerRadius = UDim.new(1,0)}, orb)
        task.spawn(function()
            while orb and orb.Parent do
                tween(orb, TweenInfo.new(.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                    Size = UDim2.fromOffset(12,12),
                    BackgroundTransparency = .35
                })
                task.wait(.8)
                tween(orb, TweenInfo.new(.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                    Size = UDim2.fromOffset(8,8),
                    BackgroundTransparency = 0
                })
                task.wait(.8)
            end
        end)
    end

    corner(root, 12)
    stroke(root, config.border)
    if config.glow then addGlow(root, config.main_color, 0.72) end
    window.Root = root

    -- Futuristic top glow line
    local topGlow = new("Frame", {
        Name = "TopGlow",
        Size = UDim2.new(1, -32, 0, 2),
        Position = UDim2.new(0, 16, 0, 46),
        BackgroundColor3 = config.main_color,
        BorderSizePixel = 0,
        BackgroundTransparency = 0.05,
    }, root)
    if config.animated then
        addGradient(topGlow, config.main_color, Color3.fromRGB(180, 90, 255), 0)
        sweepGlow(topGlow, config)
        local rootStroke = root:FindFirstChild("NeonStroke")
        if rootStroke then
            task.spawn(function()
                local g = rootStroke:FindFirstChildOfClass("UIGradient")
                if g then
                    while root and root.Parent do
                        g.Offset = Vector2.new(-1,0)
                        tween(g, TweenInfo.new(2.2, Enum.EasingStyle.Linear), {Offset = Vector2.new(1,0)})
                        task.wait(2.25)
                    end
                end
            end)
        end
    end

    if config.entrance_animation then
        addScale(root, .88)
        root.BackgroundTransparency = 1
        tween(root, TweenInfo.new(.45, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            BackgroundTransparency = config.transparency
        })
        tween(root:FindFirstChildOfClass("UIScale"), TweenInfo.new(.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Scale = 1
        })
    end

    local top = new("Frame", {
        Name = "TopBar",
        Size = UDim2.new(1,0,0,48),
        BackgroundTransparency = 1,
    }, root)
    window.TopBar = top
    makeDraggable(top, root)

    local accent = new("Frame", {
        Size = UDim2.new(0,3,0,22),
        Position = UDim2.new(0,14,0,13),
        BackgroundColor3 = config.main_color,
        BorderSizePixel = 0,
    }, top)
    corner(accent, 2)

    local titleLabel = addText(top, title or "UAI", 15, config.text, Enum.Font.GothamSemibold)
    titleLabel.Position = UDim2.new(0,25,0,0)
    titleLabel.Size = UDim2.new(1,-190,1,0)

    local status = addText(top, "● ONLINE", 10, config.main_color, Enum.Font.GothamMedium)
    status.Position = UDim2.new(1,-155,0,0)
    status.Size = UDim2.fromOffset(85,48)
    status.TextXAlignment = Enum.TextXAlignment.Right
    pulse(status, config)

    local statusDot = new("Frame", {
        Size = UDim2.fromOffset(5,5),
        Position = UDim2.new(1,-62,.5,-2),
        BackgroundColor3 = Color3.fromRGB(80,255,170),
        BorderSizePixel = 0,
        ZIndex = 20,
    }, top)
    new("UICorner", {CornerRadius = UDim.new(1,0)}, statusDot)
    task.spawn(function()
        while statusDot and statusDot.Parent do
            tween(statusDot, TweenInfo.new(.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                BackgroundTransparency = .7
            })
            task.wait(.75)
            tween(statusDot, TweenInfo.new(.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
                BackgroundTransparency = 0
            })
            task.wait(.75)
        end
    end)

    local titleLine = new("Frame", {
        Name = "TitleEnergyLine",
        Size = UDim2.new(.32,0,0,1),
        Position = UDim2.new(0,18,1,-1),
        BackgroundColor3 = config.main_color,
        BackgroundTransparency = .12,
        BorderSizePixel = 0,
        ZIndex = 30,
    }, top)
    new("UICorner", {CornerRadius = UDim.new(1,0)}, titleLine)

    local close = new("TextButton", {
        Text = "×",
        TextColor3 = config.muted,
        TextSize = 23,
        Font = Enum.Font.Gotham,
        BackgroundTransparency = 1,
        Size = UDim2.fromOffset(38,38),
        Position = UDim2.new(1,-45,0,5),
        AutoButtonColor = false,
    }, top)
    close.MouseEnter:Connect(function() tween(close,TweenInfo.new(.1),{TextColor3=config.text}) end)
    close.MouseLeave:Connect(function() tween(close,TweenInfo.new(.1),{TextColor3=config.muted}) end)
    close.MouseButton1Click:Connect(function() window:Toggle() end)

    local body = new("Frame", {
        Name = "Body",
        Position = UDim2.new(0,10,0,48),
        Size = UDim2.new(1,-20,1,-58),
        BackgroundTransparency = 1,
    }, root)

    local nav = new("ScrollingFrame", {
        Name = "Navigation",
        Size = UDim2.new(0,145,1,0),
        BackgroundColor3 = config.surface,
        BorderSizePixel = 0,
        ScrollBarThickness = 0,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, body)
    corner(nav, 9)
    pad(nav,6,6,7,7)
    local navLayout = new("UIListLayout", {Padding=UDim.new(0,4), SortOrder=Enum.SortOrder.LayoutOrder}, nav)

    local content = new("Frame", {
        Name = "Content",
        Position = UDim2.new(0,153,0,0),
        Size = UDim2.new(1,-153,1,0),
        BackgroundColor3 = config.surface,
        BorderSizePixel = 0,
    }, body)
    corner(content, 9)

    local pageHolder = new("Frame", {
        Size = UDim2.new(1,0,1,0),
        BackgroundTransparency = 1,
    }, content)
    pad(pageHolder,14,14,12,12)

    window.Nav = nav
    window.Content = content
    window.PageHolder = pageHolder

    if config.can_resize then
        local grip = new("TextButton", {
            Size = UDim2.fromOffset(18,18),
            Position = UDim2.new(1,-18,1,-18),
            Text = "",
            BackgroundTransparency = 1,
            AutoButtonColor = false,
        }, root)
        local resizing, startMouse, startSize
        grip.InputBegan:Connect(function(input)
            if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
            resizing = true
            startMouse = input.Position
            startSize = root.AbsoluteSize
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then resizing = false end
            end)
        end)
        UserInputService.InputChanged:Connect(function(input)
            if not resizing then return end
            if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
            local d = input.Position - startMouse
            local x = math.max(config.min_size.X, startSize.X+d.X)
            local y = math.max(config.min_size.Y, startSize.Y+d.Y)
            root.Size = UDim2.fromOffset(x,y)
        end)
    end

    UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == config.toggle_key then window:Toggle() end
    end)

    return window
end

Library.WindowMethods = {}

function Library.WindowMethods:AddTab(name)
    local window = self
    local tab = {
        Window = window,
        Name = tostring(name),
        Controls = {},
    }
    setmetatable(tab, {__index = Library.TabMethods})

    local navButton = new("TextButton", {
        Name = "Tab_"..tostring(name),
        Size = UDim2.new(1,0,0,36),
        BackgroundColor3 = window.Config.surface2,
        BackgroundTransparency = 1,
        Text = tostring(name),
        TextColor3 = window.Config.muted,
        TextSize = 13,
        Font = Enum.Font.GothamMedium,
        TextXAlignment = Enum.TextXAlignment.Left,
        AutoButtonColor = false,
    }, window.Nav)
    corner(navButton, 7)
    pad(navButton,11,6,0,0)
    hoverScale(navButton, window.Config, 1.035)
    addCorner(navButton, 8)
    if window.Config.neon_border then
        addNeonStroke(navButton, window.Config.main_color, Color3.fromRGB(175,75,255), .7)
    end

    local page = new("ScrollingFrame", {
        Name = tostring(name),
        Size = UDim2.new(1,0,1,0),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = window.Config.border,
        Visible = false,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, window.PageHolder)
    local layout = new("UIListLayout", {Padding=UDim.new(0,8), SortOrder=Enum.SortOrder.LayoutOrder}, page)
    pad(page,2,5,2,2)

    tab.NavButton = navButton
    tab.Page = page
    tab.Layout = layout
    table.insert(window.Tabs, tab)

    navButton.MouseButton1Click:Connect(function()
        window:SelectTab(tab)
    end)

    if not window.ActiveTab then window:SelectTab(tab) end
    return tab
end

function Library.WindowMethods:SelectTab(tab)
    playClick(self.Config)
    for _,t in ipairs(self.Tabs) do
        local active = t == tab
        t.Page.Visible = active
        t.NavButton.BackgroundTransparency = active and 0 or 1
        t.NavButton.BackgroundColor3 = self.Config.surface2
        t.NavButton.TextColor3 = active and self.Config.text or self.Config.muted

        if active then
            t.NavButton.TextColor3 = self.Config.main_color
            if self.Config.tab_animation then
                animateScale(t.NavButton, .96, 1, .20, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
                t.Page.CanvasPosition = Vector2.new(0, 0)
            end

            if self.Config.card_animation then
                for i, child in ipairs(t.Page:GetChildren()) do
                    if child:IsA("GuiObject") and child ~= t.Layout then
                        animateCardIn(child, math.min((i - 1) * .035, .28), self.Config)
                    end
                end
            end
        end
    end
    self.ActiveTab = tab
end

function Library.WindowMethods:Toggle()
    if self.Visible then
        self:Hide()
    else
        self:Show()
    end
end

function Library.WindowMethods:Show()
    self.Visible = true
    self.Root.Visible = true
    if self.Config.entrance_animation then
        local scale = addScale(self.Root, .90)
        tween(scale, TweenInfo.new(.34, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1})
    end
end

function Library.WindowMethods:Hide()
    if self.Config.entrance_animation then
        local scale = addScale(self.Root, 1)
        tween(scale, TweenInfo.new(.20, Enum.EasingStyle.Quint, Enum.EasingDirection.In), {Scale = .90})
        task.delay(.20, function()
            if self.Root then
                self.Visible = false
                self.Root.Visible = false
            end
        end)
    else
        self.Visible = false
        self.Root.Visible = false
    end
end

function Library.WindowMethods:FormatWindows()
    return self
end

function Library.WindowMethods:Destroy()
    if self.Gui then self.Gui:Destroy() end
end

-- Tab methods must exist before defining methods with the `Library.TabMethods:...` syntax.
-- Without this table, Lua tries to index nil while loading the library.
Library.TabMethods = {}

local function addCard(tab, height)
    local card = new("Frame", {
        Size = UDim2.new(1,-4,0,height or 44),
        BackgroundColor3 = tab.Window.Config.background,
        BorderSizePixel = 0,
    }, tab.Page)
    corner(card, 8)
    stroke(card, tab.Window.Config.border)
    animateCardIn(card, 0, tab.Window.Config)
    hoverScale(card, tab.Window.Config, 1.008)
    return card
end

function Library.TabMethods:AddLabel(text)
    local card = addCard(self, 40)
    local label = addText(card,text,13,self.Window.Config.text)
    label.Position = UDim2.new(0,12,0,0)
    label.Size = UDim2.new(1,-24,1,0)
    return label
end

function Library.TabMethods:AddButton(text, callback)
    local card = addCard(self, 44)
    local button = new("TextButton", {
        Size=UDim2.new(1,-8,1,-8), Position=UDim2.new(0,4,0,4),
        BackgroundColor3=self.Window.Config.surface2, Text=tostring(text),
        TextColor3=self.Window.Config.text, TextSize=13, Font=Enum.Font.GothamMedium,
        AutoButtonColor=false,
    }, card)
    corner(button,7)
    hoverScale(button, self.Window.Config, 1.035)
    button.MouseEnter:Connect(function()
        tween(button,TweenInfo.new(.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),{
            BackgroundColor3=self.Window.Config.main_color
        })
    end)
    button.MouseLeave:Connect(function()
        tween(button,TweenInfo.new(.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),{
            BackgroundColor3=self.Window.Config.surface2
        })
    end)
    button.MouseButton1Click:Connect(function()
        playClick(self.Window.Config)
        if self.Window.Config.animated then
            local s = addScale(button, 1)
            tween(s, TweenInfo.new(.07, Enum.EasingStyle.Quad), {Scale = .96})
            task.delay(.07, function()
                if s and s.Parent then
                    tween(s, TweenInfo.new(.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Scale = 1})
                end
            end)
        end
        if callback then callback() end
    end)
    return button
end

function Library.TabMethods:AddSwitch(text, callback)
    local card=addCard(self,44)
    local label=addText(card,text,13,self.Window.Config.text)
    label.Position=UDim2.new(0,12,0,0); label.Size=UDim2.new(1,-75,1,0)
    local sw=new("TextButton",{Size=UDim2.fromOffset(42,22),Position=UDim2.new(1,-54,.5,-11),Text="",AutoButtonColor=false,BackgroundColor3=self.Window.Config.surface2},card)
    corner(sw,11); stroke(sw,self.Window.Config.border)
    hoverScale(sw, self.Window.Config, 1.08)
    local knob=new("Frame",{Size=UDim2.fromOffset(16,16),Position=UDim2.new(0,3,.5,-8),BackgroundColor3=self.Window.Config.muted,BorderSizePixel=0},sw)
    corner(knob,8)
    local state=false
    local function set(v, silent)
        state=not not v
        tween(sw,TweenInfo.new(.12),{BackgroundColor3=state and self.Window.Config.main_color or self.Window.Config.surface2})
        tween(knob,TweenInfo.new(.12),{Position=state and UDim2.new(1,-19,.5,-8) or UDim2.new(0,3,.5,-8),BackgroundColor3=state and Color3.new(1,1,1) or self.Window.Config.muted})
        if not silent and callback then callback(state) end
    end
    sw.MouseButton1Click:Connect(function()
        playClick(self.Window.Config)
        set(not state)
    end)
    return {Set=set,Get=function() return state end,Instance=sw}
end

function Library.TabMethods:AddTextBox(placeholder, callback, options)
    options=options or {}
    local card=addCard(self,44)
    local box=new("TextBox",{Size=UDim2.new(1,-16,1,-12),Position=UDim2.new(0,8,0,6),BackgroundColor3=self.Window.Config.surface2,TextColor3=self.Window.Config.text,PlaceholderColor3=self.Window.Config.muted,PlaceholderText=tostring(placeholder),Text="",TextSize=13,Font=Enum.Font.Gotham,ClearTextOnFocus=false},card)
    corner(box,7); pad(box,10,10,0,0)
    box.FocusLost:Connect(function(enter) if callback then callback(box.Text,enter) end end)
    return box
end

function Library.TabMethods:AddSlider(text, callback, options)
    options=options or {}
    local min,max=options.min or 0, options.max or 100
    local value=options.default or min
    local card=addCard(self,58)
    local label=addText(card,text,12,self.Window.Config.text); label.Position=UDim2.new(0,12,0,5); label.Size=UDim2.new(1,-80,0,20)
    local val=addText(card,tostring(value),12,self.Window.Config.muted); val.Position=UDim2.new(1,-55,0,5); val.Size=UDim2.new(0,43,0,20); val.TextXAlignment=Enum.TextXAlignment.Right
    local bar=new("TextButton",{Size=UDim2.new(1,-24,0,6),Position=UDim2.new(0,12,1,-15),Text="",AutoButtonColor=false,BackgroundColor3=self.Window.Config.surface2},card); corner(bar,3)
    local fill=new("Frame",{Size=UDim2.new((value-min)/(max-min),0,1,0),BackgroundColor3=self.Window.Config.main_color,BorderSizePixel=0},bar); corner(fill,3)
    local function set(v)
        value=math.clamp(v,min,max); local a=(value-min)/(max-min)
        fill.Size=UDim2.new(a,0,1,0); val.Text=tostring(math.floor(value*100)/100)
        if callback then callback(value) end
    end
    bar.MouseButton1Down:Connect(function()
        local move
        local function update(x) set(min+(max-min)*math.clamp((x-bar.AbsolutePosition.X)/bar.AbsoluteSize.X,0,1)) end
        update(UserInputService:GetMouseLocation().X)
        move=UserInputService.InputChanged:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseMovement then update(i.Position.X) end end)
        local endc
        endc=UserInputService.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 then move:Disconnect(); endc:Disconnect() end end)
    end)
    return {Set=set,Get=function() return value end}
end

function Library.TabMethods:AddDropdown(text, callback)
    local card=addCard(self,44)
    local button=new("TextButton",{Size=UDim2.new(1,-16,1,-12),Position=UDim2.new(0,8,0,6),BackgroundColor3=self.Window.Config.surface2,Text=tostring(text).."  ▾",TextColor3=self.Window.Config.text,TextSize=13,Font=Enum.Font.Gotham,TextXAlignment=Enum.TextXAlignment.Left,AutoButtonColor=false},card)
    corner(button,7); pad(button,10,10,0,0)
    local drop={Items={},Button=button}
    function drop:Add(item)
        table.insert(self.Items,item)
        local menu=card:FindFirstChild("Menu")
        if not menu then
            menu=new("Frame",{Name="Menu",Position=UDim2.new(0,0,1,5),Size=UDim2.new(1,0,0,0),BackgroundColor3=self.Window.Config.surface2,BorderSizePixel=0,ZIndex=20,Visible=false},card); corner(menu,7); stroke(menu,self.Window.Config.border)
            new("UIListLayout",{Padding=UDim.new(0,2)},menu)
        end
        local b=new("TextButton",{Size=UDim2.new(1,0,0,30),BackgroundTransparency=1,Text=tostring(item),TextColor3=self.Window.Config.text,TextSize=12,Font=Enum.Font.Gotham,AutoButtonColor=false,ZIndex=21},menu)
        b.MouseButton1Click:Connect(function()
            button.Text=tostring(item).."  ▾"; menu.Visible=false
            if callback then callback(item) end
        end)
        menu.Size=UDim2.new(1,0,0,#self.Items*32+4)
        return self
    end
    button.MouseButton1Click:Connect(function()
        local m=card:FindFirstChild("Menu"); if m then m.Visible=not m.Visible end
    end)
    return drop
end

function Library.TabMethods:AddKeybind(text, callback, options)
    options=options or {}
    local key=options.default or Enum.KeyCode.RightShift
    local card=addCard(self,44)
    local label=addText(card,text,13,self.Window.Config.text); label.Position=UDim2.new(0,12,0,0); label.Size=UDim2.new(1,-110,1,0)
    local b=new("TextButton",{Size=UDim2.fromOffset(82,28),Position=UDim2.new(1,-94,.5,-14),BackgroundColor3=self.Window.Config.surface2,Text=key.Name,TextColor3=self.Window.Config.muted,TextSize=12,Font=Enum.Font.Gotham,AutoButtonColor=false},card); corner(b,6)
    local listening=false
    b.MouseButton1Click:Connect(function()
        playClick(self.Window.Config)
        listening=true; b.Text="Press key..."
    end)
    UserInputService.InputBegan:Connect(function(input,gp)
        if listening and input.UserInputType==Enum.UserInputType.Keyboard then
            key=input.KeyCode; listening=false; b.Text=key.Name
            if callback then callback(key) end
        end
    end)
    return {Get=function() return key end,Set=function(k) key=k; b.Text=k.Name end}
end

function Library.TabMethods:AddColorPicker(callback)
    local card=addCard(self,44)
    local current=self.Window.Config.main_color
    local button=new("TextButton",{Size=UDim2.fromOffset(90,28),Position=UDim2.new(1,-102,.5,-14),BackgroundColor3=current,Text="Color",TextColor3=Color3.new(1,1,1),TextSize=12,Font=Enum.Font.Gotham,AutoButtonColor=false},card); corner(button,6)
    button.MouseButton1Click:Connect(function()
        playClick(self.Window.Config)
        if callback then callback(current) end
    end)
    return {Set=function(c) current=c; button.BackgroundColor3=c; if callback then callback(c) end end,Get=function() return current end}
end

function Library.TabMethods:AddHorizontalAlignment()
    local holder=new("Frame",{Size=UDim2.new(1,-4,0,2),BackgroundTransparency=1},self.Page)
    return holder
end

function Library.TabMethods:AddFolder(name)
    local folder = {}
    setmetatable(folder,{__index=self})
    folder.Name=name
    local header=addCard(self,38)
    local label=addText(header,name,12,self.Window.Config.main_color)
    label.Position=UDim2.new(0,12,0,0); label.Size=UDim2.new(1,-24,1,0)
    return folder
end

--==============================================================
-- Extra UAI-style features
--==============================================================

function Library.WindowMethods:SetTitle(text)
    local label = self.TopBar and self.TopBar:FindFirstChildWhichIsA("TextLabel")
    if label then label.Text = tostring(text) end
    return self
end

function Library.WindowMethods:SetSize(width, height)
    local w = math.max(self.Config.min_size.X, tonumber(width) or self.Config.size.X)
    local h = math.max(self.Config.min_size.Y, tonumber(height) or self.Config.size.Y)
    self.Root.Size = UDim2.fromOffset(w, h)
    return self
end

function Library.WindowMethods:Minimize()
    if self._minimized then
        self._minimized = false
        self.Body.Visible = true
        self.Root.Size = self._oldSize or UDim2.fromOffset(self.Config.size.X, self.Config.size.Y)
    else
        self._oldSize = self.Root.Size
        self._minimized = true
        self.Body.Visible = false
        self.Root.Size = UDim2.fromOffset(math.max(self.Config.min_size.X, 360), 48)
    end
    return self
end

function Library.WindowMethods:AddNotification(title, message, duration)
    duration = tonumber(duration) or 3
    local gui = self.Gui
    if not gui then return end

    local holder = gui:FindFirstChild("UAI_Notifications")
    if not holder then
        holder = new("Frame", {
            Name = "UAI_Notifications",
            AnchorPoint = Vector2.new(1,1),
            Position = UDim2.new(1,-18,1,-18),
            Size = UDim2.fromOffset(320, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            ZIndex = 1000,
        }, gui)
        new("UIListLayout", {
            Padding = UDim.new(0,8),
            HorizontalAlignment = Enum.HorizontalAlignment.Right,
            VerticalAlignment = Enum.VerticalAlignment.Bottom,
            SortOrder = Enum.SortOrder.LayoutOrder,
        }, holder)
    end

    local card = new("Frame", {
        Size = UDim2.new(1,0,0,72),
        BackgroundColor3 = self.Config.surface,
        BorderSizePixel = 0,
        BackgroundTransparency = 1,
        ZIndex = 1001,
    }, holder)
    corner(card, 9)
    stroke(card, self.Config.border)

    local accent = new("Frame", {
        Size = UDim2.new(0,3,1,-20),
        Position = UDim2.new(0,8,0,10),
        BackgroundColor3 = self.Config.main_color,
        BorderSizePixel = 0,
        ZIndex = 1002,
    }, card)
    corner(accent, 2)

    local t = addText(card, title or "UAI", 13, self.Config.text, Enum.Font.GothamSemibold)
    t.Position = UDim2.new(0,22,0,8)
    t.Size = UDim2.new(1,-32,0,20)
    t.ZIndex = 1002

    local m = addText(card, message or "", 11, self.Config.muted)
    m.Position = UDim2.new(0,22,0,29)
    m.Size = UDim2.new(1,-32,0,35)
    m.TextWrapped = true
    m.ZIndex = 1002

    tween(card, TweenInfo.new(.18), {BackgroundTransparency = 0})
    task.delay(duration, function()
        if card and card.Parent then
            tween(card, TweenInfo.new(.18), {BackgroundTransparency = 1})
            task.wait(.2)
            if card then card:Destroy() end
        end
    end)

    return card
end

function Library.TabMethods:AddSeparator()
    local line = new("Frame", {
        Size = UDim2.new(1,-4,0,1),
        BackgroundColor3 = self.Window.Config.border,
        BorderSizePixel = 0,
    }, self.Page)
    return line
end

function Library.TabMethods:AddSection(title, subtitle)
    local card = addCard(self, subtitle and 58 or 38)
    local label = addText(card, title or "Section", 13, self.Window.Config.main_color, Enum.Font.GothamSemibold)
    label.Position = UDim2.new(0,12,0,6)
    label.Size = UDim2.new(1,-24,0,20)

    if subtitle then
        local desc = addText(card, subtitle, 11, self.Window.Config.muted)
        desc.Position = UDim2.new(0,12,0,27)
        desc.Size = UDim2.new(1,-24,0,20)
        desc.TextWrapped = true
    end
    return card
end

function Library.TabMethods:AddParagraph(title, text)
    local card = addCard(self, 76)
    local head = addText(card, title or "Information", 13, self.Window.Config.text, Enum.Font.GothamSemibold)
    head.Position = UDim2.new(0,12,0,7)
    head.Size = UDim2.new(1,-24,0,20)

    local body = addText(card, text or "", 11, self.Window.Config.muted)
    body.Position = UDim2.new(0,12,0,28)
    body.Size = UDim2.new(1,-24,0,40)
    body.TextWrapped = true
    body.TextYAlignment = Enum.TextYAlignment.Top
    return card
end

function Library.TabMethods:AddProgressBar(text, options)
    options = options or {}
    local value = tonumber(options.default) or 0
    local min = tonumber(options.min) or 0
    local max = tonumber(options.max) or 100
    if max <= min then max = min + 1 end

    local card = addCard(self, 58)
    local label = addText(card, text or "Progress", 12, self.Window.Config.text)
    label.Position = UDim2.new(0,12,0,6)
    label.Size = UDim2.new(1,-75,0,18)

    local valueLabel = addText(card, "", 11, self.Window.Config.muted)
    valueLabel.Position = UDim2.new(1,-58,0,6)
    valueLabel.Size = UDim2.fromOffset(46,18)
    valueLabel.TextXAlignment = Enum.TextXAlignment.Right

    local bar = new("Frame", {
        Size = UDim2.new(1,-24,0,7),
        Position = UDim2.new(0,12,1,-17),
        BackgroundColor3 = self.Window.Config.surface2,
        BorderSizePixel = 0,
    }, card)
    corner(bar, 4)

    local fill = new("Frame", {
        Size = UDim2.new(0,0,1,0),
        BackgroundColor3 = self.Window.Config.main_color,
        BorderSizePixel = 0,
    }, bar)
    corner(fill, 4)

    local api = {}
    function api:Set(v)
        value = math.clamp(tonumber(v) or min, min, max)
        local a = (value-min)/(max-min)
        fill.Size = UDim2.new(a,0,1,0)
        valueLabel.Text = tostring(math.floor(value*100)/100)
        return api
    end
    function api:Get() return value end
    api:Set(value)
    return api
end

function Library.TabMethods:AddStatus(text, status)
    local card = addCard(self, 42)
    local dot = new("Frame", {
        Size = UDim2.fromOffset(9,9),
        Position = UDim2.new(0,12,.5,-4),
        BackgroundColor3 = self.Window.Config.main_color,
        BorderSizePixel = 0,
    }, card)
    corner(dot, 5)

    local label = addText(card, text or "Status", 12, self.Window.Config.text)
    label.Position = UDim2.new(0,30,0,0)
    label.Size = UDim2.new(1,-42,1,0)

    local api = {}
    function api:Set(value)
        status = tostring(value or "")
        label.Text = tostring(text or "Status") .. (status ~= "" and " • "..status or "")
        return api
    end
    function api:SetColor(color)
        dot.BackgroundColor3 = color
        return api
    end
    api:Set(status)
    return api
end

function Library.TabMethods:AddMultiDropdown(text, callback)
    local card = addCard(self, 44)
    local button = new("TextButton", {
        Size=UDim2.new(1,-16,1,-12),
        Position=UDim2.new(0,8,0,6),
        BackgroundColor3=self.Window.Config.surface2,
        Text=tostring(text or "Select"),
        TextColor3=self.Window.Config.text,
        TextSize=13,
        Font=Enum.Font.Gotham,
        TextXAlignment=Enum.TextXAlignment.Left,
        AutoButtonColor=false,
    }, card)
    corner(button,7)
    pad(button,10,10,0,0)

    local api = {Items={}, Selected={}, Button=button}

    local menu = new("Frame", {
        Name="MultiMenu",
        Position=UDim2.new(0,0,1,5),
        Size=UDim2.new(1,0,0,4),
        BackgroundColor3=self.Window.Config.surface2,
        BorderSizePixel=0,
        ZIndex=30,
        Visible=false,
    }, card)
    corner(menu,7)
    stroke(menu,self.Window.Config.border)
    new("UIListLayout",{Padding=UDim.new(0,2)},menu)

    local function refresh()
        local names = {}
        for item, selected in pairs(api.Selected) do
            if selected then names[#names+1] = tostring(item) end
        end
        button.Text = (#names > 0 and table.concat(names,", ") or tostring(text or "Select")) .. "  ▾"
        if callback then callback(names, api.Selected) end
    end

    function api:Add(item)
        item = tostring(item)
        table.insert(self.Items,item)

        local row = new("TextButton", {
            Size=UDim2.new(1,0,0,30),
            BackgroundTransparency=1,
            Text="□  "..item,
            TextColor3=self.Window.Config.text,
            TextSize=12,
            Font=Enum.Font.Gotham,
            TextXAlignment=Enum.TextXAlignment.Left,
            AutoButtonColor=false,
            ZIndex=31,
        }, menu)
        pad(row,10,4,0,0)

        row.MouseButton1Click:Connect(function()
            playClick(self.Window.Config)
            self.Selected[item] = not self.Selected[item]
            row.Text = (self.Selected[item] and "✓  " or "□  ")..item
            refresh()
        end)

        menu.Size=UDim2.new(1,0,0,#self.Items*32+4)
        return self
    end

    button.MouseButton1Click:Connect(function()
        playClick(self.Window.Config)
        menu.Visible = not menu.Visible
    end)

    return api
end

function Library.TabMethods:AddImage(asset, height)
    local card = addCard(self, tonumber(height) or 150)
    local image = new("ImageLabel", {
        Size=UDim2.new(1,-12,1,-12),
        Position=UDim2.new(0,6,0,6),
        BackgroundColor3=self.Window.Config.surface2,
        Image=tostring(asset or ""),
        ScaleType=Enum.ScaleType.Crop,
        BorderSizePixel=0,
    }, card)
    corner(image,7)
    stroke(image, self.Window.Config.border, 0.15)
    return image
end

function Library.TabMethods:AddColorLabel(text, color)
    local card = addCard(self, 42)
    local label = addText(card, text or "Color", 12, self.Window.Config.text)
    label.Position = UDim2.new(0,12,0,0)
    label.Size = UDim2.new(1,-65,1,0)

    local swatch = new("Frame", {
        Size=UDim2.fromOffset(30,20),
        Position=UDim2.new(1,-42,.5,-10),
        BackgroundColor3=color or self.Window.Config.main_color,
        BorderSizePixel=0,
    }, card)
    corner(swatch,6)
    stroke(swatch,self.Window.Config.border)
    return swatch
end

return setmetatable({}, {__index=Library})
