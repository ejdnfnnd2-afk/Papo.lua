--[[
    UAI Easy Library
    UAI-inspired visual style + simple AddWindow/AddTab API.

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
    corner(root, 12)
    stroke(root, config.border)
    window.Root = root

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
    titleLabel.Size = UDim2.new(1,-115,1,0)

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
    for _,t in ipairs(self.Tabs) do
        local active = t == tab
        t.Page.Visible = active
        t.NavButton.BackgroundTransparency = active and 0 or 1
        t.NavButton.BackgroundColor3 = self.Config.surface2
        t.NavButton.TextColor3 = active and self.Config.text or self.Config.muted
        if active then
            t.NavButton.TextColor3 = self.Config.main_color
        end
    end
    self.ActiveTab = tab
end

function Library.WindowMethods:Toggle()
    self.Visible = not self.Visible
    self.Root.Visible = self.Visible
end

function Library.WindowMethods:Show()
    self.Visible = true
    self.Root.Visible = true
end

function Library.WindowMethods:Hide()
    self.Visible = false
    self.Root.Visible = false
end

function Library.WindowMethods:FormatWindows()
    return self
end

function Library.WindowMethods:Destroy()
    if self.Gui then self.Gui:Destroy() end
end

local function addCard(tab, height)
    local card = new("Frame", {
        Size = UDim2.new(1,-4,0,height or 44),
        BackgroundColor3 = tab.Window.Config.background,
        BorderSizePixel = 0,
    }, tab.Page)
    corner(card, 8)
    stroke(card, tab.Window.Config.border)
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
    button.MouseEnter:Connect(function() tween(button,TweenInfo.new(.1),{BackgroundColor3=self.Window.Config.main_color}) end)
    button.MouseLeave:Connect(function() tween(button,TweenInfo.new(.1),{BackgroundColor3=self.Window.Config.surface2}) end)
    button.MouseButton1Click:Connect(function() if callback then callback() end end)
    return button
end

function Library.TabMethods:AddSwitch(text, callback)
    local card=addCard(self,44)
    local label=addText(card,text,13,self.Window.Config.text)
    label.Position=UDim2.new(0,12,0,0); label.Size=UDim2.new(1,-75,1,0)
    local sw=new("TextButton",{Size=UDim2.fromOffset(42,22),Position=UDim2.new(1,-54,.5,-11),Text="",AutoButtonColor=false,BackgroundColor3=self.Window.Config.surface2},card)
    corner(sw,11); stroke(sw,self.Window.Config.border)
    local knob=new("Frame",{Size=UDim2.fromOffset(16,16),Position=UDim2.new(0,3,.5,-8),BackgroundColor3=self.Window.Config.muted,BorderSizePixel=0},sw)
    corner(knob,8)
    local state=false
    local function set(v, silent)
        state=not not v
        tween(sw,TweenInfo.new(.12),{BackgroundColor3=state and self.Window.Config.main_color or self.Window.Config.surface2})
        tween(knob,TweenInfo.new(.12),{Position=state and UDim2.new(1,-19,.5,-8) or UDim2.new(0,3,.5,-8),BackgroundColor3=state and Color3.new(1,1,1) or self.Window.Config.muted})
        if not silent and callback then callback(state) end
    end
    sw.MouseButton1Click:Connect(function() set(not state) end)
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
    b.MouseButton1Click:Connect(function() listening=true; b.Text="Press key..." end)
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
    button.MouseButton1Click:Connect(function() if callback then callback(current) end end)
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

return setmetatable({}, {__index=Library})
