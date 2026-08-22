
-- ============================================================
-- TRAYECTO CORE: Task Manager + Configuration
-- ============================================================
local TrayectoCore = {
    Tasks = {},
    Config = {
        AutoFarm = false,
        AutoRebirth = false,
        AutoTrade = false,
        AutoBuy = false,
        AutoEvolve = false,
        SafeMode = true,
        DebugMode = false,
    },
    Diagnostics = {
        LastError = nil,
        ErrorCount = 0,
        StartedAt = os.clock(),
    }
}

function TrayectoCore:Log(message, level)
    level = tostring(level or "DEBUG"):upper()
    local prefix = string.format("[Trayecto][%s][%.3f]", level, os.clock())
    print(prefix .. " " .. tostring(message))
end

function TrayectoCore:LogError(context, err, traceback)
    local message = string.format(
        "%s | %s",
        tostring(context or "Unknown"),
        tostring(err or "Unknown error")
    )
    local trace = tostring(traceback or "")
    self.Diagnostics.LastError = message
    self.Diagnostics.ErrorCount = (self.Diagnostics.ErrorCount or 0) + 1

    -- Siempre sale por consola. No depende de DebugMode.
    warn(string.format(
        "[Trayecto][ERROR][%.3f] %s%s",
        os.clock(),
        message,
        trace ~= "" and ("\n" .. trace) or ""
    ))
end

function TrayectoCore:IsRunning(name)
    local taskState = self.Tasks[name]
    return taskState ~= nil and taskState.running == true
end

function TrayectoCore:Stop(name)
    local taskState = self.Tasks[name]
    if not taskState then return end

    taskState.running = false

    if taskState.connection then
        pcall(function()
            taskState.connection:Disconnect()
        end)
        taskState.connection = nil
    end

    if type(taskState.connections) == "table" then
        for _, connection in ipairs(taskState.connections) do
            pcall(function()
                if connection then
                    connection:Disconnect()
                end
            end)
        end
        taskState.connections = {}
    end

    self.Tasks[name] = nil
    self:Log("Stopped: " .. tostring(name))
end

function TrayectoCore:StopAll()
    local names = {}
    for name in pairs(self.Tasks) do
        names[#names + 1] = name
    end

    for _, name in ipairs(names) do
        self:Stop(name)
    end
end

function TrayectoCore:Start(name, runner)
    if self:IsRunning(name) then
        return false
    end

    local taskState = {
        running = true,
        connection = nil,
        connections = {},
        startedAt = os.clock(),
    }

    self.Tasks[name] = taskState
    self:Log("Started: " .. tostring(name))

    task.spawn(function()
        local ok, err = xpcall(function()
            runner(taskState)
        end, debug.traceback)

        if not ok then
            self:LogError(
                "Task: " .. tostring(name),
                err,
                tostring(err)
            )
        end

        if self.Tasks[name] == taskState then
            self:Stop(name)
        end
    end)

    return true
end

function TrayectoCore:SetConfig(name, value)
    self.Config[name] = value
end

function TrayectoCore:GetConfig(name, default)
    local value = self.Config[name]
    if value == nil then
        return default
    end
    return value
end

-- ============================================================
-- Persistent configuration helpers
-- ============================================================
local TrayectoConfig = {
    FileName = "Trayecto_Config.json",
    Data = {}
}

local function loadTrayectoConfig()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then
        return
    end

    if not isfile(TrayectoConfig.FileName) then
        return
    end

    local ok, decoded = pcall(function()
        return game:GetService("HttpService"):JSONDecode(
            readfile(TrayectoConfig.FileName)
        )
    end)

    if ok and type(decoded) == "table" then
        TrayectoConfig.Data = decoded

        for key, value in pairs(decoded) do
            TrayectoCore.Config[key] = value
        end
    else
        warn("[Trayecto] No se pudo cargar la configuración.")
    end
end

local function saveTrayectoConfig()
    if type(writefile) ~= "function" then
        return
    end

    local ok, encoded = pcall(function()
        return game:GetService("HttpService"):JSONEncode(TrayectoCore.Config)
    end)

    if ok then
        pcall(function()
            writefile(TrayectoConfig.FileName, encoded)
        end)
    end
end

local function resetTrayectoConfig()
    TrayectoCore:StopAll()

    for key, defaultValue in pairs({
        AutoFarm = false,
        AutoRebirth = false,
        AutoTrade = false,
        AutoBuy = false,
        AutoEvolve = false,
        SafeMode = true,
        DebugMode = false,
    }) do
        TrayectoCore.Config[key] = defaultValue
    end

    TrayectoConfig.Data = {}

    if type(delfile) == "function" and type(isfile) == "function" then
        pcall(function()
            if isfile(TrayectoConfig.FileName) then
                delfile(TrayectoConfig.FileName)
            end
        end)
    end

    saveTrayectoConfig()
end

loadTrayectoConfig()

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local UserInputService = game:GetService("UserInputService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local StarterGui = game:GetService("StarterGui")
local VirtualUser = game:GetService("VirtualUser")
local Stats = game:GetService("Stats")
local SoundService = game:GetService("SoundService")
local UIS = UserInputService
local player = Players.LocalPlayer
local petsFolder = player:WaitForChild("petsFolder", 10)
local muscleEvent = player:WaitForChild("muscleEvent")
local leaderstats = player:WaitForChild("leaderstats")
local rebirthsStat = leaderstats:WaitForChild("Rebirths")


-- ============================================================
-- TRAYECTO IMPROVEMENTS: task coordination + recovery helpers
-- No existing feature is removed; this layer only adds helpers.
-- ============================================================
local TrayectoManager = {
    Tasks = {},
    Stats = {
        Recoveries = 0,
        Cycles = 0,
        Errors = 0,
    },
    Config = {
        AutoRecover = true,
        AntiStuck = true,
        Diagnostics = true,
    }
}

function TrayectoManager:SetTask(name, state)
    self.Tasks[name] = state and true or false
end

function TrayectoManager:IsTaskActive(name)
    return self.Tasks[name] == true
end

function TrayectoManager:Safe(label, fn)
    local ok, result = pcall(fn)
    if not ok then
        self.Stats.Errors = self.Stats.Errors + 1
        if self.Config.Diagnostics then
            warn("[Trayecto][" .. tostring(label) .. "] " .. tostring(result))
        end
        return nil
    end
    return result
end

function TrayectoManager:GetCharacter()
    local char = player.Character
    if char and char.Parent then
        return char
    end
    return player.CharacterAdded:Wait()
end

function TrayectoManager:GetMuscleEvent()
    local remote = player:FindFirstChild("muscleEvent")
    if remote and remote.Parent then
        return remote
    end
    return nil
end

function TrayectoManager:GetTool(name)
    local char = player.Character
    local backpack = player:FindFirstChildOfClass("Backpack")
    return (char and char:FindFirstChild(name))
        or (backpack and backpack:FindFirstChild(name))
end

function TrayectoManager:EquipTool(name)
    local char = self:GetCharacter()
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    local backpack = player:FindFirstChildOfClass("Backpack")
    if not (char and hum and backpack) then return nil end

    local tool = char:FindFirstChild(name) or backpack:FindFirstChild(name)
    if tool and tool.Parent ~= char then
        self:Safe("Equip "..name, function()
            hum:EquipTool(tool)
        end)
    end
    return char:FindFirstChild(name) or tool
end

player.CharacterAdded:Connect(function()
    if TrayectoManager.Config.AutoRecover then
        TrayectoManager.Stats.Recoveries = TrayectoManager.Stats.Recoveries + 1
        task.wait(0.25)
        TrayectoManager:Safe("Character recovery", function()
            TrayectoManager:GetCharacter()
        end)
    end
end)

task.spawn(function()
    while task.wait(2) do
        if TrayectoManager.Config.AntiStuck and TrayectoManager.Config.Diagnostics then
            -- Keep diagnostics passive; existing farm loops remain untouched.
        end
    end
end)

local function getCharacter()
    return player.Character or player.CharacterAdded:Wait()
end


local title = " SERAPH HUB PRIVATED | bienvenido  " .. player.DisplayName

local library = (function()
local a={
    main_color=Color3.fromRGB(218,184,92),
    min_size=Vector2.new(760,640),
    toggle_key=Enum.KeyCode.RightShift,
    can_resize=true,
    tween_time=0.12,
    title_bar={Color3.fromRGB(35,28,8),Color3.fromRGB(10,10,12)},
    background={Color3.fromRGB(12,12,15),Color3.fromRGB(20,18,12)},
    title_bar_transparency=0,
    background_transparency=0.04
}

--[[ GOLD PREMIUM - Error Diagnostics / Console Logger ]]
local ErrorLog = {}
local MAX_ERROR_HISTORY = 200
local DiagnosticScriptName = "UnknownScript"

local function GetDiagnosticScriptName()
    local ok, fullName = pcall(function()
        if script then
            return script:GetFullName()
        end
        return "UnknownScript"
    end)
    return ok and tostring(fullName) or "UnknownScript"
end

DiagnosticScriptName = GetDiagnosticScriptName()

local function GetTraceback(message, level)
    if debug and type(debug.traceback) == "function" then
        return debug.traceback(tostring(message or "Unknown error"), level or 3)
    end
    return tostring(message or "No traceback available")
end

local function PrintConsoleError(message, traceback, source, kind)
    local prefix = string.format(
        "[SERAPH][%s][%s][%.3f]",
        tostring(kind or "ERROR"):upper(),
        tostring(source or DiagnosticScriptName),
        os.clock()
    )

    -- warn() garantiza que el error quede claramente visible en la consola.
    -- Se mantiene en un único punto para evitar mensajes duplicados.
    warn(prefix .. " " .. tostring(message or "Unknown error"))
    if traceback and tostring(traceback) ~= "" then
        warn("[SERAPH][TRACEBACK] " .. tostring(traceback))
    end
end

local function AddErrorLog(message, traceback, source, kind)
    local entry = {
        time = os.date("!*t"),
        timestamp = os.time(),
        message = tostring(message or "Unknown error"),
        traceback = tostring(traceback or GetTraceback(message, 4)),
        source = tostring(source or DiagnosticScriptName),
        kind = tostring(kind or "ERROR"),
    }

    table.insert(ErrorLog, entry)
    while #ErrorLog > MAX_ERROR_HISTORY do
        table.remove(ErrorLog, 1)
    end

    PrintConsoleError(entry.message, entry.traceback, entry.source, entry.kind)
    return entry
end

local function ClearErrorLog()
    table.clear(ErrorLog)
end

local function GetErrorLog()
    local copy = {}
    for index, entry in ipairs(ErrorLog) do
        copy[index] = {
            time = entry.time,
            message = entry.message,
            traceback = entry.traceback,
            source = entry.source,
            timestamp = entry.timestamp,
            kind = entry.kind,
        }
    end
    return copy
end


-- ============================================================
-- TRAYECTOO ERROR DETECTOR / CONSOLE LOGGER
-- Detecta errores de ejecución que lleguen al LogService y los
-- deja claramente marcados en la consola sin provocar un bucle.
-- ============================================================
local TrayectooErrorDetector = {
    Enabled = true,
    Errors = {},
    MaxErrors = 200,
    _busy = false,
    _connection = nil,
}

function TrayectooErrorDetector:Log(kind, message, traceback, source)
    if not self.Enabled then return end

    local entry = {
        Time = os.time(),
        Kind = tostring(kind or "ERROR"):upper(),
        Message = tostring(message or "Unknown error"),
        Traceback = tostring(traceback or ""),
        Source = tostring(source or DiagnosticScriptName),
    }

    self.Errors[#self.Errors + 1] = entry
    while #self.Errors > self.MaxErrors do
        table.remove(self.Errors, 1)
    end

    -- Este logger usa print para no generar otro MessageError en LogService.
    print(string.format(
        "[Trayectoo][%s][%s] %s",
        entry.Kind,
        entry.Source,
        entry.Message
    ))

    if entry.Traceback ~= "" then
        print("[Trayectoo][TRACEBACK] " .. entry.Traceback)
    end
end

function TrayectooErrorDetector:Install()
    if self._connection then return true end
    local ok, logService = pcall(function()
        return game:GetService("LogService")
    end)
    if not ok or not logService then
        print("[Trayectoo][ERROR DETECTOR] LogService no disponible")
        return false
    end

    local connected, connection = pcall(function()
        return logService.MessageOut:Connect(function(message, messageType)
            if self._busy or not self.Enabled then return end
            local isError = false
            pcall(function()
                isError = messageType == Enum.MessageType.MessageError
            end)
            if not isError then return end

            self._busy = true
            local text = tostring(message or "Unknown error")

            -- Registrar también en el historial principal.
            AddErrorLog(
                text,
                text,
                DiagnosticScriptName,
                "RUNTIME"
            )

            -- Y conservar el historial específico del detector.
            self:Log("RUNTIME", text, nil, DiagnosticScriptName)
            self._busy = false
        end)
    end)

    if connected and connection then
        self._connection = connection
        print("[Trayectoo][ERROR DETECTOR] activo")
        return true
    end

    print("[Trayectoo][ERROR DETECTOR] no se pudo conectar a LogService")
    return false
end

function TrayectooErrorDetector:GetErrors()
    return self.Errors
end

function TrayectooErrorDetector:Clear()
    table.clear(self.Errors)
end

pcall(function()
    TrayectooErrorDetector:Install()
end)

local function SafeCallback(callback, ...)
    if type(callback) ~= "function" then
        local message = "callback inválido: " .. tostring(callback)
        local traceback = (debug and type(debug.traceback) == "function") and debug.traceback("SafeCallback", 2) or "No traceback available"
        AddErrorLog(message, traceback, DiagnosticScriptName)
        return false, message
    end

    local args = {...}
    local function invoke()
        return callback(table.unpack(args))
    end

    local ok, result = xpcall(invoke, function(err)
        local traceback = GetTraceback(err, 2)
        AddErrorLog(err, traceback, DiagnosticScriptName, "CALLBACK")
        return err
    end)

    return ok, result
end

local function SpawnSafe(label, callback, ...)
    if type(callback) ~= "function" then
        AddErrorLog(
            "SpawnSafe recibió un callback inválido: " .. tostring(callback),
            GetTraceback("SpawnSafe callback inválido", 3),
            tostring(label or DiagnosticScriptName),
            "CALLBACK"
        )
        return nil
    end

    local args = {...}
    return task.spawn(function()
        local ok, err = xpcall(function()
            callback(table.unpack(args))
        end, function(runtimeError)
            return GetTraceback(runtimeError, 2)
        end)

        if not ok then
            AddErrorLog(
                tostring(label or "SpawnSafe"),
                err,
                DiagnosticScriptName,
                "TASK"
            )
        end
    end)
end

do local b=game:GetService("CoreGui"):FindFirstChild("imgui")if b then b:Destroy()end end;local b=Instance.new("ScreenGui")local c=Instance.new("Frame")local d=Instance.new("TextLabel")local e=Instance.new("ImageLabel")local f=Instance.new("Frame")local g=Instance.new("Frame")local h=Instance.new("ImageButton")local i=Instance.new("ImageLabel")local j=Instance.new("ImageLabel")local k=Instance.new("Frame")local l=Instance.new("TextLabel")local m=Instance.new("ImageLabel")local n=Instance.new("ScrollingFrame")local o=Instance.new("Frame")local p=Instance.new("UIListLayout")local q=Instance.new("Frame")local r=Instance.new("Frame")local s=Instance.new("UIListLayout")local t=Instance.new("TextBox")local u=Instance.new("ImageLabel")local v=Instance.new("ImageLabel")local w=Instance.new("TextLabel")local x=Instance.new("ImageLabel")local y=Instance.new("TextLabel")local z=Instance.new("TextLabel")local A=Instance.new("TextLabel")local B=Instance.new("ImageLabel")local C=Instance.new("UIListLayout")local D=Instance.new("TextButton")local E=Instance.new("ImageLabel")local F=Instance.new("ImageButton")local G=Instance.new("ScrollingFrame")local H=Instance.new("UIListLayout")local I=Instance.new("ImageLabel")local J=Instance.new("TextButton")local K=Instance.new("ImageLabel")local L=Instance.new("ImageLabel")local M=Instance.new("TextButton")local N=Instance.new("ImageLabel")local O=Instance.new("ImageLabel")local P=Instance.new("Frame")local Q=Instance.new("UIListLayout")local R=Instance.new("Frame")local S=Instance.new("UIListLayout")local T=Instance.new("ImageLabel")local U=Instance.new("ScrollingFrame")local V=Instance.new("TextBox")local W=Instance.new("TextLabel")local X=Instance.new("TextLabel")local Y=Instance.new("TextLabel")local Z=Instance.new("TextLabel")local _=Instance.new("TextLabel")local a0=Instance.new("TextLabel")local a1=Instance.new("TextLabel")local a2=Instance.new("TextLabel")local a3=Instance.new("TextLabel")local a4=Instance.new("ImageLabel")local a5=Instance.new("ImageLabel")local a6=Instance.new("ImageLabel")local a7=Instance.new("ImageLabel")local a8=Instance.new("ImageLabel")local a9=Instance.new("Frame")local aa=Instance.new("TextButton")local ab=Instance.new("ImageLabel")local ac=Instance.new("TextLabel")local ad=Instance.new("TextButton")local ae=Instance.new("ImageLabel")local af=Instance.new("TextButton")local ag=Instance.new("ImageLabel")local ah=Instance.new("TextLabel")local ai=Instance.new("TextButton")local aj=Instance.new("ImageLabel")local ak=Instance.new("Frame")local G_glowList={};local function G_glow(o)o.TextStrokeTransparency=1;return o end;b.Name="imgui"local guiParent = game:GetService("CoreGui")
if type(gethui) == "function" then
    local ok, hui = pcall(gethui)
    if ok and hui then guiParent = hui end
end
b.Parent = guiParent; c.Name="Prefabs"c.Parent=b;c.BackgroundColor3=Color3.new(1,1,1)c.Size=UDim2.new(0,100,0,100)c.Visible=false;d.Name="Label"d.Parent=c;d.BackgroundColor3=Color3.new(1,1,1)d.BackgroundTransparency=1;d.Size=UDim2.new(0,200,0,20)d.Font=Enum.Font.Gotham;d.Text="Hello, world 123"d.TextColor3=Color3.new(1,1,1)G_glow(d);d.TextSize=16;d.TextXAlignment=Enum.TextXAlignment.Left;e.Name="Window"e.Parent=c;e.Active=true;e.BackgroundColor3=Color3.new(1,1,1)e.BackgroundTransparency=1;e.ClipsDescendants=true;e.Position=UDim2.new(0,20,0,20)e.Selectable=true;e.Size=UDim2.new(0,200,0,200)e.Image="rbxassetid://2851926732"e.ImageColor3=Color3.fromRGB(24,24,28)e.ScaleType=Enum.ScaleType.Slice;e.SliceCenter=Rect.new(12,12,12,12)local techStroke=Instance.new("UIStroke")techStroke.Parent=e;techStroke.Thickness=1;techStroke.Transparency=0.45;techStroke.ApplyStrokeMode=Enum.ApplyStrokeMode.Border;local techCorner=Instance.new("UICorner");techCorner.CornerRadius=UDim.new(0,12);techCorner.Parent=e;local techStrokeGrad=Instance.new("UIGradient")techStrokeGrad.Parent=techStroke;techStrokeGrad.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.fromRGB(70,70,78)),ColorSequenceKeypoint.new(0.5,Color3.fromRGB(95,95,105)),ColorSequenceKeypoint.new(1,Color3.fromRGB(70,70,78))})f.Name="Resizer"f.Parent=e;f.Active=true;f.BackgroundColor3=Color3.new(1,1,1)f.BackgroundTransparency=1;f.BorderSizePixel=0;f.Position=UDim2.new(1,-20,1,-20)f.Size=UDim2.new(0,20,0,20)g.Name="Bar"g.Parent=e;local barCorner=Instance.new("UICorner");barCorner.CornerRadius=UDim.new(0,8);barCorner.Parent=g;g.BackgroundColor3=Color3.fromRGB(32,32,36)g.BorderSizePixel=0;g.Position=UDim2.new(0,0,0,0)g.Size=UDim2.new(1,0,0,40)local techBarGrad=Instance.new("UIGradient")techBarGrad.Parent=g;techBarGrad.Color=ColorSequence.new({ColorSequenceKeypoint.new(0,Color3.fromRGB(32,32,36)),ColorSequenceKeypoint.new(0.5,Color3.fromRGB(42,42,48)),ColorSequenceKeypoint.new(1,Color3.fromRGB(32,32,36))})h.Name="Toggle"h.Parent=g;h.BackgroundColor3=Color3.new(1,1,1)h.BackgroundTransparency=1;h.Position=UDim2.new(0,5,0,-2)h.Rotation=0;h.Size=UDim2.new(0,20,0,20)h.ZIndex=2;h.Image="https://www.roblox.com/Thumbs/Asset.ashx?width=420&height=420&assetId=117051021868712"i.Name="Base"i.Parent=g;i.BackgroundColor3=Color3.new(1,1,1)i.BorderSizePixel=0;i.Position=UDim2.new(0,0,0.800000012,0)i.Size=UDim2.new(1,0,0,10)i.Image="rbxassetid://2851926732"i.ImageColor3=Color3.new(1,1,1)i.ScaleType=Enum.ScaleType.Slice;i.SliceCenter=Rect.new(12,12,12,12)j.Name="Top"j.Parent=g;j.BackgroundColor3=Color3.new(1,1,1)j.BackgroundTransparency=1;j.Position=UDim2.new(0,0,0,-5)j.Size=UDim2.new(1,0,0,10)j.Image="rbxassetid://2851926732"j.ImageColor3=Color3.new(1,1,1)j.ScaleType=Enum.ScaleType.Slice;j.SliceCenter=Rect.new(12,12,12,12)k.Name="Tabs"k.Parent=e;k.BackgroundColor3=Color3.new(1,1,1)k.BackgroundTransparency=1;k.Position=UDim2.new(0,156,0,32)k.Size=UDim2.new(1,-168,1,-44)k.ClipsDescendants=true;l.Name="Title"l.Parent=e;l.BackgroundColor3=Color3.new(1,1,1)l.BackgroundTransparency=1;l.Position=UDim2.new(0,30,0,10)l.Size=UDim2.new(1,-190,0,20);l.TextTruncate=Enum.TextTruncate.None;l.Font=Enum.Font.Gotham;l.Text="Gamer Time"l.TextColor3=Color3.new(1,1,1)G_glow(l);l.TextSize=14;l.TextXAlignment=Enum.TextXAlignment.Left
-- TITLE FIX: use the available top-bar width and shrink text only when needed.
local function fitWindowTitle(label)
    if not label or not label:IsA("TextLabel") then return end
    local maxSize = 14
    local minSize = 9
    label.TextTruncate = Enum.TextTruncate.None
    label.TextWrapped = false
    label.TextXAlignment = Enum.TextXAlignment.Left

    local function fit()
        local size = maxSize
        label.TextSize = size
        while size > minSize and label.TextBounds.X > math.max(40, label.AbsoluteSize.X - 8) do
            size = size - 1
            label.TextSize = size
        end
    end

    fit()
    label:GetPropertyChangedSignal("Text"):Connect(fit)
    label:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
end
fitWindowTitle(l);m.Name="TabSelection"m.Parent=e;m.BackgroundColor3=Color3.new(1,1,1)m.BackgroundTransparency=1;m.Position=UDim2.new(0,15,0,50)m.Size=UDim2.new(0,120,1,-65)m.Visible=true;m.Image="rbxassetid://2851929490"m.ImageColor3=Color3.fromRGB(30,30,36)m.ScaleType=Enum.ScaleType.Slice;m.SliceCenter=Rect.new(4,4,4,4)n.Name="TabScrolling"n.Parent=m;n.BackgroundTransparency=1;n.BorderSizePixel=0;n.Size=UDim2.new(1,0,1,0)n.CanvasSize=UDim2.new(0,0,0,0)n.ScrollBarThickness=0;n.ScrollingDirection=Enum.ScrollingDirection.Y;o.Name="TabButtons"o.Parent=n;o.BackgroundColor3=Color3.new(1,1,1)o.BackgroundTransparency=1;o.Size=UDim2.new(1,0,0,0)o.ClipsDescendants=true;p.Parent=o;p.FillDirection=Enum.FillDirection.Vertical;p.SortOrder=Enum.SortOrder.LayoutOrder;p.Padding=UDim.new(0,4)q.Parent=m;q.BackgroundColor3=Color3.new(1,1,1)q.BorderColor3=Color3.fromRGB(70,70,78)q.BorderSizePixel=0;q.Position=UDim2.new(1,-1,0,0)q.Size=UDim2.new(0,1,1,0)r.Name="Tab"r.Parent=c;r.BackgroundColor3=Color3.new(1,1,1)r.BackgroundTransparency=1;r.Size=UDim2.new(1,0,1,0)r.Visible=false;s.Parent=r;s.SortOrder=Enum.SortOrder.LayoutOrder;s.Padding=UDim.new(0,5)t.Parent=c;t.BackgroundColor3=Color3.new(1,1,1)t.BackgroundTransparency=1;t.BorderSizePixel=0;t.Size=UDim2.new(1,0,0,20)t.ZIndex=2;t.Font=Enum.Font.Gotham;t.PlaceholderColor3=Color3.fromRGB(150,150,160)t.PlaceholderText="Input Text"t.Text=""t.TextColor3=Color3.fromRGB(225,225,230)G_glow(t);t.TextSize=14;u.Name="TextBox_Roundify_4px"u.Parent=t;u.BackgroundColor3=Color3.new(1,1,1)u.BackgroundTransparency=1;u.Size=UDim2.new(1,0,1,0)u.Image="rbxassetid://2851929490"u.ImageColor3=Color3.fromRGB(32,32,38)u.ScaleType=Enum.ScaleType.Slice;u.SliceCenter=Rect.new(4,4,4,4)v.Name="Slider"v.Parent=c;v.BackgroundColor3=Color3.new(1,1,1)v.BackgroundTransparency=1;v.Position=UDim2.new(0,0,0.178571433,0)v.Size=UDim2.new(1,0,0,20)v.Image="rbxassetid://2851929490"v.ImageColor3=Color3.fromRGB(30,30,36)v.ScaleType=Enum.ScaleType.Slice;v.SliceCenter=Rect.new(4,4,4,4)w.Name="Title"w.Parent=v;w.BackgroundColor3=Color3.new(1,1,1)w.BackgroundTransparency=1;w.Position=UDim2.new(0.5,0,0.5,-10)w.Size=UDim2.new(0,0,0,20)w.ZIndex=2;w.Font=Enum.Font.Gotham;w.Text="Slider"w.TextColor3=Color3.fromRGB(225,225,230)G_glow(w);w.TextSize=14;x.Name="Indicator"x.Parent=v;x.BackgroundColor3=Color3.new(1,1,1)x.BackgroundTransparency=1;x.Size=UDim2.new(0,0,0,20)x.Image="rbxassetid://2851929490"x.ImageColor3=Color3.fromRGB(218,184,92)x.ScaleType=Enum.ScaleType.Slice;x.SliceCenter=Rect.new(4,4,4,4)y.Name="Value"y.Parent=v;y.BackgroundColor3=Color3.new(1,1,1)y.BackgroundTransparency=1;y.Position=UDim2.new(1,-55,0.5,-10)y.Size=UDim2.new(0,50,0,20)y.Font=Enum.Font.Gotham;y.Text="0%"y.TextColor3=Color3.fromRGB(225,225,230)G_glow(y);y.TextSize=14;z.Parent=v;z.BackgroundColor3=Color3.new(1,1,1)z.BackgroundTransparency=1;z.Position=UDim2.new(1,-20,-0.75,0)z.Size=UDim2.new(0,26,0,50)z.Font=Enum.Font.Gotham;z.Text="]"z.TextColor3=Color3.new(0.627451,0.627451,0.627451)G_glow(z);z.TextSize=14;A.Parent=v;A.BackgroundColor3=Color3.new(1,1,1)A.BackgroundTransparency=1;A.Position=UDim2.new(1,-65,-0.75,0)A.Size=UDim2.new(0,26,0,50)A.Font=Enum.Font.Gotham;A.Text="["A.TextColor3=Color3.new(0.627451,0.627451,0.627451)G_glow(A);A.TextSize=14;B.Name="Circle"B.Parent=c;B.BackgroundColor3=Color3.new(1,1,1)B.BackgroundTransparency=1;B.Image="rbxassetid://266543268"B.ImageTransparency=0.5;C.Parent=c;C.FillDirection=Enum.FillDirection.Horizontal;C.SortOrder=Enum.SortOrder.LayoutOrder;C.Padding=UDim.new(0,20)D.Name="Dropdown"D.Parent=c;D.BackgroundColor3=Color3.new(1,1,1)D.BackgroundTransparency=1;D.BorderSizePixel=0;D.Position=UDim2.new(-0.055555556,0,0.0833333284,0)D.Size=UDim2.new(0,200,0,20)D.ZIndex=2;D.Font=Enum.Font.Gotham;D.Text="      Dropdown"D.TextColor3=Color3.fromRGB(225,225,230)G_glow(D);D.TextSize=14;D.TextXAlignment=Enum.TextXAlignment.Left;E.Name="Indicator"E.Parent=D;E.BackgroundColor3=Color3.new(1,1,1)E.BackgroundTransparency=1;E.Position=UDim2.new(0.899999976,-10,0.100000001,0)E.Rotation=-90;E.Size=UDim2.new(0,15,0,15)E.ZIndex=2;E.Image="https://www.roblox.com/Thumbs/Asset.ashx?width=420&height=420&assetId=4744658743"F.Name="Box"F.Parent=D;F.BackgroundColor3=Color3.new(1,1,1)F.BackgroundTransparency=1;F.Position=UDim2.new(0,0,0,25)F.Size=UDim2.new(1,0,0,150)F.ZIndex=3;F.Image="rbxassetid://2851929490"F.ImageColor3=Color3.fromRGB(18,18,21)F.ScaleType=Enum.ScaleType.Slice;F.SliceCenter=Rect.new(4,4,4,4)G.Name="Objects"G.Parent=F;G.BackgroundColor3=Color3.new(1,1,1)G.BackgroundTransparency=1;G.BorderSizePixel=0;G.Size=UDim2.new(1,0,1,0)G.ZIndex=3;G.CanvasSize=UDim2.new(0,0,0,0)G.ScrollBarThickness=4;G.ScrollBarImageColor3=Color3.fromRGB(218,184,92)H.Parent=G;H.SortOrder=Enum.SortOrder.LayoutOrder;I.Name="TextButton_Roundify_4px"I.Parent=D;I.BackgroundColor3=Color3.new(1,1,1)I.BackgroundTransparency=1;I.Size=UDim2.new(1,0,1,0)I.Image="rbxassetid://2851929490"I.ImageColor3=Color3.fromRGB(32,32,38)I.ScaleType=Enum.ScaleType.Slice;I.SliceCenter=Rect.new(4,4,4,4)J.Name="TabButton"J.Parent=c;J.BackgroundColor3=Color3.fromRGB(218,184,92)J.BackgroundTransparency=1;J.BorderSizePixel=0;J.Position=UDim2.new(0,0,0,0)J.Size=UDim2.new(1,0,0,34)J.ZIndex=2;J.Font=Enum.Font.Gotham;J.Text="Test tab"J.TextColor3=Color3.fromRGB(225,225,230)J.TextXAlignment=Enum.TextXAlignment.Left;G_glow(J);J.TextSize=14;K.Name="TextButton_Roundify_4px"K.Parent=J;K.BackgroundColor3=Color3.new(1,1,1)K.BackgroundTransparency=1;K.Size=UDim2.new(1,0,1,0)K.Image="rbxassetid://2851929490"K.ImageColor3=Color3.fromRGB(32,32,38)K.ScaleType=Enum.ScaleType.Slice;K.SliceCenter=Rect.new(4,4,4,4)L.Name="Folder"L.Parent=c;L.BackgroundColor3=Color3.new(1,1,1)L.BackgroundTransparency=1;L.Position=UDim2.new(0,0,0,50)L.Size=UDim2.new(1,0,0,20)L.Image="rbxassetid://2851929490"L.ImageColor3=Color3.fromRGB(10,10,12)L.ScaleType=Enum.ScaleType.Slice;L.SliceCenter=Rect.new(4,4,4,4)M.Name="Button"M.Parent=L;M.BackgroundColor3=Color3.fromRGB(218,184,92)M.BackgroundTransparency=1;M.BorderSizePixel=0;M.Size=UDim2.new(1,0,0,20)M.ZIndex=2;M.Font=Enum.Font.Gotham;M.Text="      Folder"M.TextColor3=Color3.new(1,1,1)G_glow(M);M.TextSize=14;M.TextXAlignment=Enum.TextXAlignment.Left;N.Name="TextButton_Roundify_4px"N.Parent=M;N.BackgroundColor3=Color3.new(1,1,1)N.BackgroundTransparency=1;N.Size=UDim2.new(1,0,1,0)N.Image="rbxassetid://2851929490"N.ImageColor3=Color3.fromRGB(218,184,92)N.ScaleType=Enum.ScaleType.Slice;N.SliceCenter=Rect.new(4,4,4,4)O.Name="Toggle"O.Parent=M;O.BackgroundColor3=Color3.new(1,1,1)O.BackgroundTransparency=1;O.Position=UDim2.new(0,5,0,0)O.Size=UDim2.new(0,20,0,20)O.Image="https://www.roblox.com/Thumbs/Asset.ashx?width=420&height=420&assetId=4731371541"P.Name="Objects"P.Parent=L;P.BackgroundColor3=Color3.new(1,1,1)P.BackgroundTransparency=1;P.Position=UDim2.new(0,10,0,25)P.Size=UDim2.new(1,-10,1,-25)P.Visible=false;Q.Parent=P;Q.SortOrder=Enum.SortOrder.LayoutOrder;Q.Padding=UDim.new(0,5)R.Name="HorizontalAlignment"R.Parent=c;R.BackgroundColor3=Color3.new(1,1,1)R.BackgroundTransparency=1;R.Size=UDim2.new(1,0,0,20)S.Parent=R;S.FillDirection=Enum.FillDirection.Horizontal;S.SortOrder=Enum.SortOrder.LayoutOrder;S.Padding=UDim.new(0,5)T.Name="Console"T.Parent=c;T.BackgroundColor3=Color3.new(1,1,1)T.BackgroundTransparency=1;T.Size=UDim2.new(1,0,0,200)T.Image="rbxassetid://2851928141"T.ImageColor3=Color3.fromRGB(18,18,21)T.ScaleType=Enum.ScaleType.Slice;T.SliceCenter=Rect.new(8,8,8,8)U.Parent=T;U.BackgroundColor3=Color3.new(1,1,1)U.BackgroundTransparency=1;U.BorderSizePixel=0;U.Size=UDim2.new(1,0,1,1)U.CanvasSize=UDim2.new(0,0,0,0)U.ScrollBarThickness=4;V.Name="Source"V.Parent=U;V.BackgroundColor3=Color3.new(1,1,1)V.BackgroundTransparency=1;V.Position=UDim2.new(0,40,0,0)V.Size=UDim2.new(1,-40,0,10000)V.ZIndex=3;V.ClearTextOnFocus=false;V.Font=Enum.Font.Gotham;V.MultiLine=true;V.PlaceholderColor3=Color3.new(0.8,0.8,0.8)V.Text=""V.TextColor3=Color3.new(1,1,1)G_glow(V);V.TextSize=15;V.TextStrokeColor3=Color3.new(1,1,1)V.TextWrapped=true;V.TextXAlignment=Enum.TextXAlignment.Left;V.TextYAlignment=Enum.TextYAlignment.Top;W.Name="Comments"W.Parent=V;W.BackgroundColor3=Color3.new(1,1,1)W.BackgroundTransparency=1;W.Size=UDim2.new(1,0,1,0)W.ZIndex=5;W.Font=Enum.Font.Gotham;W.Text=""W.TextColor3=Color3.new(0.231373,0.784314,0.231373)G_glow(W);W.TextSize=15;W.TextXAlignment=Enum.TextXAlignment.Left;W.TextYAlignment=Enum.TextYAlignment.Top;X.Name="Globals"X.Parent=V;X.BackgroundColor3=Color3.new(1,1,1)X.BackgroundTransparency=1;X.Size=UDim2.new(1,0,1,0)X.ZIndex=5;X.Font=Enum.Font.Gotham;X.Text=""X.TextColor3=Color3.new(0.517647,0.839216,0.968628)G_glow(X);X.TextSize=15;X.TextXAlignment=Enum.TextXAlignment.Left;X.TextYAlignment=Enum.TextYAlignment.Top;Y.Name="Keywords"Y.Parent=V;Y.BackgroundColor3=Color3.new(1,1,1)Y.BackgroundTransparency=1;Y.Size=UDim2.new(1,0,1,0)Y.ZIndex=5;Y.Font=Enum.Font.Gotham;Y.Text=""Y.TextColor3=Color3.new(0.972549,0.427451,0.486275)G_glow(Y);Y.TextSize=15;Y.TextXAlignment=Enum.TextXAlignment.Left;Y.TextYAlignment=Enum.TextYAlignment.Top;Z.Name="RemoteHighlight"Z.Parent=V;Z.BackgroundColor3=Color3.new(1,1,1)Z.BackgroundTransparency=1;Z.Size=UDim2.new(1,0,1,0)Z.ZIndex=5;Z.Font=Enum.Font.Gotham;Z.Text=""Z.TextColor3=Color3.new(0,0.568627,1)G_glow(Z);Z.TextSize=15;Z.TextXAlignment=Enum.TextXAlignment.Left;Z.TextYAlignment=Enum.TextYAlignment.Top;_.Name="Strings"_.Parent=V;_.BackgroundColor3=Color3.new(1,1,1)_.BackgroundTransparency=1;_.Size=UDim2.new(1,0,1,0)_.ZIndex=5;_.Font=Enum.Font.Gotham;_.Text=""_.TextColor3=Color3.new(0.678431,0.945098,0.584314)G_glow(_);_.TextSize=15;_.TextXAlignment=Enum.TextXAlignment.Left;_.TextYAlignment=Enum.TextYAlignment.Top;a0.Name="Tokens"a0.Parent=V;a0.BackgroundColor3=Color3.new(1,1,1)a0.BackgroundTransparency=1;a0.Size=UDim2.new(1,0,1,0)a0.ZIndex=5;a0.Font=Enum.Font.Gotham;a0.Text=""a0.TextColor3=Color3.new(1,1,1)G_glow(a0);a0.TextSize=15;a0.TextXAlignment=Enum.TextXAlignment.Left;a0.TextYAlignment=Enum.TextYAlignment.Top;a1.Name="Numbers"a1.Parent=V;a1.BackgroundColor3=Color3.new(1,1,1)a1.BackgroundTransparency=1;a1.Size=UDim2.new(1,0,1,0)a1.ZIndex=4;a1.Font=Enum.Font.Gotham;a1.Text=""a1.TextColor3=Color3.new(1,0.776471,0)G_glow(a1);a1.TextSize=15;a1.TextXAlignment=Enum.TextXAlignment.Left;a1.TextYAlignment=Enum.TextYAlignment.Top;a2.Name="Info"a2.Parent=V;a2.BackgroundColor3=Color3.new(1,1,1)a2.BackgroundTransparency=1;a2.Size=UDim2.new(1,0,1,0)a2.ZIndex=5;a2.Font=Enum.Font.Gotham;a2.Text=""a2.TextColor3=Color3.new(0,0.635294,1)G_glow(a2);a2.TextSize=15;a2.TextXAlignment=Enum.TextXAlignment.Left;a2.TextYAlignment=Enum.TextYAlignment.Top;a3.Name="Lines"a3.Parent=U;a3.BackgroundColor3=Color3.new(1,1,1)a3.BackgroundTransparency=1;a3.BorderSizePixel=0;a3.Size=UDim2.new(0,40,0,10000)a3.ZIndex=4;a3.Font=Enum.Font.Gotham;a3.Text="1\n"a3.TextColor3=Color3.new(1,1,1)G_glow(a3);a3.TextSize=15;a3.TextWrapped=true;a3.TextYAlignment=Enum.TextYAlignment.Top;a4.Name="ColorPicker"a4.Parent=c;a4.BackgroundColor3=Color3.new(1,1,1)a4.BackgroundTransparency=1;a4.Size=UDim2.new(0,180,0,110)a4.Image="rbxassetid://2851929490"a4.ImageColor3=Color3.fromRGB(32,32,38)a4.ScaleType=Enum.ScaleType.Slice;a4.SliceCenter=Rect.new(4,4,4,4)a5.Name="Palette"a5.Parent=a4;a5.BackgroundColor3=Color3.new(1,1,1)a5.BackgroundTransparency=1;a5.Position=UDim2.new(0.0500000007,0,0.0500000007,0)a5.Size=UDim2.new(0,100,0,100)a5.Image="rbxassetid://698052001"a5.ScaleType=Enum.ScaleType.Slice;a5.SliceCenter=Rect.new(4,4,4,4)a6.Name="Indicator"a6.Parent=a5;a6.BackgroundColor3=Color3.new(1,1,1)a6.BackgroundTransparency=1;a6.Size=UDim2.new(0,5,0,5)a6.ZIndex=2;a6.Image="rbxassetid://2851926732"a6.ImageColor3=Color3.new(0,0,0)a6.ScaleType=Enum.ScaleType.Slice;a6.SliceCenter=Rect.new(12,12,12,12)a7.Name="Sample"a7.Parent=a4;a7.BackgroundColor3=Color3.new(1,1,1)a7.BackgroundTransparency=1;a7.Position=UDim2.new(0.800000012,0,0.0500000007,0)a7.Size=UDim2.new(0,25,0,25)a7.Image="rbxassetid://2851929490"a7.ScaleType=Enum.ScaleType.Slice;a7.SliceCenter=Rect.new(4,4,4,4)a8.Name="Saturation"a8.Parent=a4;a8.BackgroundColor3=Color3.new(1,1,1)a8.Position=UDim2.new(0.649999976,0,0.0500000007,0)a8.Size=UDim2.new(0,15,0,100)a8.Image="rbxassetid://3641079629"a9.Name="Indicator"a9.Parent=a8;a9.BackgroundColor3=Color3.new(1,1,1)a9.BorderSizePixel=0;a9.Size=UDim2.new(0,20,0,2)a9.ZIndex=2;aa.Name="Switch"aa.Parent=c;aa.BackgroundColor3=Color3.new(1,1,1)aa.BackgroundTransparency=1;aa.BorderSizePixel=0;aa.Position=UDim2.new(0.229411766,0,0.20714286,0)aa.Size=UDim2.new(0,20,0,20)aa.ZIndex=2;aa.Font=Enum.Font.SourceSans;aa.Text=""aa.TextColor3=Color3.new(1,1,1)G_glow(aa);aa.TextSize=14;ab.Name="TextButton_Roundify_4px"ab.Parent=aa;ab.BackgroundColor3=Color3.new(1,1,1)ab.BackgroundTransparency=1;ab.Size=UDim2.new(1,0,1,0)ab.Image="rbxassetid://2851929490"ab.ImageColor3=Color3.fromRGB(218,184,92)ab.ImageTransparency=0.5;ab.ScaleType=Enum.ScaleType.Slice;ab.SliceCenter=Rect.new(4,4,4,4)ac.Name="Title"ac.Parent=aa;ac.BackgroundColor3=Color3.new(1,1,1)ac.BackgroundTransparency=1;ac.Position=UDim2.new(1.20000005,0,0,0)ac.Size=UDim2.new(0,20,0,20)ac.Font=Enum.Font.Gotham;ac.Text="Switch"ac.TextColor3=Color3.fromRGB(225,225,230)G_glow(ac);ac.TextSize=14;ac.TextXAlignment=Enum.TextXAlignment.Left;ad.Name="Button"ad.Parent=c;ad.BackgroundColor3=Color3.fromRGB(218,184,92)ad.BackgroundTransparency=1;ad.BorderSizePixel=0;ad.Size=UDim2.new(0,91,0,20)ad.ZIndex=2;ad.Font=Enum.Font.Gotham;ad.TextColor3=Color3.new(1,1,1)G_glow(ad);ad.TextSize=14;ae.Name="TextButton_Roundify_4px"ae.Parent=ad;ae.BackgroundColor3=Color3.new(1,1,1)ae.BackgroundTransparency=1;ae.Size=UDim2.new(1,0,1,0)ae.Image="rbxassetid://2851929490"ae.ImageColor3=Color3.fromRGB(218,184,92)ae.ScaleType=Enum.ScaleType.Slice;ae.SliceCenter=Rect.new(4,4,4,4)af.Name="DropdownButton"af.Parent=c;af.BackgroundColor3=Color3.fromRGB(18,18,21)af.BorderSizePixel=0;af.Size=UDim2.new(1,0,0,20)af.ZIndex=3;af.Font=Enum.Font.Gotham;af.Text="      Button"af.TextColor3=Color3.fromRGB(225,225,230)G_glow(af);af.TextSize=14;af.TextXAlignment=Enum.TextXAlignment.Left;ag.Name="Keybind"ag.Parent=c;ag.BackgroundColor3=Color3.new(1,1,1)ag.BackgroundTransparency=1;ag.Size=UDim2.new(0,200,0,20)ag.Image="rbxassetid://2851929490"ag.ImageColor3=Color3.fromRGB(32,32,38)ag.ScaleType=Enum.ScaleType.Slice;ag.SliceCenter=Rect.new(4,4,4,4)ah.Name="Title"ah.Parent=ag;ah.BackgroundColor3=Color3.new(1,1,1)ah.BackgroundTransparency=1;ah.Size=UDim2.new(0,0,1,0)ah.Font=Enum.Font.Gotham;ah.Text="Keybind"ah.TextColor3=Color3.fromRGB(225,225,230)G_glow(ah);ah.TextSize=14;ah.TextXAlignment=Enum.TextXAlignment.Left;ai.Name="Input"ai.Parent=ag;ai.BackgroundColor3=Color3.new(1,1,1)ai.BackgroundTransparency=1;ai.BorderSizePixel=0;ai.Position=UDim2.new(1,-85,0,2)ai.Size=UDim2.new(0,80,1,-4)ai.ZIndex=2;ai.Font=Enum.Font.Gotham;ai.Text="RShift"ai.TextColor3=Color3.fromRGB(225,225,230)G_glow(ai);ai.TextSize=12;ai.TextWrapped=true;aj.Name="Input_Roundify_4px"aj.Parent=ai;aj.BackgroundColor3=Color3.new(1,1,1)aj.BackgroundTransparency=1;aj.Size=UDim2.new(1,0,1,0)aj.Image="rbxassetid://2851929490"aj.ImageColor3=Color3.fromRGB(28,25,17)aj.ScaleType=Enum.ScaleType.Slice;aj.SliceCenter=Rect.new(4,4,4,4)ak.Name="Windows"ak.Parent=b;ak.BackgroundColor3=Color3.new(1,1,1)ak.BackgroundTransparency=1;ak.Position=UDim2.new(0,20,0,20)ak.Size=UDim2.new(1,20,1,-20)local guiRoot = b
local al=game:GetService("UserInputService")local am=game:GetService("TweenService")local an=game:GetService("RunService")local ao=game:GetService("Players")local ap=ao.LocalPlayer;local aq=ap:GetMouse()local c=guiRoot:WaitForChild("Prefabs")local ak=guiRoot:FindFirstChild("Windows")local ar={binding=false}local as={}local function at(au)table.insert(as,au)return au end;local function av()for aw,au in ipairs(as)do if au.Connected then au:Disconnect()end end;as={}end;at(al.InputBegan:Connect(function(ax,ay)if ax.KeyCode==(typeof(a.toggle_key)=="EnumItem"and a.toggle_key or Enum.KeyCode.RightShift)then if guiRoot and not ar.binding then guiRoot.Enabled=not guiRoot.Enabled end end end))local function az(aA,aB,aC)aC=aC or 0.1;if aC==0 then for aD,aE in pairs(aB)do aA[aD]=aE end;return end;local aF=TweenInfo.new(aC,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)local aG=am:Create(aA,aF,aB)aG:Play()return aG end;local function aH(aI,aJ,aK)local aL=aI:FindFirstChild("UIGradient")if aL then aL:Destroy()end;if typeof(aJ)=="Color3"then aJ={aJ}end;if not aJ or#aJ==0 then return end;if#aJ==1 then if aI:IsA("ImageLabel")or aI:IsA("ImageButton")then aI.ImageColor3=aJ[1]else aI.BackgroundColor3=aJ[1]end;return end;local aM=Instance.new("UIGradient")aM.Parent=aI;aM.Rotation=aK or 0;local aN={}if#aJ==2 then aN={ColorSequenceKeypoint.new(0,aJ[1]),ColorSequenceKeypoint.new(1,aJ[2])}elseif#aJ>=3 then aN={ColorSequenceKeypoint.new(0,aJ[1]),ColorSequenceKeypoint.new(0.5,aJ[2]),ColorSequenceKeypoint.new(1,aJ[3])}end;aM.Color=ColorSequence.new(aN)if aI:IsA("ImageLabel")or aI:IsA("ImageButton")then aI.ImageColor3=Color3.new(1,1,1)else aI.BackgroundColor3=Color3.new(1,1,1)end end;local function aO(aP,aQ,aR)aP,aQ,aR=aP/255,aQ/255,aR/255;local aS,aT=math.max(aP,aQ,aR),math.min(aP,aQ,aR)local aU,aV,aW=0,0,aS;local aX=aS-aT;aV=aS==0 and 0 or aX/aS;if aS==aT then aU=0 else if aS==aP then aU=(aQ-aR)/aX+(aQ<aR and 6 or 0)elseif aS==aQ then aU=(aR-aP)/aX+2 elseif aS==aR then aU=(aP-aQ)/aX+4 end;aU=aU/6 end;return aU,aV,aW end;local function aY(aZ,aD)local a_,b0=pcall(function()return aZ[tostring(aD)]end)return a_ and b0 end;local function b1(b2)return b2.TextBounds.X+15 end;local function b3()return Vector2.new(al:GetMouseLocation().X+1,al:GetMouseLocation().Y-35)end;local function b4(b5,b6,b7)task.spawn(function()b5.ClipsDescendants=true;local b8=c:FindFirstChild("Circle"):Clone()b8.Parent=b5;b8.ZIndex=1000;local b9=b6-b8.AbsolutePosition.X;local ba=b7-b8.AbsolutePosition.Y;b8.Position=UDim2.new(0,b9,0,ba)local bb=math.max(b5.AbsoluteSize.X,b5.AbsoluteSize.Y)*1.5;b8:TweenSizeAndPosition(UDim2.new(0,bb,0,bb),UDim2.new(0.5,-bb/2,0.5,-bb/2),Enum.EasingDirection.Out,Enum.EasingStyle.Quad,0.5,false)az(b8,{ImageTransparency=1},0.5)task.wait(0.5)b8:Destroy()end)end;local bc=0;local bd={}local function be()local bf=c:FindFirstChild("UIListLayout"):Clone()bf.Parent=ak;local bg={}for aw,aW in ipairs(ak:GetChildren())do if not aW:IsA("UIListLayout")then bg[aW]=aW.AbsolutePosition end end;bf:Destroy()for bh,aW in pairs(bg)do bh.Position=UDim2.new(0,aW.X,0,aW.Y)end end;function bd:FormatWindows()be()end;function bd:AddWindow(bi,bj)bc=bc+1;local bk=false;bi=tostring(bi or"New Window")bj=typeof(bj)=="table"and bj or a;bj.tween_time=bj.tween_time or 0.1;bj.title_bar=bj.title_bar or{Color3.fromRGB(40,145,225),Color3.fromRGB(45,45,52)}if typeof(bj.title_bar)=="Color3"then bj.title_bar={bj.title_bar}end;bj.title_bar_transparency=bj.title_bar_transparency or 0;bj.background=bj.background or{Color3.fromRGB(14,14,18)}if typeof(bj.background)=="Color3"then bj.background={bj.background}end;bj.background_transparency=bj.background_transparency or 0.04;if not bj.main_color then bj.main_color=bj.title_bar[1]end;local e=c:FindFirstChild("Window"):Clone()e.Parent=ak;
        -- Responsive sizing keeps the window usable on different screen sizes.
        pcall(function() bd:SetResponsiveWindow(e) end)
        pcall(function() bd:CenterWindow(e) end)
        pcall(function() bd:FitWindowToViewport(e, 24) end)
        e:SetAttribute("GP_Version", bd.Version)
        pcall(function() bd:ApplyPremiumStyle(e) end);
        pcall(function() bd:AddWindowControls(e) end)
        -- GOLD PREMIUM V3: cleaner window shell / depth
        do
            local shell = e:FindFirstChild("PremiumShell")
            if not shell then
                shell = Instance.new("UIStroke")
                shell.Name = "PremiumShell"
                shell.Color = bj.main_color
                shell.Thickness = 1.25
                shell.Transparency = 0.48
                shell.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
                shell.Parent = e
            end

            local bg = e:FindFirstChild("Background") or e:FindFirstChild("Main")
            if bg and bg:IsA("GuiObject") then
                bg.BackgroundColor3 = bj.background[1] or Color3.fromRGB(14,14,18)
                bg.BackgroundTransparency = bj.background_transparency
            end

            local padding = e:FindFirstChild("PremiumPadding")
            if not padding then
                padding = Instance.new("UIPadding")
                padding.Name = "PremiumPadding"
                padding.PaddingLeft = UDim.new(0,6)
                padding.PaddingRight = UDim.new(0,6)
                padding.PaddingBottom = UDim.new(0,6)
                padding.Parent = e
            end
        end;e:FindFirstChild("Title").Text=bi;e.Size=UDim2.new(0,bj.min_size.X,0,bj.min_size.Y)e.ZIndex=e.ZIndex+bc*10;do local g=e:FindFirstChild("Bar")local l=g:FindFirstChild("Title")local h=g:FindFirstChild("Toggle")local i=g:FindFirstChild("Base")local j=g:FindFirstChild("Top")local m=e:FindFirstChild("TabSelection")local bl=m:FindFirstChild("Frame")local bm=24;local bn=(bm-18)/2;g.Size=UDim2.new(1,0,0,34)g.Position=UDim2.new(0,0,0,0)if i then i:Destroy()end;if j then j:Destroy()end;local bo=Instance.new("UICorner")bo.CornerRadius=UDim.new(0,10)bo.Parent=g;if h then h.Position=UDim2.new(0,5,0,bn)end;if l then local bp=25;local bq=5;l.Position=UDim2.new(0,bp,0,bn)l.Size=UDim2.new(1,-(bp+bq),1,-bn*2)l.TextXAlignment=Enum.TextXAlignment.Center;l.Font=Enum.Font.GothamBold;l.TextSize=14;l.TextColor3=Color3.fromRGB(245,238,220) end;g.BackgroundTransparency=bj.title_bar_transparency;aH(g,bj.title_bar,90)do local barGlow=Instance.new("UIStroke")barGlow.Color=bj.main_color;barGlow.Thickness=1;barGlow.Transparency=0.55;barGlow.Parent=g;
            local barGradient = g:FindFirstChild("PremiumGradient")
            if not barGradient then
                barGradient = Instance.new("UIGradient")
                barGradient.Name = "PremiumGradient"
                barGradient.Rotation = 0
                barGradient.Color = ColorSequence.new({
                    ColorSequenceKeypoint.new(0, bj.main_color),
                    ColorSequenceKeypoint.new(1, Color3.fromRGB(45,42,30))
                })
                barGradient.Transparency = NumberSequence.new({
                    NumberSequenceKeypoint.new(0, 0.08),
                    NumberSequenceKeypoint.new(1, 0.18)
                })
                barGradient.Parent = g
            end;end;if m then m.Size=UDim2.new(0,132,1,-38)m.Position=UDim2.new(0,12,0,32)local br=Instance.new("UICorner")br.CornerRadius=UDim.new(0,10)br.Parent=m;m.ImageTransparency=0.12;aH(m,{Color3.fromRGB(30,30,34)},0)local bs=m:FindFirstChild("TabScrolling")if bs then local bt=bs:FindFirstChild("TabButtons")if bt then local bu=bt:FindFirstChild("UIListLayout")if bu then bu.FillDirection=Enum.FillDirection.Vertical;bu.HorizontalAlignment=Enum.HorizontalAlignment.Left;bu.VerticalAlignment=Enum.VerticalAlignment.Top;bu.Padding=UDim.new(0,6)end end end;if bl then bl:Destroy()end end;e.ImageTransparency=bj.background_transparency;aH(e,bj.background,45)do local windowGlow=Instance.new("UIStroke")windowGlow.Color=bj.main_color;windowGlow.Thickness=1.5;windowGlow.Transparency=0.35;windowGlow.ApplyStrokeMode=Enum.ApplyStrokeMode.Border;windowGlow.Parent=e;end;local bv=e:FindFirstChild("Tabs")h.MouseButton1Click:Connect(function()local bw=bv.Visible;if bw then bv.Visible=false;az(e,{Size=UDim2.new(0,e.AbsoluteSize.X,0,bm)},bj.tween_time)else bv.Visible=true;e.Size=UDim2.new(0,e.AbsoluteSize.X,0,bj.min_size.Y)end end)end;local f=e:WaitForChild("Resizer")local bx={}e.Draggable=true;do local by=aq.Icon;local bz=false;f.MouseEnter:Connect(function()e.Draggable=false;if bj.can_resize then by=aq.Icon end;bz=true end)f.MouseLeave:Connect(function()bz=false;if bj.can_resize then aq.Icon=by end;e.Draggable=true end)local bA=false;local bB;al.InputBegan:Connect(function(bC)if bC.UserInputType==Enum.UserInputType.MouseButton1 then bA=true;if bz and f.Active and bj.can_resize then bB=an.Heartbeat:Connect(function()if not bA or not f.Active then if bB then bB:Disconnect()bB=nil end;return end;local bD=b3()local b6=bD.X-e.AbsolutePosition.X;local b7=bD.Y-e.AbsolutePosition.Y;local minW,minH=bj.min_size.X,bj.min_size.Y
                    local maxW,maxH=1100,760
                    b6=math.clamp(b6,minW,maxW)
                    b7=math.clamp(b7,minH,maxH)
                    e.Size=UDim2.new(0,b6,0,b7)end)end end end)al.InputEnded:Connect(function(bC)if bC.UserInputType==Enum.UserInputType.MouseButton1 then bA=false;if bB then bB:Disconnect()bB=nil end end end)end;do local bE=e:FindFirstChild("Bar"):FindFirstChild("Toggle")local bF=true;local bG=true;local bH={}local bI=e.AbsoluteSize.Y;bE.MouseButton1Click:Connect(function()if not bG then return end;bG=false;if bF then bH={}for aw,aW in ipairs(e:FindFirstChild("Tabs"):GetChildren())do bH[aW]=aW.Visible;aW.Visible=false end;f.Active=false;bI=e.AbsoluteSize.Y;az(bE,{Rotation=0},bj.tween_time)local aG=az(e,{Size=UDim2.new(0,e.AbsoluteSize.X,0,26)},bj.tween_time)if bE.Parent:FindFirstChild("Base")then bE.Parent:FindFirstChild("Base").Transparency=1 end else for bh,aW in pairs(bH)do bh.Visible=aW end;f.Active=true;az(bE,{Rotation=0},bj.tween_time)local aG=az(e,{Size=UDim2.new(0,e.AbsoluteSize.X,0,bI)},bj.tween_time)if bE.Parent:FindFirstChild("Base")then bE.Parent:FindFirstChild("Base").Transparency=bj.title_bar_transparency end end;bF=not bF;task.delay(bj.tween_time,function()bG=true end)end)end;do local bJ=e:FindFirstChild("Tabs")local bK=e:FindFirstChild("TabSelection")local bL=bK:FindFirstChild("TabScrolling")local bM=bL:FindFirstChild("TabButtons")local bN=nil;local bO=nil;local function bP()local bQ=0;local bR=bM:FindFirstChildOfClass("UIListLayout").Padding.Offset or 0;for aw,bS in ipairs(bM:GetChildren())do if bS:IsA("TextButton")then bQ=bQ+bS.AbsoluteSize.Y+bR end end;bM.Size=UDim2.new(1,-8,0,bQ);if bL then bL.CanvasSize=UDim2.new(0,0,0,bQ+8)end end;function bx:AddTab(bT)local bU={}bT=tostring(bT or"New Tab")bK.Visible=true;local bV=c:FindFirstChild("TabButton"):Clone()bV.Parent=bM;bV.Text=bT;bV.Size=UDim2.new(1,-8,0,34)bV.ZIndex=bV.ZIndex+bc*10;bV.BackgroundTransparency=1;local bW=bV:GetChildren()[1]bW.ZIndex=bV.ZIndex+bc*10;bW.ImageTransparency=1;local bX=Instance.new("UICorner")bX.CornerRadius=UDim.new(0,4)bX.Parent=bV;bV.TextColor3=Color3.fromRGB(205,205,210)bV.TextSize=13;bV.Font=Enum.Font.Gotham;bV.TextXAlignment=Enum.TextXAlignment.Left;
            pcall(function() bd:AddHoverEffect(bV, Color3.fromRGB(30,30,34), bj.main_color) end)
            do
                local hover = Instance.new("Frame")
                hover.Name = "PremiumHover"
                hover.BackgroundColor3 = bj.main_color
                hover.BackgroundTransparency = 1
                hover.BorderSizePixel = 0
                hover.Size = UDim2.new(0,3,1,-8)
                hover.Position = UDim2.new(0,0,0,4)
                hover.ZIndex = bV.ZIndex + 2
                hover.Parent = bV
                local hc = Instance.new("UICorner")
                hc.CornerRadius = UDim.new(1,0)
                hc.Parent = hover
                bV.MouseEnter:Connect(function()
                    az(hover,{BackgroundTransparency=0.15},0.12)
                end)
                bV.MouseLeave:Connect(function()
                    az(hover,{BackgroundTransparency=1},0.12)
                end)
            end;local bY=Instance.new("UIStroke")bY.Color=Color3.new(0,0,0)bY.Thickness=1.2;bY.Transparency=0.7;bY.Parent=bV;local bZ=Instance.new("Frame")bZ.Name="TabOutline"bZ.Size=UDim2.new(1,0,1,0)bZ.BackgroundTransparency=1;bZ.BorderSizePixel=2;bZ.BorderColor3=bj.main_color;bZ.ZIndex=bV.ZIndex+10;bZ.Visible=false;local b_=Instance.new("UICorner")b_.CornerRadius=UDim.new(0,4)b_.Parent=bZ;bZ.Parent=bV;local c0=c:FindFirstChild("Tab"):Clone()c0.Parent=bJ;c0.ZIndex=c0.ZIndex+bc*10;c0.Visible=false;c0.ClipsDescendants=false;c0.Size=UDim2.new(1,0,1,0)c0.BackgroundTransparency=1;local c1=Instance.new("ScrollingFrame")c1.Name="TabScroller"c1.Parent=c0;c1.Size=UDim2.new(1,-12,1,0)c1.Position=UDim2.new(0,6,0,0)c1.BackgroundTransparency=1;c1.BorderSizePixel=0;c1.ScrollBarThickness=3;c1.CanvasSize=UDim2.new(0,0,0,0)c1.ZIndex=c0.ZIndex;c1.ScrollBarImageColor3=Color3.fromRGB(218,184,92)c1.ScrollBarImageTransparency=0.4;local bu=c0:FindFirstChildOfClass("UIListLayout")if bu then bu.Parent=c1 end;local function c2()local c3=bu.AbsoluteContentSize.Y;c1.CanvasSize=UDim2.new(0,0,0,c3+10)end;bu:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(c2)c2()task.defer(bP)local function c4(b5)if b5~=bN then return end;local c5=b5.AbsoluteSize;for bh=1,3 do task.spawn(function()local c6=Instance.new("Frame")c6.Name="SimpleParticle"c6.Size=UDim2.new(0,1.5,0,1.5)c6.AnchorPoint=Vector2.new(0.5,0.5)c6.BackgroundColor3=Color3.fromRGB(255,255,255)c6.BorderSizePixel=0;c6.ZIndex=b5.ZIndex+15;local bo=Instance.new("UICorner")bo.CornerRadius=UDim.new(1,0)bo.Parent=c6;local c7=math.random(1,4)local c8,c9=0,0;if c7==1 then c8=math.random(5,c5.X-5)c9=1 elseif c7==2 then c8=c5.X-1;c9=math.random(5,c5.Y-5)elseif c7==3 then c8=math.random(5,c5.X-5)c9=c5.Y-1 else c8=1;c9=math.random(5,c5.Y-5)end;c6.Position=UDim2.new(0,c8,0,c9)c6.Parent=b5;local ca,cb=c5.X/2,c5.Y/2;local cc,cd=c8-ca,c9-cb;local ce=math.sqrt(cc*cc+cd*cd)cc,cd=cc/ce,cd/ce;local cf=c8+cc*6;local cg=c9+cd*6;local aF=TweenInfo.new(0.5,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)local aG=am:Create(c6,aF,{Position=UDim2.new(0,cf,0,cg),BackgroundTransparency=1})aG:Play()task.wait(0.5)if c6 and c6.Parent then c6:Destroy()end end)end end;local function ch()end;local function ci()if bk then return end;if bN and bN~=bV then local cj=bN:FindFirstChild("TabOutline")if cj then cj.Visible=false end;local oldRail=bN:FindFirstChild('ActiveRail');if oldRail then oldRail.Visible=false end;bN.TextColor3=Color3.fromRGB(205,205,210)end;for aw,aW in ipairs(bJ:GetChildren())do if aW:IsA("Frame")then aW.Visible=false end end;bN=bV;local ck=bV:FindFirstChild("TabOutline")if ck then ck.Visible=true;ck.BackgroundColor3=bj.main_color end;local cr=bV:FindFirstChild('ActiveRail');if cr then cr.Visible=true end;bV.TextColor3=Color3.new(1,1,1)ch()c0.Visible=true end;bV.MouseButton1Click:Connect(ci)bV.MouseEnter:Connect(function()if bV~=bN then bV.TextColor3=Color3.fromRGB(230,230,230)end end)bV.MouseLeave:Connect(function()if bV~=bN then bV.TextColor3=Color3.fromRGB(200,200,200)end end)function bU:Show()ci()end;bV.AncestryChanged:Connect(function()if not bV.Parent then if bN==bV then bN=nil;if bO then bO:Disconnect()bO=nil end end end end)if#bM:GetChildren()==2 then ci()end;do function bU:AddLabel(cl)cl=tostring(cl or"New Label")local cm=c:FindFirstChild("Label"):Clone()local c1=c0:FindFirstChild("TabScroller")cm.Parent=c1 or c0;cm.Text=cl;cm.Size=UDim2.new(0,b1(cm),0,20)cm.ZIndex=cm.ZIndex+bc*10;return cm end;function bU:AddButton(cn,co)cn=tostring(cn or"New Button")co=typeof(co)=="function"and co or function()end;local b5=c:FindFirstChild("Button"):Clone()local c1=c0:FindFirstChild("TabScroller")b5.Parent=c1 or c0;b5.Text=cn;b5.Size=UDim2.new(0,b1(b5),0,20)b5.ZIndex=b5.ZIndex+bc*10;local cp=b5:GetChildren()[1]cp.ZIndex=cp.ZIndex+bc*10;cp.ImageTransparency=bj.title_bar_transparency or 0;aH(cp,bj.title_bar,0)b5.TextColor3=Color3.new(1,1,1)b5.MouseButton1Click:Connect(function()b4(b5,aq.X,aq.Y)SafeCallback(co)end)return b5 end;function bU:AddSwitch(cq,co)local cr={}cq=tostring(cq or"New Switch")co=typeof(co)=="function"and co or function()end;local cs=c:FindFirstChild("Switch"):Clone()local c1=c0:FindFirstChild("TabScroller")cs.Parent=c1 or c0;cs:FindFirstChild("Title").Text=cq;cs:FindFirstChild("Title").ZIndex=cs:FindFirstChild("Title").ZIndex+bc*10;cs.ZIndex=cs.ZIndex+bc*10;local ct=cs:GetChildren()[1]ct.ZIndex=ct.ZIndex+bc*10;ct.ImageTransparency=bj.title_bar_transparency or 0;aH(ct,bj.title_bar,0)local cu=false;cs.MouseButton1Click:Connect(function()cu=not cu;cs.Text=cu and utf8.char(10003)or""SafeCallback(co,cu)end)function cr:Set(cv)cu=typeof(cv)=="boolean"and cv or false;cs.Text=cu and utf8.char(10003)or""SafeCallback(co,cu)end;return cr,cs end;function bU:AddTextBox(cw,co,cx)cw=tostring(cw or"New TextBox")co=typeof(co)=="function"and co or function()end;cx=typeof(cx)=="table"and cx or{clear=false}cx.clear=cx.clear==true;local cy=c:FindFirstChild("TextBox"):Clone()cy.Size=UDim2.new(0.5,-5,0,20)local c1=c0:FindFirstChild("TabScroller")cy.Parent=c1 or c0;cy.PlaceholderText=cw;cy.ZIndex=cy.ZIndex+bc*10;local cz=cy:GetChildren()[1]cz.ZIndex=cz.ZIndex+bc*10;cz.ImageTransparency=bj.title_bar_transparency or 0;aH(cz,bj.title_bar,0)cy.TextColor3=Color3.new(1,1,1)cy.PlaceholderColor3=Color3.fromRGB(200,200,200)cy.FocusLost:Connect(function(cA)if cA and#cy.Text>0 then SafeCallback(co,cy.Text)if cx.clear then cy.Text=""end end end)return cy end;function bU:AddSlider(cB,co,cC)local cD={}cB=tostring(cB or"New Slider")co=typeof(co)=="function"and co or function()end;cC=typeof(cC)=="table"and cC or{}cC.min=cC.min or 0;cC.max=cC.max or 100;cC.readonly=cC.readonly or false;local cE=c:FindFirstChild("Slider"):Clone()local c1=c0:FindFirstChild("TabScroller")cE.Parent=c1 or c0;cE.ZIndex=cE.ZIndex+bc*10;local bi=cE:FindFirstChild("Title")local cF=cE:FindFirstChild("Indicator")local cG=cE:FindFirstChild("Value")bi.ZIndex=bi.ZIndex+bc*10;cF.ZIndex=cF.ZIndex+bc*10;cG.ZIndex=cG.ZIndex+bc*10;bi.Text=cB;local bz=false;local cH;cE.MouseEnter:Connect(function()bz=true;e.Draggable=false end)cE.MouseLeave:Connect(function()bz=false;e.Draggable=true end)local bA=false;al.InputBegan:Connect(function(bC)if bC.UserInputType==Enum.UserInputType.MouseButton1 then bA=true;if bz and not cC.readonly then cH=an.Heartbeat:Connect(function()if not bA or bk then if cH then cH:Disconnect()cH=nil end;return end;local bD=b3()local b6=math.clamp((bD.X-cE.AbsolutePosition.X)/cE.AbsoluteSize.X,0,1)cF.Size=UDim2.new(b6,0,0,20)local ap=math.floor(b6*100)local cI=cC.max;local cJ=cC.min;local cK=cI-cJ;local cL=math.floor(cK/100*ap+cJ)cG.Text=tostring(cL)SafeCallback(co,cL)end)end end end)al.InputEnded:Connect(function(bC)if bC.UserInputType==Enum.UserInputType.MouseButton1 then bA=false;if cH then cH:Disconnect()cH=nil end end end)function cD:Set(cM)cM=tonumber(cM)or 0;cM=math.clamp(cM,0,100)/100;cF.Size=UDim2.new(cM,0,0,20)local ap=math.floor(cM*100)local cI=cC.max;local cJ=cC.min;local cK=cI-cJ;local cL=math.floor(cK/100*ap+cJ)cG.Text=tostring(cL)SafeCallback(co,cL)end;cD:Set(cC.min)return cD,cE end;function bU:AddKeybind(cN,co,cO)local cP={}cN=tostring(cN or"New Keybind")co=typeof(co)=="function"and co or function()end;cO=typeof(cO)=="table"and cO or{}cO.standard=cO.standard or Enum.KeyCode.RightShift;local cQ=c:FindFirstChild("Keybind"):Clone()local ax=cQ:FindFirstChild("Input")local bi=cQ:FindFirstChild("Title")cQ.ZIndex=cQ.ZIndex+bc*10;ax.ZIndex=ax.ZIndex+bc*10;ax:GetChildren()[1].ZIndex=ax:GetChildren()[1].ZIndex+bc*10;bi.ZIndex=bi.ZIndex+bc*10;local c1=c0:FindFirstChild("TabScroller")cQ.Parent=c1 or c0;bi.Text="  "..cN;cQ.Size=UDim2.new(0,b1(bi)+80,0,20)local cR={RightControl="RightCtrl",LeftControl="LeftCtrl",LeftShift="LShift",RightShift="RShift",MouseButton1="Mouse1",MouseButton2="Mouse2"}local cS=cO.standard;function cP:SetKeybind(ag)local cT=cR[ag.Name]or ag.Name;ax.Text=cT;cS=ag end;al.InputBegan:Connect(function(cU,aR)if ar.binding then task.defer(function()ar.binding=false end)return end;if cU.KeyCode==cS and not aR then SafeCallback(co,cS)end end)cP:SetKeybind(cO.standard)ax.MouseButton1Click:Connect(function()if ar.binding then return end;ax.Text="..."ar.binding=true;local cU=al.InputBegan:Wait()cP:SetKeybind(cU.KeyCode)end)return cP,cQ end;function bU:AddDropdown(cV,co)local cW={}cV=tostring(cV or"New Dropdown")co=typeof(co)=="function"and co or function()end;local cX=c:FindFirstChild("Dropdown"):Clone()local cY=cX:FindFirstChild("Box")local cZ=cY:FindFirstChild("Objects")local cF=cX:FindFirstChild("Indicator")cX.ZIndex=cX.ZIndex+bc*10;cY.ZIndex=cY.ZIndex+bc*10;cZ.ZIndex=cZ.ZIndex+bc*10;cF.ZIndex=cF.ZIndex+bc*10;cX.Size=UDim2.new(0.5,-5,0,20)local c_=cX:GetChildren()[3]c_.ZIndex=c_.ZIndex+bc*10;c_.ImageTransparency=bj.title_bar_transparency or 0;aH(c_,bj.title_bar,0)cY.ImageTransparency=bj.background_transparency or 0.1;aH(cY,bj.background,0)local d0=Instance.new("UICorner")d0.CornerRadius=UDim.new(0,6)d0.Parent=cY;cZ.BackgroundTransparency=1;cZ.Position=UDim2.new(0,0,0,0)cZ.Size=UDim2.new(1,0,1,0)local c1=c0:FindFirstChild("TabScroller")cX.Parent=c1 or c0;cX.Text="      "..cV;cY.Size=UDim2.new(1,0,0,0)cY.Position=UDim2.new(0,0,0,25)cX.TextColor3=Color3.new(1,1,1)local bF=false;local d1=false;cX.MouseButton1Click:Connect(function()bF=not bF;local d2=math.min((#cZ:GetChildren()-1)*20,200)if#cZ:GetChildren()-1>=10 then cZ.CanvasSize=UDim2.new(0,0,(#cZ:GetChildren()-1)*0.1,0)end;if bF then if bk then return end;bk=true;local d3=cX.AbsolutePosition.Y;local d4=cX.AbsoluteSize.Y;local d5=e.AbsolutePosition.Y+e.AbsoluteSize.Y;local d6=d5-(d3+d4)if d6<d2 then d1=true;cY.Position=UDim2.new(0,0,0,-d2-5)cY.Size=UDim2.new(1,0,0,0)local aF=TweenInfo.new(bj.tween_time,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)local aG=am:Create(cY,aF,{Size=UDim2.new(1,0,0,d2),Position=UDim2.new(0,0,0,-d2-5)})aG:Play()az(cF,{Rotation=-90},bj.tween_time)else d1=false;cY.Position=UDim2.new(0,0,0,25)cY.Size=UDim2.new(1,0,0,0)az(cY,{Size=UDim2.new(1,0,0,d2)},bj.tween_time)az(cF,{Rotation=90},bj.tween_time)end else bk=false;if d1 then local aF=TweenInfo.new(bj.tween_time,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)local aG=am:Create(cY,aF,{Size=UDim2.new(1,0,0,0),Position=UDim2.new(0,0,0,-5)})aG:Play()aG.Completed:Connect(function()cY.Position=UDim2.new(0,0,0,25)end)else az(cY,{Size=UDim2.new(1,0,0,0)},bj.tween_time)end;az(cF,{Rotation=-90},bj.tween_time)end end)function cW:Add(d7)local d8={}d7=tostring(d7 or"New Object")local aZ=c:FindFirstChild("DropdownButton"):Clone()aZ.Parent=cZ;aZ.Text="      "..d7;aZ.ZIndex=aZ.ZIndex+bc*10+5;aZ.BackgroundTransparency=1;aZ.TextColor3=Color3.new(1,1,1)aZ.BorderSizePixel=0;aZ.TextXAlignment=Enum.TextXAlignment.Left;local d9=aZ:FindFirstChildOfClass("UICorner")if d9 then d9:Destroy()end;local bY=Instance.new("UIStroke")bY.Color=Color3.new(0,0,0)bY.Thickness=1;bY.Transparency=0.3;bY.Parent=aZ;aZ.MouseEnter:Connect(function()aZ.BackgroundTransparency=0.8;aZ.BackgroundColor3=bj.main_color end)aZ.MouseLeave:Connect(function()aZ.BackgroundTransparency=1 end)if bF then local d2=math.min((#cZ:GetChildren()-1)*20,200)if#cZ:GetChildren()-1>=10 then cZ.CanvasSize=UDim2.new(0,0,(#cZ:GetChildren()-1)*0.1,0)end;if d1 then local aF=TweenInfo.new(bj.tween_time,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)local aG=am:Create(cY,aF,{Size=UDim2.new(1,0,0,d2),Position=UDim2.new(0,0,0,-d2-5)})aG:Play()else az(cY,{Size=UDim2.new(1,0,0,d2)},bj.tween_time)end end;aZ.MouseButton1Click:Connect(function()if bk then cX.Text="      [ "..d7 .." ]"bk=false;bF=false;if d1 then local aF=TweenInfo.new(bj.tween_time,Enum.EasingStyle.Quad,Enum.EasingDirection.Out)local aG=am:Create(cY,aF,{Size=UDim2.new(1,0,0,0),Position=UDim2.new(0,0,0,-5)})aG:Play()aG.Completed:Connect(function()cY.Position=UDim2.new(0,0,0,25)end)else az(cY,{Size=UDim2.new(1,0,0,0)},bj.tween_time)end;az(cF,{Rotation=-90},bj.tween_time)SafeCallback(co,d7)end end)function d8:Remove()aZ:Destroy()end;return aZ,d8 end;function cW:Remove(da)local db=cZ:FindFirstChild(da)if db then db:Destroy()if cW.currentSelection==da then local dc=cZ:GetChildren()[1]local dd=dc and dc.Text or"No Selection"cW.currentSelection=dd;cX.Text="        [ "..dd.." ]"SafeCallback(co,dd)end end end;return cW,cX end;function bU:AddColorPicker(co)local de={}co=typeof(co)=="function"and co or function()end;local df=c:FindFirstChild("ColorPicker"):Clone()local c1=c0:FindFirstChild("TabScroller")df.Parent=c1 or c0;df.ZIndex=df.ZIndex+bc*10;local dg=df:FindFirstChild("Palette")local dh=df:FindFirstChild("Sample")local di=df:FindFirstChild("Saturation")dg.ZIndex=dg.ZIndex+bc*10;dh.ZIndex=dh.ZIndex+bc*10;di.ZIndex=di.ZIndex+bc*10;local aU,aV,aW=0,1,1;local function dj()local dk=Color3.fromHSV(aU,aV,aW)dh.ImageColor3=dk;di.ImageColor3=Color3.fromHSV(aU,1,1)SafeCallback(co,dk)end;local dk=Color3.fromHSV(aU,aV,aW)dh.ImageColor3=dk;di.ImageColor3=Color3.fromHSV(aU,1,1)local dl,dm=false,false;dg.MouseEnter:Connect(function()e.Draggable=false;dl=true end)dg.MouseLeave:Connect(function()e.Draggable=true;dl=false end)di.MouseEnter:Connect(function()e.Draggable=false;dm=true end)di.MouseLeave:Connect(function()e.Draggable=true;dm=false end)local dn=dg:FindFirstChild("Indicator")local dp=di:FindFirstChild("Indicator")dn.ZIndex=dn.ZIndex+bc*10;dp.ZIndex=dp.ZIndex+bc*10;local bA=false;local dq;al.InputBegan:Connect(function(bC)if bC.UserInputType==Enum.UserInputType.MouseButton1 then bA=true;dq=an.Heartbeat:Connect(function()if not bA or bk then if dq then dq:Disconnect()dq=nil end;return end;if dl then local bD=b3()local b6=math.clamp((bD.X-dg.AbsolutePosition.X)/dg.AbsoluteSize.X,0,1)local b7=math.clamp((bD.Y-dg.AbsolutePosition.Y)/dg.AbsoluteSize.Y,0,1)aU=b6;aV=1-b7;dn.Position=UDim2.new(b6,-dn.AbsoluteSize.X/2,b7,-dn.AbsoluteSize.Y/2)dj()elseif dm then local bD=b3()local b7=math.clamp((bD.Y-di.AbsolutePosition.Y)/di.AbsoluteSize.Y,0,1)aW=1-b7;dp.Position=UDim2.new(0,0,b7,0)dj()end end)end end)al.InputEnded:Connect(function(bC)if bC.UserInputType==Enum.UserInputType.MouseButton1 then bA=false;if dq then dq:Disconnect()dq=nil end end end)function de:Set(dk)dk=typeof(dk)=="Color3"and dk or Color3.new(1,1,1)local dr,ds,dt=aO(dk.r*255,dk.g*255,dk.b*255)dh.ImageColor3=dk;di.ImageColor3=Color3.fromHSV(dr,1,1)SafeCallback(co,dk)end;return de,df end;function bU:AddHorizontalAlignment()local du={}local dv=c:FindFirstChild("HorizontalAlignment"):Clone()local c1=c0:FindFirstChild("TabScroller")dv.Parent=c1 or c0;function du:AddButton(...)local dw={bU:AddButton(...)}local aZ=dw[#dw]aZ.Parent=dv;return table.unpack(dw)end;return du,dv end;function bU:AddFolder(dx)local dy={}dx=tostring(dx or"New Folder")local dz=c:FindFirstChild("Folder"):Clone()local b5=dz:FindFirstChild("Button")local cZ=dz:FindFirstChild("Objects")local dA=b5:FindFirstChild("Toggle")dz.ZIndex=dz.ZIndex+bc*10;b5.ZIndex=b5.ZIndex+bc*10;cZ.ZIndex=cZ.ZIndex+bc*10;dA.ZIndex=dA.ZIndex+bc*10;b5:GetChildren()[1].ZIndex=b5:GetChildren()[1].ZIndex+bc*10;local c1=c0:FindFirstChild("TabScroller")dz.Parent=c1 or c0;b5.Text="      "..dx;local cp=b5:GetChildren()[1]cp.ImageColor3=bj.main_color;local function dB()local d7=25;for aw,aW in ipairs(cZ:GetChildren())do if not aW:IsA("UIListLayout")then d7=d7+aW.AbsoluteSize.Y+5 end end;return d7 end;local bF=false;local dC;b5.MouseButton1Click:Connect(function()bF=not bF;if bF then az(dA,{Rotation=90},bj.tween_time)cZ.Visible=true;if dC then dC:Disconnect()end;dC=an.Heartbeat:Connect(function()if bF then dz.Size=UDim2.new(1,0,0,dB())else if dC then dC:Disconnect()dC=nil end end end)else az(dA,{Rotation=0},bj.tween_time)cZ.Visible=false;dz.Size=UDim2.new(1,0,0,20)if dC then dC:Disconnect()dC=nil end end end)for bh,aW in pairs(bU)do dy[bh]=function(...)local dw={aW(...)}local aZ=dw[#dw]aZ.Parent=cZ;return table.unpack(dw)end end;return dy,dz end end;return bU,c0 end end;for aw,aW in ipairs(e:GetDescendants())do if aY(aW,"ZIndex")then aW.ZIndex=aW.ZIndex+bc*10 end end;return bx,e end;if script and script.AncestryChanged then
    script.AncestryChanged:Connect(function()
        if not script.Parent then av() end
    end)
end

--[[ GOLD PREMIUM V2 - UI/UX + stability extensions
     Keeps the original AddWindow/AddTab/AddFolder/etc. API intact. ]]

bd.Version = "GOLD PREMIUM ULTIMATE"
bd.Theme = {
    Main = Color3.fromRGB(218,184,92),
    Background = Color3.fromRGB(12,12,15),
    Surface = Color3.fromRGB(24,23,20),
    Text = Color3.fromRGB(238,238,242),
    Muted = Color3.fromRGB(160,160,168),
    Success = Color3.fromRGB(90,200,130),
    Warning = Color3.fromRGB(235,180,70),
    Danger = Color3.fromRGB(225,85,85),
    Overlay = Color3.fromRGB(0,0,0)
}
bd.Themes = {}
function bd:CreateTheme(name, values)
    name = tostring(name or "Custom")
    values = type(values) == "table" and values or {}
    local theme = {}
    for key, value in pairs(self.Theme) do theme[key] = value end
    for key, value in pairs(values) do theme[key] = value end
    self.Themes = self.Themes or {}
    self.Themes[name] = theme
    return theme
end

bd:CreateTheme("MidnightGold", {
    Main = Color3.fromRGB(218,184,92),
    Background = Color3.fromRGB(12,12,15),
    Surface = Color3.fromRGB(24,23,20),
    Text = Color3.fromRGB(238,238,242),
    Muted = Color3.fromRGB(160,160,168)
})
bd:CreateTheme("Obsidian", {
    Main = Color3.fromRGB(190,190,200),
    Background = Color3.fromRGB(8,9,12),
    Surface = Color3.fromRGB(19,20,25),
    Text = Color3.fromRGB(242,242,246),
    Muted = Color3.fromRGB(150,153,165)
})


function bd:SetToggleKey(key)
    if typeof(key) ~= "EnumItem" then return false end
    a.toggle_key = key
    return true
end

function bd:GetToggleKey()
    return a.toggle_key
end

function bd:Notify(title, message, duration, accent)
    duration = math.clamp(tonumber(duration) or 3, 0.8, 12)
    title = tostring(title or "GOLD PREMIUM")
    message = tostring(message or "")
    accent = typeof(accent) == "Color3" and accent or self.Theme.Main

    local holder = b:FindFirstChild("GPN_Notifications")
    if not holder then
        holder = Instance.new("Frame")
        holder.Name = "GPN_Notifications"
        holder.BackgroundTransparency = 1
        holder.AnchorPoint = Vector2.new(1, 0)
        holder.Position = UDim2.new(1, -18, 0, 18)
        holder.Size = UDim2.new(0, 320, 0, 0)
        holder.ZIndex = 10000
        holder.Parent = b

        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 8)
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
        layout.VerticalAlignment = Enum.VerticalAlignment.Top
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent = holder
    end

    local card = Instance.new("Frame")
    card.Name = "Notification"
    card.BackgroundColor3 = self.Theme.Surface
    card.BackgroundTransparency = 0.04
    card.BorderSizePixel = 0
    card.Size = UDim2.new(1, 0, 0, 72)
    card.ZIndex = 10001
    card.Parent = holder

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Color = accent
    stroke.Thickness = 1.2
    stroke.Transparency = 0.2
    stroke.Parent = card

    local rail = Instance.new("Frame")
    rail.BackgroundColor3 = accent
    rail.BorderSizePixel = 0
    rail.Size = UDim2.new(0, 3, 1, -16)
    rail.Position = UDim2.new(0, 8, 0, 8)
    rail.ZIndex = 10002
    rail.Parent = card
    local railCorner = Instance.new("UICorner")
    railCorner.CornerRadius = UDim.new(1, 0)
    railCorner.Parent = rail

    local titleLabel = Instance.new("TextLabel")
    titleLabel.BackgroundTransparency = 1
    titleLabel.Position = UDim2.new(0, 20, 0, 8)
    titleLabel.Size = UDim2.new(1, -30, 0, 20)
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.Text = title
    titleLabel.TextColor3 = self.Theme.Text
    titleLabel.TextSize = 13
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.ZIndex = 10002
    titleLabel.Parent = card

    local bodyLabel = Instance.new("TextLabel")
    bodyLabel.BackgroundTransparency = 1
    bodyLabel.Position = UDim2.new(0, 20, 0, 29)
    bodyLabel.Size = UDim2.new(1, -110, 0, 34)
    bodyLabel.Font = Enum.Font.Gotham
    bodyLabel.Text = message
    bodyLabel.TextColor3 = self.Theme.Muted
    bodyLabel.TextSize = 11
    bodyLabel.TextWrapped = true
    bodyLabel.TextXAlignment = Enum.TextXAlignment.Left
    bodyLabel.TextYAlignment = Enum.TextYAlignment.Top
    bodyLabel.ZIndex = 10002
    bodyLabel.Parent = card

    card.BackgroundTransparency = 1
    titleLabel.TextTransparency = 1
    bodyLabel.TextTransparency = 1
    rail.BackgroundTransparency = 1

    az(card, {BackgroundTransparency = 0.04}, 0.16)
    az(titleLabel, {TextTransparency = 0}, 0.16)
    az(bodyLabel, {TextTransparency = 0}, 0.16)
    az(rail, {BackgroundTransparency = 0}, 0.16)

    task.delay(duration, function()
        if not card or not card.Parent then return end
        local tw = az(card, {BackgroundTransparency = 1}, 0.18)
        az(titleLabel, {TextTransparency = 1}, 0.18)
        az(bodyLabel, {TextTransparency = 1}, 0.18)
        az(rail, {BackgroundTransparency = 1}, 0.18)
        if tw then tw.Completed:Wait() end
        if card and card.Parent then card:Destroy() end
    end)

    return card
end

-- GOLD PREMIUM V4: reusable UI style + responsive helpers
-- Inspired by Roblox Creator Hub guidance for hierarchy, UIStroke/UIGradient,
-- responsive sizing and TweenService state transitions.

function bd:SetWindowTitle(title, subtitle)
    self.WindowTitle = tostring(title or "GOLD PREMIUM")
    self.WindowSubtitle = tostring(subtitle or "")
    for _, win in ipairs(ak:GetChildren()) do
        local top = win:FindFirstChild("Topbar", true) or win:FindFirstChild("TitleBar", true)
        if top then
            local titleObj = top:FindFirstChild("Title", true)
            local subObj = top:FindFirstChild("Subtitle", true)
            if titleObj and titleObj:IsA("TextLabel") then
                titleObj.Text = self.WindowTitle
            end
            if subObj and subObj:IsA("TextLabel") then
                subObj.Text = self.WindowSubtitle
            end
        end
    end
end

function bd:SetWindowMinimized(window, minimized)
    if not window or not window:IsA("GuiObject") then return false end
    minimized = minimized == true

    local body = window:FindFirstChild("Body", true)
        or window:FindFirstChild("Content", true)
        or window:FindFirstChild("Elements", true)

    local tabs = window:FindFirstChild("Tabs", true)
        or window:FindFirstChild("TabList", true)

    if body then body.Visible = not minimized end
    if tabs then tabs.Visible = not minimized end

    local button = window:FindFirstChild("GP_Minimize", true)
    if button and button:IsA("TextButton") then
        button.Text = minimized and "+" or "−"
    end

    return minimized
end

function bd:AddWindowControls(window)
    if not window or not window:IsA("GuiObject") then return end
    local top = window:FindFirstChild("Topbar", true)
        or window:FindFirstChild("TitleBar", true)
    if not top then return end

    local existing = top:FindFirstChild("GP_WindowControls")
    if existing then return existing end

    local controls = Instance.new("Frame")
    controls.Name = "GP_WindowControls"
    controls.BackgroundTransparency = 1
    controls.AnchorPoint = Vector2.new(1, 0.5)
    controls.Position = UDim2.new(1, -10, 0.5, 0)
    controls.Size = UDim2.new(0, 72, 0, 28)
    controls.ZIndex = 50
    controls.Parent = top

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    layout.VerticalAlignment = Enum.VerticalAlignment.Center
    layout.Padding = UDim.new(0, 6)
    layout.Parent = controls

    local function makeButton(name, symbol, callback)
        local b = Instance.new("TextButton")
        b.Name = name
        b.Size = UDim2.new(0, 30, 0, 26)
        b.BackgroundColor3 = self.Theme.Surface
        b.BackgroundTransparency = 0.12
        b.BorderSizePixel = 0
        b.AutoButtonColor = false
        b.Text = symbol
        b.TextColor3 = self.Theme.Text
        b.Font = Enum.Font.GothamBold
        b.TextSize = 14
        b.ZIndex = 51
        b.Parent = controls

        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 7)
        c.Parent = b

        local s = Instance.new("UIStroke")
        s.Color = self.Theme.Main
        s.Transparency = 0.78
        s.Thickness = 1
        s.Parent = b

        b.MouseEnter:Connect(function()
            az(b, {BackgroundColor3 = self.Theme.Main, TextColor3 = self.Theme.Background}, self:GetTweenTime(0.1))
        end)
        b.MouseLeave:Connect(function()
            az(b, {BackgroundColor3 = self.Theme.Surface, TextColor3 = self.Theme.Text}, self:GetTweenTime(0.1))
        end)
        b.Activated:Connect(callback)
        return b
    end

    local minButton = makeButton("GP_Minimize", "−", function()
        local minimized = not (window:GetAttribute("GP_Minimized") == true)
        window:SetAttribute("GP_Minimized", minimized)
        self:SetWindowMinimized(window, minimized)
    end)

    minButton:SetAttribute("GP_Control", true)

    local closeButton = makeButton("GP_Close", "×", function()
        window.Visible = false
    end)
    closeButton:SetAttribute("GP_Control", true)

    return controls
end

function bd:SetTheme(theme)
    if type(theme) ~= "table" then return false end
    for key, value in pairs(theme) do
        if self.Theme[key] ~= nil and typeof(value) == typeof(self.Theme[key]) then
            self.Theme[key] = value
        end
    end

    for _, win in ipairs(ak:GetChildren()) do
        for _, obj in ipairs(win:GetDescendants()) do
            if obj:IsA("UIStroke") and obj.Name ~= "GP_Stroke" then
                obj.Color = self.Theme.Main
            end
        end
    end
    return true
end


function bd:EnableEscapeToClose(enabled)
    if self._EscapeConnection then
        self._EscapeConnection:Disconnect()
        self._EscapeConnection = nil
    end
    if enabled == false then return false end

    local UIS = game:GetService("UserInputService")
    self._EscapeConnection = UIS.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == Enum.KeyCode.Escape then
            self:Close()
        end
    end)
    return true
end

function bd:NewFlag(defaultValue)
    self._FlagCounter = (self._FlagCounter or 0) + 1
    return "GP_" .. tostring(self._FlagCounter)
end

function bd:SetFlag(flag, value)
    self.Flags = self.Flags or {}
    self.Flags[tostring(flag)] = value
    return value
end

function bd:GetFlag(flag, defaultValue)
    self.Flags = self.Flags or {}
    local value = self.Flags[tostring(flag)]
    if value == nil then return defaultValue end
    return value
end

function bd:ClearFlags()
    self.Flags = {}
end

function bd:NotifyAction(title, message, duration, actionName, callback)
    local card = self:Notify(title, message, duration, self.Theme.Main)
    if not card then return nil end

    local action = Instance.new("TextButton")
    action.Name = "Action"
    action.AnchorPoint = Vector2.new(1, 0.5)
    action.Position = UDim2.new(1, -10, 0.5, 0)
    action.Size = UDim2.new(0, 70, 0, 26)
    action.BackgroundColor3 = self.Theme.Main
    action.BorderSizePixel = 0
    action.Text = tostring(actionName or "OK")
    action.TextColor3 = self.Theme.Background
    action.Font = Enum.Font.GothamBold
    action.TextSize = 10
    action.ZIndex = 10003
    action.Parent = card

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = action

    action.Activated:Connect(function()
        if type(callback) == "function" then
            pcall(callback)
        end
        if card and card.Parent then card:Destroy() end
    end)

    return card
end

function bd:SetTabVisible(tab, visible)
    if not tab or not tab:IsA("GuiObject") then return false end
    tab.Visible = visible ~= false
    return tab.Visible
end

function bd:FindUI(query, root)
    root = root or b
    query = string.lower(tostring(query or ""))
    if query == "" then return {} end

    local result = {}
    for _, obj in ipairs(root:GetDescendants()) do
        if (obj:IsA("TextButton") or obj:IsA("TextLabel") or obj:IsA("TextBox")) then
            local value = string.lower(tostring(obj.Text or ""))
            if string.find(value, query, 1, true) then
                result[#result + 1] = obj
            end
        end
    end
    return result
end

function bd:FitWindowToViewport(window, margin)
    if not window or not window:IsA("GuiObject") then return false end
    margin = tonumber(margin) or 24

    local camera = workspace.CurrentCamera
    if not camera then return false end

    local viewport = camera.ViewportSize
    local maxW = math.max(360, viewport.X - margin * 2)
    local maxH = math.max(260, viewport.Y - margin * 2)

    local constraint = window:FindFirstChild("GP_Size")
    if constraint and constraint:IsA("UISizeConstraint") then
        constraint.MaxSize = Vector2.new(math.min(1100, maxW), math.min(760, maxH))
    end

    return true
end

function bd:Validate()
    local problems = {}
    if type(self.Theme) ~= "table" then
        problems[#problems + 1] = "Theme inválido"
    end
    if type(self.GetWindows) ~= "function" then
        problems[#problems + 1] = "GetWindows ausente"
    end
    for _, win in ipairs(self:GetWindows()) do
        if not win:IsA("GuiObject") then
            problems[#problems + 1] = "Ventana inválida"
        end
    end
    return #problems == 0, problems
end



function bd:UseTheme(name)
    if not self.Themes or not self.Themes[name] then return false end
    return self:SetTheme(self.Themes[name])
end

function bd:ResetTheme()
    self.Theme = {
        Main = Color3.fromRGB(218,184,92),
        Background = Color3.fromRGB(12,12,15),
        Surface = Color3.fromRGB(24,23,20),
        Text = Color3.fromRGB(238,238,242),
        Muted = Color3.fromRGB(160,160,168)
    }
    return true
end

function bd:SaveState(key, value)
    self.State = self.State or {}
    self.State[tostring(key)] = value
    return value
end

function bd:LoadState(key, default)
    self.State = self.State or {}
    local value = self.State[tostring(key)]
    if value == nil then return default end
    return value
end

function bd:ClearState()
    self.State = {}
end

function bd:Open()
    for _, win in ipairs(ak:GetChildren()) do
        if win:IsA("GuiObject") then win.Visible = true end
    end
    return true
end

function bd:Close()
    for _, win in ipairs(ak:GetChildren()) do
        if win:IsA("GuiObject") then win.Visible = false end
    end
    return true
end

function bd:Toggle()
    local anyVisible = false
    for _, win in ipairs(ak:GetChildren()) do
        if win:IsA("GuiObject") and win.Visible then
            anyVisible = true
            break
        end
    end
    if anyVisible then return self:Close() else return self:Open() end
end

function bd:GetWindows()
    local result = {}
    for _, win in ipairs(ak:GetChildren()) do
        if win:IsA("GuiObject") then
            result[#result + 1] = win
        end
    end
    return result
end

function bd:RefreshTheme()
    for _, win in ipairs(self:GetWindows()) do
        for _, obj in ipairs(win:GetDescendants()) do
            if obj:IsA("UIStroke") and (obj.Name == "GP_Stroke" or obj.Name == "GP_WindowStroke" or obj.Name == "PremiumShell") then
                obj.Color = self.Theme.Main
            elseif obj:IsA("TextLabel") or obj:IsA("TextButton") then
                if obj.Name ~= "GP_Tooltip" then
                    obj.TextColor3 = self.Theme.Text
                end
            end
        end
    end
    return true
end

function bd:GetDiagnostics()
    local stats = self:GetStats()
    return {
        Version = stats.Version,
        Windows = stats.Windows,
        Errors = stats.Errors,
        LastError = stats.LastError,
        Effects = self.EffectsEnabled ~= false,
        Theme = self.Theme,
        StateKeys = (function() local n=0; for _ in pairs(self.State or {}) do n = n + 1 end; return n end)()
    }
end

function bd:GetConfig()
    return {
        Version = self.Version,
        Theme = self.Theme,
        ToggleKey = self:GetToggleKey(),
        EffectsEnabled = self.EffectsEnabled ~= false
    }
end

function bd:SetEffectsEnabled(enabled)
    self.EffectsEnabled = enabled ~= false
    for _, win in ipairs(ak:GetChildren()) do
        local particles = win:FindFirstChild("FluentParticles", true)
        if particles then particles.Visible = self.EffectsEnabled end
    end
    return self.EffectsEnabled
end

function bd:CenterWindow(window)
    if not window or not window:IsA("GuiObject") then return false end
    window.AnchorPoint = Vector2.new(0.5, 0.5)
    window.Position = UDim2.fromScale(0.5, 0.5)
    return true
end

function bd:ToggleWindow(window)
    if not window or not window:IsA("GuiObject") then return false end
    window.Visible = not window.Visible
    return window.Visible
end

function bd:SetWindowVisible(window, visible)
    if not window or not window:IsA("GuiObject") then return false end
    window.Visible = visible ~= false
    return window.Visible
end

function bd:GetTweenTime(defaultTime)
    local ok, reduced = pcall(function()
        return game:GetService("GuiService").ReducedMotionEnabled
    end)
    return (ok and reduced) and 0 or (tonumber(defaultTime) or a.tween_time or 0.12)
end

function bd:ApplyPremiumStyle(gui)
    if not gui or not gui:IsA("GuiObject") then return gui end

    local corner = gui:FindFirstChild("GP_Corner")
    if not corner then
        corner = Instance.new("UICorner")
        corner.Name = "GP_Corner"
        corner.CornerRadius = UDim.new(0, 10)
        corner.Parent = gui
    end

    local stroke = gui:FindFirstChild("GP_Stroke")
    if not stroke then
        stroke = Instance.new("UIStroke")
        stroke.Name = "GP_Stroke"
        stroke.Color = self.Theme.Main
        stroke.Thickness = 1
        stroke.Transparency = 0.72
        stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        stroke.Parent = gui
    end

    return gui
end

function bd:AddHoverEffect(button, normalColor, hoverColor)
    if not button or not button:IsA("GuiButton") then return end
    normalColor = normalColor or button.BackgroundColor3
    hoverColor = hoverColor or self.Theme.Main

    local scale = button:FindFirstChild("GP_Scale")
    if not scale then
        scale = Instance.new("UIScale")
        scale.Name = "GP_Scale"
        scale.Scale = 1
        scale.Parent = button
    end

    local function tween(target)
        az(scale, {Scale = target}, self:GetTweenTime(0.12))
    end

    button.MouseEnter:Connect(function()
        if button.BackgroundTransparency < 1 then
            az(button, {BackgroundColor3 = hoverColor}, self:GetTweenTime(0.12))
        end
        tween(1.025)
    end)

    button.MouseLeave:Connect(function()
        if button.BackgroundTransparency < 1 then
            az(button, {BackgroundColor3 = normalColor}, self:GetTweenTime(0.12))
        end
        tween(1)
    end)

    button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            tween(0.97)
        end
    end)

    button.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            tween(1.025)
        end
    end)

    return button
end

function bd:SetResponsiveWindow(window)
    if not window or not window:IsA("GuiObject") then return end

    -- Keep sizing flexible: UISizeConstraint protects usability while the
    -- library's own resizer remains free to change width/height independently.
    local constraint = window:FindFirstChild("GP_Aspect")
    if constraint then constraint:Destroy() end

    local size = window:FindFirstChild("GP_Size")
    if not size then
        size = Instance.new("UISizeConstraint")
        size.Name = "GP_Size"
        size.MinSize = Vector2.new(360, 260)
        size.MaxSize = Vector2.new(1100, 760)
        size.Parent = window
    end
end



function bd:AddTooltip(guiObject, textValue)
    if not guiObject or not guiObject:IsA("GuiObject") then return end
    local tooltip = guiObject:FindFirstChild("GP_Tooltip")
    if tooltip then tooltip:Destroy() end

    tooltip = Instance.new("TextLabel")
    tooltip.Name = "GP_Tooltip"
    tooltip.Visible = false
    tooltip.BackgroundColor3 = self.Theme.Surface
    tooltip.BackgroundTransparency = 0.04
    tooltip.BorderSizePixel = 0
    tooltip.Size = UDim2.new(0, math.max(120, #tostring(textValue) * 6 + 24), 0, 30)
    tooltip.AnchorPoint = Vector2.new(0.5, 1)
    tooltip.Position = UDim2.new(0.5, 0, 0, -7)
    tooltip.Font = Enum.Font.GothamMedium
    tooltip.Text = tostring(textValue or "")
    tooltip.TextColor3 = self.Theme.Text
    tooltip.TextSize = 11
    tooltip.ZIndex = 1000
    tooltip.Parent = guiObject

    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 7)
    c.Parent = tooltip

    local s = Instance.new("UIStroke")
    s.Color = self.Theme.Main
    s.Transparency = 0.72
    s.Thickness = 1
    s.Parent = tooltip

    guiObject.MouseEnter:Connect(function()
        tooltip.Visible = true
    end)
    guiObject.MouseLeave:Connect(function()
        tooltip.Visible = false
    end)
    guiObject.SelectionGained:Connect(function()
        tooltip.Visible = true
    end)
    guiObject.SelectionLost:Connect(function()
        tooltip.Visible = false
    end)

    return tooltip
end


function bd:ConstrainText(guiObject, minSize, maxSize)
    if not guiObject then return end
    if not (guiObject:IsA("TextLabel") or guiObject:IsA("TextButton") or guiObject:IsA("TextBox")) then
        return
    end
    local c = guiObject:FindFirstChild("GP_TextConstraint")
    if not c then
        c = Instance.new("UITextSizeConstraint")
        c.Name = "GP_TextConstraint"
        c.Parent = guiObject
    end
    c.MinTextSize = math.max(9, tonumber(minSize) or 10)
    c.MaxTextSize = math.max(c.MinTextSize, tonumber(maxSize) or 18)
    return c
end

function bd:FilterButtons(container, query)
    if not container then return 0 end
    query = string.lower(tostring(query or ""))
    local visible = 0

    for _, obj in ipairs(container:GetDescendants()) do
        if obj:IsA("TextButton") or obj:IsA("TextLabel") then
            local textValue = string.lower(tostring(obj.Text or ""))
            if obj.Name ~= "GP_Minimize" and obj.Name ~= "GP_Close" then
                local show = query == "" or string.find(textValue, query, 1, true) ~= nil
                obj.Visible = show
                if show then visible = visible + 1 end
            end
        end
    end

    return visible
end


function bd:GetStats()
    local last = ErrorLog[#ErrorLog]
    return {
        Version = self.Version,
        Windows = #ak:GetChildren(),
        Errors = #ErrorLog,
        LastError = last and {
            message = last.message,
            source = last.source,
            time = last.time
        } or nil
    }
end

function bd:Destroy()
    if self._EscapeConnection then self._EscapeConnection:Disconnect(); self._EscapeConnection = nil end
    fluentParticleRunning = false
    av()
    local notifications = b:FindFirstChild("GPN_Notifications")
    if notifications then notifications:Destroy() end
    if b and b.Parent then b:Destroy() end
end

bd.ClearErrorLog = ClearErrorLog;bd.GetErrorLog = GetErrorLog;bd.SafeCallback = SafeCallback;bd.GetLastError = function() return ErrorLog[#ErrorLog] end;bd.ErrorDetector = TrayectooErrorDetector;bd.GetRuntimeErrors = function() return TrayectooErrorDetector:GetErrors() end;bd.ClearRuntimeErrors = function() TrayectooErrorDetector:Clear() end



-- ============================================================
-- GOLD PREMIUM VISUAL V5
-- Visual-only polish: no extra gameplay features.
-- ============================================================

pcall(function()
    local Visual = {
        Gold = Color3.fromRGB(218,184,92),
        GoldSoft = Color3.fromRGB(170,142,70),
        Background = Color3.fromRGB(9,10,13),
        Surface = Color3.fromRGB(17,18,22),
        Surface2 = Color3.fromRGB(22,23,28),
        Text = Color3.fromRGB(242,242,246),
        Muted = Color3.fromRGB(150,153,162)
    }

    bd.VisualVersion = "V5"

    local function styleObject(obj)
        if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
            obj.Font = Enum.Font.Gotham
            obj.TextColor3 = Visual.Text

            if obj:IsA("TextButton") then
                obj.AutoButtonColor = false
            end

            pcall(function()
                bd:ConstrainText(obj, 10, 16)
            end)
        elseif obj:IsA("ScrollingFrame") then
            obj.ScrollBarThickness = 3
            obj.ScrollBarImageColor3 = Visual.Gold
            obj.ScrollBarImageTransparency = 0.55
            obj.BackgroundTransparency = 1
        end
    end

    local function polishWindow(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = Visual.Background

        local corner = win:FindFirstChild("VisualCorner")
        if not corner then
            corner = Instance.new("UICorner")
            corner.Name = "VisualCorner"
            corner.CornerRadius = UDim.new(0, 12)
            corner.Parent = win
        end

        local stroke = win:FindFirstChild("VisualStroke")
        if not stroke then
            stroke = Instance.new("UIStroke")
            stroke.Name = "VisualStroke"
            stroke.Color = Visual.Gold
            stroke.Thickness = 1
            stroke.Transparency = 0.62
            stroke.Parent = win
        end

        local bar = win:FindFirstChild("Bar", true)
        if bar then
            bar.BackgroundColor3 = Visual.Surface2

            local barCorner = bar:FindFirstChild("VisualBarCorner")
            if not barCorner then
                barCorner = Instance.new("UICorner")
                barCorner.Name = "VisualBarCorner"
                barCorner.CornerRadius = UDim.new(0, 10)
                barCorner.Parent = bar
            end

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.Font = Enum.Font.GothamBold
                title.TextSize = 14
                title.TextColor3 = Visual.Text
            end
        end

        local tabs = win:FindFirstChild("TabSelection", true)
        if tabs and tabs:IsA("GuiObject") then
            tabs.BackgroundColor3 = Visual.Surface
            tabs.BackgroundTransparency = 0.08

            local tabsCorner = tabs:FindFirstChild("VisualTabsCorner")
            if not tabsCorner then
                tabsCorner = Instance.new("UICorner")
                tabsCorner.Name = "VisualTabsCorner"
                tabsCorner.CornerRadius = UDim.new(0, 10)
                tabsCorner.Parent = tabs
            end
        end

        for _, obj in ipairs(win:GetDescendants()) do
            styleObject(obj)

            if obj:IsA("TextButton") and obj.Name ~= "GP_Minimize" and obj.Name ~= "GP_Close" then
                pcall(function()
                    bd:AddHoverEffect(
                        obj,
                        Visual.Surface2,
                        Visual.Gold
                    )
                end)
            end
        end
    end

    -- Apply to current and future windows.
    for _, win in ipairs(bd:GetWindows()) do
        polishWindow(win)
    end

    bd.PolishVisuals = polishWindow

    -- Replace particle toggle with a clean-effects toggle.
    function bd:SetEffectsEnabled(enabled)
        self.EffectsEnabled = enabled ~= false

        for _, win in ipairs(self:GetWindows()) do
            for _, obj in ipairs(win:GetDescendants()) do
                if obj:IsA("UIStroke") then
                    if obj.Name == "VisualStroke" then
                        obj.Transparency = self.EffectsEnabled and 0.62 or 0.82
                    elseif obj.Name == "VisualBarStroke" then
                        obj.Transparency = self.EffectsEnabled and 0.55 or 0.8
                    end
                end
            end
        end

        return self.EffectsEnabled
    end

    -- Compact, cleaner notification cards.
    bd.NotifyStyle = {
        Width = 300,
        Height = 64,
        Corner = 9
    }

    -- Make the visual style available as a theme.
    bd:CreateTheme("CleanGold", {
        Main = Visual.Gold,
        Background = Visual.Background,
        Surface = Visual.Surface,
        Text = Visual.Text,
        Muted = Visual.Muted
    })

    bd:UseTheme("CleanGold")

    task.defer(function()
        for _, win in ipairs(bd:GetWindows()) do
            polishWindow(win)
        end
    end)
end)




-- ============================================================
-- GOLD PREMIUM VISUAL V6
-- Extra visual polish only: spacing, hierarchy, shadows,
-- buttons, tabs, inputs and notification presentation.
-- ============================================================

pcall(function()
    local V6 = {
        Gold = Color3.fromRGB(218,184,92),
        GoldBright = Color3.fromRGB(235,205,120),
        Background = Color3.fromRGB(8,9,12),
        Surface = Color3.fromRGB(15,16,20),
        Surface2 = Color3.fromRGB(21,22,27),
        Surface3 = Color3.fromRGB(27,28,34),
        Text = Color3.fromRGB(245,245,248),
        Muted = Color3.fromRGB(145,148,158),
        Border = Color3.fromRGB(48,49,57)
    }

    local function corner(parent, radius, name)
        local c = parent:FindFirstChild(name)
        if not c then
            c = Instance.new("UICorner")
            c.Name = name
            c.CornerRadius = UDim.new(0, radius)
            c.Parent = parent
        end
        return c
    end

    local function stroke(parent, color, transparency, thickness, name)
        local s = parent:FindFirstChild(name)
        if not s then
            s = Instance.new("UIStroke")
            s.Name = name
            s.Parent = parent
        end
        s.Color = color
        s.Transparency = transparency
        s.Thickness = thickness
        return s
    end

    local function addPadding(parent, amount, name)
        local p = parent:FindFirstChild(name)
        if not p then
            p = Instance.new("UIPadding")
            p.Name = name
            p.Parent = parent
        end
        p.PaddingTop = UDim.new(0, amount)
        p.PaddingBottom = UDim.new(0, amount)
        p.PaddingLeft = UDim.new(0, amount)
        p.PaddingRight = UDim.new(0, amount)
        return p
    end

    local function styleButton(obj)
        if not obj:IsA("TextButton") then return end
        if obj.Name == "GP_Close" or obj.Name == "GP_Minimize" then return end

        obj.AutoButtonColor = false
        obj.BackgroundColor3 = V6.Surface2
        obj.TextColor3 = V6.Text
        obj.Font = Enum.Font.GothamMedium
        obj.TextSize = 13

        corner(obj, 7, "V6Corner")
        stroke(obj, V6.Border, 0.35, 1, "V6Stroke")

        pcall(function()
            bd:AddHoverEffect(obj, V6.Surface3, V6.GoldBright)
        end)
    end

    local function styleInput(obj)
        if not obj:IsA("TextBox") then return end

        obj.BackgroundColor3 = V6.Surface
        obj.TextColor3 = V6.Text
        obj.PlaceholderColor3 = V6.Muted
        obj.Font = Enum.Font.Gotham
        obj.TextSize = 13

        corner(obj, 7, "V6InputCorner")
        stroke(obj, V6.Border, 0.25, 1, "V6InputStroke")
    end

    local function styleLabel(obj)
        if not obj:IsA("TextLabel") then return end

        obj.Font = Enum.Font.Gotham
        obj.TextColor3 = V6.Text
        obj.TextSize = math.clamp(obj.TextSize, 11, 15)
    end

    local function styleWindow(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = V6.Background
        corner(win, 13, "V6WindowCorner")
        stroke(win, V6.Gold, 0.72, 1, "V6WindowStroke")

        -- Subtle depth without animated glow.
        if not win:FindFirstChild("V6Shadow") then
            local shadow = Instance.new("ImageLabel")
            shadow.Name = "V6Shadow"
            shadow.BackgroundTransparency = 1
            shadow.Image = "rbxassetid://6014261993"
            shadow.ImageTransparency = 0.72
            shadow.ScaleType = Enum.ScaleType.Slice
            shadow.SliceCenter = Rect.new(49,49,450,450)
            shadow.Size = UDim2.new(1, 24, 1, 24)
            shadow.Position = UDim2.fromOffset(-12, -12)
            shadow.ZIndex = math.max(0, win.ZIndex - 1)
            shadow.Parent = win
        end

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = V6.Surface
            corner(bar, 11, "V6BarCorner")
            stroke(bar, V6.Border, 0.3, 1, "V6BarStroke")

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.Font = Enum.Font.GothamBold
                title.TextColor3 = V6.Text
                title.TextSize = 14
            end
        end

        local tabs = win:FindFirstChild("TabSelection", true)
        if tabs and tabs:IsA("GuiObject") then
            tabs.BackgroundColor3 = V6.Surface
            corner(tabs, 9, "V6TabsCorner")
            addPadding(tabs, 4, "V6TabsPadding")
        end

        for _, obj in ipairs(win:GetDescendants()) do
            styleButton(obj)
            styleInput(obj)
            styleLabel(obj)

            if obj:IsA("ScrollingFrame") then
                obj.ScrollBarThickness = 3
                obj.ScrollBarImageColor3 = V6.Gold
                obj.ScrollBarImageTransparency = 0.45
                obj.BackgroundTransparency = 1
            elseif obj:IsA("Frame") then
                -- Keep structural frames mostly transparent; avoid flattening
                -- the existing library layout.
                if obj.Name:lower():find("section") then
                    obj.BackgroundColor3 = V6.Surface
                    corner(obj, 8, "V6SectionCorner")
                end
            end
        end
    end

    for _, win in ipairs(bd:GetWindows()) do
        styleWindow(win)
    end

    bd.V6VisualStyle = {
        Name = "Clean Gold Ultra",
        AnimatedEffects = false,
        Particles = false
    }

    bd.PolishV6 = styleWindow

    -- Reapply styling shortly after construction so dynamically-created
    -- controls inherit the visual system without a permanent per-frame loop.
    task.delay(0.25, function()
        for _, win in ipairs(bd:GetWindows()) do
            styleWindow(win)
        end
    end)

    task.delay(1, function()
        for _, win in ipairs(bd:GetWindows()) do
            styleWindow(win)
        end
    end)
end)




-- ============================================================
-- GOLD PREMIUM WINDOW V7
-- Ventana visual premium: header, profundidad, botones de
-- minimizar/cerrar y mejor jerarquía. Sin partículas.
-- ============================================================

pcall(function()
    local W7 = {
        Gold = Color3.fromRGB(218,184,92),
        GoldBright = Color3.fromRGB(240,211,126),
        Bg = Color3.fromRGB(7,8,11),
        Panel = Color3.fromRGB(13,14,18),
        Header = Color3.fromRGB(18,19,24),
        Header2 = Color3.fromRGB(24,25,31),
        Text = Color3.fromRGB(247,247,250),
        Muted = Color3.fromRGB(145,148,158),
        Border = Color3.fromRGB(54,55,64)
    }

    local function makeCorner(parent, radius, name)
        local x = parent:FindFirstChild(name)
        if not x then
            x = Instance.new("UICorner")
            x.Name = name
            x.CornerRadius = UDim.new(0, radius)
            x.Parent = parent
        end
        return x
    end

    local function makeStroke(parent, color, transparency, thickness, name)
        local x = parent:FindFirstChild(name)
        if not x then
            x = Instance.new("UIStroke")
            x.Name = name
            x.Parent = parent
        end
        x.Color = color
        x.Transparency = transparency
        x.Thickness = thickness
        return x
    end

    local function decorateWindow(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = W7.Bg
        makeCorner(win, 15, "W7Corner")
        makeStroke(win, W7.Gold, 0.72, 1, "W7Border")

        -- Clean static shadow.
        local shadow = win:FindFirstChild("W7Shadow")
        if not shadow then
            shadow = Instance.new("ImageLabel")
            shadow.Name = "W7Shadow"
            shadow.BackgroundTransparency = 1
            shadow.Image = "rbxassetid://6014261993"
            shadow.ImageTransparency = 0.68
            shadow.ScaleType = Enum.ScaleType.Slice
            shadow.SliceCenter = Rect.new(49,49,450,450)
            shadow.Size = UDim2.new(1, 34, 1, 34)
            shadow.Position = UDim2.fromOffset(-17, -17)
            shadow.ZIndex = 0
            shadow.Parent = win
        end

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = W7.Header
            makeCorner(bar, 13, "W7HeaderCorner")
            makeStroke(bar, W7.Border, 0.25, 1, "W7HeaderBorder")

            -- Gold accent line.
            local accent = bar:FindFirstChild("W7Accent")
            if not accent then
                accent = Instance.new("Frame")
                accent.Name = "W7Accent"
                accent.BorderSizePixel = 0
                accent.BackgroundColor3 = W7.Gold
                accent.Position = UDim2.new(0, 14, 1, -2)
                accent.Size = UDim2.new(1, -28, 0, 2)
                accent.ZIndex = bar.ZIndex + 2
                accent.Parent = bar
            end
            makeCorner(accent, 2, "AccentCorner")

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.Font = Enum.Font.GothamBold
                title.TextColor3 = W7.Text
                title.TextSize = 15
                title.TextXAlignment = Enum.TextXAlignment.Left
            end

            -- Small decorative status dot.
            if not bar:FindFirstChild("W7Status") then
                local dot = Instance.new("Frame")
                dot.Name = "W7Status"
                dot.Size = UDim2.fromOffset(7, 7)
                dot.Position = UDim2.new(0, 8, 0.5, -3)
                dot.BorderSizePixel = 0
                dot.BackgroundColor3 = W7.Gold
                dot.ZIndex = bar.ZIndex + 3
                dot.Parent = bar
                makeCorner(dot, 7, "StatusCorner")
            end
        end

        local tabs = win:FindFirstChild("TabSelection", true)
        if tabs and tabs:IsA("GuiObject") then
            tabs.BackgroundColor3 = W7.Panel
            tabs.BackgroundTransparency = 0
            makeCorner(tabs, 11, "W7TabsCorner")
            makeStroke(tabs, W7.Border, 0.5, 1, "W7TabsBorder")
        end

        -- Make standard controls visually consistent.
        for _, obj in ipairs(win:GetDescendants()) do
            if obj:IsA("TextButton") then
                if obj.Name ~= "GP_Close" and obj.Name ~= "GP_Minimize" then
                    obj.AutoButtonColor = false
                    obj.BackgroundColor3 = W7.Header2
                    obj.TextColor3 = W7.Text
                    obj.Font = Enum.Font.GothamMedium
                    obj.TextSize = 13
                    makeCorner(obj, 8, "W7ButtonCorner")
                    makeStroke(obj, W7.Border, 0.35, 1, "W7ButtonBorder")

                    pcall(function()
                        bd:AddHoverEffect(obj, W7.Header2, W7.GoldBright)
                    end)
                end
            elseif obj:IsA("TextBox") then
                obj.BackgroundColor3 = W7.Header
                obj.TextColor3 = W7.Text
                obj.PlaceholderColor3 = W7.Muted
                obj.Font = Enum.Font.Gotham
                obj.TextSize = 13
                makeCorner(obj, 8, "W7InputCorner")
                makeStroke(obj, W7.Border, 0.3, 1, "W7InputBorder")
            end
        end
    end

    for _, win in ipairs(bd:GetWindows()) do
        decorateWindow(win)
    end

    bd.DecoratePremiumWindow = decorateWindow

    task.delay(0.25, function()
        for _, win in ipairs(bd:GetWindows()) do
            decorateWindow(win)
        end
    end)
end)




-- ============================================================
-- GOLD PREMIUM WINDOW V8 ULTRA
-- Diseño visual: responsive, contraste, jerarquía, gradientes
-- sutiles, padding, títulos y controles consistentes.
-- ============================================================

pcall(function()
    local GuiService = game:GetService("GuiService")

    local U = {
        Gold = Color3.fromRGB(218,184,92),
        GoldLight = Color3.fromRGB(239,211,128),
        GoldDark = Color3.fromRGB(126,101,45),
        Bg = Color3.fromRGB(7,8,11),
        Panel = Color3.fromRGB(13,14,18),
        Panel2 = Color3.fromRGB(18,19,24),
        Panel3 = Color3.fromRGB(24,25,31),
        Text = Color3.fromRGB(246,246,249),
        Muted = Color3.fromRGB(151,154,164),
        Border = Color3.fromRGB(48,50,59)
    }

    local function ensureCorner(o, r, n)
        local x = o:FindFirstChild(n)
        if not x then
            x = Instance.new("UICorner")
            x.Name = n
            x.Parent = o
        end
        x.CornerRadius = UDim.new(0, r)
        return x
    end

    local function ensureStroke(o, c, t, th, n)
        local x = o:FindFirstChild(n)
        if not x then
            x = Instance.new("UIStroke")
            x.Name = n
            x.Parent = o
        end
        x.Color = c
        x.Transparency = t
        x.Thickness = th
        return x
    end

    local function ensureGradient(o, c1, c2, n)
        local g = o:FindFirstChild(n)
        if not g then
            g = Instance.new("UIGradient")
            g.Name = n
            g.Parent = o
        end
        g.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, c1),
            ColorSequenceKeypoint.new(1, c2)
        })
        g.Rotation = 90
        return g
    end

    local function ensurePadding(o, l, r, t, b, n)
        local p = o:FindFirstChild(n)
        if not p then
            p = Instance.new("UIPadding")
            p.Name = n
            p.Parent = o
        end
        p.PaddingLeft = UDim.new(0, l)
        p.PaddingRight = UDim.new(0, r)
        p.PaddingTop = UDim.new(0, t)
        p.PaddingBottom = UDim.new(0, b)
        return p
    end

    local function textConstraint(o, minSize, maxSize)
        if not o:IsA("TextLabel") and not o:IsA("TextButton") and not o:IsA("TextBox") then
            return
        end

        local c = o:FindFirstChild("V8TextConstraint")
        if not c then
            c = Instance.new("UITextSizeConstraint")
            c.Name = "V8TextConstraint"
            c.Parent = o
        end
        c.MinTextSize = minSize
        c.MaxTextSize = maxSize
    end

    local function styleWindow(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = U.Bg
        win.BackgroundTransparency = 0
        ensureCorner(win, 15, "V8WindowCorner")
        ensureStroke(win, U.Gold, 0.74, 1, "V8WindowStroke")

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = U.Panel2
            bar.BackgroundTransparency = 0
            ensureCorner(bar, 13, "V8HeaderCorner")
            ensureStroke(bar, U.Border, 0.22, 1, "V8HeaderStroke")
            ensureGradient(bar, U.Panel3, U.Panel2, "V8HeaderGradient")
            ensurePadding(bar, 12, 10, 0, 0, "V8HeaderPadding")

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.Font = Enum.Font.GothamBold
                title.TextColor3 = U.Text
                title.TextSize = 15
                title.TextXAlignment = Enum.TextXAlignment.Left
                textConstraint(title, 13, 18)
            end

            -- Accent line gives the header a clean premium identity.
            local accent = bar:FindFirstChild("V8Accent")
            if not accent then
                accent = Instance.new("Frame")
                accent.Name = "V8Accent"
                accent.BorderSizePixel = 0
                accent.Parent = bar
            end
            accent.BackgroundColor3 = U.Gold
            accent.Position = UDim2.new(0, 14, 1, -2)
            accent.Size = UDim2.new(1, -28, 0, 2)
            accent.ZIndex = bar.ZIndex + 3
            ensureCorner(accent, 2, "V8AccentCorner")

            local dot = bar:FindFirstChild("V8StatusDot")
            if not dot then
                dot = Instance.new("Frame")
                dot.Name = "V8StatusDot"
                dot.Parent = bar
            end
            dot.Size = UDim2.fromOffset(7, 7)
            dot.Position = UDim2.new(0, 8, 0.5, -3)
            dot.BorderSizePixel = 0
            dot.BackgroundColor3 = U.Gold
            dot.ZIndex = bar.ZIndex + 3
            ensureCorner(dot, 7, "V8DotCorner")
        end

        local tabs = win:FindFirstChild("TabSelection", true)
        if tabs and tabs:IsA("GuiObject") then
            tabs.BackgroundColor3 = U.Panel
            tabs.BackgroundTransparency = 0
            ensureCorner(tabs, 10, "V8TabsCorner")
            ensureStroke(tabs, U.Border, 0.48, 1, "V8TabsStroke")
            ensurePadding(tabs, 5, 5, 5, 5, "V8TabsPadding")
        end

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                if o.Name ~= "GP_Close" and o.Name ~= "GP_Minimize" then
                    o.AutoButtonColor = false
                    o.BackgroundColor3 = U.Panel2
                    o.TextColor3 = U.Text
                    o.Font = Enum.Font.GothamMedium
                    o.TextSize = 13
                    ensureCorner(o, 8, "V8ButtonCorner")
                    ensureStroke(o, U.Border, 0.30, 1, "V8ButtonStroke")
                    textConstraint(o, 12, 16)

                    pcall(function()
                        bd:AddHoverEffect(o, U.Panel3, U.GoldLight)
                    end)
                end
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = U.Panel2
                o.TextColor3 = U.Text
                o.PlaceholderColor3 = U.Muted
                o.Font = Enum.Font.Gotham
                o.TextSize = 13
                ensureCorner(o, 8, "V8InputCorner")
                ensureStroke(o, U.Border, 0.25, 1, "V8InputStroke")
                ensurePadding(o, 9, 9, 0, 0, "V8InputPadding")
                textConstraint(o, 12, 16)
            elseif o:IsA("TextLabel") then
                o.Font = Enum.Font.Gotham
                o.TextColor3 = U.Text
                textConstraint(o, 11, 16)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = U.Gold
                o.ScrollBarImageTransparency = 0.45
                o.BackgroundTransparency = 1
            end
        end

        -- Responsive sizing: keep a usable margin on smaller screens.
        local camera = workspace.CurrentCamera
        if camera then
            local viewport = camera.ViewportSize
            if viewport.X < 700 then
                win.Size = UDim2.new(0.94, 0, 0.88, 0)
            elseif viewport.X < 1000 then
                win.Size = UDim2.new(0.78, 0, 0.84, 0)
            end
        end
    end

    for _, win in ipairs(bd:GetWindows()) do
        styleWindow(win)
    end

    bd.V8UltraStyle = {
        Theme = "Clean Gold Ultra",
        Responsive = true,
        HighContrast = true,
        Particles = false,
        AnimatedGlow = false
    }

    bd.StyleUltraWindow = styleWindow

    -- Reapply only at construction/resizing moments, not every frame.
    task.delay(0.2, function()
        for _, win in ipairs(bd:GetWindows()) do
            styleWindow(win)
        end
    end)

    if workspace.CurrentCamera then
        workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            for _, win in ipairs(bd:GetWindows()) do
                styleWindow(win)
            end
        end)
    end
end)




-- ============================================================
-- GOLD PREMIUM GITHUB-INSPIRED V9
-- Inspirado en patrones públicos de UI: jerarquía, superficies,
-- estados de controles, iconografía, padding y responsive.
-- No copia código propietario; implementa los conceptos aquí.
-- ============================================================

pcall(function()
    local TweenService = game:GetService("TweenService")
    local UserInputService = game:GetService("UserInputService")

    local C = {
        BG = Color3.fromRGB(7,8,11),
        Surface = Color3.fromRGB(14,15,19),
        Surface2 = Color3.fromRGB(20,21,26),
        Surface3 = Color3.fromRGB(27,28,34),
        Gold = Color3.fromRGB(218,184,92),
        GoldBright = Color3.fromRGB(239,211,128),
        Text = Color3.fromRGB(246,246,249),
        Muted = Color3.fromRGB(148,151,161),
        Border = Color3.fromRGB(52,53,62),
        Success = Color3.fromRGB(120,205,150)
    }

    local function corner(o, r, n)
        local x = o:FindFirstChild(n)
        if not x then
            x = Instance.new("UICorner")
            x.Name = n
            x.Parent = o
        end
        x.CornerRadius = UDim.new(0, r)
    end

    local function stroke(o, color, transparency, thickness, n)
        local x = o:FindFirstChild(n)
        if not x then
            x = Instance.new("UIStroke")
            x.Name = n
            x.Parent = o
        end
        x.Color = color
        x.Transparency = transparency
        x.Thickness = thickness
    end

    local function padding(o, l, r, t, b, n)
        local p = o:FindFirstChild(n)
        if not p then
            p = Instance.new("UIPadding")
            p.Name = n
            p.Parent = o
        end
        p.PaddingLeft = UDim.new(0,l)
        p.PaddingRight = UDim.new(0,r)
        p.PaddingTop = UDim.new(0,t)
        p.PaddingBottom = UDim.new(0,b)
    end

    local function gradient(o, a, b, rotation, n)
        local g = o:FindFirstChild(n)
        if not g then
            g = Instance.new("UIGradient")
            g.Name = n
            g.Parent = o
        end
        g.Color = ColorSequence.new(a,b)
        g.Rotation = rotation or 90
    end

    local function text(o, size, color, font)
        if not (o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox")) then
            return
        end
        o.Font = font or Enum.Font.Gotham
        o.TextSize = size
        o.TextColor3 = color or C.Text
        o.TextTruncate = Enum.TextTruncate.AtEnd
    end

    local function decorate(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = C.BG
        corner(win, 16, "V9WindowCorner")
        stroke(win, C.Gold, 0.76, 1, "V9WindowStroke")

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = C.Surface
            gradient(bar, C.Surface3, C.Surface, 90, "V9HeaderGradient")
            corner(bar, 13, "V9HeaderCorner")
            stroke(bar, C.Border, 0.18, 1, "V9HeaderStroke")
            padding(bar, 34, 90, 0, 0, "V9HeaderPadding")

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                text(title, 15, C.Text, Enum.Font.GothamBold)
                title.TextXAlignment = Enum.TextXAlignment.Left
            end

            -- Compact status badge.
            local badge = bar:FindFirstChild("V9Badge")
            if not badge then
                badge = Instance.new("Frame")
                badge.Name = "V9Badge"
                badge.Size = UDim2.fromOffset(58, 22)
                badge.AnchorPoint = Vector2.new(1, .5)
                badge.Position = UDim2.new(1, -46, .5, 0)
                badge.BorderSizePixel = 0
                badge.Parent = bar
                corner(badge, 11, "BadgeCorner")

                local badgeText = Instance.new("TextLabel")
                badgeText.Name = "Text"
                badgeText.Size = UDim2.fromScale(1,1)
                badgeText.BackgroundTransparency = 1
                badgeText.Text = "READY"
                badgeText.Parent = badge
                text(badgeText, 10, C.Success, Enum.Font.GothamBold)
            end
            badge.BackgroundColor3 = C.Surface3

            local dot = bar:FindFirstChild("V9Dot")
            if not dot then
                dot = Instance.new("Frame")
                dot.Name = "V9Dot"
                dot.Size = UDim2.fromOffset(7,7)
                dot.Position = UDim2.new(0,16,.5,-3)
                dot.BorderSizePixel = 0
                dot.BackgroundColor3 = C.Gold
                dot.Parent = bar
                corner(dot,7,"DotCorner")
            end

            local accent = bar:FindFirstChild("V9Accent")
            if not accent then
                accent = Instance.new("Frame")
                accent.Name = "V9Accent"
                accent.BorderSizePixel = 0
                accent.Parent = bar
            end
            accent.BackgroundColor3 = C.Gold
            accent.Position = UDim2.new(0,14,1,-2)
            accent.Size = UDim2.new(1,-28,0,2)
            corner(accent,2,"AccentCorner")
        end

        local tabs = win:FindFirstChild("TabSelection", true)
        if tabs and tabs:IsA("GuiObject") then
            tabs.BackgroundColor3 = C.Surface
            tabs.BackgroundTransparency = 0
            corner(tabs, 10, "V9TabsCorner")
            stroke(tabs, C.Border, .48, 1, "V9TabsStroke")
            padding(tabs, 5,5,5,5,"V9TabsPadding")
        end

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") and o.Name ~= "GP_Close" and o.Name ~= "GP_Minimize" then
                o.AutoButtonColor = false
                o.BackgroundColor3 = C.Surface2
                corner(o, 8, "V9ButtonCorner")
                stroke(o, C.Border, .28, 1, "V9ButtonStroke")
                text(o, 13, C.Text, Enum.Font.GothamMedium)

                pcall(function()
                    bd:AddHoverEffect(o, C.Surface3, C.GoldBright)
                end)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = C.Surface
                corner(o, 8, "V9InputCorner")
                stroke(o, C.Border, .22, 1, "V9InputStroke")
                padding(o, 9,9,0,0,"V9InputPadding")
                text(o, 13, C.Text, Enum.Font.Gotham)
            elseif o:IsA("TextLabel") then
                text(o, math.clamp(o.TextSize,11,15), C.Text, Enum.Font.Gotham)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = C.Gold
                o.ScrollBarImageTransparency = .45
                o.BackgroundTransparency = 1
            end
        end

        -- A restrained card hierarchy for common content frames.
        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("Frame") and o ~= bar and o ~= tabs then
                local n = o.Name:lower()
                if n:find("section") or n:find("folder") or n:find("container") then
                    o.BackgroundColor3 = C.Surface
                    corner(o, 9, "V9CardCorner")
                    stroke(o, C.Border, .65, 1, "V9CardStroke")
                end
            end
        end
    end

    for _, win in ipairs(bd:GetWindows()) do
        decorate(win)
    end

    bd.GitHubInspiredStyle = true
    bd.DecorateV9 = decorate

    -- Apply only when the GUI is created/changed, not every frame.
    task.delay(.25, function()
        for _, win in ipairs(bd:GetWindows()) do
            decorate(win)
        end
    end)
end)




-- ============================================================
-- GOLD PREMIUM GITHUB-INSPIRED V10 ULTRA
-- Visual system based on public Roblox UI/UX patterns:
-- design tokens, clear states, responsive layout, spacing,
-- hierarchy, cards, badges and accessible contrast.
-- ============================================================

pcall(function()
    local UIS = game:GetService("UserInputService")

    local T = {
        bg = Color3.fromRGB(7,8,11),
        surface = Color3.fromRGB(14,15,19),
        surface2 = Color3.fromRGB(20,21,26),
        surface3 = Color3.fromRGB(27,28,34),
        gold = Color3.fromRGB(218,184,92),
        gold2 = Color3.fromRGB(239,211,128),
        text = Color3.fromRGB(246,246,249),
        muted = Color3.fromRGB(148,151,161),
        border = Color3.fromRGB(52,53,62),
        success = Color3.fromRGB(118,205,148),
        danger = Color3.fromRGB(220,100,100)
    }

    local function ensure(className, parent, name)
        local x = parent:FindFirstChild(name)
        if not x then
            x = Instance.new(className)
            x.Name = name
            x.Parent = parent
        end
        return x
    end

    local function round(o, r, name)
        local c = ensure("UICorner", o, name)
        c.CornerRadius = UDim.new(0, r)
    end

    local function outline(o, color, transparency, thickness, name)
        local s = ensure("UIStroke", o, name)
        s.Color = color
        s.Transparency = transparency
        s.Thickness = thickness
        s.LineJoinMode = Enum.LineJoinMode.Round
    end

    local function pad(o, n, name)
        local p = ensure("UIPadding", o, name)
        p.PaddingLeft = UDim.new(0,n)
        p.PaddingRight = UDim.new(0,n)
        p.PaddingTop = UDim.new(0,n)
        p.PaddingBottom = UDim.new(0,n)
    end

    local function grad(o, a, b, name)
        local g = ensure("UIGradient", o, name)
        g.Color = ColorSequence.new(a,b)
        g.Rotation = 90
    end

    local function textStyle(o, size, color, font)
        if not (o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox")) then return end
        o.Font = font or Enum.Font.Gotham
        o.TextSize = size
        o.TextColor3 = color or T.text
        local c = ensure("UITextSizeConstraint", o, "V10TextConstraint")
        c.MinTextSize = math.max(10, size-2)
        c.MaxTextSize = size+3
    end

    local function styleWindow(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = T.bg
        round(win, 16, "V10WindowCorner")
        outline(win, T.gold, .78, 1, "V10WindowStroke")

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = T.surface
            grad(bar, T.surface3, T.surface, "V10HeaderGradient")
            round(bar, 13, "V10HeaderCorner")
            outline(bar, T.border, .18, 1, "V10HeaderStroke")

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                textStyle(title, 15, T.text, Enum.Font.GothamBold)
                title.TextXAlignment = Enum.TextXAlignment.Left
            end

            local dot = ensure("Frame", bar, "V10StatusDot")
            dot.Size = UDim2.fromOffset(7,7)
            dot.Position = UDim2.new(0,14,.5,-3)
            dot.BorderSizePixel = 0
            dot.BackgroundColor3 = T.success
            dot.ZIndex = bar.ZIndex + 4
            round(dot, 7, "DotCorner")

            local badge = ensure("Frame", bar, "V10ReadyBadge")
            badge.Size = UDim2.fromOffset(60,22)
            badge.AnchorPoint = Vector2.new(1,.5)
            badge.Position = UDim2.new(1,-42,.5,0)
            badge.BorderSizePixel = 0
            badge.BackgroundColor3 = T.surface3
            badge.ZIndex = bar.ZIndex + 2
            round(badge, 11, "BadgeCorner")
            outline(badge, T.border, .35, 1, "BadgeStroke")

            local bt = ensure("TextLabel", badge, "BadgeText")
            bt.Size = UDim2.fromScale(1,1)
            bt.BackgroundTransparency = 1
            bt.Text = "READY"
            textStyle(bt, 10, T.success, Enum.Font.GothamBold)

            local accent = ensure("Frame", bar, "V10Accent")
            accent.Position = UDim2.new(0,14,1,-2)
            accent.Size = UDim2.new(1,-28,0,2)
            accent.BorderSizePixel = 0
            accent.BackgroundColor3 = T.gold
            accent.ZIndex = bar.ZIndex + 5
            round(accent, 2, "AccentCorner")
        end

        local tabs = win:FindFirstChild("TabSelection", true)
        if tabs and tabs:IsA("GuiObject") then
            tabs.BackgroundColor3 = T.surface
            tabs.BackgroundTransparency = 0
            round(tabs, 10, "V10TabsCorner")
            outline(tabs, T.border, .5, 1, "V10TabsStroke")
            pad(tabs, 5, "V10TabsPadding")
        end

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") and o.Name ~= "GP_Close" and o.Name ~= "GP_Minimize" then
                o.AutoButtonColor = false
                o.BackgroundColor3 = T.surface2
                textStyle(o, 13, T.text, Enum.Font.GothamMedium)
                round(o, 8, "V10ButtonCorner")
                outline(o, T.border, .3, 1, "V10ButtonStroke")
                pcall(function()
                    bd:AddHoverEffect(o, T.surface3, T.gold2)
                end)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = T.surface
                textStyle(o, 13, T.text, Enum.Font.Gotham)
                o.PlaceholderColor3 = T.muted
                round(o, 8, "V10InputCorner")
                outline(o, T.border, .25, 1, "V10InputStroke")
                pad(o, 8, "V10InputPadding")
            elseif o:IsA("TextLabel") then
                textStyle(o, math.clamp(o.TextSize,11,15), T.text, Enum.Font.Gotham)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = T.gold
                o.ScrollBarImageTransparency = .45
                o.BackgroundTransparency = 1
            end
        end

        -- Make common section containers read as cards.
        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("Frame") and o ~= bar and o ~= tabs then
                local n = o.Name:lower()
                if n:find("section") or n:find("folder") or n:find("container") then
                    o.BackgroundColor3 = T.surface
                    round(o, 9, "V10CardCorner")
                    outline(o, T.border, .68, 1, "V10CardStroke")
                end
            end
        end

        -- Cross-platform sizing.
        local camera = workspace.CurrentCamera
        if camera then
            local x = camera.ViewportSize.X
            if x < 650 then
                win.Size = UDim2.new(.94,0,.86,0)
            elseif x < 950 then
                win.Size = UDim2.new(.82,0,.84,0)
            end
        end
    end

    for _, win in ipairs(bd:GetWindows()) do
        styleWindow(win)
    end

    bd.DesignTokens = T
    bd.StyleWindowV10 = styleWindow

    task.delay(.25, function()
        for _, win in ipairs(bd:GetWindows()) do
            styleWindow(win)
        end
    end)

    local camera = workspace.CurrentCamera
    if camera then
        camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            for _, win in ipairs(bd:GetWindows()) do
                styleWindow(win)
            end
        end)
    end
end)




-- ============================================================
-- GOLD PREMIUM GITHUB-INSPIRED V11 ULTRA
-- Extra visual layer based on public Roblox UI patterns:
-- design tokens, state feedback, responsive constraints,
-- consistent spacing, shadows, cards and reduced motion.
-- ============================================================

pcall(function()
    local TweenService = game:GetService("TweenService")

    local T11 = {
        bg = Color3.fromRGB(7,8,11),
        surface = Color3.fromRGB(14,15,19),
        surface2 = Color3.fromRGB(20,21,26),
        surface3 = Color3.fromRGB(27,28,34),
        gold = Color3.fromRGB(218,184,92),
        goldBright = Color3.fromRGB(239,211,128),
        text = Color3.fromRGB(246,246,249),
        muted = Color3.fromRGB(148,151,161),
        border = Color3.fromRGB(52,53,62),
        success = Color3.fromRGB(118,205,148),
        danger = Color3.fromRGB(220,100,100)
    }

    local function get(parent, className, name)
        local x = parent:FindFirstChild(name)
        if not x then
            x = Instance.new(className)
            x.Name = name
            x.Parent = parent
        end
        return x
    end

    local function corner(o, radius, name)
        local c = get(o, "UICorner", name)
        c.CornerRadius = UDim.new(0, radius)
    end

    local function outline(o, color, transparency, thickness, name)
        local s = get(o, "UIStroke", name)
        s.Color = color
        s.Transparency = transparency
        s.Thickness = thickness
        s.LineJoinMode = Enum.LineJoinMode.Round
    end

    local function setText(o, size, color, font)
        if not (o:IsA("TextLabel") or o:IsA("TextButton") or o:IsA("TextBox")) then
            return
        end
        o.Font = font or Enum.Font.Gotham
        o.TextSize = size
        o.TextColor3 = color or T11.text
        o.TextTruncate = Enum.TextTruncate.AtEnd
        local c = get(o, "UITextSizeConstraint", "V11TextConstraint")
        c.MinTextSize = math.max(10, size - 2)
        c.MaxTextSize = size + 3
    end

    local function styleButton(button)
        if not button:IsA("TextButton") then return end
        if button.Name == "GP_Close" or button.Name == "GP_Minimize" then return end

        button.AutoButtonColor = false
        button.BackgroundColor3 = T11.surface2
        setText(button, 13, T11.text, Enum.Font.GothamMedium)
        corner(button, 8, "V11ButtonCorner")
        outline(button, T11.border, .28, 1, "V11ButtonStroke")

        -- Small state feedback instead of permanent glow.
        pcall(function()
            bd:AddHoverEffect(button, T11.surface3, T11.goldBright)
        end)
    end

    local function styleInput(input)
        if not input:IsA("TextBox") then return end

        input.BackgroundColor3 = T11.surface
        input.PlaceholderColor3 = T11.muted
        setText(input, 13, T11.text, Enum.Font.Gotham)
        corner(input, 8, "V11InputCorner")
        outline(input, T11.border, .25, 1, "V11InputStroke")

        local padding = get(input, "UIPadding", "V11InputPadding")
        padding.PaddingLeft = UDim.new(0, 9)
        padding.PaddingRight = UDim.new(0, 9)
    end

    local function styleWindow(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = T11.bg
        corner(win, 16, "V11WindowCorner")
        outline(win, T11.gold, .78, 1, "V11WindowStroke")

        -- Static depth layer.
        local shadow = get(win, "ImageLabel", "V11Shadow")
        shadow.BackgroundTransparency = 1
        shadow.Image = "rbxassetid://6014261993"
        shadow.ImageTransparency = .78
        shadow.ScaleType = Enum.ScaleType.Slice
        shadow.SliceCenter = Rect.new(49,49,450,450)
        shadow.Size = UDim2.new(1, 26, 1, 26)
        shadow.Position = UDim2.fromOffset(-13,-13)
        shadow.ZIndex = math.max(0, win.ZIndex - 1)

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = T11.surface
            corner(bar, 13, "V11HeaderCorner")
            outline(bar, T11.border, .18, 1, "V11HeaderStroke")

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                setText(title, 15, T11.text, Enum.Font.GothamBold)
                title.TextXAlignment = Enum.TextXAlignment.Left
            end

            local accent = get(bar, "Frame", "V11Accent")
            accent.BorderSizePixel = 0
            accent.BackgroundColor3 = T11.gold
            accent.Position = UDim2.new(0,14,1,-2)
            accent.Size = UDim2.new(1,-28,0,2)
            corner(accent, 2, "AccentCorner")

            local status = get(bar, "Frame", "V11Status")
            status.Size = UDim2.fromOffset(7,7)
            status.Position = UDim2.new(0,14,.5,-3)
            status.BorderSizePixel = 0
            status.BackgroundColor3 = T11.success
            corner(status, 7, "StatusCorner")

            local badge = get(bar, "Frame", "V11Badge")
            badge.Size = UDim2.fromOffset(60,22)
            badge.AnchorPoint = Vector2.new(1,.5)
            badge.Position = UDim2.new(1,-42,.5,0)
            badge.BackgroundColor3 = T11.surface3
            badge.BorderSizePixel = 0
            corner(badge, 11, "BadgeCorner")
            outline(badge, T11.border, .35, 1, "BadgeStroke")

            local badgeText = get(badge, "TextLabel", "BadgeText")
            badgeText.Size = UDim2.fromScale(1,1)
            badgeText.BackgroundTransparency = 1
            badgeText.Text = "READY"
            setText(badgeText, 10, T11.success, Enum.Font.GothamBold)
        end

        local tabs = win:FindFirstChild("TabSelection", true)
        if tabs and tabs:IsA("GuiObject") then
            tabs.BackgroundColor3 = T11.surface
            tabs.BackgroundTransparency = 0
            corner(tabs, 10, "V11TabsCorner")
            outline(tabs, T11.border, .48, 1, "V11TabsStroke")
        end

        for _, obj in ipairs(win:GetDescendants()) do
            if obj:IsA("TextButton") then
                styleButton(obj)
            elseif obj:IsA("TextBox") then
                styleInput(obj)
            elseif obj:IsA("TextLabel") then
                setText(obj, math.clamp(obj.TextSize, 11, 15), T11.text, Enum.Font.Gotham)
            elseif obj:IsA("ScrollingFrame") then
                obj.ScrollBarThickness = 3
                obj.ScrollBarImageColor3 = T11.gold
                obj.ScrollBarImageTransparency = .45
                obj.BackgroundTransparency = 1
            end
        end

        -- Responsive root constraint.
        local sizeConstraint = get(win, "UISizeConstraint", "V11SizeConstraint")
        sizeConstraint.MinSize = Vector2.new(320, 360)
        sizeConstraint.MaxSize = Vector2.new(1100, 900)
    end

    for _, win in ipairs(bd:GetWindows()) do
        styleWindow(win)
    end

    bd.GitHubInspiredV11 = true
    bd.StyleWindowV11 = styleWindow

    task.delay(.25, function()
        for _, win in ipairs(bd:GetWindows()) do
            styleWindow(win)
        end
    end)
end)


-- Final integrity check: never return a broken library table.
if type(bd) ~= "table" or type(bd.AddWindow) ~= "function" or type(bd.GetWindows) ~= "function" then
    error("GOLD PREMIUM: biblioteca incompleta (AddWindow/GetWindows no disponibles)")
end

-- Final return: must be last so all visual layers V5-V11 are applied.
return bd

end)()
if type(library) ~= "table" or type(library.AddWindow) ~= "function" then
    error("Trayectoo: la biblioteca GOLD PREMIUM no se inicializó correctamente")
end
local window = library:AddWindow(title, {
    main_color = Color3.fromRGB(0, 0, 0),
    min_size = Vector2.new(760, 760),
    can_resize = true,
})
local function Crearpets()
local pets = window:AddTab("pets")
local Foldersexo = pets:AddFolder("crystals")
-- Crystal data structure with exact names from your original code
local crystalData = {
    ["Blue Crystal"] = {
        {name = "Blue Birdie", rarity = "Basic"},
        {name = "Orange Hedgehog", rarity = "Basic"},
        {name = "Blue Aura", rarity = "Basic"},
        {name = "Red Kitty", rarity = "Basic"},
        {name = "Dark Vampy", rarity = "Advanced"},
        {name = "Blue Bunny", rarity = "Basic"},
        {name = "Red Aura", rarity = "Basic"},
        {name = "Blue Aura", rarity = "Basic"},
        {name = "Green Aura", rarity = "Basic"},
        {name = "Purple Aura", rarity = "Basic"},
        {name = "Red Aura", rarity = "Basic"},
        {name = "Yellow Aura", rarity = "Basic"}
    },
    ["Green Crystal"] = {
        {name = "Silver Dog", rarity = "Basic"},
        {name = "Green Aura", rarity = "Advanced"},
        {name = "Dark Golem", rarity = "Advanced"},
        {name = "Green Butterfly", rarity = "Advanced"},
        {name = "Crimson Falcon", rarity = "Rare"},
        {name = "Red Aura", rarity = "Basic"},
        {name = "Blue Aura", rarity = "Basic"},
        {name = "Green Aura", rarity = "Basic"},
        {name = "Purple Aura", rarity = "Basic"},
        {name = "Red Aura", rarity = "Basic"},
        {name = "Yellow Aura", rarity = "Basic"}
    },
    ["Frost Crystal"] = {
        {name = "Yellow Butterfly", rarity = "Advanced"},
        {name = "Purple Dragon", rarity = "Rare"},
        {name = "Blue Pheonix", rarity = "Epic"},
        {name = "Orange Pegasus", rarity = "Rare"},
        {name = "Lightning", rarity = "Rare"},
        {name = "Electro", rarity = "Advanced"}
    },
    ["Mythical Crystal"] = {
        {name = "Purple Falcon", rarity = "Rare"},
        {name = "Red Dragon", rarity = "Rare"},
        {name = "Blue Firecaster", rarity = "Epic"},
        {name = "Golden Pheonix", rarity = "Epic"},
        {name = "Power Lightning", rarity = "Rare"},
        {name = "Dark Lightning", rarity = "Epic"}
    },
    ["Inferno Crystal"] = {
        {name = "Red Firecaster", rarity = "Epic"},
        {name = "Infernal Dragon", rarity = "Unique"},
        {name = "White Pegasus", rarity = "Rare"},
        {name = "Golden Pheonix", rarity = "Epic"},
        {name = "Inferno", rarity = "Epic"},
        {name = "Dark Storm", rarity = "Unique"}
    },
    ["Legends Crystal"] = {
        {name = "Ultra Birdie", rarity = "Unique"},
        {name = "Magic Butterfly", rarity = "Unique"},
        {name = "Green Firecaster", rarity = "Epic"},
        {name = "White Pheonix", rarity = "Epic"},
        {name = "Supernova", rarity = "Epic"},
        {name = "Purple Nova", rarity = "Unique"}
    },
    ["Muscle Elite Crystal"] = {
        {name = "Frostwave Legends Penguin", rarity = "Rare"},
        {name = "Phantom Genesis Dragon", rarity = "Rare"},
        {name = "Dark Legends Manticore", rarity = "Epic"},
        {name = "Ultimate Supernova Pegasus", rarity = "Epic"},
        {name = "Aether Spirit Bunny", rarity = "Unique"},
        {name = "Cybernetic Showdown Dragon", rarity = "Unique"}
    },
    ["Galaxy Oracle Crystal"] = {
        {name = "Eternal Strike Leviathan", rarity = "Rare"},
        {name = "Lightning Strike Phantom", rarity = "Epic"},
        {name = "Darkstar Hunter", rarity = "Unique"},
        {name = "Muscle King", rarity = "Unique"},
        {name = "Azure Tundra", rarity = "Epic"},
        {name = "Ultra Inferno", rarity = "Rare"}
    },
    ["Jungle Crystal"] = {
        {name = "Entropic Blast", rarity = "Unique"},
        {name = "Muscle Sensei", rarity = "Unique"},
        {name = "Grand Supernova", rarity = "Epic"},
        {name = "Neon Guardian", rarity = "Unique"},
        {name = "Eternal Megastrike", rarity = "Unique"},
        {name = "Golden Viking", rarity = "Epic"},
        {name = "Astral Electro", rarity = "Epic"},
        {name = "Dark Electro", rarity = "Epic"},
        {name = "Enchanted Mirage", rarity = "Epic"},
        {name = "Ultra Mirage", rarity = "Unique"},
        {name = "Unstable Mirage", rarity = "Unique"}
    }
}

-- Function to collect all unique pets and auras
local function getAllPetsAndAuras()
    local allPets = {}
    local allAuras = {}
    
    for crystalName, pets in pairs(crystalData) do
        for _, pet in ipairs(pets) do
            if string.find(pet.name, "Aura") then
                if not allAuras[pet.name] then
                    allAuras[pet.name] = {name = pet.name, rarity = pet.rarity, crystal = crystalName}
                end
            else
                if not allPets[pet.name] then
                    allPets[pet.name] = {name = pet.name, rarity = pet.rarity, crystal = crystalName}
                end
            end
        end
    end
    
    return allPets, allAuras
end

-- Function to find which crystal contains a specific pet/aura
local function findCrystalForItem(itemName)
    for crystalName, pets in pairs(crystalData) do
        for _, pet in ipairs(pets) do
            if pet.name == itemName then
                return crystalName
            end
        end
    end
    return nil
end

-- Variables to track current selections
local selectedPet = ""
local selectedAura = ""

-- Get all pets and auras
local allPets, allAuras = getAllPetsAndAuras()

Foldersexo:AddButton("--- Buy pets and auras ---", function() end)

-- Pet dropdown
local petDropdown = Foldersexo:AddDropdown("Select pet", function(text)
    selectedPet = text
    local crystal = findCrystalForItem(text)
    print("Pet selected: " .. text .. " (Found in: " .. (crystal or "Unknown") .. ")")
end)

-- Add all pets manually (sorted by rarity)
-- Basic Pets
petDropdown:Add("Blue Birdie (Basic)")
petDropdown:Add("Orange Hedgehog (Basic)")
petDropdown:Add("Red Kitty (Basic)")
petDropdown:Add("Blue Bunny (Basic)")
petDropdown:Add("Silver Dog (Basic)")

-- Advanced Pets
petDropdown:Add("Dark Vampy (Advanced)")
petDropdown:Add("Dark Golem (Advanced)")
petDropdown:Add("Green Butterfly (Advanced)")
petDropdown:Add("Yellow Butterfly (Advanced)")

-- Rare Pets
petDropdown:Add("Crimson Falcon (Rare)")
petDropdown:Add("Purple Dragon (Rare)")
petDropdown:Add("Orange Pegasus (Rare)")
petDropdown:Add("Purple Falcon (Rare)")
petDropdown:Add("Red Dragon (Rare)")
petDropdown:Add("White Pegasus (Rare)")
petDropdown:Add("Frostwave Legends Penguin (Rare)")
petDropdown:Add("Phantom Genesis Dragon (Rare)")
petDropdown:Add("Eternal Strike Leviathan (Rare)")

-- Epic Pets
petDropdown:Add("Blue Pheonix (Epic)")
petDropdown:Add("Blue Firecaster (Epic)")
petDropdown:Add("Golden Pheonix (Epic)")
petDropdown:Add("Red Firecaster (Epic)")
petDropdown:Add("Green Firecaster (Epic)")
petDropdown:Add("White Pheonix (Epic)")
petDropdown:Add("Dark Legends Manticore (Epic)")
petDropdown:Add("Ultimate Supernova Pegasus (Epic)")
petDropdown:Add("Lightning Strike Phantom (Epic)")
petDropdown:Add("Golden Viking (Epic)")

-- Unique Pets
petDropdown:Add("Infernal Dragon (Unique)")
petDropdown:Add("Ultra Birdie (Unique)")
petDropdown:Add("Magic Butterfly (Unique)")
petDropdown:Add("Aether Spirit Bunny (Unique)")
petDropdown:Add("Cybernetic Showdown Dragon (Unique)")
petDropdown:Add("Darkstar Hunter (Unique)")
petDropdown:Add("Muscle Sensei (Unique)")
petDropdown:Add("Neon Guardian (Unique)")

-- Aura dropdown
local auraDropdown = Foldersexo:AddDropdown("Select Aura", function(text)
    selectedAura = text
    local crystal = findCrystalForItem(text)
    print("Aura selected: " .. text .. " (Found in: " .. (crystal or "Unknown") .. ")")
end)

-- Add all auras manually (sorted by rarity)
-- Basic Auras
auraDropdown:Add("Blue Aura (Basic)")
auraDropdown:Add("Green Aura (Basic)")
auraDropdown:Add("Purple Aura (Basic)")
auraDropdown:Add("Red Aura (Basic)")
auraDropdown:Add("Yellow Aura (Basic)")
auraDropdown:Add("Ultra Inferno  (Rare)")
auraDropdown:Add("Azure Tundra (Epic)")
auraDropdown:Add("Grand Supernova (Epic)")
auraDropdown:Add("Muscle King (Unique)")
auraDropdown:Add("Entropic Blast (Unique)")
auraDropdown:Add("Eternal Megastrike (Unique)")

Foldersexo:AddButton("--- System to buys---", function() end)

-- Auto buy pet toggle
Foldersexo:AddSwitch("Auto Buy Pet", function(bool)
    _G.AutoBuyPet = bool
    
    if bool then
        if selectedPet == "" then
            print("Please select a pet first!")
            return
        end
        
        -- Extract pet name from dropdown selection (remove rarity part)
        local petName = selectedPet:match("^(.-)%s*%(")
        if not petName then
            petName = selectedPet
        end
        
        local crystal = findCrystalForItem(petName)
        if not crystal then
            print("Could not find crystal for pet: " .. petName)
            return
        end
        
        print("Auto buy pet started for: " .. petName .. " from " .. crystal)
        spawn(function()
            while _G.AutoBuyPet and selectedPet ~= "" do
                local petToBuy = ReplicatedStorage.cPetShopFolder:FindFirstChild(petName)
                if petToBuy then
                    ReplicatedStorage.cPetShopRemote:InvokeServer(petToBuy)
                    print("Bought pet: " .. petName)
                else
                    print("Pet not found: " .. petName)
                end
                task.wait(0.1)
            end
        end)
    else
        print("Auto buy pet stopped")
    end
end)

-- Auto buy aura toggle
Foldersexo:AddSwitch("Auto buy Aura", function(bool)
    _G.AutoBuyAura = bool
    
    if bool then
        if selectedAura == "" then
            print("Please select an aura first!")
            return
        end
        
        -- Extract aura name from dropdown selection (remove rarity part)
        local auraName = selectedAura:match("^(.-)%s*%(")
        if not auraName then
            auraName = selectedAura
        end
        
        local crystal = findCrystalForItem(auraName)
        if not crystal then
            print("Could not find crystal for aura: " .. auraName)
            return
        end
        
        print("Auto buy aura started for: " .. auraName .. " from " .. crystal)
        spawn(function()
            while _G.AutoBuyAura and selectedAura ~= "" do
                local auraToBuy = ReplicatedStorage.cPetShopFolder:FindFirstChild(auraName)
                if auraToBuy then
                    ReplicatedStorage.cPetShopRemote:InvokeServer(auraToBuy)
                    print("Bought aura: " .. auraName)
                else
                    print("Aura not found: " .. auraName)
                end
                task.wait(0.1)
            end
        end)
    else
        print("Auto buy aura stopped")
    end
end)

pets:Show()

Foldersexo:AddLabel("=== buy ultimates ===")

-- Ultimate options
local ultimateOptions = {
    "+1 Daily Spin",
    "+1 Pet Slot", 
	"+10 Item Capacity",
    "+5% Rep Speed",
    "Demon Damage",
    "Galaxy Gains",
    "Golden Rebirth",
    "Jungle Swift",
    "Muscle Mind",
    "x2 Chest Rewards",
    "x2 Quest Rewards"
}

-- Variable to track selected ultimate
local selectedUltimate = ""

-- Ultimate dropdown
local ultimateDropdown = Foldersexo:AddDropdown("Select ultimate", function(text)
    selectedUltimate = text
    print("Ultimate selected: " .. text)
end)

-- Add all ultimate options to dropdown
for _, ultimate in ipairs(ultimateOptions) do
    ultimateDropdown:Add(ultimate)
end

-- Auto upgrade ultimate toggle
Foldersexo:AddSwitch("Auto Buy Ultimates", function(bool)
    _G.AutoUpgradeUltimate = bool
    
    if bool then
        if selectedUltimate == "" then
            print("Please select an ultimate first!")
            return
        end
			print("Auto upgrade ultimate started for: " .. selectedUltimate)
        spawn(function()
            while _G.AutoUpgradeUltimate and selectedUltimate ~= "" do
                ReplicatedStorage.rEvents.ultimatesRemote:InvokeServer(
                    "upgradeUltimate",
                    selectedUltimate
                )
                print("Upgraded ultimate: " .. selectedUltimate)
                task.wait(1)
            end
        end)
    else
        print("Auto comprar ultimates")
    end
end)
local Pets = {
    "Blue Birdie",
    "Orange Hedgehog",
    "Red Kitty",
    "Blue Bunny",
    "Silver Dog",
    "Dark Vampy",
    "Dark Golem",
    "Green Butterfly",
    "Yellow Butterfly",
    "Crimson Falcon",
    "Purple Dragon",
    "Orange Pegasus",
    "Purple Falcon",
    "Red Dragon",
    "White Pegasus",
    "Frostwave Legends Penguin",
    "Phantom Genesis Dragon",
    "Eternal Strike Leviathan",
    "Blue Pheonix",
    "Blue Firecaster",
    "Golden Pheonix",
    "Red Firecaster",
    "Green Firecaster",
    "White Pheonix",
    "Dark Legends Manticore",
    "Ultimate Supernova Pegasus",
    "Lightning Strike Phantom",
    "Golden Viking",
    "Infernal Dragon",
    "Ultra Birdie",
    "Magic Butterfly",
    "Aether Spirit Bunny",
    "Cybernetic Showdown Dragon",
    "Darkstar Hunter",
    "Muscle Sensei",
    "Neon Guardian"
}

local evolveRemote = ReplicatedStorage:WaitForChild("rEvents"):WaitForChild("petEvolveEvent")

local function evolvePets()
	for _, petName in ipairs(Pets) do
		local args = {"evolvePet", petName}
		evolveRemote:FireServer(unpack(args))
		warn("Intentando evolucionar:", petName)
	end
end

pets:AddSwitch("Auto Evolve Pets", function(state)
	_G.AutoEvolvePets = state
	if state then
		print("Auto evolve ON")
		task.spawn(function()
			while _G.AutoEvolvePets do
				evolvePets()
				task.wait(0.1)
			end
		end)
	else
		print("Auto evolve OFF")
	end
end)
local FolderTrade = pets:AddFolder("trade")

local petList = {
	["Blue Birdie"] = "Basic",
	["Orange Hedgehog"] = "Basic",
	["Red Kitty"] = "Basic",
	["Blue Bunny"] = "Basic",
	["Silver Dog"] = "Basic",
	["Dark Vampy"] = "Advanced",
	["Dark Golem"] = "Advanced",
	["Green Butterfly"] = "Advanced",
	["Yellow Butterfly"] = "Advanced",
	["Crimson Falcon"] = "Rare",
	["Purple Dragon"] = "Rare",
	["Orange Pegasus"] = "Rare",
	["Purple Falcon"] = "Rare",
	["Red Dragon"] = "Rare",
	["White Pegasus"] = "Rare",
	["Frostwave Legends Penguin"] = "Rare",
	["Phantom Genesis Dragon"] = "Rare",
	["Eternal Strike Leviathan"] = "Rare",
	["Blue Pheonix"] = "Epic",
	["Blue Firecaster"] = "Epic",
	["Golden Pheonix"] = "Epic",
	["Red Firecaster"] = "Epic",
	["Green Firecaster"] = "Epic",
	["White Pheonix"] = "Epic",
	["Dark Legends Manticore"] = "Epic",
	["Ultimate Supernova Pegasus"] = "Epic",
	["Lightning Strike Phantom"] = "Epic",
	["Golden Viking"] = "Epic",
	["Infernal Dragon"] = "Unique",
	["Ultra Birdie"] = "Unique",
	["Magic Butterfly"] = "Unique",
	["Aether Spirit Bunny"] = "Unique",
	["Cybernetic Showdown Dragon"] = "Unique",
	["Darkstar Hunter"] = "Unique",
	["Muscle Sensei"] = "Unique",
	["Neon Guardian"] = "Unique"
}

local selectedPlayer = nil
local selectedPet = nil
local selectedRarity = nil
local autoTrading = false
local tradeAll = false

local playerDropdown = FolderTrade:AddDropdown("Choose Player", function(value)
	selectedPlayer = value
end)

for _, plr in pairs(Players:GetPlayers()) do
	if plr ~= player then
		playerDropdown:Add(plr.Name)
	end
end

Players.PlayerAdded:Connect(function(plr)
	playerDropdown:Add(plr.Name)
end)
Players.PlayerRemoving:Connect(function(plr)
	playerDropdown:Remove(plr.Name)
end)

local petDropdown = FolderTrade:AddDropdown("Choose Pet", function(value)
	selectedPet = value
	selectedRarity = petList[value]
end)

for name, _ in pairs(petList) do
	petDropdown:Add(name)
end

local function getSixPets(petName, rarity)
	local folder = player:WaitForChild("petsFolder"):FindFirstChild(rarity)
	if not folder then return {} end
	local found = {}
	for _, pet in ipairs(folder:GetChildren()) do
		if pet.Name == petName then
			table.insert(found, pet)
			if #found >= 9 then break end
		end
	end
	return found
end

local function doTrade(target)
	if not target or not selectedPet or not selectedRarity then return end
	local args1 = {"sendTradeRequest", target}
	ReplicatedStorage.rEvents.tradingEvent:FireServer(unpack(args1))
	task.wait(1)
	local petsToOffer = getSixPets(selectedPet, selectedRarity)
	for _, pet in ipairs(petsToOffer) do
		local args2 = {"offerItem", pet}
		ReplicatedStorage.rEvents.tradingEvent:FireServer(unpack(args2))
		task.wait(0.1)
	end
	local args3 = {"acceptTrade"}
	ReplicatedStorage.rEvents.tradingEvent:FireServer(unpack(args3))
end

FolderTrade:AddSwitch("Start Auto Trade", function(state)
	autoTrading = state
	if state and selectedPlayer and selectedPet then
		task.spawn(function()
			doTrade(Players:FindFirstChild(selectedPlayer))
		end)
	end
end)

FolderTrade:AddSwitch("Trade All Players", function(state)
	tradeAll = state
	if state and selectedPet then
		task.spawn(function()
			while tradeAll do
				for _, plr in pairs(Players:GetPlayers()) do
					if plr ~= player then
						doTrade(plr)
						task.wait(0.1)
					end
				end
				task.wait(0.1)
			end
		end)
	end
end)

Players.PlayerAdded:Connect(function(plr)
	if tradeAll and selectedPet then
		task.wait(0.1)
		doTrade(plr)
	end
end)
end
local FarmingTab
local Folderfarming
local Folder_rebirth

local function CrearRock()
local farmTab = window:AddTab("Rock")
local Folderanal = farmTab:AddFolder("FARM-ROCK-V1")
Folderanal:AddLabel("Rock Farming")

getgenv().autoFarm = false

-- 🔥 TOOL + REMOTE MEJORADO
local function gettool()
        local char = player.Character
    local bp = player.Backpack

    local tool = char:FindFirstChildOfClass("Tool") or bp:FindFirstChildOfClass("Tool")

    if tool then
        tool.Parent = char

        local attackTime = tool:FindFirstChild("attackTime")
        if attackTime then
            attackTime.Value = 0
        end
    end

    local remote = player:FindFirstChild("muscleEvent")
    if remote then
        remote:FireServer("punch", "rightHand")
        remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		remote:FireServer("punch", "rightHand")
		
	end
end

-- ⚡ FUNCIÓN BASE DE FARM (MEJORADA)
local function farmRock(targetDurability)
    spawn(function()
        while getgenv().autoFarm do
                        local char = player.Character

            if char and char:FindFirstChild("RightHand") and char:FindFirstChild("LeftHand") then
                local right = char.RightHand
                local left = char.LeftHand

                for _, v in pairs(workspace.machinesFolder:GetDescendants()) do
                    if v.Name == "neededDurability" and v.Value == targetDurability then
                        local rock = v.Parent:FindFirstChild("Rock")

                        if rock then
                            -- 💀 MULTI TOUCH (RANGE BOOST)
                            for i = 90000, 100000 do
								firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
										firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
										firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
								
								
								
                            end
                            -- 🔥 punch real
                            gettool()
                        end
                    end
                end
            end

           task.wait(0)  -- ⚡ velocidad óptima
        end
    end)
end

-- 🔘 SWITCHES (todos arreglados)
Folderanal:AddSwitch("Tiny Island Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(0) end
end)

Folderanal:AddSwitch("Starter Island Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(100) end
end)

Folderanal:AddSwitch("Legend Beach Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(5000) end
end)

Folderanal:AddSwitch("Frost Gym Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(150000) end
end)

Folderanal:AddSwitch("Mythical Gym Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(400000) end
end)

Folderanal:AddSwitch("Eternal Gym Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(750000) end
end)

Folderanal:AddSwitch("Legend Gym Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(1000000) end
end)

Folderanal:AddSwitch("Muscle King Gym Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(5000000) end
end)

Folderanal:AddSwitch("Ancient Jungle Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(10000000) end
end) 
local urls = {
    "https://raw.githubusercontent.com/f58075956-gif/Antiafk/refs/heads/main/Anti%20afk.lua",
}

-- ⚡ Botón que ejecuta todos los scripts remotos
farmTab:AddButton("anti afk", function()
    for _, url in ipairs(urls) do
        spawn(function()
            local success, response = pcall(function()
                return game:HttpGet(url)
            end)
            if success and response then
                local loadSuccess, err = pcall(function()
                    local compiler = loadstring or load
if type(compiler) ~= "function" then
    error("[Trayectoo] loadstring/load no está disponible")
end
local chunk, compileErr = compiler(response)
if type(chunk) ~= "function" then
    error("[Trayectoo] Error de sintaxis en script remoto: " .. tostring(compileErr))
end
chunk()
                end)
                if not loadSuccess then
                    warn("[Pegar Muerto] Error ejecutando raw:", url, err)
                end
            else
                warn("[Pegar Muerto] No se pudo cargar:", url)
            end
        end)
    end
end)
-- 📂 ROCK V2
local FolderROCK2 = farmTab:AddFolder("ROCK-V2")

getgenv().autoFarm = false
getgenv().autoPunch = false

-- 📍 TP A LA ROCA
local function tpToRock(rock)
        local char = player.Character

    if char and char:FindFirstChild("HumanoidRootPart") then
        char.HumanoidRootPart.CFrame = rock.CFrame + Vector3.new(0,3,0)
    end
end

-- 👊 AUTO PUNCH
spawn(function()
    while task.wait(0) do
        if getgenv().autoPunch then
            local remote = player:FindFirstChild("muscleEvent")

            if remote then
                remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
					remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
            end
        end
    end
end)

-- ⚡ FARM ROCK
local function farmRock(targetDurability)
    spawn(function()

        -- 🔥 activa auto punch automáticamente
        getgenv().autoPunch = true

        while getgenv().autoFarm do
                        local char = player.Character

            if char and char:FindFirstChild("RightHand") and char:FindFirstChild("LeftHand") then
                local right = char.RightHand
                local left = char.LeftHand

                for _, v in pairs(workspace.machinesFolder:GetDescendants()) do
                    if v.Name == "neededDurability" and v.Value == targetDurability then
                        local rock = v.Parent:FindFirstChild("Rock")

                        if rock then
                            -- 📍 TP
                            tpToRock(rock)

                            -- 💥 TOUCH
                            for i = 1, 300 do
                                firetouchinterest(rock, right, 0)
                                firetouchinterest(rock, right, 1)

                                firetouchinterest(rock, left, 0)
                                firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
                                firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
                                firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
                                firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
                                firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
                                firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
                                firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
                                firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 0)
									firetouchinterest(rock, left, 1)
								firetouchinterest(rock, left, 1)
									firetouchinterest(rock, left, 0)
								firetouchinterest(rock, left, 1)
                            end
                        end
                    end
                end
            end

            task.wait(0)
        end

        -- ❌ desactiva auto punch al apagar
        getgenv().autoPunch = false
    end)
end

-- 🪨 ROCKS
FolderROCK2:AddSwitch("Tiny Island Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(0) end
end)

FolderROCK2:AddSwitch("Starter Island Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(100) end
end)

FolderROCK2:AddSwitch("Legend Beach Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(5000) end
end)

FolderROCK2:AddSwitch("Frost Gym Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(150000) end
end)

FolderROCK2:AddSwitch("Mythical Gym Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(400000) end
end)

FolderROCK2:AddSwitch("Eternal Gym Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(750000) end
end)

FolderROCK2:AddSwitch("Legend Gym Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(1000000) end
end)

FolderROCK2:AddSwitch("Muscle King Gym Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(5000000) end
end)

FolderROCK2:AddSwitch("Ancient Jungle Rock", function(bool)
    getgenv().autoFarm = bool
    if bool then farmRock(10000000) end
end)
local FolderROCK3 = farmTab:AddFolder("ROCK-V3")

getgenv().autoFarmV3 = false
getgenv().autoPunchV3 = false

-- 🪨 TRAER ROCA
local function bringRockV3(rock)
    local char = player.Character

    if char and char:FindFirstChild("HumanoidRootPart") then
        rock.CFrame = char.HumanoidRootPart.CFrame * CFrame.new(0,0,-3)
    end
end

-- 👊 AUTO PUNCH
spawn(function()
    while task.wait(0) do
        if getgenv().autoPunchV3 then
            local remote = player:FindFirstChild("muscleEvent")

            if remote then
                remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				remote:FireServer("punch","rightHand")
                remote:FireServer("punch","leftHand")
				
					
            end
        end
    end
end)

-- ⚡ FARM
local function farmRockV3(targetDurability)
    spawn(function()

        getgenv().autoPunchV3 = true

        while getgenv().autoFarmV3 do
                        local char = player.Character

            if char and char:FindFirstChild("RightHand") and char:FindFirstChild("LeftHand") then
                local right = char.RightHand
                local left = char.LeftHand

                for _,v in pairs(workspace.machinesFolder:GetDescendants()) do
                    if v.Name == "neededDurability" and v.Value == targetDurability then
                        local rock = v.Parent:FindFirstChild("Rock")

                        if rock then
                            -- 🪨 TRAER ROCA
                            bringRockV3(rock)

                            -- 💥 TOUCH SPAM
                            for i = 1,400 do
                                firetouchinterest(rock, right, 0)
                                firetouchinterest(rock, right, 1)
									firetouchinterest(rock, right, 0)
                                firetouchinterest(rock, right, 1)
									firetouchinterest(rock, right, 0)
                                firetouchinterest(rock, right, 1)
									firetouchinterest(rock, right, 0)
                                firetouchinterest(rock, right, 1)
									

                                
                            end
                        end
                    end
                end
            end

            task.wait(0)
        end

        getgenv().autoPunchV3 = false
    end)
end

-- 🪨 ROCKS
FolderROCK3:AddSwitch("Tiny Island Rock", function(bool)
    getgenv().autoFarmV3 = bool
    if bool then farmRockV3(0) end
end)

FolderROCK3:AddSwitch("Starter Island Rock", function(bool)
    getgenv().autoFarmV3 = bool
    if bool then farmRockV3(100) end
end)

FolderROCK3:AddSwitch("Legend Beach Rock", function(bool)
    getgenv().autoFarmV3 = bool
    if bool then farmRockV3(5000) end
end)

FolderROCK3:AddSwitch("Frost Gym Rock", function(bool)
    getgenv().autoFarmV3 = bool
    if bool then farmRockV3(150000) end
end)

FolderROCK3:AddSwitch("Mythical Gym Rock", function(bool)
    getgenv().autoFarmV3 = bool
    if bool then farmRockV3(400000) end
end)

FolderROCK3:AddSwitch("Eternal Gym Rock", function(bool)
    getgenv().autoFarmV3 = bool
    if bool then farmRockV3(750000) end
end)

FolderROCK3:AddSwitch("Legend Gym Rock", function(bool)
    getgenv().autoFarmV3 = bool
    if bool then farmRockV3(1000000) end
end)

FolderROCK3:AddSwitch("Muscle King Gym Rock", function(bool)
    getgenv().autoFarmV3 = bool
    if bool then farmRockV3(5000000) end
end)

FolderROCK3:AddSwitch("Ancient Jungle Rock", function(bool)
    getgenv().autoFarmV3 = bool
    if bool then farmRockV3(10000000) end
end)

local Calculadora = window:AddTab("calculator", Color3.fromRGB(200, 100, 100))

local baseStrength = 0
local resultadoLabelsDamage = {}

local FolderDamage = Calculadora:AddFolder("Pack Damage Calculator")

FolderDamage:AddTextBox("Base Strongth (ej: 1.27Qa, T, B)", function(text)
    local unidades = { ["T"] = 1e12, ["Q"] = 1e15, ["B"] = 1e9 }
    text = text:upper()
    for u, m in pairs(unidades) do
        if text:find(u) then
            local num = tonumber(text:match("(%d+%.?%d*)"))
            if num then
                baseStrength = num * m
                return
            end
        end
    end
    baseStrength = tonumber(text:match("(%d+%.?%d*)")) or 0
end)

local mensajeLabelDamage = FolderDamage:AddLabel("")

for i = 1, 8 do
    resultadoLabelsDamage[i] = FolderDamage:AddLabel(string.format("%d pack(s): -", i))
end

FolderDamage:AddButton("Calculate Damage", function()
    if baseStrength <= 0 then
        mensajeLabelDamage.Text = "Enter a valid value."
        for i = 1, 8 do
            resultadoLabelsDamage[i].Text = string.format("%d pack(s): -", i)
        end
        return
    end

    mensajeLabelDamage.Text = ""

    local danoAjustado = baseStrength * 0.10
    local incremento = 0.335

    for pack = 1, 8 do
        local mult = 1 + (pack * incremento)
        local valor = danoAjustado * mult

        local disp
        if valor >= 1e15 then
            disp = string.format("%.3f Qa", valor / 1e15)
        elseif valor >= 1e12 then
            disp = string.format("%.2f T", valor / 1e12)
        elseif valor >= 1e9 then
            disp = string.format("%.2f B", valor / 1e9)
        else
            disp = tostring(math.floor(valor))
        end

        resultadoLabelsDamage[pack].Text = string.format("%d pack(s): %s", pack, disp)
    end
end)

local baseDurabilidad = 0
local resultadoLabelsDurabilidad = {}

local FolderDurabilidad = Calculadora:AddFolder("Pack Durability Calculator")

FolderDurabilidad:AddTextBox("Base durability (ej: 1.27Qa, T, B)", function(text)
    local unidades = { ["T"] = 1e12, ["Q"] = 1e15, ["B"] = 1e9 }
    text = text:upper()
    for u, m in pairs(unidades) do
        if text:find(u) then
            local num = tonumber(text:match("(%d+%.?%d*)"))
            if num then
                baseDurabilidad = num * m
                return
            end
        end
    end
    baseDurabilidad = tonumber(text:match("(%d+%.?%d*)")) or 0
end)

local mensajeLabelDurabilidad = FolderDurabilidad:AddLabel("")

for i = 1, 8 do
    resultadoLabelsDurabilidad[i] = FolderDurabilidad:AddLabel(string.format("%d pack(s): -", i))
end

FolderDurabilidad:AddButton("Calculate Durability", function()
    if baseDurabilidad <= 0 then
        mensajeLabelDurabilidad.Text = "Enter a valid value."
        for i = 1, 8 do
            resultadoLabelsDurabilidad[i].Text = string.format("%d pack(s): -", i)
        end
        return
    end

    mensajeLabelDurabilidad.Text = ""

    local incremento = 0.335
    local adicional = 1.5

    for pack = 1, 8 do
        local mult = 1 + (pack * incremento)
        local valor = baseDurabilidad * mult * adicional

        local disp
        if valor >= 1e15 then
            disp = string.format("%.3f Qa", valor / 1e15)
        elseif valor >= 1e12 then
            disp = string.format("%.2f T", valor / 1e12)
        elseif valor >= 1e9 then
            disp = string.format("%.2f B", valor / 1e9)
        else
            disp = tostring(math.floor(valor))
        end

        resultadoLabelsDurabilidad[pack].Text = string.format("%d pack(s): %s", pack, disp)
    end
end)
local PetFolder = Calculadora:AddFolder("🐾 Pet Analyzer")

--========================================================--
-- VARIABLES
--========================================================--

local PetData = {}
local SelectedPet = nil

--========================================================--
-- LABELS
--========================================================--

local PetStatus = PetFolder:AddLabel(
    "Estado: esperando..."
)

local TotalPetsLabel = PetFolder:AddLabel(
    "Pets totales: 0"
)

local EquippedPetsLabel = PetFolder:AddLabel(
    "Pets equipados: 0"
)

local HighestLevelLabel = PetFolder:AddLabel(
    "Mayor nivel: -"
)

local HighestExpLabel = PetFolder:AddLabel(
    "Mayor EXP: -"
)

local SelectedPetLabel = PetFolder:AddLabel(
    "Pet seleccionado: -"
)

local SelectedLevelLabel = PetFolder:AddLabel(
    "Nivel: -"
)

local SelectedExpLabel = PetFolder:AddLabel(
    "EXP: -"
)

local SelectedEquippedLabel = PetFolder:AddLabel(
    "Equipado: -"
)

local SelectedEvolvedLabel = PetFolder:AddLabel(
    "Evolucionado: -"
)

--========================================================--
-- FORMATEAR NÚMEROS
--========================================================--

local function ShortNumber(value)

    value = tonumber(value) or 0

    if value >= 1e18 then
        return string.format("%.2fQi", value / 1e18)

    elseif value >= 1e15 then
        return string.format("%.2fQa", value / 1e15)

    elseif value >= 1e12 then
        return string.format("%.2fT", value / 1e12)

    elseif value >= 1e9 then
        return string.format("%.2fB", value / 1e9)

    elseif value >= 1e6 then
        return string.format("%.2fM", value / 1e6)

    elseif value >= 1e3 then
        return string.format("%.2fK", value / 1e3)
    end

    return string.format("%.0f", value)
end

--========================================================--
-- OBTENER NIVEL
--========================================================--

local function GetPetLevel(pet)

    local level = pet:FindFirstChild("level")

    if level then
        return tonumber(level.Value) or 0
    end

    return 0
end

--========================================================--
-- OBTENER EXP
--========================================================--

local function GetPetExp(pet)

    local exp = pet:FindFirstChild("exp")

    if exp then
        return tonumber(exp.Value) or 0
    end

    return 0
end

--========================================================--
-- COMPROBAR EQUIPADO
--========================================================--

local function IsPetEquipped(pet)

    local equippedPets =
        player:FindFirstChild("equippedPets")

    if not equippedPets then
        return false
    end

    for _, equipped in ipairs(
        equippedPets:GetChildren()
    ) do

        if equipped:IsA("ObjectValue") then

            if equipped.Value == pet then
                return true
            end

        elseif equipped.Name == pet.Name then

            return true
        end
    end

    return false
end

--========================================================--
-- COMPROBAR EVOLUCIÓN
--========================================================--

local function IsPetEvolved(pet)

    local evolved =
        pet:FindFirstChild("evolved")

    if not evolved then
        return false
    end

    if evolved:IsA("BoolValue") then
        return evolved.Value
    end

    return tostring(evolved.Value):lower() == "true"
end

--========================================================--
-- ESCANEAR PETS
--========================================================--

local function ScanPets()

    table.clear(PetData)

    local total = 0
    local equipped = 0

    local highestLevel = -1
    local highestLevelPet = nil

    local highestExp = -1
    local highestExpPet = nil

    for _, container in ipairs(petsFolder:GetChildren()) do
        local pets = container:GetChildren()

        -- Support both rarity-folder layouts and direct pet instances.
        if container:FindFirstChild("level") or container:FindFirstChild("exp") then
            pets = {container}
        end

        for _, pet in ipairs(pets) do
            total = total + 1

            local level = GetPetLevel(pet)
            local exp = GetPetExp(pet)
            local isEquipped = IsPetEquipped(pet)
            local evolved = IsPetEvolved(pet)

            if isEquipped then
                equipped = equipped + 1
            end

            local data = {
                instance = pet,
                name = pet.Name,
                level = level,
                exp = exp,
                equipped = isEquipped,
                evolved = evolved
            }

            table.insert(PetData, data)

            if level > highestLevel then
                highestLevel = level
                highestLevelPet = data
            end

            if exp > highestExp then
                highestExp = exp
                highestExpPet = data
            end
        end
    end

    TotalPetsLabel.Text =
        "Pets totales: "
        .. tostring(total)

    EquippedPetsLabel.Text =
        "Pets equipados: "
        .. tostring(equipped)

    if highestLevelPet then

        HighestLevelLabel.Text =
            "Mayor nivel: "
            .. highestLevelPet.name
            .. " Lv."
            .. tostring(
                highestLevelPet.level
            )

    else

        HighestLevelLabel.Text =
            "Mayor nivel: -"

    end

    if highestExpPet then

        HighestExpLabel.Text =
            "Mayor EXP: "
            .. highestExpPet.name
            .. " ("
            .. ShortNumber(
                highestExpPet.exp
            )
            .. ")"

    else

        HighestExpLabel.Text =
            "Mayor EXP: -"

    end

    PetStatus.Text =
        "🟢 Escaneo completado: "
        .. tostring(total)
        .. " pets"
end

--========================================================--
-- PET SELECCIONADO
--========================================================--

local function UpdateSelectedPet()

    if not SelectedPet then

        SelectedPetLabel.Text =
            "Pet seleccionado: -"

        SelectedLevelLabel.Text =
            "Nivel: -"

        SelectedExpLabel.Text =
            "EXP: -"

        SelectedEquippedLabel.Text =
            "Equipado: -"

        SelectedEvolvedLabel.Text =
            "Evolucionado: -"

        return
    end

    local pet = SelectedPet.instance

    if not pet
        or not pet.Parent then

        SelectedPet = nil

        UpdateSelectedPet()

        return
    end

    local level =
        GetPetLevel(pet)

    local exp =
        GetPetExp(pet)

    local equipped =
        IsPetEquipped(pet)

    local evolved =
        IsPetEvolved(pet)

    SelectedPetLabel.Text =
        "Pet seleccionado: "
        .. pet.Name

    SelectedLevelLabel.Text =
        "Nivel: "
        .. tostring(level)

    SelectedExpLabel.Text =
        "EXP: "
        .. ShortNumber(exp)

    SelectedEquippedLabel.Text =
        "Equipado: "
        .. (
            equipped
            and "🟢 YES"
            or "🔴 NO"
        )

    SelectedEvolvedLabel.Text =
        "Evolucionado: "
        .. (
            evolved
            and "🟢 YES"
            or "⚪ NO"
        )
end

--========================================================--
-- BUSCADOR
--========================================================--

PetFolder:AddTextBox(
    "🔎 Buscar pet",
    function(text)

        text =
            string.lower(
                tostring(text)
            )

        if text == "" then

            PetStatus.Text =
                "⚠️ Escribe un nombre"

            return
        end

        for _, data in ipairs(PetData) do

            if string.find(
                string.lower(data.name),
                text,
                1,
                true
            ) then

                SelectedPet = data

                UpdateSelectedPet()

                PetStatus.Text =
                    "🔍 Encontrado: "
                    .. data.name

                return
            end
        end

        PetStatus.Text =
            "❌ No se encontró: "
            .. text
    end
)

--========================================================--
-- RANKING
--========================================================--

local RankingFolder =
    PetFolder:AddFolder(
        "🏆 Pet Ranking"
    )

local RankingLabel =
    RankingFolder:AddLabel(
        "Ranking: esperando..."
    )

local function UpdateRanking()

    local sorted = {}

    for _, data in ipairs(PetData) do
        table.insert(
            sorted,
            data
        )
    end

    table.sort(
        sorted,
        function(a, b)

            if a.level == b.level then
                return a.exp > b.exp
            end

            return a.level > b.level
        end
    )

    local lines = {
        "🏆 PET RANKING"
    }

    local amount =
        math.min(
            5,
            #sorted
        )

    for i = 1, amount do

        local data = sorted[i]

        local icon

        if i == 1 then
            icon = "🥇"

        elseif i == 2 then
            icon = "🥈"

        elseif i == 3 then
            icon = "🥉"

        else
            icon = "⭐"
        end

        table.insert(
            lines,
            icon
            .. " "
            .. data.name
            .. " | Lv."
            .. tostring(data.level)
            .. " | EXP "
            .. ShortNumber(data.exp)
        )
    end

    if amount == 0 then

        table.insert(
            lines,
            "No hay pets."
        )

    end

    RankingLabel.Text =
        table.concat(
            lines,
            "\n"
        )
end

--========================================================--
-- BOTÓN ESCANEAR
--========================================================--

PetFolder:AddButton(
    "🔍 Escanear pets",
    function()

        ScanPets()
        UpdateRanking()
        UpdateSelectedPet()

    end
)

--========================================================--
-- BOTÓN ACTUALIZAR
--========================================================--

PetFolder:AddButton(
    "🔄 Actualizar",
    function()

        ScanPets()
        UpdateRanking()
        UpdateSelectedPet()

    end
)

--========================================================--
-- ACTUALIZACIÓN AUTOMÁTICA
--========================================================--

task.spawn(function()

    while task.wait(2) do

        pcall(function()

            ScanPets()
            UpdateRanking()
            UpdateSelectedPet()

        end)

    end

end)

--========================================================--
-- NUEVO PET
--========================================================--

if petsFolder then
    petsFolder.ChildAdded:Connect(function()


    task.wait(0.2)

    pcall(function()

        ScanPets()
        UpdateRanking()

    end)

end)
end
--========================================================--
-- PET ELIMINADO
--========================================================--

if petsFolder then
    petsFolder.ChildRemoved:Connect(function()

        task.wait(0.2)

        pcall(function()
            ScanPets()
            UpdateRanking()
            UpdateSelectedPet()
        end)

    end)
end


--========================================================--
-- INICIO
--========================================================--

task.spawn(function()

    task.wait(1)

    pcall(function()

        ScanPets()
        UpdateRanking()
        UpdateSelectedPet()

    end)

end)
FarmingTab = window:AddTab("Fast Farm")

Folderfarming = FarmingTab:AddFolder("farm")

local strengthStat = leaderstats:WaitForChild("Strength")
local durabilityStat = player:WaitForChild("Durability")

local function formatNumber(number)
    local isNegative = number < 0
    number = math.abs(number)
    if number >= 1e15 then
        return (isNegative and "-" or "") .. string.format("%.2fQa", number / 1e15)
    elseif number >= 1e12 then
        return (isNegative and "-" or "") .. string.format("%.2fT", number / 1e12)
    elseif number >= 1e9 then
        return (isNegative and "-" or "") .. string.format("%.2fB", number / 1e9)
    elseif number >= 1e6 then
        return (isNegative and "-" or "") .. string.format("%.2fM", number / 1e6)
    elseif number >= 1e3 then
        return (isNegative and "-" or "") .. string.format("%.2fK", number / 1e3)
    else
        return (isNegative and "-" or "") .. string.format("%.2f", number)
    end
end

Folderfarming:AddLabel("Time:").TextSize = 20
local stopwatchLabel = FarmingTab:AddLabel("0d 0h 0m 0s - Fast Rep Inactive")
stopwatchLabel.TextSize = 17
stopwatchLabel.TextColor3 = Color3.fromRGB(255, 50, 50)

local projectedStrengthLabel = Folderfarming:AddLabel("[Strength Pace: 0 /Hour | 0 /Day | 0 /Week]")
projectedStrengthLabel.TextSize = 17
local projectedDurabilityLabel = Folderfarming:AddLabel("[Durability Pace: 0 /Hour | 0 /Day | 0 /Week]")
projectedDurabilityLabel.TextSize = 17
local averageStrengthLabel = Folderfarming:AddLabel("[Average Strength Pace: 0 /Hour | 0 /Day | 0 /Week]")
averageStrengthLabel.TextSize = 17
local averageDurabilityLabel = Folderfarming:AddLabel("[Average Durability Pace: 0 /Hour | 0 /Day | 0 /Week]")
averageDurabilityLabel.TextSize = 17

Folderfarming:AddLabel("").TextSize = 10
local statsLabel = Folderfarming:AddLabel("Stats:")
statsLabel.TextSize = 20
local strengthLabel = Folderfarming:AddLabel("Strength: 0 | Gained: 0")
strengthLabel.TextSize = 17
local durabilityLabel = Folderfarming:AddLabel("Durability: 0 | Gained: 0")
durabilityLabel.TextSize = 17

local startTime = 0
local pausedElapsedTime = 0
local lastPauseTime = 0

local runFastRep = false
local trackingStarted = false

local strengthHistory = {}
local durabilityHistory = {}
local calculationInterval = 10

local initialStrength = strengthStat.Value
local initialDurability = durabilityStat.Value

task.spawn(function()
    local lastCalcTime = tick()
    while true do
        local currentTime = tick()
        local currentStrength = strengthStat.Value
        local currentDurability = durabilityStat.Value

        strengthLabel.Text = "Strength: " .. formatNumber(currentStrength) .. " | Gained: " .. formatNumber(currentStrength - initialStrength)
        durabilityLabel.Text = "Durability: " .. formatNumber(currentDurability) .. " | Gained: " .. formatNumber(currentDurability - initialDurability)

        if runFastRep then
            if not trackingStarted then
                trackingStarted = true
                startTime = currentTime
                strengthHistory = {}
                durabilityHistory = {}
            end
            local elapsedTime = pausedElapsedTime + (currentTime - startTime)
            local days = math.floor(elapsedTime / (24 * 3600))
            local hours = math.floor((elapsedTime % (24 * 3600)) / 3600)
            local minutes = math.floor((elapsedTime % 3600) / 60)
            local seconds = math.floor(elapsedTime % 60)
            stopwatchLabel.Text = string.format("%dd %dh %dm %ds - Fast Rep Running", days, hours, minutes, seconds)
            stopwatchLabel.TextColor3 = Color3.fromRGB(50, 255, 50)

            table.insert(strengthHistory, {time = currentTime, value = currentStrength})
            table.insert(durabilityHistory, {time = currentTime, value = currentDurability})

            while #strengthHistory > 0 and currentTime - strengthHistory[1].time > calculationInterval do
                table.remove(strengthHistory, 1)
            end
            while #durabilityHistory > 0 and currentTime - durabilityHistory[1].time > calculationInterval do
                table.remove(durabilityHistory, 1)
            end

            if currentTime - lastCalcTime >= calculationInterval then
                lastCalcTime = currentTime

                if #strengthHistory >= 2 then
                    local strengthDelta = strengthHistory[#strengthHistory].value - strengthHistory[1].value
                    local strengthPerSecond = strengthDelta / calculationInterval
                    local strengthPerHour = strengthPerSecond * 3600
                    local strengthPerDay = strengthPerSecond * 86400
                    local strengthPerWeek = strengthPerSecond * 604800
                    projectedStrengthLabel.Text = "Strength Pace: " .. formatNumber(strengthPerHour) .. "/Hour | " .. formatNumber(strengthPerDay) .. "/Day | " .. formatNumber(strengthPerWeek) .. "/Week"
                end

                if #durabilityHistory >= 2 then
                    local durabilityDelta = durabilityHistory[#durabilityHistory].value - durabilityHistory[1].value
                    local durabilityPerSecond = durabilityDelta / calculationInterval
                    local durabilityPerHour = durabilityPerSecond * 3600
                    local durabilityPerDay = durabilityPerSecond * 86400
                    local durabilityPerWeek = durabilityPerSecond * 604800
                    projectedDurabilityLabel.Text = "Durability Pace: " .. formatNumber(durabilityPerHour) .. "/Hour | " .. formatNumber(durabilityPerDay) .. "/Day | " .. formatNumber(durabilityPerWeek) .. "/Week"
                end

                local totalElapsed = pausedElapsedTime + (currentTime - startTime)
                if totalElapsed > 0 then
                    local avgStrengthPerSecond = (currentStrength - initialStrength) / totalElapsed
                    local avgStrengthPerHour = avgStrengthPerSecond * 3600
                    local avgStrengthPerDay = avgStrengthPerSecond * 86400
                    local avgStrengthPerWeek = avgStrengthPerSecond * 604800
                    averageStrengthLabel.Text = "Average Strength Pace: " .. formatNumber(avgStrengthPerHour) .. "/Hour | " .. formatNumber(avgStrengthPerDay) .. "/Day | " .. formatNumber(avgStrengthPerWeek) .. "/Week"

                    local avgDurabilityPerSecond = (currentDurability - initialDurability) / totalElapsed
                    local avgDurabilityPerHour = avgDurabilityPerSecond * 3600
                    local avgDurabilityPerDay = avgDurabilityPerSecond * 86400
                    local avgDurabilityPerWeek = avgDurabilityPerSecond * 604800
                    averageDurabilityLabel.Text = "Average Durability Pace: " .. formatNumber(avgDurabilityPerHour) .. "/Hour | " .. formatNumber(avgDurabilityPerDay) .. "/Day | " .. formatNumber(avgDurabilityPerWeek) .. "/Week"
                end
            end
        else
            if trackingStarted then
                trackingStarted = false
                pausedElapsedTime = pausedElapsedTime + (currentTime - startTime)
                stopwatchLabel.Text = string.format("%dd %dh %dm %ds - Fast Rep Stopped", math.floor(pausedElapsedTime / (24 * 3600)), math.floor((pausedElapsedTime % (24 * 3600)) / 3600), math.floor((pausedElapsedTime % 3600) / 60), math.floor(pausedElapsedTime % 60))
                stopwatchLabel.TextColor3 = Color3.fromRGB(255, 165, 0)

                projectedStrengthLabel.Text = "Strength Pace: 0 /Hour | 0 /Day | 0 /Week"
                projectedDurabilityLabel.Text = "Durability Pace: 0 /Hour | 0 /Day | 0 /Week"
                averageStrengthLabel.Text = "Average Strength Pace: 0 /Hour | 0 /Day | 0 /Week"
                averageDurabilityLabel.Text = "Average Durability Pace: 0 /Hour | 0 /Day | 0 /Week"

                strengthHistory = {}
                durabilityHistory = {}
            end
        end

        task.wait(0.04)
    end
end)

Folderfarming:AddLabel("")
Folderfarming:AddLabel("Fast Farm (Recommended Speed: 20)").TextSize = 20

local repsPerTick = 70
local runFastRep = false

local function getPing()
    local stats = game:GetService("Stats")
    local performanceStats = stats:FindFirstChild("PerformanceStats")
    local pingStat = performanceStats and performanceStats:FindFirstChild("Ping")
    return pingStat and pingStat:GetValue() or 0
end

Folderfarming:AddLabel("")
Folderfarming:AddLabel("⚡ FAST FARM FUERZA ULTRA").TextSize = 20

Folderfarming:AddTextBox("Rep Speed", function(value)
    local num = tonumber(value)
    if num and num > 0 then
        repsPerTick = math.floor(num)
    end
end, {
    placeholder = "70",
})

local function fastRepLoop()
    while runFastRep do
        for i = 1, repsPerTick do
            if not runFastRep then
                break
            end
            muscleEvent:FireServer("rep")
        end

        task.wait()

        if getPing() >= 350 then
            task.wait(0)
        end
    end
end

Folderfarming:AddSwitch("Fast Farm Fuerza", function(state)
    runFastRep = state

    if state then
        task.spawn(fastRepLoop)
    end
end)

-- 💾 CONFIGURACIÓN: GUARDAR / CARGAR
local ConfigFolder = "PacksPrivated"
local ConfigFile = ConfigFolder .. "/settings.json"

local Config = {
    RepSpeed = repsPerTick or 50,
}

local function notifyConfig(title, message)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = message,
            Duration = 4
        })
    end)
end

local function saveConfig()
    if not writefile then
        notifyConfig("Configuración", "Tu executor no soporta guardar archivos.")
        return
    end

    local ok, result = pcall(function()
        if makefolder then
            pcall(function()
                makefolder(ConfigFolder)
            end)
        end

        Config.RepSpeed = repsPerTick
        writefile(ConfigFile, HttpService:JSONEncode(Config))
    end)

    if ok then
        notifyConfig("Configuración", "Configuración guardada.")
    else
        notifyConfig("Configuración", "Error al guardar: " .. tostring(result))
    end
end

local function loadConfig()
    if not readfile or not isfile then
        notifyConfig("Configuración", "Tu executor no soporta cargar archivos.")
        return
    end

    if not isfile(ConfigFile) then
        notifyConfig("Configuración", "No existe una configuración guardada.")
        return
    end

    local ok, result = pcall(function()
        local data = HttpService:JSONDecode(readfile(ConfigFile))

        if type(data) == "table" and tonumber(data.RepSpeed) then
            repsPerTick = math.max(1, math.floor(tonumber(data.RepSpeed)))
        end
    end)

    if ok then
        notifyConfig("Configuración", "Configuración cargada. Rep Speed: " .. tostring(repsPerTick))
    else
        notifyConfig("Configuración", "Error al cargar: " .. tostring(result))
    end
end

local ConfigTab = window:AddTab("Config")
local ConfigFolderUI = ConfigTab:AddFolder("Configuración")

ConfigFolderUI:AddButton("💾 Guardar configuración", function()
    saveConfig()
end)

ConfigFolderUI:AddButton("📂 Cargar configuración", function()
    loadConfig()
end)

ConfigFolderUI:AddLabel("Guarda/carga Rep Speed en el dispositivo.")

local SelectedTool = nil
local AutoFarmActive = false
local selectedRock = nil

Folderfarming:AddSwitch("Fast Tools", function(state)
    _G.FastTools = state

    local toolSettings = {
        {"Punch",       "attackTime", state and 0 or 0.01},
        {"Ground Slam", "attackTime", state and 0 or 6},
        {"Stomp",       "attackTime", state and 0 or 7},
        {"Handstands",  "repTime",    state and 0 or 1},
        {"Pushups",     "repTime",    state and 0 or 1},
        {"Weight",      "repTime",    state and 0 or 1},
        {"Situps",      "repTime",    state and 0 or 1},
    }

    local function applyTool(tool)
        -- Backpack
        local backpackTool = player.Backpack:FindFirstChild(tool[1])
        if backpackTool and backpackTool:FindFirstChild(tool[2]) then
            backpackTool[tool[2]].Value = tool[3]
        end

        -- Character
        local character = player.Character
        if character then
            local equippedTool = character:FindFirstChild(tool[1])
            if equippedTool and equippedTool:FindFirstChild(tool[2]) then
                equippedTool[tool[2]].Value = tool[3]
            end
        end
    end

    for _, tool in ipairs(toolSettings) do
        applyTool(tool)
    end
end)
end 
local function Crearpepe()
local FolderautoTools = FarmingTab:AddFolder("TOOLS X ROCK")
FolderautoTools:AddLabel("Select the tool you will use:").TextSize = 22

local toolDropdown = FolderautoTools:AddDropdown("Select Tool", function(selection)
    SelectedTool = selection
end)
toolDropdown:Add("Weight")
toolDropdown:Add("Pushups")
toolDropdown:Add("Situps")
toolDropdown:Add("Handstands")
toolDropdown:Add("Fast Punch")
toolDropdown:Add("Stomp")
toolDropdown:Add("Ground Slam")


local rockData = {
    ["Jungle Rock"] = 10000000
}

local rockDropdown = FolderautoTools:AddDropdown("Select Rock", function(selection)
    selectedRock = selection
end)
for rockName in pairs(rockData) do
    rockDropdown:Add(rockName)
end

local function punchTool()
    for _, v in pairs(player.Backpack:GetChildren()) do
        if v.Name == "Punch" and player.Character:FindFirstChild("Humanoid") then
            player.Character.Humanoid:EquipTool(v)
        end
    end
    player.muscleEvent:FireServer("punch", "leftHand")
    player.muscleEvent:FireServer("punch", "rightHand")
end

local function startFarming()
    task.spawn(function()
        while AutoFarmActive do
            local char = player.Character or player.CharacterAdded:Wait()
            local toolName = SelectedTool
            local durability = player.Durability and player.Durability.Value or 0

            if toolName == "Weight" or toolName == "Pushups" or toolName == "Situps" or toolName == "Handstands" then
                if not char:FindFirstChild(toolName) then
                    local tool = player.Backpack:FindFirstChild(toolName)
                    if tool then
                        pcall(function() char.Humanoid:EquipTool(tool) end)
                    end
                end
                pcall(function() player.muscleEvent:FireServer("rep") end)
            elseif toolName == "Fast Punch" then
                punchTool()
            elseif toolName == "Stomp" then
                local stomp = player.Backpack:FindFirstChild("Stomp")
                if stomp and not char:FindFirstChild("Stomp") then
                    pcall(function() stomp.Parent = char end)
                    if stomp:FindFirstChild("attackTime") then
                        pcall(function() stomp.attackTime.Value = 0 end)
                    end
                end
                pcall(function() player.muscleEvent:FireServer("stomp") end)
                if char:FindFirstChild("Stomp") then
                    pcall(function() char.Stomp:Activate() end)
                end
                if tick() % 6 < 0.1 then
                    local vu = VirtualUser
                    pcall(function()
                        vu:CaptureController()
                        vu:ClickButton1(Vector2.new(500, 500))
                    end)
                end
            elseif toolName == "Ground Slam" then
                local gs = player.Backpack:FindFirstChild("Ground Slam")
                if gs and not char:FindFirstChild("Ground Slam") then
                    pcall(function() gs.Parent = char end)
                    if gs:FindFirstChild("attackTime") then
                        pcall(function() gs.attackTime.Value = 0 end)
                    end
                end
                pcall(function() player.muscleEvent:FireServer("slam") end)
                if char:FindFirstChild("Ground Slam") then
                    pcall(function() char["Ground Slam"]:Activate() end)
                end
                if tick() % 6 < 0.1 then
                    local vu = VirtualUser
                    pcall(function()
                        vu:CaptureController()
                        vu:ClickButton1(Vector2.new(500, 500))
                    end)
                end
            end

            if selectedRock then
                local requiredDurability = rockData[selectedRock]
                if durability >= requiredDurability then
                    for _, v in pairs(workspace:GetDescendants()) do
                        if v.Name == "neededDurability" and v.Value == requiredDurability and
                           char:FindFirstChild("LeftHand") and char:FindFirstChild("RightHand") then
                            local rock = v.Parent:FindFirstChild("Rock")
                            if rock then
                                pcall(function()
                                    firetouchinterest(rock, char.RightHand, 0)
                                    firetouchinterest(rock, char.RightHand, 1)
                                    firetouchinterest(rock, char.LeftHand, 0)
                                    firetouchinterest(rock, char.LeftHand, 1)
                                end)
                                punchTool()
                            end
                        end
                    end
                end
            end
            task.wait()
        end
    end)
end

FolderautoTools:AddSwitch("Start", function(enabled)
    AutoFarmActive = enabled
    if enabled then
        startFarming()
    else
        if SelectedTool and player.Character and player.Character:FindFirstChild(SelectedTool) then
            pcall(function()
                player.Character:FindFirstChild(SelectedTool).Parent = player.Backpack
            end)
        end
    end
end)

local Folder_AutoGym = FarmingTab:AddFolder(' Auto Gym')

Folder_AutoGym:AddLabel('King Gym')
Folder_AutoGym:AddSwitch('Auto Muscle King Lift', function(p36)
    if p36 then
        _G.automlking = true

        while _G.automlking do
            local v37 = {
                'useMachine',
                workspace.machinesFolder:FindFirstChild('Muscle King Lift').interactSeat,
            }

            game:GetService('ReplicatedStorage').rEvents.machineInteractRemote:InvokeServer(unpack(v37))

            local _Character = player.Character
            local v39 = Vector3.new(-8773, 17, -5669)

            if _Character then
                _Character.HumanoidRootPart.CFrame = CFrame.new(v39)
            end

            wait()

            local v40 = {
                'rep',
                workspace.machinesFolder:FindFirstChild('Muscle King Lift').interactSeat,
            }

            player.muscleEvent:FireServer(unpack(v40))
            game:GetService('RunService').RenderStepped:Wait()

            if not _G.automlking then
            end
        end
    else
        _G.automlking = false

        return
    end
end)
Folder_AutoGym:AddSwitch('Auto Muscle King Bench', function(p41)
    if p41 then
        _G.automlking = true

        while _G.automlking do
            local v42 = {
                'useMachine',
                workspace.machinesFolder:FindFirstChild('Muscle King Bench').interactSeat,
            }

            game:GetService('ReplicatedStorage').rEvents.machineInteractRemote:InvokeServer(unpack(v42))

            local _Character2 = player.Character
            local v44 = Vector3.new(-8593.6884765625, 22.231548309326172, -6061.2900390625)

            if _Character2 then
                _Character2.HumanoidRootPart.CFrame = CFrame.new(v44)
            end

            wait()

            local v45 = {
                'rep',
                workspace.machinesFolder:FindFirstChild('Muscle King Bench').interactSeat,
            }

            player.muscleEvent:FireServer(unpack(v45))
            game:GetService('RunService').RenderStepped:Wait()

            if not _G.automlking then
            end
        end
    else
        _G.automlking = false

        return
    end
end)
Folder_AutoGym:AddSwitch('Auto Muscle King Squat', function(p46)
    if p46 then
        _G.automlking = true

        while _G.automlking do
            local v47 = {
                'useMachine',
                workspace.machinesFolder:FindFirstChild('Muscle King Squat').interactSeat,
            }

            game:GetService('ReplicatedStorage').rEvents.machineInteractRemote:InvokeServer(unpack(v47))

            local _Character3 = player.Character
            local v49 = Vector3.new(-8752, 24, -6051)

            if _Character3 then
                _Character3.HumanoidRootPart.CFrame = CFrame.new(v49)
            end

            wait()

            local v50 = {
                'rep',
                workspace.machinesFolder:FindFirstChild('Muscle King Squat').interactSeat,
            }

            player.muscleEvent:FireServer(unpack(v50))
            game:GetService('RunService').RenderStepped:Wait()

            if not _G.automlking then
            end
        end
    else
        _G.automlking = false

        return
    end
end)
Folder_AutoGym:AddSwitch('Auto Muscle King Boulder', function(p51)
    if p51 then
        _G.automlking = true

        while _G.automlking do
            local v52 = {
                'useMachine',
                workspace.machinesFolder:FindFirstChild('King Boulder').interactSeat,
            }

            game:GetService('ReplicatedStorage').rEvents.machineInteractRemote:InvokeServer(unpack(v52))

            local _Character4 = player.Character
            local v54 = Vector3.new(-8944, 24, -5684)

            if _Character4 then
                _Character4.HumanoidRootPart.CFrame = CFrame.new(v54)
            end

            wait()

            local v55 = {
                'rep',
                workspace.machinesFolder:FindFirstChild('King Boulder').interactSeat,
            }

            player.muscleEvent:FireServer(unpack(v55))
            game:GetService('RunService').RenderStepped:Wait()

            if not _G.automlking then
            end
        end
    else
        _G.automlking = false

        return
    end
end)
Folder_AutoGym:AddLabel('Legends Gym')
Folder_AutoGym:AddSwitch('Auto Legends Press', function(p56)
    if p56 then
        _G.autolegends = true

        while _G.autolegends do
            local v57 = {
                'useMachine',
                workspace.machinesFolder:FindFirstChild('Legends Press').interactSeat,
            }

            game:GetService('ReplicatedStorage').rEvents.machineInteractRemote:InvokeServer(unpack(v57))

            local _Character5 = player.Character
            local v59 = Vector3.new(4097.8427734375, 996.5140380859375, -3787.60791015625)

            if _Character5 then
                _Character5.HumanoidRootPart.CFrame = CFrame.new(v59)
            end

            wait()

            local v60 = {
                'rep',
                workspace.machinesFolder:FindFirstChild('Legends Press').interactSeat,
            }

            player.muscleEvent:FireServer(unpack(v60))
            game:GetService('RunService').RenderStepped:Wait()

            if not _G.autolegends then
            end
        end
    else
        _G.autolegends = false

        return
    end
end)
Folder_AutoGym:AddSwitch('Auto Legends Throw', function(p61)
    if p61 then
        _G.autolegends = true

        local v62 = {
            'useMachine',
            workspace.machinesFolder:FindFirstChild('Legends Throw').interactSeat,
        }

        game:GetService('ReplicatedStorage').rEvents.machineInteractRemote:InvokeServer(unpack(v62))

        local _Character6 = player.Character
        local v64 = Vector3.new(4196.248046875, 991.5355224609375, -3905.087158203125)

        if _Character6 then
            _Character6.HumanoidRootPart.CFrame = CFrame.new(v64)
        end

        wait()

        local v65 = {
            'rep',
            workspace.machinesFolder:FindFirstChild('Legends Throw').interactSeat,
        }

        player.muscleEvent:FireServer(unpack(v65))
        game:GetService('RunService').RenderStepped:Wait()

        if not _G.autolegends then
        end
    end

    _G.autolegends = false
end)
Folder_AutoGym:AddSwitch('Auto Legends Pullup', function(p66)
    if p66 then
        _G.autolegends = true

        while _G.autolegends do
            local v67 = {
                'useMachine',
                workspace.machinesFolder:FindFirstChild('Legends Pullup').interactSeat,
            }

            game:GetService('ReplicatedStorage').rEvents.machineInteractRemote:InvokeServer(unpack(v67))

            local _Character7 = player.Character
            local v69 = Vector3.new(4308, 998, -4121)

            if _Character7 then
                _Character7.HumanoidRootPart.CFrame = CFrame.new(v69)
            end

            wait()

            local v70 = {
                'rep',
                workspace.machinesFolder:FindFirstChild('Legends Pullup').interactSeat,
            }

            player.muscleEvent:FireServer(unpack(v70))
            game:GetService('RunService').RenderStepped:Wait()

            if not _G.autolegends then
            end
        end
    else
        _G.autolegends = false

        return
    end
end)
Folder_AutoGym:AddSwitch('Auto Legends Squat', function(p71)
    if p71 then
        _G.autolegends = true

        while _G.autolegends do
            local v72 = {
                'useMachine',
                workspace.machinesFolder:FindFirstChild('Legends Squat').interactSeat,
            }

            game:GetService('ReplicatedStorage').rEvents.machineInteractRemote:InvokeServer(unpack(v72))

            local _Character8 = player.Character
            local v74 = Vector3.new(4446, 998, -4069)

            if _Character8 then
                _Character8.HumanoidRootPart.CFrame = CFrame.new(v74)
            end

            wait()

            local v75 = {
                'rep',
                workspace.machinesFolder:FindFirstChild('Legends Squat').interactSeat,
            }

            player.muscleEvent:FireServer(unpack(v75))
            game:GetService('RunService').RenderStepped:Wait()

            if not _G.autolegends then
            end
        end
    else
        _G.autolegends = false

        return
    end
end)
Folder_AutoGym:AddSwitch('Auto Legends Lift', function(p76)
    if p76 then
        _G.autolegends = true

        while _G.autolegends do
            local v77 = {
                'useMachine',
                workspace.machinesFolder:FindFirstChild('Legends Lift').interactSeat,
            }

            game:GetService('ReplicatedStorage').rEvents.machineInteractRemote:InvokeServer(unpack(v77))

            local _Character9 = player.Character
            local v79 = Vector3.new(4527.3583984375, 991.4735717773438, -4001.750732421875)

            if _Character9 then
                _Character9.HumanoidRootPart.CFrame = CFrame.new(v79)
            end

            wait()

            local v80 = {
                'rep',
                workspace.machinesFolder:FindFirstChild('Legends Lift').interactSeat,
            }

            player.muscleEvent:FireServer(unpack(v80))
            game:GetService('RunService').RenderStepped:Wait()

            if not _G.autolegends then
            end
        end
    else
        _G.autolegends = false

        return
    end
end)

Folder_rebirth = FarmingTab:AddFolder("sin packs")
local targetRebirthValue = 1
Folder_rebirth:AddTextBox("Rebirth Target", function(text)
    local newValue = tonumber(text)
    if newValue and newValue > 0 then
        targetRebirthValue = newValue
        
        StarterGui:SetCore("SendNotification", {
            Title = "Objetivo Actualizado",
            Text = "Nuevo objetivo: " .. tostring(targetRebirthValue) .. " renacimientos",
            Duration = 0
        })
    else
        StarterGui:SetCore("SendNotification", {
            Title = "Size",
            Text = "Put a size larger than 0",
            Duration = 0
        })
    end
end)

local targetSwitch = Folder_rebirth:AddSwitch("Auto Rebirth Target", function(bool)
    _G.targetRebirthActive = bool
    
    if bool then
        if _G.infiniteRebirthActive and infiniteSwitch then
            infiniteSwitch:Set(false)
            _G.infiniteRebirthActive = false
        end
        
        spawn(function()
            while _G.targetRebirthActive and wait(0.1) do
                local currentRebirths = player.leaderstats.Rebirths.Value
                
                if currentRebirths >= targetRebirthValue then
                    targetSwitch:Set(false)
                    _G.targetRebirthActive = false
                    
                    StarterGui:SetCore("SendNotification", {
                        Title = "¡Objetivo Alcanzado!",
                        Text = "Has alcanzado " .. tostring(targetRebirthValue) .. " renacimientos",
                        Duration = 5
                    })
                    
                    break
                end
                
                ReplicatedStorage.rEvents.rebirthRemote:InvokeServer("rebirthRequest")
            end
        end)
    end
end, "automatic rebirth until reaching the goal")

infiniteSwitch = Folder_rebirth:AddSwitch("Auto Rebirth (Infinitely)", function(bool)
    _G.infiniteRebirthActive = bool
    
    if bool then
        if _G.targetRebirthActive and targetSwitch then
            targetSwitch:Set(false)
            _G.targetRebirthActive = false
        end
        
        spawn(function()
            while _G.infiniteRebirthActive and wait(0.1) do
                ReplicatedStorage.rEvents.rebirthRemote:InvokeServer("rebirthRequest")
            end
        end)
    end
end, "rebirth infinitely")

local sizeSwitch = Folder_rebirth:AddSwitch("Auto Size 2", function(bool)
    _G.autoSizeActive = bool
    
    if bool then
        spawn(function()
            while _G.autoSizeActive and wait() do
                ReplicatedStorage.rEvents.changeSpeedSizeRemote:InvokeServer("changeSize", 2)
            end
        end)
    end
end, "Size 2")

local teleportSwitch = Folder_rebirth:AddSwitch("Auto Teleport to Muscle King", function(bool)
    _G.teleportActive = bool
    
    if bool then
        spawn(function()
            while _G.teleportActive and wait() do
                if player.Character then
                    player.Character:MoveTo(Vector3.new(-8646, 17, -5738))
                end
            end
        end)
    end
end, "Tp to Mk")

local AutoEggEnabled = false

local function ConsumeProteinEgg()

    player:WaitForChild("Backpack")

    local character = player.Character or player.CharacterAdded:Wait()

    local egg = player.Backpack:FindFirstChild("Protein Egg")

    if egg then
        egg.Parent = character

        pcall(function()
            egg:Activate()
        end)

        print("[AutoEgg] Protein Egg consumido.")
    else
        warn("[AutoEgg] No se encontró Protein Egg en el Backpack.")
    end
end

task.spawn(function()
    while true do
        if AutoEggEnabled then
            ConsumeProteinEgg()
            task.wait(1800) -- 30 minutos
        else
            task.wait(1)
        end
    end
end)

Folder_rebirth:AddSwitch("Eat Egg (30 Min)", function(state)
    AutoEggEnabled = state

    if state then
        print("[AutoEgg] Activado.")
    else
        print("[AutoEgg] Desactivado.")
    end
end)
end
local function Crearextra()
local extraTab = window:AddTab("Extra")
local lockSwitch = extraTab:AddSwitch("Lock Position", function(Value)

    if Value then
        lockRunning = true
        lockConnection = RunService.Heartbeat:Connect(function()
            local char = player.Character
            if not char or not char:FindFirstChild("HumanoidRootPart") or not char:FindFirstChildOfClass("Humanoid") then return end

            local hrp = char.HumanoidRootPart
            local humanoid = char:FindFirstChildOfClass("Humanoid")

            if not humanoid or not hrp then return end

            if not humanoid:FindFirstChild("LockState") then
                humanoid.WalkSpeed = 0
                humanoid.JumpPower = 0
                humanoid.AutoRotate = false
                humanoid:ChangeState(Enum.HumanoidStateType.Physics)
                local marker = Instance.new("BoolValue", humanoid)
                marker.Name = "LockState"
                marker.Value = true
                humanoid:SetAttribute("LockCFrame", hrp.CFrame)
            end

            local savedCFrame = humanoid:GetAttribute("LockCFrame")
            if savedCFrame then
                hrp.Velocity = Vector3.zero
                hrp.RotVelocity = Vector3.zero
                hrp.CFrame = savedCFrame
            end
        end)
    else
        lockRunning = false
        if lockConnection then
            lockConnection:Disconnect()
            lockConnection = nil
        end
        local char = player.Character
        if char then
            local humanoid = char:FindFirstChildOfClass("Humanoid")
            if humanoid then
                humanoid.WalkSpeed = 250
                humanoid.JumpPower = 50
                humanoid.AutoRotate = true
                humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
                if humanoid:FindFirstChild("LockState") then
                    humanoid.LockState:Destroy()
                end
                humanoid:SetAttribute("LockCFrame", nil)
            end
        end
    end
end)

lockSwitch:Set(false)
--------------------------------------------------
-- 🐾 SHOW / HIDE PETS
--------------------------------------------------
local function onShowPets(enabled)
    local v = player:FindFirstChild("hidePets")
    if v then
        v.Value = enabled
    end
end

extraTab:AddSwitch("Show Pets", onShowPets)

--------------------------------------------------
-- 🦘 INFINITE JUMP
--------------------------------------------------
local infJump = false

local function onInfiniteJump(state)
    infJump = state
end

UIS.JumpRequest:Connect(function()
    if infJump then
        local char = player.Character
        if char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then
                hum:ChangeState(Enum.HumanoidStateType.Jumping)
            end
        end
    end
end)

extraTab:AddSwitch("Infinite Jump", onInfiniteJump)


--------------------------------------------------
-- ⚡ FAST REBIRTH + PET CYCLE
--------------------------------------------------
local SwiftSamuraiAmount = 8
local TribalOverlordAmount = 8
local fastRebirthEnabled = false
local fastRebirthThread = nil

extraTab:AddTextBox("Swift Samurai Amount", function(value)
    local num = tonumber(value)
    if num then
        SwiftSamuraiAmount = math.clamp(math.floor(num), 1, 8)
    end
end, {placeholder = "8"})

extraTab:AddTextBox("Tribal Overlord Amount", function(value)
    local num = tonumber(value)
    if num then
        TribalOverlordAmount = math.clamp(math.floor(num), 1, 8)
    end
end, {placeholder = "8"})

local function fastRebirthEquipPet(petName, amount)
    local remoteFolder = ReplicatedStorage:FindFirstChild("rEvents")
    local equipRemote = remoteFolder and remoteFolder:FindFirstChild("equipPetEvent")
    local unique = player:FindFirstChild("petsFolder") and player.petsFolder:FindFirstChild("Unique")
    if not equipRemote or not unique then
        warn("[Fast Rebirth] No se encontró equipPetEvent o petsFolder.Unique")
        return 0
    end

    local equipped = 0
    for _, pet in ipairs(unique:GetChildren()) do
        if pet.Name == petName then
            local ok = pcall(function()
                equipRemote:FireServer("equipPet", pet)
            end)
            if ok then
                equipped = equipped + 1
            end
            if equipped >= amount then
                break
            end
        end
    end
    return equipped
end

local function fastRebirthUnequipTargets()
    local remoteFolder = ReplicatedStorage:FindFirstChild("rEvents")
    local equipRemote = remoteFolder and remoteFolder:FindFirstChild("equipPetEvent")
    local pf = player:FindFirstChild("petsFolder")
    if not equipRemote or not pf then return end

    local targets = {
        ["Swift Samurai"] = true,
        ["Tribal Overlord"] = true,
    }

    for _, folder in ipairs(pf:GetChildren()) do
        if folder:IsA("Folder") then
            for _, pet in ipairs(folder:GetChildren()) do
                if targets[pet.Name] then
                    pcall(function()
                        equipRemote:FireServer("unequipPet", pet)
                    end)
                end
            end
        end
    end
end

local function startFastRebirth()
    if fastRebirthThread then return end

    fastRebirthThread = task.spawn(function()
        local globalFunctions
        local ok, result = pcall(function()
            return require(ReplicatedStorage:WaitForChild("globalFunctions"))
        end)
        if not ok then
            warn("[Fast Rebirth] No se pudo cargar globalFunctions: " .. tostring(result))
            fastRebirthThread = nil
            return
        end
        globalFunctions = result

        local stats = player:FindFirstChild("leaderstats")
        local strength = stats and stats:FindFirstChild("Strength")
        local rebirths = stats and stats:FindFirstChild("Rebirths")
        local events = ReplicatedStorage:FindFirstChild("rEvents")
        local rebirthRemote = events and events:FindFirstChild("rebirthRemote")

        if not strength or not rebirths or not rebirthRemote then
            warn("[Fast Rebirth] Faltan Strength, Rebirths o rebirthRemote.")
            fastRebirthThread = nil
            return
        end

        while fastRebirthEnabled do
            local neededStrength
            local calcOK, calcResult = pcall(function()
                return globalFunctions.calculateRequiredRebirthStrength(rebirths.Value, player)
            end)
            if calcOK then
                neededStrength = calcResult
            else
                warn("[Fast Rebirth] Error calculando fuerza: " .. tostring(calcResult))
                break
            end

            fastRebirthUnequipTargets()
            task.wait(0.05)
            fastRebirthEquipPet("Swift Samurai", SwiftSamuraiAmount)

            while fastRebirthEnabled and strength.Value < neededStrength do
                for _ = 1, 6 do
                    pcall(function()
                        muscleEvent:FireServer("rep")
                    end)
                end
                task.wait()
            end

            if not fastRebirthEnabled then break end

            fastRebirthEquipPet("Tribal Overlord", TribalOverlordAmount)
            local oldRebirths = rebirths.Value

            repeat
                pcall(function()
                    rebirthRemote:InvokeServer("rebirthRequest")
                end)
                task.wait()
            until rebirths.Value > oldRebirths or not fastRebirthEnabled
        end

        fastRebirthThread = nil
    end)
end

extraTab:AddSwitch("FAST REBIRTH", function(state)
    fastRebirthEnabled = state
    if state then
        startFastRebirth()
    end
end)

--------------------------------------------------
-- 🥚 EAT PROTEIN EGG (30 MIN)
--------------------------------------------------
local extraAutoEggEnabled = false
local extraEggThread = nil

local function consumeProteinEgg()
    local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5)
    local character = player.Character or player.CharacterAdded:Wait()
    if not backpack or not character then return false end

    local egg = backpack:FindFirstChild("Protein Egg")
    if not egg then
        return false
    end

    egg.Parent = character
    local ok = pcall(function()
        egg:Activate()
    end)
    return ok
end

extraTab:AddSwitch("Eat Egg (30 Min)", function(state)
    extraAutoEggEnabled = state
    if not state then return end
    if extraEggThread then return end

    extraEggThread = task.spawn(function()
        while extraAutoEggEnabled do
            consumeProteinEgg()
            task.wait(1800)
        end
        extraEggThread = nil
    end)
end)

--------------------------------------------------
-- 💤 ANTI AFK (LOCAL)
--------------------------------------------------
local antiAFKEnabled = false
local antiAFKConnection = nil

extraTab:AddSwitch("Anti AFK", function(state)
    antiAFKEnabled = state

    if antiAFKConnection then
        antiAFKConnection:Disconnect()
        antiAFKConnection = nil
    end

    if state then
        antiAFKConnection = player.Idled:Connect(function()
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(Vector2.new())
            end)
        end)
    end
end)

--------------------------------------------------
-- 🚀 FULL OPTIMIZATION
-- No destruye ScreenGuis para no romper el propio hub.
--------------------------------------------------
local fullOptimizationEnabled = false
local optimizationConnection = nil

local function applyFullOptimization()
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.Brightness = 0
        Lighting.ClockTime = 0
        Lighting.TimeOfDay = "00:00:00"
        Lighting.OutdoorAmbient = Color3.new(0, 0, 0)
        Lighting.Ambient = Color3.new(0, 0, 0)
        Lighting.FogColor = Color3.new(0, 0, 0)
        Lighting.FogEnd = 9e9
    end)

    for _, obj in ipairs(workspace:GetDescendants()) do
        pcall(function()
            if obj:IsA("ParticleEmitter") or obj:IsA("Smoke") or obj:IsA("Fire") or obj:IsA("Sparkles") then
                obj.Enabled = false
            elseif obj:IsA("PointLight") or obj:IsA("SpotLight") or obj:IsA("SurfaceLight") then
                obj.Enabled = false
            elseif obj:IsA("Decal") or obj:IsA("Texture") then
                obj.Transparency = 1
            elseif obj:IsA("BasePart") then
                obj.Reflectance = 0
                if not obj:IsA("MeshPart") then
                    obj.Material = Enum.Material.SmoothPlastic
                end
            end
        end)
    end

    for _, obj in ipairs(Lighting:GetChildren()) do
        pcall(function()
            if obj:IsA("PostEffect") then
                obj.Enabled = false
            end
        end)
    end

    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    end)
end

extraTab:AddSwitch("Full Optimization", function(state)
    fullOptimizationEnabled = state

    if optimizationConnection then
        optimizationConnection:Disconnect()
        optimizationConnection = nil
    end

    if state then
        applyFullOptimization()
        optimizationConnection = RunService.Heartbeat:Connect(function()
            if fullOptimizationEnabled then
                -- Reaplica solo de forma periódica; Heartbeat no hace trabajo pesado.
            end
        end)

        task.spawn(function()
            while fullOptimizationEnabled do
                applyFullOptimization()
                task.wait(5)
            end
        end)
    end
end)

--------------------------------------------------
-- 🌊 WALK ON WATER (OPTIMIZADO)
--------------------------------------------------
local waterPart = nil
local waterConnection = nil

local function onWalkOnWater(state)
    if state then
        if not waterPart then
            waterPart = Instance.new("Part")
            waterPart.Size = Vector3.new(5000, 1, 5000)
            waterPart.Anchored = true
            waterPart.Transparency = 1
            waterPart.Name = "WaterPlatform"
            waterPart.Parent = workspace
        end

        local char = player.Character
        if char then
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if hrp then
                waterPart.Position = Vector3.new(hrp.Position.X, hrp.Position.Y - 5, hrp.Position.Z)
            end
        end

        if waterConnection then
            waterConnection:Disconnect()
        end

        waterConnection = RunService.Heartbeat:Connect(function()
            if waterPart then
                local char = player.Character
                if char then
                    local hrp = char:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        waterPart.Position = Vector3.new(hrp.Position.X, hrp.Position.Y - 5, hrp.Position.Z)
                    end
                end
            end
        end)
    else
        if waterConnection then
            waterConnection:Disconnect()
            waterConnection = nil
        end
        if waterPart then
            waterPart:Destroy()
            waterPart = nil
        end
    end
end

local WalkWaterSwitch = extraTab:AddSwitch("Walk on Water", onWalkOnWater)
WalkWaterSwitch:Set(false)

--------------------------------------------------
-- 🌗 TIME CONTROL
--------------------------------------------------
local function onChangeTime(value)
    if value == "Night" then
        Lighting.ClockTime = 0
    elseif value == "Day" then
        Lighting.ClockTime = 12
    elseif value == "Midnight" then
        Lighting.ClockTime = 0
    end
end


local TimeDropdown = extraTab:AddDropdown("Change Time", onChangeTime)
TimeDropdown:Add("Night")
TimeDropdown:Add("Day")
TimeDropdown:Add("Midnight")


extraTab:AddButton("Equip Swift Samurai", function()
    print("Boton presionado: equipando 8 Swift Samurai")


    -- Primero desequipamos todo
    local petsFolder = player:FindFirstChild("petsFolder")
    if not petsFolder then return end

    for _, folder in pairs(petsFolder:GetChildren()) do
        if folder:IsA("Folder") then
            for _, pet in pairs(folder:GetChildren()) do
                ReplicatedStorage.rEvents.equipPetEvent:FireServer("unequipPet", pet)
            end
        end
    end
    task.wait(0.1)

    -- Ahora equipamos mÃ¡ximo 8 "Swift Samurai"
    local equipped = 0
    local maxEquip = 8
    for _, folder in pairs(petsFolder:GetChildren()) do
        if folder:IsA("Folder") then
            for _, pet in pairs(folder:GetChildren()) do
                if pet.Name == "Swift Samurai" then
                    ReplicatedStorage.rEvents.equipPetEvent:FireServer("equipPet", pet)
                    equipped = equipped + 1
                    print("Equipado Swift Samurai #" .. equipped)

                    if equipped >= maxEquip then
                        return -- salir cuando ya haya 8 equipados
                    end
                end
            end
        end
    end

    print("Se equiparon " .. equipped .. " Swift Samurai")
end)

extraTab:AddButton("Jungle lift", function()
    local char = player.Character or player.CharacterAdded:Wait()
    local hrp = char:WaitForChild("HumanoidRootPart")

    -- Teletransportar al nuevo CFrame
    hrp.CFrame = CFrame.new(-8652.8672, 29.2667, 2089.2617)
    task.wait(0.2)

    local VirtualInputManager = game:GetService("VirtualInputManager")
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
    task.wait(0.05)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
end)



local MP3_URL = ""
local Playlist = {}
local currentIndex = 0
local isPaused = false
local fileName = "GenesisPlaylist_"..player.Name..".txt"
local tempIndex = 0
local currentSound = nil
local fileApiAvailable = type(isfile) == "function" and type(readfile) == "function" and type(writefile) == "function"

if fileApiAvailable then
    if isfile(fileName) then
        local data = readfile(fileName)
        for url in string.gmatch(data, "[^,]+") do
            table.insert(Playlist, url)
        end
    else
        writefile(fileName, "")
    end
end

local function savePlaylist()
    if not fileApiAvailable then
        return
    end
    writefile(fileName, table.concat(Playlist, ","))
end

local function formatTime(sec)
	sec = math.floor(sec or 0)
	local m = math.floor(sec / 60)
	local s = sec % 60
	return string.format("%02d:%02d", m, s)
end

local TimeLabel = extraTab:AddLabel("00:00 / 00:00")

local function loadMP3(url)
    if url == "" then return end
    if not fileApiAvailable or type(getcustomasset) ~= "function" then
        warn("[Trayecto] MP3 requiere isfile/readfile/writefile/getcustomasset.")
        return
    end
	tempIndex = tempIndex + 1
	local tempFile = "GenesisMusic_"..tempIndex..".mp3"

	pcall(function()
		if isfile(tempFile) then delfile(tempFile) end
		writefile(tempFile, game:HttpGet(url))
	end)

	if currentSound then
		currentSound:Destroy()
	end

	currentSound = Instance.new("Sound")
	currentSound.Name = "papi karmaMP3Sound"
	currentSound.Parent = SoundService
	currentSound.SoundId = getcustomasset(tempFile)
	currentSound.Volume = 1
	currentSound.Looped = false
	currentSound:Play()
	isPaused = false

	-- Cuando termina la canciÃ³n, pasa a la siguiente
	currentSound.Ended:Connect(function()
		if not currentSound.Looped and not isPaused then
			currentIndex = currentIndex + 1
			if currentIndex > #Playlist then currentIndex = 1 end
			loadMP3(Playlist[currentIndex])
		end
	end)
end

-- Bucle de actualizaciÃ³n de tiempo
task.spawn(function()
	while task.wait(0.1) do
		if currentSound and currentSound:IsDescendantOf(SoundService) and currentSound.IsLoaded then
			TimeLabel.Text = "â±ï¸ " .. formatTime(currentSound.TimePosition) .. " / " .. formatTime(currentSound.TimeLength)

			-- Respaldo por si el evento Ended falla
			if not currentSound.IsPlaying and not isPaused and currentSound.TimePosition > 0 and currentSound.TimePosition >= currentSound.TimeLength - 0.2 then
				currentIndex = currentIndex + 1
				if currentIndex > #Playlist then currentIndex = 1 end
				loadMP3(Playlist[currentIndex])
			end
		end
	end
end)

-- Controles
extraTab:AddTextBox(" MP3 URL", function(val)
	MP3_URL = val
end, {["clear"] = false})

extraTab:AddButton("Play", function()
	if MP3_URL ~= "" then
		loadMP3(MP3_URL)
	end
end)

extraTab:AddButton("Continue", function()
	if currentSound then
		if isPaused then
			isPaused = false
			currentSound:Resume()
		else
			currentSound:Play()
		end
	end
end)

extraTab:AddButton("Pause", function()
	if currentSound and currentSound.IsPlaying then
		currentSound:Pause()
		isPaused = true
	end
end)

extraTab:AddButton("Stop", function()
	if currentSound then
		currentSound:Stop()
		isPaused = false
	end
end)

extraTab:AddTextBox("Volumen (0-5)", function(val)
	if currentSound then
		local num = tonumber(val)
		if num then
			currentSound.Volume = math.clamp(num, 0, 5)
		end
	end
end, {["clear"] = false})

extraTab:AddButton("Toggle Loop", function()
	if currentSound then
		currentSound.Looped = not currentSound.Looped
	end
end)

extraTab:AddButton("Add to Playlist", function()
    if not fileApiAvailable then
        warn("[Trayecto] Este executor no tiene soporte de archivos para la playlist.")
        return
    end
    if MP3_URL ~= "" then
		tempIndex = tempIndex + 1
		local tempFile = "GenesisMusic_"..tempIndex..".mp3"
		pcall(function()
			if isfile(tempFile) then delfile(tempFile) end
			writefile(tempFile, game:HttpGet(MP3_URL))
		end)
		table.insert(Playlist, MP3_URL)
		savePlaylist()
	end
end)

extraTab:AddButton("Play Playlist", function()
	if #Playlist > 0 then
		currentIndex = 1
		loadMP3(Playlist[currentIndex])
	end
end)

extraTab:AddButton("Next", function()
	if #Playlist > 0 then
		currentIndex = currentIndex + 1
		if currentIndex > #Playlist then currentIndex = 1 end
		loadMP3(Playlist[currentIndex])
	end
end)

extraTab:AddButton("Previous", function()
	if #Playlist > 0 then
		currentIndex = currentIndex - 1
		if currentIndex < 1 then currentIndex = #Playlist end
		loadMP3(Playlist[currentIndex])
	end
end)

extraTab:AddButton("Clear Playlist", function()
	Playlist = {}
	savePlaylist()
	currentIndex = 0
end)
extraTab:AddTextBox("Speed", function(value)
    local selectedSpeed = value
 
    _G.AutoSpeed = true
 
    if _G.AutoSpeed then
        if player.Character and player.Character:FindFirstChild("Humanoid") then
            player.Character.Humanoid.WalkSpeed = tonumber(selectedSpeed)
        end
    end
end)
 extraTab:AddButton('Claim All Chest ', function()
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').mythicalChest.circleInner, 0)
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').mythicalChest.circleInner, 1)
    wait()
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').magmaChest.circleInner, 0)
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').magmaChest.circleInner, 1)
    wait()
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').groupRewardsCircle.circleInner, 0)
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').groupRewardsCircle.circleInner, 1)
    wait()
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').goldenChest.circleInner, 0)
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').goldenChest.circleInner, 1)
    wait()
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').enchantedChest.circleInner, 0)
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').enchantedChest.circleInner, 1)
    wait()
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').legendsChest.circleInner, 0)
    firetouchinterest(player.Character.HumanoidRootPart, game:GetService('Workspace').legendsChest.circleInner, 1)
end)
extraTab:AddTextBox("Size", function(value)
    local selectedSize = value
 
    _G.AutoSize = true
 
    if _G.AutoSize then
        ReplicatedStorage.rEvents.changeSpeedSizeRemote:InvokeServer("changeSize", tonumber(selectedSize))
    end
end)
    extraTab:AddSwitch("Spin Fortune Wheel", function(state)
    _G.AutoSpinWheel = state

    if state then
        spawn(function()
            while _G.AutoSpinWheel and task.wait(0.1) do
                ReplicatedStorage.rEvents.openFortuneWheelRemote:InvokeServer(
                    "openFortuneWheel",
                    ReplicatedStorage.fortuneWheelChances["Fortune Wheel"]
                )
            end
        end)
    end
end)
extraTab:AddSwitch("Hide All Frames", function(state)
    local rSto = ReplicatedStorage

    for _, obj in pairs(rSto:GetDescendants()) do
        if obj:IsA("GuiObject") and obj.Name:match("Frames") then
            obj.Visible = not state
        end
    end

    if state then
        if _G.HideFramesConn then
            _G.HideFramesConn:Disconnect()
        end
        _G.HideFramesConn = rSto.DescendantAdded:Connect(function(obj)
            if obj:IsA("GuiObject") and obj.Name:match("Frames") then
                obj.Visible = false
            end
        end)
    else
        if _G.HideFramesConn then
            _G.HideFramesConn:Disconnect()
            _G.HideFramesConn = nil
        end
        for _, obj in pairs(rSto:GetDescendants()) do
            if obj:IsA("GuiObject") and obj.Name:match("Frames") then
                obj.Visible = true
            end
        end
    end
end)


extraTab:AddButton("Gamepass AutoLift", function()

    local gamepassIds = ReplicatedStorage:WaitForChild("gamepassIds")

    for _, gamepass in ipairs(gamepassIds:GetChildren()) do
        local owned = Instance.new("IntValue")
        owned.Name = gamepass.Name
        owned.Value = gamepass.Value
        owned.Parent = player:WaitForChild("ownedGamepasses")
    end

    print("[Gamepass AutoLift] Todos los gamepasses fueron agregados localmente.")

end)

extraTab:AddButton("Anti Lag", function()
    for _, v in pairs(game:GetDescendants()) do
        if v:IsA("ParticleEmitter") or v:IsA("Smoke") or v:IsA("Fire") or v:IsA("Sparkles") then
            v.Enabled = false
        end
    end
 
    local lighting = Lighting
    lighting.GlobalShadows = false
    lighting.FogEnd = 9e9
    lighting.Brightness = 0
 
    settings().Rendering.QualityLevel = 1
 
    for _, v in pairs(game:GetDescendants()) do
        if v:IsA("Decal") or v:IsA("Texture") then
            v.Transparency = 1
        elseif v:IsA("BasePart") and not v:IsA("MeshPart") then
            v.Material = Enum.Material.SmoothPlastic
            if v.Parent and (v.Parent:FindFirstChild("Humanoid") or v.Parent.Parent:FindFirstChild("Humanoid")) then
            else
                v.Reflectance = 0
            end
        end
    end
 
    for _, v in pairs(lighting:GetChildren()) do
        if v:IsA("BlurEffect") or v:IsA("SunRaysEffect") or v:IsA("ColorCorrectionEffect") or v:IsA("BloomEffect") or v:IsA("DepthOfFieldEffect") then
            v.Enabled = false
        end
    end
 
    StarterGui:SetCore("SendNotification", {
        Title = "anti lag activado",
        Text = "Full optimization applied!",
        Duration = 5
    })
end)
extraTab:AddButton("Remove Portals", function()
    for _, portal in pairs(game:GetDescendants()) do
        if portal.Name == "RobloxForwardPortals" then
            portal:Destroy()
        end
    end
    
    if _G.AdRemovalConnection then
        _G.AdRemovalConnection:Disconnect()
    end
    
    _G.AdRemovalConnection = game.DescendantAdded:Connect(function(descendant)
        if descendant.Name == "RobloxForwardPortals" then
            descendant:Destroy()
        end
    end)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Anuncios Eliminados",
        Text = "Los anuncios de Roblox han sido eliminados",
        Duration = 0
    })
end)
extraTab:AddButton("Claim Codes", function()

    local Event = ReplicatedStorage.rEvents.codeRemote

    local codes = {
        "superpunch100",
        "supermuscle100",
        "speedy50",
        "spacegems50",
        "Skyagility50",
        "musclestorm50",
        "megalift50",
        "launch250",
        "galaxycrystal50",
        "frostgems10",
        "epicreward500",
        "MillionWarriors"
    }

    for _, code in ipairs(codes) do
        Event:InvokeServer(code)
        task.wait(0.5)
    end

    StarterGui:SetCore("SendNotification", {
        Title = "Codes",
        Text = "Claim Done",
        Duration = 5
    })

end)
end

local Gift = window:AddTab("Auto Gift")
local RS = ReplicatedStorage


-- Labels for item counts
Gift:AddLabel("Gifting Protein egg:").TextSize = 22
local proteinEggLabel = Gift:AddLabel("Protein Eggs: 0")
proteinEggLabel.TextSize = 20

Gift:AddLabel("Gifting Tropical Shakes:").TextSize = 22
local tropicalShakeLabel = Gift:AddLabel("Tropical Shakes: 0")
tropicalShakeLabel.TextSize = 18

-- Dropdown helper
local function createPlayerDropdown(title, callback)
	local drop = Gift:AddDropdown(title, callback)
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= player then drop:Add(plr.DisplayName) end
	end
	Players.PlayerAdded:Connect(function(plr)
		if plr ~= player then drop:Add(plr.DisplayName) end
	end)
	return drop
end

-- Protein Egg gifting
local selectedEggPlayer = nil
local eggCount = 0

createPlayerDropdown("Player to Gift Eggs", function(display)
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.DisplayName == display then
			selectedEggPlayer = plr
			break
		end
	end
end)

Gift:AddTextBox("Amount of Eggs", function(text)
	eggCount = tonumber(text) or 0
end)

Gift:AddButton("Gift Eggs", function()
	if not selectedEggPlayer or eggCount <= 0 then return end
	for _ = 1, eggCount do
		local egg = player.consumablesFolder:FindFirstChild("Protein Egg")
		if egg then
			RS.rEvents.giftRemote:InvokeServer("giftRequest", selectedEggPlayer, egg)
			task.wait(0.1)
		end
	end
end)

-- Tropical Shake gifting
local selectedShakePlayer = nil
local shakeCount = 0

createPlayerDropdown("Player to Gift Tropical Shakes", function(display)
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.DisplayName == display then
			selectedShakePlayer = plr
			break
		end
	end
end)

Gift:AddTextBox("Tropical Shakes gift", function(text)
	shakeCount = tonumber(text) or 0
end)

Gift:AddButton("Gift Tropical Shakes", function()
	if not selectedShakePlayer or shakeCount <= 0 then return end
	for _ = 1, shakeCount do
		local shake = player.consumablesFolder:FindFirstChild("Tropical Shake")
		if shake then
			RS.rEvents.giftRemote:InvokeServer("giftRequest", selectedShakePlayer, shake)
			task.wait(0.1)
		end
	end
end)

-- Update item counts
local function updateItemCount()
	local eggs, shakes = 0, 0
	for _, item in ipairs(player.Backpack:GetChildren()) do
		if item.Name == "Protein Egg" then
			eggs = eggs + 1
		elseif item.Name == "Tropical Shake" then
			shakes = shakes + 1
		end
	end
	proteinEggLabel.Text = "Protein Eggs: " .. eggs
	tropicalShakeLabel.Text = "Tropical Shakes: " .. shakes
end

task.spawn(function()
	while true do
		updateItemCount()
		task.wait(0.25)
	end
end)

-- Auto Eat System
local itemList = {
	"Tropical Shake", "Energy Shake", "Protein Bar",
	"TOUGH Bar", "Protein Shake", "ULTRA Shake", "Energy Bar"
}

local function formatEventName(name)
	local parts = {}
	for word in name:gmatch("%S+") do parts[#parts+1] = word:lower() end
	for i = 2, #parts do
		parts[i] = parts[i]:sub(1,1):upper() .. parts[i]:sub(2)
	end
	return table.concat(parts)
end

local function activateRandomItems(count)
	local items = {unpack(itemList)}
	for i = #items, 2, -1 do
		local j = math.random(i)
		items[i], items[j] = items[j], items[i]
	end
	for i = 1, math.min(count, #items) do
		local name = items[i]
		local tool = player.Character:FindFirstChild(name) or player.Backpack:FindFirstChild(name)
		if tool then
			player.muscleEvent:FireServer(formatEventName(name), tool)
		end
	end
end

local eatingRunning = false
task.spawn(function()
	while true do
		if eatingRunning then activateRandomItems(4) end
		task.wait(0.5)
	end
end)

Gift:AddButton("Eat Everything", function(state)
	eatingRunning = state
	if state then activateRandomItems(4) end
end)

-- Requiere que ya tengas creado el Tab (acÃ¡ lo llamo StatsTab) y las
-- variables player / leaderstats como en el resto de tus scripts.

local StatsTab = window:AddTab("Stats")

local targetName = ""
local playerDropdown = StatsTab:AddDropdown("Select Player", function(value)
	-- El dropdown muestra "DisplayName | Name", nos quedamos con el Name real
	targetName = value:match("| (.+)")
end)

for _, plr in pairs(Players:GetPlayers()) do
	playerDropdown:Add(plr.DisplayName .. " | " .. plr.Name)
end

Players.PlayerAdded:Connect(function(plr)
	playerDropdown:Add(plr.DisplayName .. " | " .. plr.Name)
end)

local function formatNumber(number)
	-- Igual que en tu farming_stats.lua: agrega separador de miles y
	-- sufijo (K/M/B/T/Qa/Qi)
	local suffixes = {"", "K", "M", "B", "T", "Qa", "Qi"}
	local index = 1
	while number >= 1000 and index < #suffixes do
		number = number / 1000
		index = index + 1
	end
	return string.format("%.2f", number) .. suffixes[index]
end

-- CuÃ¡ntas mascotas de "petName" tiene equipadas el jugador dado
local function countEquippedPets(plr, petName)
	local equippedPets = plr:FindFirstChild("equippedPets")
	if not equippedPets then
		return 0
	end
	local count = 0
	for _, entry in pairs(equippedPets:GetChildren()) do
		local ref = entry:FindFirstChild("petReference")
		if ref and ref.Value and ref.Value.Name == petName then
			count = count + 1
		end
	end
	return count
end

local wildWizardLabel -- se asigna mÃ¡s abajo, junto con los demÃ¡s labels

-- Tu daÃ±o: 10% de tu Strength, + 33% de bonus por cada Wild Wizard equipado
local function calculateYourDamage()
	local strength = player:FindFirstChild("leaderstats")
		and player.leaderstats:FindFirstChild("Strength")
	if not strength then
		return 0
	end

	local base = strength.Value * 0.1
	local wildWizardCount = countEquippedPets(player, "Wild Wizard")
	local bonusMultiplier = wildWizardCount * 0.33

	if wildWizardLabel then
		wildWizardLabel.Text = "Wild Wizard equipped: " .. wildWizardCount
			.. " (" .. formatNumber(base * bonusMultiplier) .. " bonus)"
	end

	return base * (1 + bonusMultiplier)
end

-- Vida del objetivo: su Durability (con posible bonus de "Infernal Health",
-- ver nota abajo)
local function calculateEnemyLife(targetPlayer)
	if not targetPlayer then
		return 0
	end
	local durability = targetPlayer:FindFirstChild("Durability")
	return durability and durability.Value or 0
end

-- Golpes necesarios: vida / daÃ±o, redondeado hacia arriba; âˆž si da mÃ¡s de 50
local function calculateBlowsToKill(enemyLife, yourDamage)
	if yourDamage <= 0 then
		return "âˆž"
	end
	local blows = math.ceil(enemyLife / yourDamage)
	if blows > 50 then
		return "âˆž"
	end
	return tostring(math.max(blows, 1))
end

-- --- Labels ---

local enemyLifeLabel = StatsTab:AddLabel("Enemy life: N/A")
local yourDamageLabel = StatsTab:AddLabel("Your damage: N/A")
local blowsToKillLabel = StatsTab:AddLabel("Blows to kill him: N/A")
wildWizardLabel = StatsTab:AddLabel("Wild Wizard equipped: 0 (0 bonus)")

local goodKarmaLabel = StatsTab:AddLabel("Good Karma: N/A")
local evilKarmaLabel = StatsTab:AddLabel("Evil Karma: N/A")

local function updateStats(targetPlayer)
	if not targetPlayer then
		enemyLifeLabel.Text = "Enemy life: N/A"
		yourDamageLabel.Text = "Your damage: N/A"
		blowsToKillLabel.Text = "Blows to kill him: N/A"
		goodKarmaLabel.Text = "Good Karma: N/A"
		evilKarmaLabel.Text = "Evil Karma: N/A"
		return
	end

	local enemyLife = calculateEnemyLife(targetPlayer)
	local yourDamage = calculateYourDamage()

	enemyLifeLabel.Text = "Enemy life: " .. (enemyLife > 0 and formatNumber(enemyLife) or "N/A")
	yourDamageLabel.Text = "Your damage: " .. (yourDamage > 0 and formatNumber(yourDamage) or "N/A")
	blowsToKillLabel.Text = "Blows to kill him: " .. calculateBlowsToKill(enemyLife, yourDamage)

	local goodKarma = targetPlayer:FindFirstChild("goodKarma")
	local evilKarma = targetPlayer:FindFirstChild("evilKarma")
	goodKarmaLabel.Text = "Good Karma: " .. (goodKarma and formatNumber(goodKarma.Value) or "N/A")
	evilKarmaLabel.Text = "Evil Karma: " .. (evilKarma and formatNumber(evilKarma.Value) or "N/A")
end

task.spawn(function()
	while true do
		local targetPlayer = targetName ~= "" and Players:FindFirstChild(targetName)
		updateStats(targetPlayer)
		task.wait() -- se recalcula todos los frames, igual que el original
	end
end)



local teleport = window:AddTab("Tp")

teleport:AddButton("Spawn", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(2, 8, 115)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Spawn",
        Duration = 0
    })
end)

teleport:AddButton("Secret Area", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(1947, 2, 6191)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Secret Area",
        Duration = 0
    })
end)

teleport:AddButton("Tiny Island", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(-34, 7, 1903)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Tiny Island",
        Duration = 0
    })
end)

teleport:AddButton("Frozen Island", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(- 2600.00244, 3.67686558, - 403.884369, 0.0873617008, 1.0482899e-09, 0.99617666, 3.07204253e-08, 1, - 3.7464023e-09, - 0.99617666, 3.09302628e-08, 0.0873617008)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Frozen Island",
        Duration = 0
    })
end)

teleport:AddButton("Mythical Island", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(2255, 7, 1071)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Mythical Island",
        Duration = 0
    })
end)

teleport:AddButton("Hell Island", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(-6768, 7, -1287)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Hell Island",
        Duration = 0
    })
end)

teleport:AddButton("Legend Island", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(4604, 991, -3887)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Legend Island",
        Duration = 0
    })
end)

teleport:AddButton("Muscle King Island", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(-8646, 17, -5738)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Muscle King",
        Duration = 0
    })
end)

teleport:AddButton("Jungle Island", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(-8659, 6, 2384)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Jungle Island",
        Duration = 0
    })
end)

teleport:AddButton("Brawl Lava", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(4471, 119, -8836)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Brawl Lava",
        Duration = 0
    })
end)

teleport:AddButton("Brawl Desert", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(960, 17, -7398)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Brawl Desert",
        Duration = 0
    })
end)

teleport:AddButton("Brawl Regular", function()
    local character = player.Character or player.CharacterAdded:Wait()
    local humanoidRootPart = character:WaitForChild("HumanoidRootPart")
    humanoidRootPart.CFrame = CFrame.new(-1849, 20, -6335)
    
    StarterGui:SetCore("SendNotification", {
        Title = "Teletransporte",
        Text = "Teleported to Brawl Regular",
        Duration = 0
    })
end)


local Killer = window:AddTab("Kills op")

local playerWhitelist = {}
local targetPlayerNames = {}
local autoGoodKarma = false
local autoBadKarma = false
local autoKill = false
local killTarget = false
local spying = false
local autoEquipPunch = false
local autoPunchNoAnim = false
local targetDropdownItems = {}
local availableTargets = {}

local titleLabel = Killer:AddLabel("Equipar pet de dura o daño")
titleLabel.TextSize = 14
titleLabel.Font = Enum.Font.Merriweather 
titleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)

local dropdown = Killer:AddDropdown("Select Pet", function(text)
    local petsFolder = player.petsFolder
    for _, folder in pairs(petsFolder:GetChildren()) do
        if folder:IsA("Folder") then
            for _, pet in pairs(folder:GetChildren()) do
                ReplicatedStorage.rEvents.equipPetEvent:FireServer("unequipPet", pet)
            end
        end
    end
    task.wait(0.2)

    local petName = text
    local petsToEquip = {}

    for _, pet in pairs(player.petsFolder.Unique:GetChildren()) do
        if pet.Name == petName then
            table.insert(petsToEquip, pet)
        end
    end

    local maxPets = 8
    local equippedCount = math.min(#petsToEquip, maxPets)

    for i = 1, equippedCount do
        ReplicatedStorage.rEvents.equipPetEvent:FireServer("equipPet", petsToEquip[i])
        task.wait(0.1)
    end
end)

local Wild_Wizard = dropdown:Add("Wild Wizard")
local Powerful_Monster = dropdown:Add("Mighty Monster")

Killer:AddSwitch("Auto Good Karma", function(bool)
    autoGoodKarma = bool
    task.spawn(function()
        while autoGoodKarma do
            local playerChar = player.Character
            local rightHand = playerChar and playerChar:FindFirstChild("RightHand")
            local leftHand = playerChar and playerChar:FindFirstChild("LeftHand")
            
            if playerChar and rightHand and leftHand then
                for _, target in ipairs(Players:GetPlayers()) do
                    if target ~= player then
                        local evilKarma = target:FindFirstChild("evilKarma")
                        local goodKarma = target:FindFirstChild("goodKarma")
                        
                        if evilKarma and goodKarma and evilKarma:IsA("IntValue") and goodKarma:IsA("IntValue") and evilKarma.Value > goodKarma.Value then
                            local rootPart = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
                            if rootPart then
                                firetouchinterest(rightHand, rootPart, 1)
                                firetouchinterest(leftHand, rootPart, 1)
                                firetouchinterest(rightHand, rootPart, 0)
                                firetouchinterest(leftHand, rootPart, 0)
                            end
                        end
                    end
                end
            end
            task.wait(0.01)
        end
    end)
end)
Killer:AddSwitch("Auto Bad Karma", function(bool)
    autoBadKarma = bool
    task.spawn(function()
        while autoBadKarma do
            local playerChar = player.Character
            local rightHand = playerChar and playerChar:FindFirstChild("RightHand")
            local leftHand = playerChar and playerChar:FindFirstChild("LeftHand")
            
            if playerChar and rightHand and leftHand then
                for _, target in ipairs(Players:GetPlayers()) do
                    if target ~= player and target.Character then
                        local evilKarma = target:FindFirstChild("evilKarma")
                        local goodKarma = target:FindFirstChild("goodKarma")
                        local rootPart = target.Character:FindFirstChild("HumanoidRootPart")
                        
                        if evilKarma and goodKarma and rootPart and 
                           evilKarma:IsA("IntValue") and goodKarma:IsA("IntValue") and 
                           goodKarma.Value > evilKarma.Value then
                            
                            -- ATACAR
                            firetouchinterest(rightHand, rootPart, 1)
                            firetouchinterest(leftHand, rootPart, 1)
                            firetouchinterest(rightHand, rootPart, 0)
                            firetouchinterest(leftHand, rootPart, 0)
                        end
                    end
                end
            end
            -- Espera un poco para que el juego procese
            task.wait(0.01)
        end
    end)
end)

local friendWhitelistActive = false

Killer:AddSwitch("Auto Whitelist Friends", function(state)
    friendWhitelistActive = state

    if state then
        for _, targetPlayer in ipairs(Players:GetPlayers()) do
            if targetPlayer ~= player and player:IsFriendsWith(targetPlayer.UserId) then
                playerWhitelist[targetPlayer.Name] = true
            end
        end

        Players.PlayerAdded:Connect(function(targetPlayer)
            if friendWhitelistActive and targetPlayer ~= player and player:IsFriendsWith(targetPlayer.UserId) then
                playerWhitelist[targetPlayer.Name] = true
            end
        end)
    else
        for name in pairs(playerWhitelist) do
            local friend = Players:FindFirstChild(name)
            if friend and player:IsFriendsWith(friend.UserId) then
                playerWhitelist[name] = nil
            end
        end
    end
end)

Killer:AddTextBox("Whitelist", function(text)
    local target = Players:FindFirstChild(text)
    if target then
        playerWhitelist[target.Name] = true
    end
end)

Killer:AddTextBox("UnWhitelist", function(text)
    local target = Players:FindFirstChild(text)
    if target then
        playerWhitelist[target.Name] = nil
    end
end)

Killer:AddSwitch("Auto Kill", function(bool)
    autoKill = bool

    task.spawn(function()
        while autoKill do
            local character = player.Character or player.CharacterAdded:Wait()
            local rightHand = character:FindFirstChild("RightHand")
            local leftHand = character:FindFirstChild("LeftHand")

            local punch = player.Backpack:FindFirstChild("Punch")
            if punch and not character:FindFirstChild("Punch") then
                punch.Parent = character
            end

            if rightHand and leftHand then
                for _, target in ipairs(Players:GetPlayers()) do
                    if target ~= player and not playerWhitelist[target.Name] then
                        local targetChar = target.Character
                        local rootPart = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
                        if rootPart then
                            pcall(function()
                                firetouchinterest(rightHand, rootPart, 1)
                                firetouchinterest(leftHand, rootPart, 1)
                                firetouchinterest(rightHand, rootPart, 0)
                                firetouchinterest(leftHand, rootPart, 0)
								firetouchinterest(rightHand, rootPart, 1)
                                firetouchinterest(leftHand, rootPart, 1)
                                firetouchinterest(rightHand, rootPart, 0)
                                firetouchinterest(leftHand, rootPart, 0)
								firetouchinterest(rightHand, rootPart, 1)
                                firetouchinterest(leftHand, rootPart, 1)
                                firetouchinterest(rightHand, rootPart, 0)
                                firetouchinterest(leftHand, rootPart, 0)
                            end)
                        end
                    end
                end
            end

            task.wait(0.1)
        end
    end)
end)

local targetDropdown = Killer:AddDropdown("Select Target", function(name)
    if name and not table.find(targetPlayerNames, name) then
        table.insert(targetPlayerNames, name)
    end
end)

Killer:AddTextBox("Remove Target", function(name)
    for i, v in ipairs(targetPlayerNames) do
        if v == name then
            table.remove(targetPlayerNames, i)
            break
        end
    end
end)

for _, targetPlayer in ipairs(Players:GetPlayers()) do
    if targetPlayer ~= player then
        targetDropdown:Add(targetPlayer.Name)
        targetDropdownItems[targetPlayer.Name] = true
    end
end

Players.PlayerAdded:Connect(function(targetPlayer)
    if targetPlayer ~= player then
        targetDropdown:Add(targetPlayer.Name)
        targetDropdownItems[targetPlayer.Name] = true
    end
end)

Players.PlayerRemoving:Connect(function(removedPlayer)
    if targetDropdownItems[removedPlayer.Name] then
        targetDropdownItems[removedPlayer.Name] = nil
        targetDropdown:Clear()
        for name in pairs(targetDropdownItems) do
            targetDropdown:Add(name)
        end
    end

    for i = #targetPlayerNames, 1, -1 do
        if targetPlayerNames[i] == removedPlayer.Name then
            table.remove(targetPlayerNames, i)
        end
    end
end)

Killer:AddSwitch("Start Kill Target", function(state)
    killTarget = state

    task.spawn(function()
        while killTarget do
            local character = player.Character or player.CharacterAdded:Wait()

            local punch = player.Backpack:FindFirstChild("Punch")
            if punch and not character:FindFirstChild("Punch") then
                punch.Parent = character
            end

            local rightHand = character:WaitForChild("RightHand", 5)
            local leftHand = character:WaitForChild("LeftHand", 5)
					local rightHand = character:WaitForChild("RightHand", 5)
            local leftHand = character:WaitForChild("LeftHand", 5)
						local rightHand = character:WaitForChild("RightHand", 5)
            local leftHand = character:WaitForChild("LeftHand", 5)

            if rightHand and leftHand then
                for _, name in ipairs(targetPlayerNames) do
                    local target = Players:FindFirstChild(name)
                    if target and target ~= player then
                        local rootPart = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
                        if rootPart then
                            pcall(function()
                                firetouchinterest(rightHand, rootPart, 1)
                                firetouchinterest(leftHand, rootPart, 1)
                                firetouchinterest(rightHand, rootPart, 0)
                                firetouchinterest(leftHand, rootPart, 0)
												firetouchinterest(rightHand, rootPart, 1)
                                firetouchinterest(leftHand, rootPart, 1)
                                firetouchinterest(rightHand, rootPart, 0)
                                firetouchinterest(leftHand, rootPart, 0)
												firetouchinterest(rightHand, rootPart, 1)
                                firetouchinterest(leftHand, rootPart, 1)
                                firetouchinterest(rightHand, rootPart, 0)
                                firetouchinterest(leftHand, rootPart, 0)
                            end)
                        end
                    end
                end
            end

            task.wait(0.1)
        end
    end)
end)

local spyTargetDropdown = Killer:AddDropdown("Select View Target", function(name)
    targetPlayerName = name
end)

for _, targetPlayer in ipairs(Players:GetPlayers()) do
    if targetPlayer ~= player then
        spyTargetDropdown:Add(targetPlayer.Name)
    end
end

Players.PlayerAdded:Connect(function(targetPlayer)
    if targetPlayer ~= player then
        spyTargetDropdown:Add(targetPlayer.Name)
    end
end)

Players.PlayerRemoving:Connect(function(removedPlayer)
    spyTargetDropdown:Clear()
    for _, targetPlayer in ipairs(Players:GetPlayers()) do
        if targetPlayer ~= player then
            spyTargetDropdown:Add(targetPlayer.Name)
        end
    end
    if targetPlayerName == removedPlayer.Name then
        targetPlayerName = nil
        spying = false
    end
end)

Killer:AddSwitch("View Player", function(bool)
    spying = bool
    if not spying then
        local cam = workspace.CurrentCamera
        cam.CameraSubject = player.Character and player.Character:FindFirstChild("Humanoid") or player
        return
    end
    task.spawn(function()
        while spying do
            local target = Players:FindFirstChild(targetPlayerName)
            if target and target ~= player then
                local humanoid = target.Character and target.Character:FindFirstChild("Humanoid")
                if humanoid then
                    workspace.CurrentCamera.CameraSubject = humanoid
                end
            end
            task.wait(0.1)
        end
    end)
end)

local button = Killer:AddButton("Remove Punch Anim", function()
    local blockedAnimations = {
        ["rbxassetid://3638729053"] = true,
        ["rbxassetid://3638767427"] = true,
    }

    local function setupAnimationBlocking()
        local char = player.Character
        if not char or not char:FindFirstChild("Humanoid") then return end

        local humanoid = char:FindFirstChild("Humanoid")

        for _, track in pairs(humanoid:GetPlayingAnimationTracks()) do
            if track.Animation then
                local animId = track.Animation.AnimationId
                local animName = track.Name:lower()

                if blockedAnimations[animId] or
                    animName:match("punch") or
                    animName:match("attack") or
                    animName:match("right") then
                    track:Stop()
                end
            end
        end

        if not _G.AnimBlockConnection then
            local connection = humanoid.AnimationPlayed:Connect(function(track)
                if track.Animation then
                    local animId = track.Animation.AnimationId
                    local animName = track.Name:lower()

                    if blockedAnimations[animId] or
                        animName:match("punch") or
                        animName:match("attack") or
                        animName:match("right") then
                        track:Stop()
                    end
                end
            end)

            _G.AnimBlockConnection = connection
        end
    end

    setupAnimationBlocking()

    local function overrideToolActivation()
        local function processTool(tool)
            if tool and (tool.Name == "Punch" or tool.Name:match("Attack") or tool.Name:match("Right")) then
                if not tool:GetAttribute("ActivatedOverride") then
                    tool:SetAttribute("ActivatedOverride", true)

                    local connection = tool.Activated:Connect(function()
                        task.wait(0.05)

                        local char = player.Character
                        if char and char:FindFirstChild("Humanoid") then
                            for _, track in pairs(char.Humanoid:GetPlayingAnimationTracks()) do
                                if track.Animation then
                                    local animId = track.Animation.AnimationId
                                    local animName = track.Name:lower()

                                    if blockedAnimations[animId] or
                                        animName:match("punch") or
                                        animName:match("attack") or
                                        animName:match("right") then
                                        track:Stop()
                                    end
                                end
                            end
                        end
                    end)

                    if not _G.ToolConnections then
                        _G.ToolConnections = {}
                    end
                    _G.ToolConnections[tool] = connection
                end
            end
        end

        for _, tool in pairs(player.Backpack:GetChildren()) do
            processTool(tool)
        end

        local char = player.Character
        if char then
            for _, tool in pairs(char:GetChildren()) do
                if tool:IsA("Tool") then
                    processTool(tool)
                end
            end
        end

        if not _G.BackpackAddedConnection then
            _G.BackpackAddedConnection = player.Backpack.ChildAdded:Connect(function(child)
                if child:IsA("Tool") then
                    task.wait(0.1)
                    processTool(child)
                end
            end)
        end

        if not _G.CharacterToolAddedConnection and char then
            _G.CharacterToolAddedConnection = char.ChildAdded:Connect(function(child)
                if child:IsA("Tool") then
                    task.wait(0.1)
                    processTool(child)
                end
            end)
        end
    end

    overrideToolActivation()

    if not _G.AnimMonitorConnection then
        _G.AnimMonitorConnection = RunService.Heartbeat:Connect(function()
            if tick() % 0.5 < 0.01 then
                local char = player.Character
                if char and char:FindFirstChild("Humanoid") then
                    for _, track in pairs(char.Humanoid:GetPlayingAnimationTracks()) do
                        if track.Animation then
                            local animId = track.Animation.AnimationId
                            local animName = track.Name:lower()

                            if blockedAnimations[animId] or
                                animName:match("punch") or
                                animName:match("attack") or
                                animName:match("right") then
                                track:Stop()
                            end
                        end
                    end
                end
            end
        end)
    end

    if not _G.CharacterAddedConnection then
        _G.CharacterAddedConnection = player.CharacterAdded:Connect(function(newChar)
            task.wait(1)
            setupAnimationBlocking()
            overrideToolActivation()

            if _G.CharacterToolAddedConnection then
                _G.CharacterToolAddedConnection:Disconnect()
            end

            _G.CharacterToolAddedConnection = newChar.ChildAdded:Connect(function(child)
                if child:IsA("Tool") then
                    task.wait(0.1)
                    processTool(child)
                end
            end)
        end)
    end
end)

function RecoveryPunch()
    if _G.AnimBlockConnection then
        _G.AnimBlockConnection:Disconnect()
        _G.AnimBlockConnection = nil
    end
    if _G.AnimMonitorConnection then
        _G.AnimMonitorConnection:Disconnect()
        _G.AnimMonitorConnection = nil
    end
    if _G.ToolConnections then
        for _, conn in pairs(_G.ToolConnections) do
            if conn then conn:Disconnect() end
        end
        _G.ToolConnections = nil
    end
    if _G.BackpackAddedConnection then
        _G.BackpackAddedConnection:Disconnect()
        _G.BackpackAddedConnection = nil
    end
    if _G.CharacterToolAddedConnection then
        _G.CharacterToolAddedConnection:Disconnect()
        _G.CharacterToolAddedConnection = nil
    end
    if _G.CharacterAddedConnection then
        _G.CharacterAddedConnection:Disconnect()
        _G.CharacterAddedConnection = nil
    end
end

Killer:AddButton("Recover Punch Anim", function()
    RecoveryPunch()
end)

Killer:AddSwitch("Auto Equip Punch", function(state)
	autoEquipPunch = state
	task.spawn(function()
		while autoEquipPunch do
			local punch = player.Backpack:FindFirstChild("Punch")
			if punch then
				punch.Parent = player.Character
			end
			task.wait(0.1)
		end
	end)
end)

Killer:AddSwitch("Auto golpear [sin animación]", function(state)
	autoPunchNoAnim = state
	task.spawn(function()
		while autoPunchNoAnim do
			local punch = player.Backpack:FindFirstChild("Punch") or player.Character and player.Character:FindFirstChild("Punch")
			if punch then
				if punch.Parent ~= player.Character then
					punch.Parent = player.Character
				end
				player.muscleEvent:FireServer("punch", "rightHand")
				player.muscleEvent:FireServer("punch", "leftHand")
			else
				autoPunchNoAnim = false
			end
			task.wait(0.01)
		end
	end)
end)

Killer:AddSwitch("Auto Punch", function(state)
	_G.fastHitActive = state
	if state then
		task.spawn(function()
			while _G.fastHitActive do
				local punch = player.Backpack:FindFirstChild("Punch")
				if punch then
					punch.Parent = player.Character
					if punch:FindFirstChild("attackTime") then
						punch.attackTime.Value = 0
					end
				end
				task.wait(0.1)
			end
		end)
		task.spawn(function()
			while _G.fastHitActive do
				local punch = player.Character and player.Character:FindFirstChild("Punch")
				if punch then
					punch:Activate()
				end
				task.wait(0.1)
			end
		end)
	else
		local punch = player.Character and player.Character:FindFirstChild("Punch")
		if punch then
			punch.Parent = player.Backpack
		end
	end
end)

Killer:AddSwitch("golpe rápido", function(state)
	_G.autoPunchActive = state
	if state then
		task.spawn(function()
			while _G.autoPunchActive do
				local punch = player.Backpack:FindFirstChild("Punch")
				if punch then
					punch.Parent = player.Character
					if punch:FindFirstChild("attackTime") then
						punch.attackTime.Value = 0
					end
				end
				task.wait()
			end
		end)
		task.spawn(function()
			while _G.autoPunchActive do
				local punch = player.Character and player.Character:FindFirstChild("Punch")
				if punch then
					punch:Activate()
				end
				task.wait()
			end
		end)
	else
		local punch = player.Character and player.Character:FindFirstChild("Punch")
		if punch then
			punch.Parent = player.Backpack
		end
	end
end)



local godModeToggle = false
Killer:AddSwitch("modo dios (esperar peleas)", function(State)
    godModeToggle = State
    if State then
        task.spawn(function()
            while godModeToggle do
                ReplicatedStorage.rEvents.brawlEvent:FireServer("joinBrawl")
                task.wait()
            end
        end)
    end
end)
-- 📌 Teleport / Follow System (versión auto-follow desde Dropdown)

-- 📌 Auto Follow (TP detrás del jugador en vez de caminar)
local following = false
local followTarget = nil

-- Función auxiliar: TP detrás del jugador
function followPlayer(targetPlayer)
    local myChar = player.Character
    local targetChar = targetPlayer.Character

    if not (myChar and targetChar) then return end
    local myHRP = myChar:FindFirstChild("HumanoidRootPart")
    local targetHRP = targetChar:FindFirstChild("HumanoidRootPart")

    if myHRP and targetHRP then
        -- 📌 Calcular posición detrás del jugador (3 studs atrás)
        local followPos = targetHRP.Position - (targetHRP.CFrame.LookVector * 3)
        -- 📌 Teletransportar siempre recto
        myHRP.CFrame = CFrame.new(followPos, targetHRP.Position)
    end
end

-- Dropdown dinámico de jugadores
local followDropdown = Killer:AddDropdown("Seguir Jugador (TP)", function(selected)
    if selected and selected ~= "" then
        local target = Players:FindFirstChild(selected)
        if target then
            followTarget = target.Name
            following = true
            print("Started following:", target.Name)

            -- TP inmediato al seleccionarlo
            followPlayer(target)
        end
    end
end)

-- Inicializar lista de jugadores
for _, targetPlayer in ipairs(Players:GetPlayers()) do
    if targetPlayer ~= player then
        followDropdown:Add(targetPlayer.Name)
    end
end

-- Mantener lista actualizada
Players.PlayerAdded:Connect(function(targetPlayer)
    if targetPlayer ~= player then
        followDropdown:Add(targetPlayer.Name)
    end
end)

Players.PlayerRemoving:Connect(function(removedPlayer)
    followDropdown:Clear()
    for _, targetPlayer in ipairs(Players:GetPlayers()) do
        if targetPlayer ~= player then
            followDropdown:Add(targetPlayer.Name)
        end
    end
    if followTarget == removedPlayer.Name then
        followTarget = nil
        following = false
    end
end)

-- Botón para dejar de seguir
Killer:AddButton("Dejar de Seguir", function()
    following = false
    followTarget = nil
    print("Stopped following")
end)

-- Loop de seguimiento automático
task.spawn(function()
    while true do
        task.wait(0.2) -- cada 0.2s para actualizar TP
        if following and followTarget then
            local target = Players:FindFirstChild(followTarget)
            if target then
                followPlayer(target)
            else
                following = false
                followTarget = nil
            end
        end
    end
end)

local godDamageActive = false

Killer:AddSwitch("Daño con Godmode", function(state)
    godDamageActive = state
    if state then
        task.spawn(function()
            while godDamageActive do
                local groundSlam = player.Backpack:FindFirstChild("Ground Slam") or (player.Character and player.Character:FindFirstChild("Ground Slam"))

                if groundSlam then
                    -- Equipar
                    if groundSlam.Parent == player.Backpack then
                        groundSlam.Parent = player.Character
                    end

                    -- Quitar delay
                    if groundSlam:FindFirstChild("attackTime") then
                        groundSlam.attackTime.Value = 0
                    end

                    -- Lanzar evento
                    player.muscleEvent:FireServer("slam")

                    -- Activar herramienta
                    groundSlam:Activate()
                end

                task.wait(0.1) -- delay pequeño
            end
        end)
    end
end)

Killer:AddButton("Tamaño NaN", function()
    local args = {"changeSize", 0/0}
    ReplicatedStorage:WaitForChild("rEvents"):WaitForChild("changeSpeedSizeRemote"):InvokeServer(unpack(args))
end)
-- 📜 Lista de RAWs a ejecutar
local urls = {
    "https://raw.githubusercontent.com/SadOz8/Stuffs/refs/heads/main/Crack",
    "https://raw.githubusercontent.com/SadOz8/Stuffs/refs/heads/main/Crack2",
    "https://raw.githubusercontent.com/SadOz8/Stuffs/refs/heads/main/Crack3",
    "https://raw.githubusercontent.com/SadOz8/Stuffs/refs/heads/main/Crack4",
    "https://raw.githubusercontent.com/SadOz8/Stuffs/refs/heads/main/Crack5",
    "https://raw.githubusercontent.com/SadOz8/Stuffs/refs/heads/main/Crack6"
}

-- ⚡ Botón que ejecuta todos los scripts remotos
Killer:AddButton("Pegar Muerto", function()
    for _, url in ipairs(urls) do
        spawn(function()
            local success, response = pcall(function()
                return game:HttpGet(url)
            end)
            if success and response then
                local loadSuccess, err = pcall(function()
                    local compiler = loadstring or load
if type(compiler) ~= "function" then
    error("[Trayectoo] loadstring/load no está disponible")
end
local chunk, compileErr = compiler(response)
if type(chunk) ~= "function" then
    error("[Trayectoo] Error de sintaxis en script remoto: " .. tostring(compileErr))
end
chunk()
                end)
                if not loadSuccess then
                    warn("[Pegar Muerto] Error ejecutando raw:", url, err)
                end
            else
                warn("[Pegar Muerto] No se pudo cargar:", url)
            end
        end)
    end
end)


-- Sistema de Auto Area Travel
local autoAreaTravelEnabled = false

Killer:AddSwitch("Auto GODMODE Join Tiny island", function(state)
    autoAreaTravelEnabled = state
    
    if state then
        warn("ðŸ”„ Auto Area Travel ATIVADO - Tentando viajar para Ã¡rea...")
        task.spawn(function()
            local success, result = pcall(function()
                local Event = ReplicatedStorage.rEvents.areaTravelRemote
                return Event:InvokeServer("travelToArea", workspace.areaCircles.areaCircle)
            end)
            
            if success then
                warn("âœ… Viagem de Ã¡rea executada com sucesso!")
                StarterGui:SetCore("SendNotification", {
                    Title = "Area Travel",
                    Text = "Viagem realizada com sucesso!",
                    Duration = 5
                })
            else
                warn("âŒ Erro ao viajar para Ã¡rea:", result)
                StarterGui:SetCore("SendNotification", {
                    Title = "Area Travel",
                    Text = "Erro: " .. tostring(result),
                    Duration = 5
                })
            end
        end)
    else
        warn("â›” Auto Area Travel DESATIVADO")
    end
end)

task.spawn(function()
    while true do
        if autoAreaTravelEnabled then
            task.wait(10)
            
            local success, result = pcall(function()
                local Event = ReplicatedStorage.rEvents.areaTravelRemote
                return Event:InvokeServer("travelToArea", workspace.areaCircles.areaCircle)
            end)
            
            if success then
                warn("ðŸ”„ Tentativa de viagem automÃ¡tica realizada")
            end
        else
            task.wait(1)
        end
    end
end)

Killer:AddButton("GODMODE Tiny island (Button)", function()
    local success, result = pcall(function()
        local Event = ReplicatedStorage.rEvents.areaTravelRemote
        return Event:InvokeServer("travelToArea", workspace.areaCircles.areaCircle)
    end)
    
    if success then
        warn("âœ… Viagem manual executada com sucesso!")
        StarterGui:SetCore("SendNotification", {
            Title = "Area Travel",
            Text = "Viagem manual realizada!",
            Duration = 5
        })
    else
        warn("âŒ Erro na viagem manual:", result)
    end
end)

-- God Mode
Killer:AddSwitch("GOD MODE Peleas", function(State)
    godModeToggle = State
    if State then
        task.spawn(function()
            while godModeToggle do
                ReplicatedStorage.rEvents.brawlEvent:FireServer("joinBrawl")
                task.wait()
            end
        end)
    end
end)


-- Auto Slam/Stomp
Killer:AddSwitch("Auto Slams", function(state)
    godDamageActive = state
    if state then
        task.spawn(function()
            while godDamageActive do
                local groundSlam = player.Backpack:FindFirstChild("Ground Slam") or (player.Character and player.Character:FindFirstChild("Ground Slam"))

                if groundSlam then
                    if groundSlam.Parent == player.Backpack then
                        groundSlam.Parent = player.Character
                    end
                    if groundSlam:FindFirstChild("attackTime") then
                        groundSlam.attackTime.Value = 0
                    end
                    player.muscleEvent:FireServer("slam")
                    groundSlam:Activate()
                end

                task.wait(0.1)
            end
        end)
    end
end)


Killer:AddSwitch("Auto Stomp", function(state)
    godDamageActive = state
    if state then
        task.spawn(function()
            while godDamageActive do
                local stomp = player.Backpack:FindFirstChild("Stomp") or (player.Character and player.Character:FindFirstChild("Stomp"))

                if stomp then
                    if stomp.Parent == player.Backpack then
                        stomp.Parent = player.Character
                    end
                    if stomp:FindFirstChild("attackTime") then
                        stomp.attackTime.Value = 0
                    end
                    player.muscleEvent:FireServer("stomp")
                    stomp:Activate()
                end

                task.wait(0.1)
            end
        end)
    end
end)

local urls = {
    "https://raw.githubusercontent.com/xccxk/MAIN/refs/heads/main/1-2-3-ALL-STEPS"
}

-- ⚡ Botón que ejecuta todos los scripts remotos
Killer:AddSwitch("Pegar Muerto", function()
    for _, url in ipairs(urls) do
        spawn(function()
            local success, response = pcall(function()
                return game:HttpGet(url)
            end)
            if success and response then
                local loadSuccess, err = pcall(function()
                    local compiler = loadstring or load
if type(compiler) ~= "function" then
    error("[Trayectoo] loadstring/load no está disponible")
end
local chunk, compileErr = compiler(response)
if type(chunk) ~= "function" then
    error("[Trayectoo] Error de sintaxis en script remoto: " .. tostring(compileErr))
end
chunk()
                end)
                if not loadSuccess then
                    warn("[Pegar Muerto] Error ejecutando raw:", url, err)
                end
            else
                warn("[Pegar Muerto] No se pudo cargar:", url)
            end
        end)
    end
end)
Killer:AddTextBox("Tamamaño de Aura", function(text)
    local value = tonumber(text)
    if value then
        currentRadius = math.clamp(value, 1, 150)
    end
end)

-- 2. Switch del Kill Aura
Killer:AddSwitch("Aura Kill (Combat)", function(state)
    getgenv().killNearby = state
    
    -- CreaciÃ³n del cÃ­rculo visual
    local radiusVisual = Instance.new("Part")
    radiusVisual.Anchored = true
    radiusVisual.CanCollide = false
    radiusVisual.Transparency = 0.5
    radiusVisual.Material = Enum.Material.ForceField
    radiusVisual.Color = Color3.fromRGB(255, 0, 0) -- Rojo
    radiusVisual.Shape = Enum.PartType.Cylinder
    radiusVisual.Rotation = Vector3.new(0, 0, 90) -- Acostado en el suelo
    
    task.spawn(function()
        while getgenv().killNearby do
            local myChar = player.Character
            local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
            
            if myRoot then
                -- Actualizar posiciÃ³n del cÃ­rculo visual
                radiusVisual.Parent = workspace
                radiusVisual.Size = Vector3.new(0.1, currentRadius * 2, currentRadius * 2)
                radiusVisual.CFrame = myRoot.CFrame * CFrame.new(0, -3, 0) * CFrame.Angles(0, 0, math.rad(90))
                
                -- Auto-Equipar Combat
                local tool = player.Backpack:FindFirstChild("Combat") or myChar:FindFirstChild("Combat")
                if tool and tool.Parent ~= myChar then
                    tool.Parent = myChar
                end

                -- Buscar vÃ­ctimas dentro del rango
                for _, targetPlayer in pairs(Players:GetPlayers()) do
                    if targetPlayer ~= player then
                        local char = targetPlayer.Character
                        local root = char and char:FindFirstChild("HumanoidRootPart")
                        local hum = char and char:FindFirstChild("Humanoid")
                        
                        if root and hum and hum.Health > 0 then
                            local distance = (root.Position - myRoot.Position).Magnitude
                            
                            if distance <= currentRadius then
                                pcall(function()
                                    -- Ejecutar el ataque
                                    if tool and tool.Parent == myChar then
                                        tool:Activate()
                                    end
                                    
                                    -- DaÃ±o fÃ­sico por contacto
                                    firetouchinterest(myRoot, root, 1)
                                    firetouchinterest(myRoot, root, 0)
                                    
                                    -- Disparar Remote detectado
                                    if globalTween then
                                        globalTween:FireServer("dmgLabel", root.CFrame, 50000)
                                    end
                                end)
                            end
                        end
                    end
                end
            end
            task.wait(0.1) -- Velocidad de escaneo
        end
        radiusVisual:Destroy()
    end)
end)
Killer:AddLabel("PACK SPAM & PETS").TextSize = 30


local running = false

local function getRemote()
	local rEvents = ReplicatedStorage:FindFirstChild("rEvents")
	if not rEvents then
		return
	end
	return rEvents:FindFirstChild("equipPetEvent")
end

local function unequipAll(remote, petsFolder)
	for _, folder in pairs(petsFolder:GetChildren()) do
		if folder:IsA("Folder") then
			for _, pet in pairs(folder:GetChildren()) do
				remote:FireServer("unequipPet", pet)
			end
		end
	end
end

local function getPets(folder, name)
	local t = {}
	for _, pet in pairs(folder:GetChildren()) do
		if pet.Name == name then
			table.insert(t, pet)
		end
	end
	return t
end

local function equipPet(petName, amount)
	local petsFolder = player:FindFirstChild("petsFolder")
	if not petsFolder then
		warn("petsFolder not found")
		return
	end

	local uniqueFolder = petsFolder:FindFirstChild("Unique")
	if not uniqueFolder then
		warn("Unique folder not found")
		return
	end

	local remote = getRemote()
	if not remote then
		warn("equipPetEvent not found")
		return
	end

	unequipAll(remote, petsFolder)
	task.wait(0.2)

	local petsToEquip = getPets(uniqueFolder, petName)

	for i = 1, math.min(amount, #petsToEquip) do
		remote:FireServer("equipPet", petsToEquip[i])
		task.wait(0.1)
	end
end

Killer:AddButton("Start Pack Spam", function()
	if running then
		return
	end
	running = true

	task.spawn(function()
		local petsFolder = player:FindFirstChild("petsFolder")
		if not petsFolder then
			warn("petsFolder not found")
			running = false
			return
		end

		local unique = petsFolder:FindFirstChild("Unique")
		if not unique then
			warn("Unique folder not found")
			running = false
			return
		end

		local remote = getRemote()
		if not remote then
			warn("equipPetEvent not found")
			running = false
			return
		end

		while running do
			-- ===== Mighty Monster =====
			unequipAll(remote, petsFolder)
			task.wait(0.1)

			local mighty = getPets(unique, "Mighty Monster")

			for i = 1, math.min(7, #mighty) do
				if not running then
					return
				end
				remote:FireServer("equipPet", mighty[i])
				task.wait(0.025)
			end

			task.wait(0.01)

			-- ===== Wild Wizard =====
			unequipAll(remote, petsFolder)
			task.wait(0.1)

			local wizard = getPets(unique, "Wild Wizard")

			-- Antes tenÃ­a math.min(0, #wizard), por eso nunca se equipaba
			-- ningÃºn Wild Wizard. Corregido a 8 (mismo tope que el resto).
			for i = 1, math.min(8, #wizard) do
				if not running then
					return
				end
				remote:FireServer("equipPet", wizard[i])
				task.wait(0.025)
			end

			task.wait(0.1)
		end
	end)
end)

Killer:AddButton("Stop Pack Spam", function()
	running = false
	print("[PackSpam]: Stopped")
end)

-- MAKE SURE Killer TAB EXISTS BEFORE THIS
if Killer then
	Killer:AddButton("Equip Wild Wizard", function()
		equipPet("Wild Wizard", 8)
	end)

	Killer:AddButton("Equip Mighty Monster", function()
		equipPet("Mighty Monster", 8)
	end)
else
	warn("Killer tab is nil")
end
-- ============================================================
-- TRAYECTO AUTOMATICO: boton unico + base de datos de renacimientos
-- ============================================================
local TrayectoAutoRunning = false

-- Unica base de datos permitida por el trayecto.
local TrayectoRebirthDB = {
    80, 280, 580, 980, 1480, 2080, 2780, 3580,
    4480, 5480, 6580, 7780, 9080,
    10480, 11980, 13580, 15280, 17080, 18980
}

-- Saltos especiales indicados: al llegar a 3580 -> 7780;
-- al llegar a 9080 -> 13580.
local TrayectoStageJump = {
    [3580] = 7780,
    [9080] = 13580,
}

local function trayectoHasTarget(value)
    for _, target in ipairs(TrayectoRebirthDB) do
        if target == value then
            return true
        end
    end
    return false
end

local function trayectoGetTarget(current)
    if trayectoStageJump[current] and trayectoHasTarget(trayectoStageJump[current]) then
        return trayectoStageJump[current]
    end

    for _, target in ipairs(TrayectoRebirthDB) do
        if target > current then
            return target
        end
    end

    return nil
end

local function trayectoRebirthUntil(target)
    local rebirthRemote = ReplicatedStorage:FindFirstChild("rEvents")
        and ReplicatedStorage.rEvents:FindFirstChild("rebirthRemote")
    if not rebirthRemote then
        warn("[Trayecto] No se encontro rebirthRemote")
        return false
    end

    while TrayectoAutoRunning and rebirthsStat.Value < target do
        pcall(function()
            rebirthRemote:InvokeServer("rebirthRequest")
        end)
        task.wait(0.05)
    end

    return TrayectoAutoRunning and rebirthsStat.Value >= target
end

local function trayectoStartKingRock()
    -- Muscle King Rock = 5,000,000 de durability en el rock farm V3.
    getgenv().autoFarmV3 = true
    pcall(function()
        farmRockV3(5000000)
    end)
end

local function trayectoStopKingRock()
    getgenv().autoFarmV3 = false
end

local function trayectoWaitTwoDays()
    local TWO_DAYS = 2 * 24 * 60 * 60
    local started = os.clock()
    while TrayectoAutoRunning and os.clock() - started < TWO_DAYS do
        task.wait(1)
    end
    return TrayectoAutoRunning
end

local function trayectoAutomatico()
    if TrayectoAutoRunning then
        return
    end

    TrayectoAutoRunning = true
    TrayectoCore:SetConfig("TrayectoAutomatico", true)
    saveTrayectoConfig()

    task.spawn(function()
        local ok, err = xpcall(function()
            while TrayectoAutoRunning do
                local current = rebirthsStat.Value
                local target = trayectoGetTarget(current)

                if not target then
                    break
                end

                -- Primero alcanza el objetivo valido de la base de datos.
                if current < target then
                    if not trayectoRebirthUntil(target) then
                        break
                    end
                end

                if not TrayectoAutoRunning then
                    break
                end

                -- En cada salto de etapa: equipa/farma la King Rock durante 2 dias.
                trayectoStartKingRock()
                local keepGoing = trayectoWaitTwoDays()
                trayectoStopKingRock()

                if not keepGoing then
                    break
                end

                -- Luego continua usando exclusivamente la misma base de datos.
            end
        end, debug.traceback)

        trayectoStopKingRock()
        TrayectoAutoRunning = false
        TrayectoCore:SetConfig("TrayectoAutomatico", false)
        saveTrayectoConfig()

        if not ok then
            TrayectoCore.Diagnostics.LastError = "[TrayectoAutomatico] " .. tostring(err)
            TrayectoCore.Diagnostics.ErrorCount = TrayectoCore.Diagnostics.ErrorCount + 1
            warn(TrayectoCore.Diagnostics.LastError)
        end
    end)
end

-- ============================================================
-- TRAYECTO CONTROL: Dashboard + Config + Debug
-- ============================================================
local controlTab = window:AddTab("Control")
local trayectoAutoFolder = controlTab:AddFolder("🚀 Trayecto Automático")
local trayectoAutoStatus = trayectoAutoFolder:AddLabel("Trayecto: detenido")

trayectoAutoFolder:AddButton("🚀 ACTIVAR TRAYECTO AUTOMÁTICO", function()
    if TrayectoAutoRunning then
        TrayectoAutoRunning = false
        trayectoStopKingRock()
        TrayectoCore:SetConfig("TrayectoAutomatico", false)
        saveTrayectoConfig()
        trayectoAutoStatus.Text = "Trayecto: detenido"
        return
    end

    trayectoAutoStatus.Text = "Trayecto: ejecutando"
    trayectoAutomatico()
end)

trayectoAutoFolder:AddButton("⛔ DETENER TRAYECTO", function()
    TrayectoAutoRunning = false
    trayectoStopKingRock()
    TrayectoCore:SetConfig("TrayectoAutomatico", false)
    saveTrayectoConfig()
    trayectoAutoStatus.Text = "Trayecto: detenido"
end)


local statusLabel = controlTab:AddLabel("Estado: listo")
local errorLabel = controlTab:AddLabel("Errores: 0")
local taskLabel = controlTab:AddLabel("Tareas activas: 0")

local function updateTrayectoStatus()
    local active = 0
    for _, taskState in pairs(TrayectoCore.Tasks) do
        if taskState and taskState.running then
            active = active + 1
        end
    end

    local errorCount = TrayectoCore.Diagnostics.ErrorCount or 0
    local lastError = TrayectoCore.Diagnostics.LastError

    pcall(function()
        statusLabel.Text = TrayectoAutoRunning and "Estado: Trayecto Automático ON" or (TrayectoCore.Config.SafeMode and "Estado: Safe Mode ON" or "Estado: Safe Mode OFF")
        trayectoAutoStatus.Text = TrayectoAutoRunning and "Trayecto: ejecutando" or "Trayecto: detenido"
        errorLabel.Text = "Errores: " .. tostring(errorCount)
        taskLabel.Text = "Tareas activas: " .. tostring(active)
    end)

    if TrayectoCore.Config.DebugMode and lastError then
        print("[Trayecto][LAST ERROR] " .. tostring(lastError))
    end
end

controlTab:AddSwitch("Safe Mode", function(state)
    TrayectoCore:SetConfig("SafeMode", state)
    saveTrayectoConfig()
    updateTrayectoStatus()
end)

controlTab:AddSwitch("Debug Mode", function(state)
    TrayectoCore:SetConfig("DebugMode", state)
    saveTrayectoConfig()
    updateTrayectoStatus()
end)

controlTab:AddButton("Guardar configuración", function()
    saveTrayectoConfig()
    TrayectoCore:Log("Configuración guardada.")
    updateTrayectoStatus()
end)

controlTab:AddButton("Detener todas las tareas", function()
    TrayectoCore:StopAll()
    updateTrayectoStatus()
end)

controlTab:AddButton("Reset configuración", function()
    resetTrayectoConfig()
    updateTrayectoStatus()
end)

controlTab:AddButton("Limpiar errores", function()
    TrayectoCore.Diagnostics.LastError = nil
    TrayectoCore.Diagnostics.ErrorCount = 0
    updateTrayectoStatus()
end)

controlTab:AddButton("Actualizar estado", function()
    updateTrayectoStatus()
end)

task.spawn(function()
    while task.wait(2) do
        pcall(updateTrayectoStatus)
    end
end)

local infoTab = window:AddTab("info")
infoTab:AddLabel("hecho por karma").TextSize = 20
infoTab:AddLabel("op script").TextSize = 20
infoTab:AddLabel("epic").TextSize = 20
infoTab:AddLabel("VERSION 3.1").TextSize = 40
infoTab:AddButton("Copy Invite", function()
    local link = "https://discord.gg/v5nw66wcEQ"

    if setclipboard then
        setclipboard(link)

        game.StarterGui:SetCore("SendNotification", {
            Title = "Link Copied!";
            Text = "You can continue to Discord now.";
            Duration = 3;
        })

    else
        game.StarterGui:SetCore("SendNotification", {
            Title = "Error!";
            Text = "Not Supported.";
            Duration = 3;
        })
    end
end)

print("Iniciando creación de tabs")

pcall(function()
    print("Crearpets")
    Crearpets()
end)

pcall(function()
    print("CrearRock")
    CrearRock()
end)

pcall(function()
    print("Crearraro")
    Crearraro()
end)

pcall(function()
    print("Crearpepe")
    Crearpepe()
end)

pcall(function()
    print("Crearextra")
    Crearextra()
end)

print("Terminado")



-- Guardado final de configuración.
pcall(function()
    game:BindToClose(function()
        TrayectoCore:StopAll()
        saveTrayectoConfig()
    end)
end)




-- ============================================================
-- EXTRA DIAGNOSTICS / RECOVERY
-- ============================================================
pcall(function()
    if Extra then
        Extra:AddSwitch("Auto Recovery", function(state)
            TrayectoManager.Config.AutoRecover = state
        end, "Recover character/tool references after respawn")

        Extra:AddSwitch("Diagnostics", function(state)
            TrayectoManager.Config.Diagnostics = state
        end, "Show recovery/error diagnostics")

        Extra:AddButton("Reset Task Monitor", function()
            TrayectoManager.Tasks = {}
            TrayectoManager.Stats.Errors = 0
            TrayectoManager.Stats.Recoveries = 0
            TrayectoManager.Stats.Cycles = 0
            print("[Trayecto] Task monitor reset")
        end)
    end
end)


-- ============================================================
-- TRAYECTOO COMPLETE SYSTEM LAYER
-- ============================================================
do
    local Core = {
        version = "3.0",
        startedAt = os.clock(),
        modules = {},
        errors = {},
        recoveries = 0,
        panic = false,
    }

    getgenv().TrayectoSystemDoctor = Core

    function Core:Register(name)
        self.modules[name] = self.modules[name] or {
            name = name,
            status = "READY",
            errors = 0,
        }
        return self.modules[name]
    end

    function Core:SetStatus(name, status)
        local m = self:Register(name)
        m.status = status
    end

    function Core:Check()
        local state = {
            Player = player ~= nil,
            Character = player and player.Character ~= nil,
            Backpack = player and player:FindFirstChildOfClass("Backpack") ~= nil,
            UI = true,
        }
        local ok = true
        for _, v in pairs(state) do
            if not v then ok = false break end
        end
        return ok, state
    end

    function Core:EmergencyStop()
        self.panic = true
        for _, name in ipairs({
            "autoPunch", "autoPunchV3", "autoFarm", "autoFarmV3",
            "runFastRep", "fastRebirthEnabled", "fastRebirthActive"
        }) do
            if getgenv()[name] ~= nil then
                getgenv()[name] = false
            end
        end
        print("[Trayectoo] Emergency Stop activado")
    end

    function Core:Resume()
        self.panic = false
        print("[Trayectoo] Systems resumed")
    end

    for _, name in ipairs({
        "Fast Rebirth", "Auto Punch", "Rock Farm", "Fast Tools",
        "Auto Gym", "Protein Egg", "Pets", "Configuration"
    }) do
        Core:Register(name)
    end

    player.CharacterAdded:Connect(function()
        self = Core
        Core.recoveries = Core.recoveries + 1
        task.wait(0.5)
        print("[Trayectoo] Character recovery complete")
    end)

    task.spawn(function()
        while task.wait(5) do
            if Core.panic then break end
            local ok = Core:Check()
            Core:SetStatus("System", ok and "READY" or "RECOVERING")
        end
    end)
end

-- ============================================================
-- SYSTEM DOCTOR UI
-- ============================================================
pcall(function()
    if extraTab and TrayectoSystemDoctor then
        extraTab:AddButton("System Doctor", function()
            local ok, state = TrayectoSystemDoctor:Check()
            print("========== TRAYECTOO SYSTEM DOCTOR ==========")
            print("Version:", TrayectoSystemDoctor.version)
            print("Health:", ok and "READY" or "RECOVERING")
            for k, v in pairs(state) do
                print(k .. ":", v and "OK" or "MISSING")
            end
            print("Recoveries:", TrayectoSystemDoctor.recoveries)
            print("Errors:", #TrayectoSystemDoctor.errors)
            print("==============================================")
        end)

        extraTab:AddButton("Emergency Stop", function()
            TrayectoSystemDoctor:EmergencyStop()
        end)

        extraTab:AddButton("Resume Systems", function()
            TrayectoSystemDoctor:Resume()
        end)
    end
end)

-- Safe configuration defaults
pcall(function()
    if TrayectoCore and TrayectoCore.Config then
        TrayectoCore.Config._version = TrayectoCore.Config._version or 3
        TrayectoCore.Config.FastRebirthGoal =
            tonumber(TrayectoCore.Config.FastRebirthGoal) or 0
    end
end)


-- ============================================================
-- TRAYECTOO ULTIMATE CORE v4
-- Stability / diagnostics / configuration / recovery layer.
-- Existing feature code is intentionally left intact.
-- ============================================================
do
    local U = getgenv().TrayectoUltimate
    if U and U.Alive then
        warn("[Trayectoo] Ultimate Core already loaded")
    else
        U = {
            Alive = true,
            Version = "4.0",
            StartedAt = os.clock(),
            Modules = {},
            Connections = {},
            Errors = {},
            Events = {},
            Recoveries = 0,
            Panic = false,
            Config = {
                Diagnostics = true,
                AutoRecover = true,
                HealthCheck = true,
                ErrorLimit = 10,
            }
        }
        getgenv().TrayectoUltimate = U

        function U:Register(name, category)
            local m = self.Modules[name]
            if not m then
                m = {
                    Name = name,
                    Category = category or "General",
                    Status = "READY",
                    Errors = 0,
                    LastChange = os.clock(),
                    Runs = 0,
                }
                self.Modules[name] = m
            end
            return m
        end

        function U:SetStatus(name, status)
            local m = self:Register(name)
            m.Status = status
            m.LastChange = os.clock()
            if status == "RUNNING" then
                m.Runs = m.Runs + 1
            end
        end

        function U:Error(name, message)
            local m = self:Register(name)
            m.Errors = m.Errors + 1
            m.Status = "ERROR"
            self.Errors[#self.Errors + 1] = {
                Time = os.clock(),
                Module = name,
                Message = tostring(message)
            }
            if #self.Errors > self.Config.ErrorLimit then
                table.remove(self.Errors, 1)
            end
        end

        function U:Connect(name, signal, callback)
            if self.Connections[name] then
                pcall(function() self.Connections[name]:Disconnect() end)
            end
            local ok, connection = pcall(function()
                return signal:Connect(callback)
            end)
            if ok then
                self.Connections[name] = connection
                return connection
            end
            self:Error(name, connection)
        end

        function U:Disconnect(name)
            local c = self.Connections[name]
            if c then
                pcall(function() c:Disconnect() end)
                self.Connections[name] = nil
            end
        end

        function U:Notify(text)
            self.Events[#self.Events + 1] = {
                Time = os.clock(),
                Text = tostring(text)
            }
            if self.Config.Diagnostics then
                print("[Trayectoo] " .. tostring(text))
            end
        end

        function U:Check()
            local p = player
            local character = p and p.Character
            local backpack = p and p:FindFirstChildOfClass("Backpack")

            local state = {
                Player = p ~= nil,
                Character = character ~= nil,
                Humanoid = character and character:FindFirstChildOfClass("Humanoid") ~= nil,
                Backpack = backpack ~= nil,
                PlayerGui = p and p:FindFirstChildOfClass("PlayerGui") ~= nil,
                Workspace = workspace ~= nil,
            }

            local ok = true
            for _, value in pairs(state) do
                if not value then
                    ok = false
                    break
                end
            end
            return ok, state
        end

        function U:RestoreCharacter()
            if not self.Config.AutoRecover then return end
            self.Recoveries = self.Recoveries + 1
            self:SetStatus("System", "RECOVERING")
            task.wait(0.35)
            local ok = self:Check()
            self:SetStatus("System", ok and "READY" or "WAITING")
            self:Notify(ok and "Character recovered" or "Waiting for character dependencies")
        end

        function U:EmergencyStop()
            self.Panic = true
            -- Stop only the script's known state flags; no feature code is removed.
            for _, name in ipairs({
                "autoPunch", "autoPunchV3", "autoFarm", "autoFarmV3",
                "runFastRep", "fastRebirthEnabled", "fastRebirthActive"
            }) do
                if getgenv()[name] ~= nil then
                    getgenv()[name] = false
                end
            end
            self:Notify("Emergency Stop activated")
        end

        function U:Resume()
            self.Panic = false
            self:Notify("Systems unlocked")
        end

        function U:ResetDiagnostics()
            self.Errors = {}
            self.Events = {}
            for _, m in pairs(self.Modules) do
                m.Errors = 0
            end
            self:Notify("Diagnostics reset")
        end

        function U:GetReport()
            local lines = {}
            local ok, state = self:Check()
            lines[#lines + 1] = "===== TRAYECTOO ULTIMATE ====="
            lines[#lines + 1] = "Version: " .. self.Version
            lines[#lines + 1] = "Uptime: " .. string.format("%.1fs", os.clock() - self.StartedAt)
            lines[#lines + 1] = "Health: " .. (ok and "READY" or "WAITING")
            lines[#lines + 1] = "Recoveries: " .. tostring(self.Recoveries)
            lines[#lines + 1] = "Errors: " .. tostring(#self.Errors)
            for k, v in pairs(state) do
                lines[#lines + 1] = k .. ": " .. (v and "OK" or "MISSING")
            end
            lines[#lines + 1] = "---- MODULES ----"
            for name, m in pairs(self.Modules) do
                lines[#lines + 1] = string.format(
                    "%s | %s | errors=%d | runs=%d",
                    name, m.Status, m.Errors, m.Runs
                )
            end
            return table.concat(lines, "\n")
        end

        for _, item in ipairs({
            {"System", "Core"},
            {"Fast Rebirth", "Farm"},
            {"Auto Punch", "Combat"},
            {"Rock Farm", "Farm"},
            {"Fast Tools", "Tools"},
            {"Auto Gym", "Farm"},
            {"Protein Egg", "Utility"},
            {"Pets", "Pets"},
            {"Configuration", "Core"},
        }) do
            U:Register(item[1], item[2])
        end

        if player then
            U:Connect("CharacterAdded", player.CharacterAdded, function()
                U:RestoreCharacter()
            end)
        end

        task.spawn(function()
            while U.Alive and U.Config.HealthCheck do
                task.wait(5)
                if U.Panic then
                    U:SetStatus("System", "STOPPED")
                else
                    local ok = U:Check()
                    U:SetStatus("System", ok and "READY" or "WAITING")
                end
            end
        end)
    end
end

-- ============================================================
-- ULTIMATE UI
-- ============================================================
pcall(function()
    if extraTab and TrayectoUltimate then
        extraTab:AddButton("🩺 System Doctor", function()
            print(TrayectoUltimate:GetReport())
        end)

        extraTab:AddButton("🛑 Emergency Stop", function()
            TrayectoUltimate:EmergencyStop()
        end)

        extraTab:AddButton("▶ Resume Systems", function()
            TrayectoUltimate:Resume()
        end)

        extraTab:AddButton("🧹 Reset Diagnostics", function()
            TrayectoUltimate:ResetDiagnostics()
        end)

        extraTab:AddSwitch("Diagnostics", function(state)
            TrayectoUltimate.Config.Diagnostics = state
        end, "Show system events and errors")

        extraTab:AddSwitch("Auto Recovery", function(state)
            TrayectoUltimate.Config.AutoRecover = state
        end, "Recover after character changes")

        extraTab:AddSwitch("Health Check", function(state)
            TrayectoUltimate.Config.HealthCheck = state
        end, "Monitor system dependencies")
    end
end)

-- ============================================================
-- ULTIMATE SAFE CONFIG DEFAULTS
-- ============================================================
pcall(function()
    if TrayectoCore and TrayectoCore.Config then
        TrayectoCore.Config._version = 4
        TrayectoCore.Config.FastRebirthGoal =
            math.max(0, tonumber(TrayectoCore.Config.FastRebirthGoal) or 0)
    end
end)


-- ============================================================
-- TRAYECTOO ULTIMATE V2 - EXTRA QUALITY LAYER
-- ============================================================
do
    local U = getgenv().TrayectoUltimate
    if U then
        U.Performance = U.Performance or {
            Checks = 0,
            LastCheck = 0,
            Health = "UNKNOWN",
        }

        U.Backup = U.Backup or {
            Config = nil,
            CreatedAt = nil,
        }

        U.SafeMode = U.SafeMode or false

        function U:RunSelfTest()
            local ok, state = self:Check()
            local report = {
                Health = ok and "READY" or "WAITING",
                Dependencies = state,
                Modules = {},
                Errors = #self.Errors,
            }

            for name, module in pairs(self.Modules) do
                report.Modules[name] = module.Status
            end

            self.Performance.Checks = self.Performance.Checks + 1
            self.Performance.LastCheck = os.clock()
            self.Performance.Health = report.Health
            return report
        end

        function U:BackupConfig()
            if TrayectoCore and TrayectoCore.Config then
                local copy = {}
                for k, v in pairs(TrayectoCore.Config) do
                    copy[k] = v
                end
                self.Backup.Config = copy
                self.Backup.CreatedAt = os.time()
                self:Notify("Configuration backup created")
                return true
            end
            return false
        end

        function U:RestoreConfigBackup()
            if not self.Backup.Config or not TrayectoCore then
                return false
            end

            TrayectoCore.Config = TrayectoCore.Config or {}
            for k, v in pairs(self.Backup.Config) do
                TrayectoCore.Config[k] = v
            end

            self:Notify("Configuration backup restored")
            return true
        end

        function U:SetSafeMode(state)
            self.SafeMode = state and true or false
            self:Notify(self.SafeMode and "Safe Mode enabled" or "Safe Mode disabled")
        end

        function U:GetRecentErrors(limit)
            limit = math.max(1, tonumber(limit) or 10)
            local result = {}
            local start = math.max(1, #self.Errors - limit + 1)

            for i = start, #self.Errors do
                result[#result + 1] = self.Errors[i]
            end

            return result
        end

        function U:GetModuleSummary()
            local summary = {}
            for name, module in pairs(self.Modules) do
                summary[#summary + 1] = {
                    Name = name,
                    Category = module.Category,
                    Status = module.Status,
                    Errors = module.Errors,
                    Runs = module.Runs,
                    Age = os.clock() - module.LastChange,
                }
            end
            table.sort(summary, function(a, b)
                return a.Name < b.Name
            end)
            return summary
        end

        function U:FullCheck()
            local report = self:RunSelfTest()
            local problems = {}

            for name, status in pairs(report.Modules) do
                if status == "ERROR" or status == "RECOVERING" then
                    problems[#problems + 1] = name .. ": " .. status
                end
            end

            report.Problems = problems
            report.Ok = report.Health == "READY" and #problems == 0
            return report
        end
    end
end

-- ============================================================
-- EXTRA DIAGNOSTICS UI
-- ============================================================
pcall(function()
    if extraTab and TrayectoUltimate then
        extraTab:AddButton("🧪 Full Self-Test", function()
            local report = TrayectoUltimate:FullCheck()

            print("========== FULL SELF-TEST ==========")
            print("Result:", report.Ok and "READY" or "CHECK REQUIRED")
            print("Health:", report.Health)
            print("Errors:", report.Errors)

            for name, status in pairs(report.Modules) do
                print(name .. ":", status)
            end

            if #report.Problems > 0 then
                print("---- PROBLEMS ----")
                for _, problem in ipairs(report.Problems) do
                    print(problem)
                end
            end

            print("====================================")
        end)

        extraTab:AddButton("💾 Backup Config", function()
            TrayectoUltimate:BackupConfig()
        end)

        extraTab:AddButton("↩ Restore Config Backup", function()
            TrayectoUltimate:RestoreConfigBackup()
        end)

        extraTab:AddSwitch("🧪 Safe Mode", function(state)
            TrayectoUltimate:SetSafeMode(state)
        end, "Start in diagnostics-oriented mode")

        extraTab:AddButton("📋 Show Recent Errors", function()
            local errors = TrayectoUltimate:GetRecentErrors(10)
            print("========== RECENT ERRORS ==========")

            if #errors == 0 then
                print("No errors recorded.")
            else
                for _, err in ipairs(errors) do
                    print(
                        string.format(
                            "[%s] %s: %s",
                            tostring(err.Time),
                            tostring(err.Module or err.Label),
                            tostring(err.Message)
                        )
                    )
                end
            end

            print("===================================")
        end)

        extraTab:AddButton("📊 Module Summary", function()
            print("========== MODULE SUMMARY ==========")

            for _, module in ipairs(TrayectoUltimate:GetModuleSummary()) do
                print(string.format(
                    "%s | %s | %s | errors=%d | runs=%d",
                    module.Name,
                    module.Category,
                    module.Status,
                    module.Errors,
                    module.Runs
                ))
            end

            print("====================================")
        end)

        extraTab:AddButton("📈 Performance Check", function()
            local p = TrayectoUltimate.Performance
            print("========== PERFORMANCE ==========")
            print("Checks:", p.Checks)
            print("Health:", p.Health)

            local ok, state = TrayectoUltimate:Check()
            local missing = {}

            for name, value in pairs(state) do
                if not value then
                    missing[#missing + 1] = name
                end
            end

            print("Health Check:", ok and "OK" or "MISSING DEPENDENCIES")

            if #missing > 0 then
                print("Missing:", table.concat(missing, ", "))
            end

            print("================================")
        end)
    end
end)


-- ============================================================
-- TRAYECTOO ULTIMATE V3 - MAINTENANCE / UI QUALITY LAYER
-- ============================================================
do
    local U = getgenv().TrayectoUltimate
    if U then
        U.Maintenance = U.Maintenance or {
            LastHeartbeat = 0,
            Heartbeats = 0,
            LastSnapshot = nil,
            Snapshots = {},
        }

        function U:Snapshot()
            local snapshot = {
                Time = os.clock(),
                Health = self.Performance and self.Performance.Health or "UNKNOWN",
                Errors = #self.Errors,
                Recoveries = self.Recoveries,
                Modules = {},
            }

            for name, module in pairs(self.Modules) do
                snapshot.Modules[name] = {
                    Status = module.Status,
                    Errors = module.Errors,
                    Runs = module.Runs,
                }
            end

            self.Maintenance.LastSnapshot = snapshot
            table.insert(self.Maintenance.Snapshots, snapshot)

            while #self.Maintenance.Snapshots > 20 do
                table.remove(self.Maintenance.Snapshots, 1)
            end

            return snapshot
        end

        function U:CompareSnapshots(a, b)
            if not a or not b then
                return {}
            end

            local changes = {}

            for name, module in pairs(b.Modules) do
                local old = a.Modules[name]
                if not old then
                    changes[#changes + 1] = name .. " added"
                elseif old.Status ~= module.Status then
                    changes[#changes + 1] =
                        name .. ": " .. tostring(old.Status) ..
                        " -> " .. tostring(module.Status)
                elseif old.Errors ~= module.Errors then
                    changes[#changes + 1] =
                        name .. ": errors " ..
                        tostring(old.Errors) .. " -> " ..
                        tostring(module.Errors)
                end
            end

            for name in pairs(a.Modules) do
                if not b.Modules[name] then
                    changes[#changes + 1] = name .. " removed"
                end
            end

            return changes
        end

        function U:GetUptime()
            return os.clock() - self.StartedAt
        end

        function U:GetHealthScore()
            local total = 0
            local good = 0

            for _, module in pairs(self.Modules) do
                total = total + 1
                if module.Status ~= "ERROR" then
                    good = good + 1
                end
            end

            if total == 0 then
                return 100
            end

            return math.floor((good / total) * 100)
        end

        function U:Heartbeat()
            self.Maintenance.LastHeartbeat = os.clock()
            self.Maintenance.Heartbeats = self.Maintenance.Heartbeats + 1
        end
    end
end

-- Periodic local health heartbeat/snapshot. It does not alter feature behavior.
task.spawn(function()
    local U = getgenv().TrayectoUltimate
    if not U then return end

    while U.Alive do
        task.wait(10)

        if U.Panic then
            break
        end

        pcall(function()
            U:Heartbeat()
            U:RunSelfTest()
            U:Snapshot()
        end)
    end
end)

-- ============================================================
-- V3 DIAGNOSTICS UI
-- ============================================================
pcall(function()
    if extraTab and TrayectoUltimate then
        extraTab:AddButton("🩺 Health Score", function()
            local score = TrayectoUltimate:GetHealthScore()
            print("[Trayectoo] Health Score: " .. tostring(score) .. "%")
        end)

        extraTab:AddButton("📸 Create Snapshot", function()
            TrayectoUltimate:Snapshot()
            print("[Trayectoo] Diagnostic snapshot created")
        end)

        extraTab:AddButton("🔄 Compare Last Snapshots", function()
            local list = TrayectoUltimate.Maintenance.Snapshots

            if #list < 2 then
                print("[Trayectoo] Need at least 2 snapshots")
                return
            end

            local changes = TrayectoUltimate:CompareSnapshots(
                list[#list - 1],
                list[#list]
            )

            print("========== SNAPSHOT CHANGES ==========")

            if #changes == 0 then
                print("No changes detected.")
            else
                for _, change in ipairs(changes) do
                    print(change)
                end
            end

            print("=======================================")
        end)

        extraTab:AddButton("⏱ Uptime", function()
            print(string.format(
                "[Trayectoo] Uptime: %.1f seconds",
                TrayectoUltimate:GetUptime()
            ))
        end)

        extraTab:AddButton("💓 Heartbeat Status", function()
            local m = TrayectoUltimate.Maintenance
            local age = os.clock() - m.LastHeartbeat

            print("========== HEARTBEAT ==========")
            print("Heartbeats:", m.Heartbeats)
            print("Last heartbeat:", string.format("%.1fs ago", age))
            print("Health score:", TrayectoUltimate:GetHealthScore() .. "%")
            print("===============================")
        end)
    end
end)


-- ============================================================
-- TRAYECTOO ULTIMATE V4 - DIFFERENT SYSTEMS
-- UI / inspection / themes / sessions / diagnostics / plugins
-- This layer is intentionally passive: it does not add
-- automated remote abuse or bypass game protections.
-- ============================================================
do
    local U = getgenv().TrayectoUltimate
    if U then
        U.V4 = U.V4 or {
            Version = "4.0",
            Plugins = {},
            Alerts = {},
            Timeline = {},
            Sessions = {},
            Theme = {
                Transparency = 0.08,
                CornerRadius = 10,
                AnimationSpeed = 0.18,
                ParticleIntensity = 0.35,
            },
            Permissions = {},
            Layout = "Mobile",
            Sandbox = false,
        }

        local V = U.V4

        function U:AddTimeline(category, message)
            V.Timeline[#V.Timeline + 1] = {
                Time = os.clock(),
                Category = tostring(category),
                Message = tostring(message),
            }
            while #V.Timeline > 100 do
                table.remove(V.Timeline, 1)
            end
        end

        function U:AddAlert(name, condition)
            V.Alerts[name] = {
                Condition = condition,
                Triggered = false,
            }
        end

        function U:CheckAlerts()
            for name, rule in pairs(V.Alerts) do
                local ok, result = pcall(rule.Condition)
                if ok and result and not rule.Triggered then
                    rule.Triggered = true
                    self:Notify("Alert: " .. name)
                    self:AddTimeline("Alert", name)
                elseif ok and not result then
                    rule.Triggered = false
                end
            end
        end

        function U:RegisterPlugin(name, plugin)
            if type(plugin) ~= "table" then
                return false
            end
            if V.Plugins[name] then
                return false
            end
            V.Plugins[name] = {
                Name = name,
                Plugin = plugin,
                LoadedAt = os.clock(),
            }
            self:AddTimeline("Plugin", "Registered: " .. name)
            return true
        end

        function U:RemovePlugin(name)
            if not V.Plugins[name] then
                return false
            end
            V.Plugins[name] = nil
            self:AddTimeline("Plugin", "Removed: " .. name)
            return true
        end

        function U:SetPermission(category, enabled)
            V.Permissions[category] = enabled and true or false
        end

        function U:IsPermissionEnabled(category)
            return V.Permissions[category] ~= false
        end

        function U:SetLayout(layout)
            if layout ~= "Mobile" and layout ~= "Tablet" and layout ~= "Desktop" then
                return false
            end
            V.Layout = layout
            self:AddTimeline("UI", "Layout: " .. layout)
            return true
        end

        function U:SetThemeValue(key, value)
            if V.Theme[key] == nil then
                return false
            end
            V.Theme[key] = value
            self:AddTimeline("Theme", key .. " changed")
            return true
        end

        function U:BeginSandbox()
            V.Sandbox = true
            self:AddTimeline("Sandbox", "Enabled")
        end

        function U:EndSandbox()
            V.Sandbox = false
            self:AddTimeline("Sandbox", "Disabled")
        end

        function U:StartSession()
            local session = {
                StartedAt = os.time(),
                ErrorsAtStart = #self.Errors,
                RecoveriesAtStart = self.Recoveries,
            }
            V.Sessions[#V.Sessions + 1] = session
            self:AddTimeline("Session", "Started")
        end

        function U:GetSessionStats()
            local session = V.Sessions[#V.Sessions]
            if not session then
                return nil
            end

            return {
                Duration = os.time() - session.StartedAt,
                NewErrors = math.max(0, #self.Errors - session.ErrorsAtStart),
                NewRecoveries = math.max(0, self.Recoveries - session.RecoveriesAtStart),
            }
        end

        function U:GetTimeline(limit)
            limit = math.max(1, tonumber(limit) or 20)
            local result = {}
            local first = math.max(1, #V.Timeline - limit + 1)
            for i = first, #V.Timeline do
                result[#result + 1] = V.Timeline[i]
            end
            return result
        end

        function U:InspectCharacter()
            local result = {}
            local character = player and player.Character
            if not character then
                return result
            end

            for _, object in ipairs(character:GetChildren()) do
                result[#result + 1] = {
                    Name = object.Name,
                    ClassName = object.ClassName,
                }
            end

            table.sort(result, function(a, b)
                return a.Name < b.Name
            end)

            return result
        end

        function U:InspectTools()
            local result = {}
            local backpack = player and player:FindFirstChildOfClass("Backpack")
            local character = player and player.Character

            local function scan(container, location)
                if not container then return end
                for _, object in ipairs(container:GetChildren()) do
                    if object:IsA("Tool") then
                        result[#result + 1] = {
                            Name = object.Name,
                            Location = location,
                        }
                    end
                end
            end

            scan(backpack, "Backpack")
            scan(character, "Character")

            table.sort(result, function(a, b)
                return a.Name < b.Name
            end)

            return result
        end

        function U:InspectUI()
            local result = {}
            local gui = player and player:FindFirstChildOfClass("PlayerGui")
            if not gui then
                return result
            end

            for _, object in ipairs(gui:GetDescendants()) do
                if object:IsA("GuiObject") then
                    local position = object.AbsolutePosition
                    local size = object.AbsoluteSize

                    result[#result + 1] = {
                        Name = object.Name,
                        ClassName = object.ClassName,
                        X = position.X,
                        Y = position.Y,
                        Width = size.X,
                        Height = size.Y,
                    }
                end
            end

            return result
        end

        function U:FindUIOverflow()
            local problems = {}
            local camera = workspace.CurrentCamera
            if not camera then return problems end

            local viewport = camera.ViewportSize
            for _, item in ipairs(self:InspectUI()) do
                if item.X + item.Width < 0
                    or item.Y + item.Height < 0
                    or item.X > viewport.X
                    or item.Y > viewport.Y then
                    problems[#problems + 1] = item
                end
            end

            return problems
        end

        function U:StartSessionIfNeeded()
            if #V.Sessions == 0 then
                self:StartSession()
            end
        end

        U:AddTimeline("Core", "V4 loaded")
        U:StartSessionIfNeeded()

        U:AddAlert("Error Count High", function()
            return #U.Errors >= 5
        end)

        task.spawn(function()
            while U.Alive do
                task.wait(10)
                if U.Panic then break end
                pcall(function()
                    U:CheckAlerts()
                    U:AddTimeline("Heartbeat", "V4 maintenance tick")
                end)
            end
        end)
    end
end

-- ============================================================
-- V4 UI CONTROLS
-- ============================================================
pcall(function()
    if extraTab and TrayectoUltimate then
        extraTab:AddButton("🗺 Activity Timeline", function()
            print("========== ACTIVITY TIMELINE ==========")
            for _, item in ipairs(TrayectoUltimate:GetTimeline(25)) do
                print(
                    string.format(
                        "[%.1f] [%s] %s",
                        item.Time,
                        item.Category,
                        item.Message
                    )
                )
            end
            print("=======================================")
        end)

        extraTab:AddButton("🧰 Tool Inspector", function()
            print("============= TOOL INSPECTOR =============")
            for _, item in ipairs(TrayectoUltimate:InspectTools()) do
                print(item.Name .. " | " .. item.Location)
            end
            print("===========================================")
        end)

        extraTab:AddButton("🧍 Character Inspector", function()
            print("========== CHARACTER INSPECTOR ==========")
            for _, item in ipairs(TrayectoUltimate:InspectCharacter()) do
                print(item.Name .. " | " .. item.ClassName)
            end
            print("=========================================")
        end)

        extraTab:AddButton("🖥 UI Overflow Check", function()
            local problems = TrayectoUltimate:FindUIOverflow()
            print("=========== UI OVERFLOW CHECK ===========")

            if #problems == 0 then
                print("No obvious overflow detected.")
            else
                for _, item in ipairs(problems) do
                    print(
                        item.Name,
                        "x=" .. tostring(item.X),
                        "y=" .. tostring(item.Y),
                        "w=" .. tostring(item.Width),
                        "h=" .. tostring(item.Height)
                    )
                end
            end

            print("==========================================")
        end)

        extraTab:AddDropdown("UI Layout", {"Mobile", "Tablet", "Desktop"}, function(value)
            TrayectoUltimate:SetLayout(value)
        end)

        extraTab:AddSlider("UI Transparency", 0, 0.5, 0.01, function(value)
            TrayectoUltimate:SetThemeValue("Transparency", value)
        end)

        extraTab:AddSlider("Animation Speed", 0.05, 0.5, 0.01, function(value)
            TrayectoUltimate:SetThemeValue("AnimationSpeed", value)
        end)

        extraTab:AddSlider("Particle Intensity", 0, 1, 0.05, function(value)
            TrayectoUltimate:SetThemeValue("ParticleIntensity", value)
        end)

        extraTab:AddButton("🧪 Toggle Sandbox", function()
            if TrayectoUltimate.V4.Sandbox then
                TrayectoUltimate:EndSandbox()
            else
                TrayectoUltimate:BeginSandbox()
            end
        end)

        extraTab:AddButton("📊 Session Statistics", function()
            local stats = TrayectoUltimate:GetSessionStats()

            print("========== SESSION STATISTICS ==========")

            if not stats then
                print("No active session.")
            else
                print("Duration:", stats.Duration, "seconds")
                print("New errors:", stats.NewErrors)
                print("New recoveries:", stats.NewRecoveries)
            end

            print("========================================")
        end)

        extraTab:AddButton("🧩 Plugin List", function()
            print("============= PLUGINS =============")

            local plugins = TrayectoUltimate.V4.Plugins
            local count = 0

            for name in pairs(plugins) do
                count = count + 1
                print(name)
            end

            print("Total:", count)
            print("===================================")
        end)
    end
end)


-- ============================================================
-- TRAYECTOO ULTIMATE V5 - UTILITY / INSPECTION PACK
-- Passive tooling: does not automate remotes or bypass protections.
-- ============================================================
do
    local U = getgenv().TrayectoUltimate
    if U then
        U.V5 = U.V5 or {
            Favorites = {},
            Notes = {},
            Filters = {},
            Metrics = {},
            SearchCache = {},
            UIState = {
                Compact = false,
                ShowAdvanced = false,
            },
        }

        local V = U.V5

        function U:AddFavorite(name, value)
            V.Favorites[tostring(name)] = value
            self:AddTimeline("Favorite", "Saved: " .. tostring(name))
        end

        function U:RemoveFavorite(name)
            V.Favorites[tostring(name)] = nil
            self:AddTimeline("Favorite", "Removed: " .. tostring(name))
        end

        function U:AddNote(title, text)
            V.Notes[#V.Notes + 1] = {
                Title = tostring(title),
                Text = tostring(text),
                Time = os.time(),
            }
            while #V.Notes > 50 do
                table.remove(V.Notes, 1)
            end
        end

        function U:SearchDescendants(root, query, className)
            local result = {}
            if not root then return result end

            query = tostring(query or ""):lower()
            className = className and tostring(className) or nil

            for _, object in ipairs(root:GetDescendants()) do
                local nameMatch = query == "" or object.Name:lower():find(query, 1, true)
                local classMatch = not className or object.ClassName == className

                if nameMatch and classMatch then
                    result[#result + 1] = object
                end
            end

            return result
        end

        function U:SearchPlayerGui(query)
            local gui = player and player:FindFirstChildOfClass("PlayerGui")
            return self:SearchDescendants(gui, query)
        end

        function U:GetClassCounts(root)
            local counts = {}
            if not root then return counts end

            for _, object in ipairs(root:GetDescendants()) do
                counts[object.ClassName] = (counts[object.ClassName] or 0) + 1
            end

            return counts
        end

        function U:GetPlayerStatsSnapshot()
            local result = {}
            if not player then return result end

            for _, child in ipairs(player:GetChildren()) do
                if child:IsA("ValueBase") then
                    result[child.Name] = child.Value
                end
            end

            return result
        end

        function U:DiffTables(old, new)
            local changes = {}
            old = old or {}
            new = new or {}

            for key, value in pairs(new) do
                if old[key] ~= value then
                    changes[#changes + 1] = {
                        Key = key,
                        Old = old[key],
                        New = value,
                    }
                end
            end

            for key, value in pairs(old) do
                if new[key] == nil then
                    changes[#changes + 1] = {
                        Key = key,
                        Old = value,
                        New = nil,
                    }
                end
            end

            return changes
        end

        function U:CapturePlayerStats()
            V.Metrics.LastStats = self:GetPlayerStatsSnapshot()
            self:AddTimeline("Metrics", "Player stats snapshot captured")
            return V.Metrics.LastStats
        end

        function U:ComparePlayerStats()
            local current = self:GetPlayerStatsSnapshot()
            local old = V.Metrics.LastStats
            local changes = self:DiffTables(old, current)
            V.Metrics.LastStats = current
            return changes
        end

        function U:SetFilter(name, enabled)
            V.Filters[tostring(name)] = enabled and true or false
        end

        function U:IsFilterEnabled(name)
            return V.Filters[tostring(name)] ~= false
        end

        function U:SetCompactMode(enabled)
            V.UIState.Compact = enabled and true or false
            self:AddTimeline("UI", "Compact mode: " .. tostring(V.UIState.Compact))
        end

        function U:SetAdvancedMode(enabled)
            V.UIState.ShowAdvanced = enabled and true or false
            self:AddTimeline("UI", "Advanced mode: " .. tostring(V.UIState.ShowAdvanced))
        end

        function U:GetMemoryEstimate()
            -- Lua's collectgarbage value is an estimate, not a precise process metric.
            local kb = collectgarbage("count")
            return {
                Kilobytes = kb,
                Megabytes = kb / 1024,
            }
        end

        function U:ClearCaches()
            V.SearchCache = {}
            self:AddTimeline("Maintenance", "Search cache cleared")
        end

        function U:GetSystemSummary()
            local memory = self:GetMemoryEstimate()

            return {
                Version = self.Version,
                Uptime = self:GetUptime(),
                HealthScore = self:GetHealthScore(),
                Errors = #self.Errors,
                Recoveries = self.Recoveries,
                Modules = #self:GetModuleSummary(),
                MemoryMB = memory.Megabytes,
                TimelineEntries = #self.V4.Timeline,
                Snapshots = #self.Maintenance.Snapshots,
                Notes = #V.Notes,
                Favorites = 0,
            }
        end

        local favorites = 0
        for _ in pairs(V.Favorites) do
            favorites = favorites + 1
        end
        V.FavoritesCount = favorites
    end
end

-- ============================================================
-- V5 UI
-- ============================================================
pcall(function()
    if extraTab and TrayectoUltimate then
        extraTab:AddButton("🔎 UI Search", function()
            local matches = TrayectoUltimate:SearchPlayerGui("")
            print("========== UI SEARCH ==========")
            print("GuiObjects:", #matches)

            for i = 1, math.min(#matches, 100) do
                local object = matches[i]
                print(object:GetFullName(), "|", object.ClassName)
            end

            print("===============================")
        end)

        extraTab:AddButton("📊 UI Class Counts", function()
            local gui = player and player:FindFirstChildOfClass("PlayerGui")
            local counts = TrayectoUltimate:GetClassCounts(gui)

            print("======= UI CLASS COUNTS =======")
            for className, count in pairs(counts) do
                print(className .. ":", count)
            end
            print("===============================")
        end)

        extraTab:AddButton("📈 Player Stats Snapshot", function()
            local stats = TrayectoUltimate:CapturePlayerStats()

            print("======= PLAYER SNAPSHOT =======")
            for name, value in pairs(stats) do
                print(name .. ":", value)
            end
            print("===============================")
        end)

        extraTab:AddButton("🔄 Compare Player Stats", function()
            local changes = TrayectoUltimate:ComparePlayerStats()

            print("====== PLAYER STAT CHANGES ======")

            if #changes == 0 then
                print("No changes detected.")
            else
                for _, change in ipairs(changes) do
                    print(
                        tostring(change.Key) ..
                        ": " ..
                        tostring(change.Old) ..
                        " -> " ..
                        tostring(change.New)
                    )
                end
            end

            print("=================================")
        end)

        extraTab:AddButton("🧹 Clear Search Cache", function()
            TrayectoUltimate:ClearCaches()
        end)

        extraTab:AddButton("📝 Add Diagnostic Note", function()
            TrayectoUltimate:AddNote(
                "Manual note",
                "Created from Trayectoo diagnostics."
            )
            print("[Trayectoo] Note added")
        end)

        extraTab:AddButton("💻 System Summary", function()
            local summary = TrayectoUltimate:GetSystemSummary()

            print("========== SYSTEM SUMMARY ==========")
            for key, value in pairs(summary) do
                print(key .. ":", value)
            end
            print("====================================")
        end)

        extraTab:AddSwitch("Compact Diagnostics", function(state)
            TrayectoUltimate:SetCompactMode(state)
        end, "Reduce diagnostic output")

        extraTab:AddSwitch("Advanced Diagnostics", function(state)
            TrayectoUltimate:SetAdvancedMode(state)
        end, "Show advanced diagnostic information")
    end
end)


-- ============================================================
-- TRAYECTOO ULTIMATE V6 - AUTOMATIC MAINTENANCE / QUALITY PACK
-- Passive quality-of-life and diagnostics systems.
-- ============================================================
do
    local U = getgenv().TrayectoUltimate
    if U then
        U.V6 = U.V6 or {
            Started = os.clock(),
            EventCounters = {},
            Baselines = {},
            CleanupQueue = {},
            RateLimits = {},
            FeatureStates = {},
        }

        local V = U.V6

        function U:CountEvent(name)
            V.EventCounters[name] = (V.EventCounters[name] or 0) + 1
        end

        function U:SetFeatureState(name, state)
            V.FeatureStates[name] = state and true or false
            self:CountEvent("FeatureStateChanged")
        end

        function U:GetFeatureState(name)
            return V.FeatureStates[name] == true
        end

        function U:SetBaseline(name, value)
            V.Baselines[name] = value
        end

        function U:GetBaseline(name)
            return V.Baselines[name]
        end

        function U:QueueCleanup(name, callback)
            if type(callback) ~= "function" then return false end
            V.CleanupQueue[name] = callback
            return true
        end

        function U:RunCleanup()
            local count = 0
            for name, callback in pairs(V.CleanupQueue) do
                local ok = pcall(callback)
                if ok then
                    count = count + 1
                end
                V.CleanupQueue[name] = nil
            end
            self:AddTimeline("Cleanup", "Ran " .. tostring(count) .. " cleanup tasks")
            return count
        end

        function U:IsRateLimited(name, interval)
            local now = os.clock()
            local last = V.RateLimits[name] or 0

            if now - last < interval then
                return true
            end

            V.RateLimits[name] = now
            return false
        end

        function U:GetEventCounters()
            local copy = {}
            for name, count in pairs(V.EventCounters) do
                copy[name] = count
            end
            return copy
        end

        function U:DetectStaleConnections()
            local stale = {}

            for name, connection in pairs(self.Connections) do
                if connection == nil then
                    stale[#stale + 1] = name
                end
            end

            return stale
        end

        function U:ValidateModules()
            local problems = {}

            for name, module in pairs(self.Modules) do
                if not module.Status then
                    problems[#problems + 1] = name .. ": missing status"
                end

                if module.Errors < 0 or module.Runs < 0 then
                    problems[#problems + 1] = name .. ": invalid counters"
                end
            end

            return problems
        end

        function U:GenerateHealthReport()
            local report = self:FullCheck()
            report.Score = self:GetHealthScore()
            report.ModuleProblems = self:ValidateModules()
            report.StaleConnections = self:DetectStaleConnections()
            report.EventCounters = self:GetEventCounters()
            report.Uptime = self:GetUptime()

            return report
        end

        function U:ResetFeatureStates()
            V.FeatureStates = {}
            self:AddTimeline("Maintenance", "Feature states reset")
        end

        U:AddTimeline("V6", "Quality pack loaded")
    end
end

-- ============================================================
-- AUTOMATIC QUALITY MONITOR
-- ============================================================
task.spawn(function()
    local U = getgenv().TrayectoUltimate
    if not U then return end

    while U.Alive do
        task.wait(15)

        if U.Panic then
            break
        end

        pcall(function()
            local report = U:GenerateHealthReport()

            if #report.ModuleProblems > 0 then
                U:AddTimeline(
                    "Health",
                    tostring(#report.ModuleProblems) .. " module validation issue(s)"
                )
            end

            U:CountEvent("HealthReport")
        end)
    end
end)

-- ============================================================
-- V6 UI
-- ============================================================
pcall(function()
    if extraTab and TrayectoUltimate then
        extraTab:AddButton("🩺 Generate Health Report", function()
            local report = TrayectoUltimate:GenerateHealthReport()

            print("========== HEALTH REPORT ==========")
            print("Score:", tostring(report.Score) .. "%")
            print("Health:", report.Health)
            print("Uptime:", string.format("%.1fs", report.Uptime))
            print("Errors:", report.Errors)
            print("Recoveries:", report.Recoveries)
            print("Stale connections:", #report.StaleConnections)
            print("Module problems:", #report.ModuleProblems)
            print("===================================")
        end)

        extraTab:AddButton("🧹 Run Cleanup", function()
            TrayectoUltimate:RunCleanup()
        end)

        extraTab:AddButton("📊 Event Counters", function()
            print("========== EVENT COUNTERS ==========")

            local counters = TrayectoUltimate:GetEventCounters()

            for name, count in pairs(counters) do
                print(name .. ":", count)
            end

            print("====================================")
        end)

        extraTab:AddButton("🔍 Validate Modules", function()
            local problems = TrayectoUltimate:ValidateModules()

            print("========== MODULE VALIDATION ==========")

            if #problems == 0 then
                print("All module records are valid.")
            else
                for _, problem in ipairs(problems) do
                    print(problem)
                end
            end

            print("=======================================")
        end)

        extraTab:AddButton("♻ Reset Feature States", function()
            TrayectoUltimate:ResetFeatureStates()
        end)
    end
end)


-- ============================================================
-- TRAYECTOO ULTIMATE V7 - DATA / UI / SAFETY TOOLKIT
-- Passive utilities only; no remote bypass or exploit automation.
-- ============================================================
do
    local U = getgenv().TrayectoUltimate
    if U then
        U.V7 = U.V7 or {
            Bookmarks = {},
            Tags = {},
            RecentSearches = {},
            ConfigHistory = {},
            UIProfiles = {},
            Reports = {},
            ClipboardText = "",
            SafeLimits = {
                MaxNotes = 50,
                MaxReports = 25,
                MaxSearches = 30,
            },
        }

        local V = U.V7

        function U:AddBookmark(name, path)
            V.Bookmarks[tostring(name)] = tostring(path)
            self:AddTimeline("Bookmark", "Added: " .. tostring(name))
        end

        function U:RemoveBookmark(name)
            V.Bookmarks[tostring(name)] = nil
            self:AddTimeline("Bookmark", "Removed: " .. tostring(name))
        end

        function U:AddTag(target, tag)
            V.Tags[tostring(target)] = V.Tags[tostring(target)] or {}
            V.Tags[tostring(target)][tostring(tag)] = true
        end

        function U:GetTags(target)
            local result = {}
            local tags = V.Tags[tostring(target)] or {}

            for tag in pairs(tags) do
                result[#result + 1] = tag
            end

            table.sort(result)
            return result
        end

        function U:AddRecentSearch(query)
            query = tostring(query or "")
            if query == "" then return end

            table.insert(V.RecentSearches, query)

            while #V.RecentSearches > V.SafeLimits.MaxSearches do
                table.remove(V.RecentSearches, 1)
            end
        end

        function U:SaveConfigVersion()
            if not TrayectoCore or not TrayectoCore.Config then
                return false
            end

            local copy = {}
            for key, value in pairs(TrayectoCore.Config) do
                copy[key] = value
            end

            table.insert(V.ConfigHistory, {
                Time = os.time(),
                Config = copy,
            })

            while #V.ConfigHistory > 20 do
                table.remove(V.ConfigHistory, 1)
            end

            self:AddTimeline("Config", "Configuration version saved")
            return true
        end

        function U:CreateUIProfile(name)
            V.UIProfiles[tostring(name)] = {
                Layout = self.V4.Layout,
                Theme = {},
            }

            for key, value in pairs(self.V4.Theme) do
                V.UIProfiles[tostring(name)].Theme[key] = value
            end

            self:AddTimeline("UI", "Profile saved: " .. tostring(name))
        end

        function U:LoadUIProfile(name)
            local profile = V.UIProfiles[tostring(name)]
            if not profile then
                return false
            end

            self:SetLayout(profile.Layout)

            for key, value in pairs(profile.Theme) do
                self:SetThemeValue(key, value)
            end

            self:AddTimeline("UI", "Profile loaded: " .. tostring(name))
            return true
        end

        function U:CreateReport(name)
            local report = self:GenerateHealthReport()

            report.Name = tostring(name or "Trayectoo Report")
            report.CreatedAt = os.time()

            table.insert(V.Reports, report)

            while #V.Reports > V.SafeLimits.MaxReports do
                table.remove(V.Reports, 1)
            end

            self:AddTimeline("Report", "Created: " .. report.Name)
            return report
        end

        function U:GetReports()
            return V.Reports
        end

        function U:BuildQuickStatus()
            local memory = self:GetMemoryEstimate()

            return {
                Ready = self:GetHealthScore() >= 80 and not self.Panic,
                Health = self:GetHealthScore(),
                Errors = #self.Errors,
                Recoveries = self.Recoveries,
                Uptime = self:GetUptime(),
                MemoryMB = memory.Megabytes,
                SafeMode = self.V4.Sandbox,
                Layout = self.V4.Layout,
            }
        end

        function U:ResetV7Data()
            V.Bookmarks = {}
            V.Tags = {}
            V.RecentSearches = {}
            V.ConfigHistory = {}
            V.UIProfiles = {}
            V.Reports = {}
            self:AddTimeline("Maintenance", "V7 data reset")
        end
    end
end

-- ============================================================
-- V7 UI
-- ============================================================
pcall(function()
    if extraTab and TrayectoUltimate then
        extraTab:AddButton("⚡ Quick Status", function()
            local status = TrayectoUltimate:BuildQuickStatus()

            print("========== QUICK STATUS ==========")
            for key, value in pairs(status) do
                print(key .. ":", value)
            end
            print("==================================")
        end)

        extraTab:AddButton("📌 Save UI Profile", function()
            TrayectoUltimate:CreateUIProfile("Last Profile")
        end)

        extraTab:AddButton("↩ Load UI Profile", function()
            if not TrayectoUltimate:LoadUIProfile("Last Profile") then
                print("[Trayectoo] No saved UI profile")
            end
        end)

        extraTab:AddButton("💾 Save Config Version", function()
            TrayectoUltimate:SaveConfigVersion()
        end)

        extraTab:AddButton("📄 Create Diagnostic Report", function()
            local report = TrayectoUltimate:CreateReport("Manual Report")
            print("========== DIAGNOSTIC REPORT ==========")
            print("Name:", report.Name)
            print("Health:", report.Health)
            print("Score:", report.Score)
            print("Errors:", report.Errors)
            print("Recoveries:", report.Recoveries)
            print("=======================================")
        end)

        extraTab:AddButton("📚 Report Count", function()
            print("[Trayectoo] Reports:", #TrayectoUltimate:GetReports())
        end)

        extraTab:AddButton("🧹 Reset V7 Data", function()
            TrayectoUltimate:ResetV7Data()
        end)
    end
end)


-- ============================================================
-- TRAYECTOO ULTIMATE V8 - ORIGINAL UI PATTERNS PACK
-- Inspired by public Roblox UI-library patterns:
-- dependency visibility, scroll-friendly organization,
-- theme/save managers, notifications, keybind-style controls,
-- and declarative UI concepts.
-- Implemented independently; no source code is copied.
-- ============================================================
do
    local U = getgenv().TrayectoUltimate
    if U then
        U.V8 = U.V8 or {
            Dependencies = {},
            Notifications = {},
            Keybinds = {},
            Themes = {},
            SavedStates = {},
            SearchIndex = {},
            Sections = {},
        }

        local V = U.V8

        function U:RegisterDependency(name, predicate)
            if type(predicate) ~= "function" then return false end
            V.Dependencies[name] = predicate
            return true
        end

        function U:DependencyVisible(name)
            local predicate = V.Dependencies[name]
            if not predicate then return true end

            local ok, result = pcall(predicate)
            return ok and result == true
        end

        function U:PushNotification(title, message, duration)
            local item = {
                Title = tostring(title),
                Message = tostring(message),
                Duration = tonumber(duration) or 3,
                Time = os.clock(),
            }

            table.insert(V.Notifications, item)

            while #V.Notifications > 50 do
                table.remove(V.Notifications, 1)
            end

            self:AddTimeline("Notification", item.Title .. ": " .. item.Message)
            return item
        end

        function U:RegisterKeybind(name, key, callback)
            if type(callback) ~= "function" then return false end

            V.Keybinds[name] = {
                Key = key,
                Callback = callback,
            }

            return true
        end

        function U:RegisterTheme(name, values)
            if type(values) ~= "table" then return false end

            local copy = {}
            for key, value in pairs(values) do
                copy[key] = value
            end

            V.Themes[name] = copy
            return true
        end

        function U:ApplyTheme(name)
            local theme = V.Themes[name]
            if not theme then return false end

            for key, value in pairs(theme) do
                self:SetThemeValue(key, value)
            end

            self:AddTimeline("Theme", "Applied: " .. tostring(name))
            return true
        end

        function U:SaveState(name, state)
            if type(state) ~= "table" then return false end

            local copy = {}
            for key, value in pairs(state) do
                copy[key] = value
            end

            V.SavedStates[name] = copy
            return true
        end

        function U:LoadState(name)
            local state = V.SavedStates[name]
            if not state then return nil end

            local copy = {}
            for key, value in pairs(state) do
                copy[key] = value
            end

            return copy
        end

        function U:IndexObject(object)
            if not object then return end

            V.SearchIndex[object:GetFullName()] = {
                Name = object.Name,
                ClassName = object.ClassName,
            }
        end

        function U:BuildSearchIndex(root)
            V.SearchIndex = {}

            if not root then
                return 0
            end

            local count = 0
            for _, object in ipairs(root:GetDescendants()) do
                self:IndexObject(object)
                count = count + 1
            end

            return count
        end

        function U:SearchIndexQuery(query)
            local result = {}
            query = tostring(query or ""):lower()

            for path, info in pairs(V.SearchIndex) do
                if query == ""
                    or path:lower():find(query, 1, true)
                    or info.Name:lower():find(query, 1, true)
                    or info.ClassName:lower():find(query, 1, true) then

                    result[#result + 1] = {
                        Path = path,
                        Name = info.Name,
                        ClassName = info.ClassName,
                    }
                end
            end

            table.sort(result, function(a, b)
                return a.Path < b.Path
            end)

            return result
        end

        U:RegisterTheme("Trayectoo Dark", {
            Transparency = 0.08,
            CornerRadius = 10,
            AnimationSpeed = 0.18,
            ParticleIntensity = 0.35,
        })

        U:RegisterTheme("Trayectoo Compact", {
            Transparency = 0.14,
            CornerRadius = 7,
            AnimationSpeed = 0.12,
            ParticleIntensity = 0.15,
        })

        U:AddTimeline("V8", "Original UI patterns pack loaded")
    end
end

-- ============================================================
-- V8 UI
-- ============================================================
pcall(function()
    if extraTab and TrayectoUltimate then
        extraTab:AddButton("🔔 Test Notification", function()
            local item = TrayectoUltimate:PushNotification(
                "Trayectoo",
                "Notification system is working.",
                3
            )
            print("[Trayectoo]", item.Title, item.Message)
        end)

        extraTab:AddButton("🎨 Dark Theme", function()
            TrayectoUltimate:ApplyTheme("Trayectoo Dark")
        end)

        extraTab:AddButton("🎨 Compact Theme", function()
            TrayectoUltimate:ApplyTheme("Trayectoo Compact")
        end)

        extraTab:AddButton("🔎 Build UI Search Index", function()
            local gui = player and player:FindFirstChildOfClass("PlayerGui")
            local count = TrayectoUltimate:BuildSearchIndex(gui)
            print("[Trayectoo] Indexed objects:", count)
        end)

        extraTab:AddButton("📚 Search Indexed UI", function()
            local results = TrayectoUltimate:SearchIndexQuery("")
            print("========== INDEXED UI ==========")

            for i = 1, math.min(#results, 100) do
                local item = results[i]
                print(item.Path, "|", item.ClassName)
            end

            print("================================")
        end)

        extraTab:AddButton("💾 Save Current UI State", function()
            TrayectoUltimate:SaveState("LastUIState", {
                Layout = TrayectoUltimate.V4.Layout,
                Theme = TrayectoUltimate.V4.Theme,
                Compact = TrayectoUltimate.V5.UIState.Compact,
                Advanced = TrayectoUltimate.V5.UIState.ShowAdvanced,
            })

            print("[Trayectoo] UI state saved")
        end)

        extraTab:AddButton("📥 Read Saved UI State", function()
            local state = TrayectoUltimate:LoadState("LastUIState")

            if not state then
                print("[Trayectoo] No saved UI state")
                return
            end

            print("========== SAVED UI STATE ==========")
            print("Layout:", state.Layout)
            print("Compact:", state.Compact)
            print("Advanced:", state.Advanced)

            if state.Theme then
                for key, value in pairs(state.Theme) do
                    print("Theme." .. key .. ":", value)
                end
            end

            print("====================================")
        end)
    end
end)



-- ============================================================
-- TRAYECTOO V9 - GITHUB-INSPIRED QUALITY PACK
-- Added without replacing the existing GUI or existing features.
-- Features: live performance monitor, rock analyzer, session
-- statistics, server info and safe diagnostics.
-- ============================================================

pcall(function()
    local AnalyzerTab = window:AddTab("Analyzer")
    local PerfFolder = AnalyzerTab:AddFolder("⚡ Performance Monitor")
    local RockFolder = AnalyzerTab:AddFolder("🪨 Rock Analyzer")
    local SessionFolder = AnalyzerTab:AddFolder("📊 Session")
    local ServerFolder = AnalyzerTab:AddFolder("🌐 Server Info")

    local perfRunning = false
    local perfThread = nil

    local perfData = {
        Samples = 0,
        FPSMin = math.huge,
        FPSMax = 0,
        FPSSum = 0,
        PingMin = math.huge,
        PingMax = 0,
        PingSum = 0,
        Started = os.clock(),
    }

    local function getPingSafe()
        local ok, value = pcall(function()
            local ps = Stats:FindFirstChild("PerformanceStats")
            local ping = ps and ps:FindFirstChild("Ping")
            return ping and ping:GetValue() or 0
        end)
        return ok and tonumber(value) or 0
    end

    local function resetPerformance()
        perfData = {
            Samples = 0,
            FPSMin = math.huge,
            FPSMax = 0,
            FPSSum = 0,
            PingMin = math.huge,
            PingMax = 0,
            PingSum = 0,
            Started = os.clock(),
        }
    end

    local perfLabel = PerfFolder:AddLabel("FPS: -- | Ping: --")
    local perfAvgLabel = PerfFolder:AddLabel("Avg FPS: -- | Avg Ping: --")

    local function updatePerformance()
        local last = os.clock()

        while perfRunning do
            task.wait(1)

            local now = os.clock()
            local dt = math.max(now - last, 0.001)
            last = now

            -- This loop measures scheduler cadence, not true render FPS.
            -- Keep it as a scheduler-rate metric to avoid misleading labels.
            local fps = 1 / dt
            local ping = getPingSafe()

            perfData.Samples = perfData.Samples + 1
            perfData.FPSSum = perfData.FPSSum + fps
            perfData.FPSMin = math.min(perfData.FPSMin, fps)
            perfData.FPSMax = math.max(perfData.FPSMax, fps)

            if ping > 0 then
                perfData.PingSum = perfData.PingSum + ping
                perfData.PingMin = math.min(perfData.PingMin, ping)
                perfData.PingMax = math.max(perfData.PingMax, ping)
            end

            local avgFPS = perfData.FPSSum / perfData.Samples
            local avgPing = perfData.PingSum / math.max(perfData.Samples, 1)

            pcall(function()
                perfLabel.Text = string.format(
                    "FPS: %.0f | Ping: %.0f ms",
                    fps,
                    ping
                )
                perfAvgLabel.Text = string.format(
                    "Avg FPS: %.0f | Avg Ping: %.0f ms",
                    avgFPS,
                    avgPing
                )
            end)
        end
    end

    PerfFolder:AddSwitch("Live Performance", function(state)
        perfRunning = state

        if state then
            resetPerformance()
            if perfThread then
                return
            end

            perfThread = task.spawn(function()
                updatePerformance()
                perfThread = nil
            end)
        end
    end)

    PerfFolder:AddButton("📈 Performance Report", function()
        local samples = perfData.Samples

        if samples == 0 then
            print("[Trayectoo V9] No performance samples yet.")
            return
        end

        print("========== PERFORMANCE REPORT ==========")
        print(string.format("Samples: %d", samples))
        print(string.format("FPS Min: %.0f", perfData.FPSMin))
        print(string.format("FPS Avg: %.0f", perfData.FPSSum / samples))
        print(string.format("FPS Max: %.0f", perfData.FPSMax))

        if perfData.PingMax > 0 then
            print(string.format("Ping Min: %.0f ms", perfData.PingMin))
            print(string.format("Ping Avg: %.0f ms", perfData.PingSum / samples))
            print(string.format("Ping Max: %.0f ms", perfData.PingMax))
        end

        print("=========================================")
    end)

    PerfFolder:AddButton("🔄 Reset Performance", function()
        resetPerformance()
        perfLabel.Text = "FPS: -- | Ping: --"
        perfAvgLabel.Text = "Avg FPS: -- | Avg Ping: --"
    end)

    -- Rock Analyzer: reads the game's existing machine/rock data.
    local rockLabel = RockFolder:AddLabel("Rock: scanning...")
    local durabilityLabel = RockFolder:AddLabel("Durability: --")
    local rockCountLabel = RockFolder:AddLabel("Detected rocks: --")

    local function scanRocks()
        local results = {}
        local machines = workspace:FindFirstChild("machinesFolder")

        if not machines then
            return results
        end

        for _, obj in ipairs(machines:GetDescendants()) do
            if obj.Name == "neededDurability" and obj:IsA("ValueBase") then
                local machine = obj.Parent
                local rock = machine and machine:FindFirstChild("Rock")

                if rock then
                    results[#results + 1] = {
                        Durability = tonumber(obj.Value) or 0,
                        Name = machine.Name,
                        Rock = rock,
                    }
                end
            end
        end

        table.sort(results, function(a, b)
            return a.Durability < b.Durability
        end)

        return results
    end

    local function updateRockAnalyzer()
        local rocks = scanRocks()
        rockCountLabel.Text = "Detected rocks: " .. tostring(#rocks)

        if #rocks == 0 then
            rockLabel.Text = "Rock: none detected"
            durabilityLabel.Text = "Durability: --"
            return
        end

        local first = rocks[1]
        rockLabel.Text = "Lowest rock: " .. tostring(first.Name)
        durabilityLabel.Text = "Durability: " .. tostring(first.Durability)
    end

    RockFolder:AddButton("🔍 Scan Rocks", updateRockAnalyzer)

    RockFolder:AddButton("📋 Rock Ranking", function()
        local rocks = scanRocks()

        print("============== ROCK RANKING ==============")

        if #rocks == 0 then
            print("No rocks detected.")
        else
            for i, item in ipairs(rocks) do
                print(
                    string.format(
                        "#%d | %s | durability=%s",
                        i,
                        tostring(item.Name),
                        tostring(item.Durability)
                    )
                )
            end
        end

        print("===========================================")
    end)

    -- Session statistics based only on local leaderstats.
    local sessionStarted = os.clock()
    local startStrength = 0
    local startRebirths = 0

    pcall(function()
        local strength = leaderstats:FindFirstChild("Strength")
        if strength then
            startStrength = tonumber(strength.Value) or 0
        end
        startRebirths = tonumber(rebirthsStat.Value) or 0
    end)

    local sessionLabel = SessionFolder:AddLabel("Session: 0s")
    local gainsLabel = SessionFolder:AddLabel("Strength gained: 0 | Rebirths: 0")

    task.spawn(function()
        while true do
            task.wait(1)

            local elapsed = os.clock() - sessionStarted
            local strengthGain = 0
            local rebirthGain = 0

            pcall(function()
                local strength = leaderstats:FindFirstChild("Strength")
                strengthGain = (tonumber(strength and strength.Value) or 0) - startStrength
                rebirthGain = (tonumber(rebirthsStat.Value) or 0) - startRebirths
            end)

            sessionLabel.Text = string.format(
                "Session: %02d:%02d:%02d",
                math.floor(elapsed / 3600),
                math.floor((elapsed % 3600) / 60),
                math.floor(elapsed % 60)
            )

            gainsLabel.Text = string.format(
                "Strength gained: %s | Rebirths: %d",
                tostring(strengthGain),
                rebirthGain
            )
        end
    end)

    SessionFolder:AddButton("🔄 Reset Session Baseline", function()
        sessionStarted = os.clock()

        pcall(function()
            local strength = leaderstats:FindFirstChild("Strength")
            startStrength = tonumber(strength and strength.Value) or 0
            startRebirths = tonumber(rebirthsStat.Value) or 0
        end)

        print("[Trayectoo V9] Session baseline reset.")
    end)

    ServerFolder:AddLabel("PlaceId: " .. tostring(game.PlaceId))
    ServerFolder:AddLabel("JobId: " .. tostring(game.JobId))
    ServerFolder:AddLabel("Players: " .. tostring(#Players:GetPlayers()))

    ServerFolder:AddButton("🔄 Refresh Server Info", function()
        print("============= SERVER INFO =============")
        print("PlaceId:", game.PlaceId)
        print("JobId:", game.JobId)
        print("Players:", #Players:GetPlayers())
        print("Max Players:", Players.MaxPlayers)
        print("=======================================")
    end)

    Players.PlayerAdded:Connect(function()
        pcall(function()
            ServerFolder:AddLabel("Players now: " .. tostring(#Players:GetPlayers()))
        end)
    end)

    AnalyzerTab:Show()
end)




-- ============================================================
-- TRAYECTOO V10 - SECOND QUALITY PACK
-- Local analytics / diagnostics only.
-- ============================================================

pcall(function()
    local V10Tab = window:AddTab("V10 Tools")

    -- ---------------- PET RANKING ----------------
    local PetFolderV10 = V10Tab:AddFolder("🐾 Pet Ranking")

    local function getPetObjects()
        local folder = player and player:FindFirstChild("petsFolder")
        if not folder then return {} end

        local result = {}
        for _, pet in ipairs(folder:GetChildren()) do
            if pet:IsA("Folder") or pet:IsA("Model") or pet:IsA("Configuration") then
                result[#result + 1] = pet
            end
        end
        return result
    end

    local function readNumber(parent, names)
        for _, name in ipairs(names) do
            local obj = parent:FindFirstChild(name, true)
            if obj and obj:IsA("ValueBase") then
                local n = tonumber(obj.Value)
                if n then return n end
            end
        end
        return 0
    end

    PetFolderV10:AddButton("🏆 Analyze Pets", function()
        local pets = getPetObjects()

        table.sort(pets, function(a, b)
            local av = readNumber(a, {"Strength", "strength", "Multiplier", "multiplier", "Power"})
            local bv = readNumber(b, {"Strength", "strength", "Multiplier", "multiplier", "Power"})
            return av > bv
        end)

        print("=============== PET RANKING ===============")

        if #pets == 0 then
            print("No pet objects detected.")
        else
            for i, pet in ipairs(pets) do
                local value = readNumber(
                    pet,
                    {"Strength", "strength", "Multiplier", "multiplier", "Power"}
                )
                print(string.format("#%d | %s | value=%s", i, pet.Name, tostring(value)))
            end
        end

        print("============================================")
    end)

    -- ---------------- ROCK DPS ----------------
    local DPSFolder = V10Tab:AddFolder("🪨 Rock DPS Analyzer")

    local dpsSamples = {}
    local dpsRunning = false
    local lastDurability = nil
    local lastSampleTime = nil

    local dpsLabel = DPSFolder:AddLabel("DPS: -- | Samples: 0")

    local function findDurabilityValue()
        local candidates = {
            "Durability",
            "durability",
            "Health",
            "HP",
            "Hitpoints",
        }

        for _, name in ipairs(candidates) do
            local obj = workspace:FindFirstChild(name, true)
            if obj and obj:IsA("ValueBase") and tonumber(obj.Value) then
                return obj
            end
        end

        return nil
    end

    local function averageDPS()
        if #dpsSamples == 0 then return 0 end

        local total = 0
        for _, value in ipairs(dpsSamples) do
            total = total + value
        end
        return total / #dpsSamples
    end

    DPSFolder:AddSwitch("Measure DPS", function(state)
        dpsRunning = state

        if not state then
            lastDurability = nil
            lastSampleTime = nil
            return
        end

        task.spawn(function()
            while dpsRunning do
                task.wait(0.5)

                local value = findDurabilityValue()
                if value then
                    local current = tonumber(value.Value) or 0
                    local now = os.clock()

                    if lastDurability ~= nil and lastSampleTime then
                        local damage = math.max(0, lastDurability - current)
                        local elapsed = math.max(now - lastSampleTime, 0.001)
                        local dps = damage / elapsed

                        if dps > 0 then
                            dpsSamples[#dpsSamples + 1] = dps
                            while #dpsSamples > 30 do
                                table.remove(dpsSamples, 1)
                            end

                            dpsLabel.Text = string.format(
                                "DPS: %.2f | Samples: %d",
                                averageDPS(),
                                #dpsSamples
                            )
                        end
                    end

                    lastDurability = current
                    lastSampleTime = now
                end
            end
        end)
    end)

    DPSFolder:AddButton("🧹 Reset DPS", function()
        table.clear(dpsSamples)
        lastDurability = nil
        lastSampleTime = nil
        dpsLabel.Text = "DPS: -- | Samples: 0"
    end)

    -- ---------------- STATS / H ----------------
    local StatsFolderV10 = V10Tab:AddFolder("📈 Stats Per Hour")

    local statsStart = os.clock()
    local startStr = 0
    local startDur = 0
    local startReb = 0

    local rateLabel = StatsFolderV10:AddLabel("Strength/h: -- | Durability/h: --")
    local rebRateLabel = StatsFolderV10:AddLabel("Rebirths/h: --")

    local function resetRates()
        statsStart = os.clock()

        pcall(function()
            local s = leaderstats and leaderstats:FindFirstChild("Strength")
            startStr = tonumber(s and s.Value) or 0

            local d = player and player:FindFirstChild("Durability")
            startDur = tonumber(d and d.Value) or 0

            startReb = tonumber(rebirthsStat and rebirthsStat.Value) or 0
        end)
    end

    resetRates()

    StatsFolderV10:AddButton("🔄 Reset Rates", resetRates)

    task.spawn(function()
        while true do
            task.wait(2)

            local elapsedHours = math.max((os.clock() - statsStart) / 3600, 1 / 3600)
            local strength = 0
            local durability = 0
            local rebirths = 0

            pcall(function()
                local s = leaderstats and leaderstats:FindFirstChild("Strength")
                strength = tonumber(s and s.Value) or startStr

                local d = player and player:FindFirstChild("Durability")
                durability = tonumber(d and d.Value) or startDur

                rebirths = tonumber(rebirthsStat and rebirthsStat.Value) or startReb
            end)

            rateLabel.Text = string.format(
                "Strength/h: %.2f | Durability/h: %.2f",
                math.max(0, strength - startStr) / elapsedHours,
                math.max(0, durability - startDur) / elapsedHours
            )

            rebRateLabel.Text = string.format(
                "Rebirths/h: %.2f",
                math.max(0, rebirths - startReb) / elapsedHours
            )
        end
    end)

    -- ---------------- ETA ----------------
    local ETAFolder = V10Tab:AddFolder("⏱ ETA Calculator")

    local targetValue = 0
    local targetBox = ETAFolder:AddTextBox(
        "Target Strength",
        function(value)
            targetValue = tonumber(value) or 0
        end
    )

    local etaLabel = ETAFolder:AddLabel("ETA: --")

    ETAFolder:AddButton("🧮 Calculate ETA", function()
        local current = 0

        pcall(function()
            local s = leaderstats and leaderstats:FindFirstChild("Strength")
            current = tonumber(s and s.Value) or 0
        end)

        if targetValue <= current then
            etaLabel.Text = "ETA: Already reached"
            return
        end

        local elapsed = math.max(os.clock() - statsStart, 1)
        local gained = math.max(0, current - startStr)

        if gained <= 0 then
            etaLabel.Text = "ETA: Need more samples"
            return
        end

        local perSecond = gained / elapsed
        local seconds = (targetValue - current) / perSecond

        etaLabel.Text = string.format(
            "ETA: %02d:%02d:%02d",
            math.floor(seconds / 3600),
            math.floor((seconds % 3600) / 60),
            math.floor(seconds % 60)
        )
    end)

    -- ---------------- BEST ROCK ----------------
    local BestRockFolder = V10Tab:AddFolder("🏆 Best Available Rock")

    local bestRockLabel = BestRockFolder:AddLabel("Best rock: scanning...")

    local function getPlayerStrength()
        local value = 0
        pcall(function()
            local s = leaderstats and leaderstats:FindFirstChild("Strength")
            value = tonumber(s and s.Value) or 0
        end)
        return value
    end

    BestRockFolder:AddButton("🔎 Find Best Rock", function()
        local strength = getPlayerStrength()
        local best = nil

        local machines = workspace:FindFirstChild("machinesFolder")

        if machines then
            for _, obj in ipairs(machines:GetDescendants()) do
                if obj.Name == "neededDurability"
                    and obj:IsA("ValueBase")
                    and tonumber(obj.Value) then

                    local durability = tonumber(obj.Value)

                    if durability <= strength then
                        if not best or durability > best.Durability then
                            best = {
                                Name = obj.Parent and obj.Parent.Name or "Unknown",
                                Durability = durability,
                            }
                        end
                    end
                end
            end
        end

        if best then
            bestRockLabel.Text = string.format(
                "Best rock: %s | %s",
                best.Name,
                tostring(best.Durability)
            )
            print("[Trayectoo V10] Best rock:", best.Name, best.Durability)
        else
            bestRockLabel.Text = "Best rock: none detected"
        end
    end)

    -- ---------------- OBJECT SCANNER ----------------
    local ScanFolder = V10Tab:AddFolder("🔍 Object Scanner")

    local scanName = ""
    ScanFolder:AddTextBox("Object name", function(value)
        scanName = tostring(value)
    end)

    ScanFolder:AddButton("🔍 Scan Workspace", function()
        if scanName == "" then
            print("[Trayectoo V10] Enter an object name first.")
            return
        end

        local found = 0

        for _, obj in ipairs(workspace:GetDescendants()) do
            if string.lower(obj.Name) == string.lower(scanName) then
                found = found + 1
                print(
                    string.format(
                        "#%d | %s | %s",
                        found,
                        obj:GetFullName(),
                        obj.ClassName
                    )
                )
            end
        end

        print("[Trayectoo V10] Objects found:", found)
    end)

    -- ---------------- ERROR DASHBOARD ----------------
    local ErrorFolder = V10Tab:AddFolder("🩺 Error Dashboard")

    local errorLabel = ErrorFolder:AddLabel("Errors: 0")

    local function refreshErrors()
        if TrayectoUltimate then
            errorLabel.Text = "Errors: " .. tostring(#TrayectoUltimate.Errors)
        end
    end

    ErrorFolder:AddButton("🔄 Refresh Errors", refreshErrors)

    ErrorFolder:AddButton("📋 Print Errors", function()
        if not TrayectoUltimate then return end

        print("============== ERROR DASHBOARD ==============")

        if #TrayectoUltimate.Errors == 0 then
            print("No recorded errors.")
        else
            for i, err in ipairs(TrayectoUltimate.Errors) do
                print(
                    string.format(
                        "#%d | %s | %s",
                        i,
                        tostring(err.Module or err.Label),
                        tostring(err.Message)
                    )
                )
            end
        end

        print("==============================================")
    end)

    -- ---------------- SESSION HISTORY ----------------
    local HistoryFolder = V10Tab:AddFolder("💾 Session History")

    local history = {}
    local historyLabel = HistoryFolder:AddLabel("Sessions stored: 0")

    HistoryFolder:AddButton("💾 Save Current Session", function()
        local duration = os.clock() - statsStart

        local record = {
            Time = os.time(),
            Duration = duration,
            StrengthStart = startStr,
            DurabilityStart = startDur,
            RebirthsStart = startReb,
        }

        history[#history + 1] = record

        while #history > 20 do
            table.remove(history, 1)
        end

        historyLabel.Text = "Sessions stored: " .. tostring(#history)
        print("[Trayectoo V10] Session saved.")
    end)

    HistoryFolder:AddButton("📋 Show History", function()
        print("============== SESSION HISTORY ==============")

        for i, session in ipairs(history) do
            print(
                string.format(
                    "#%d | duration=%.1fs | strengthStart=%s | rebirthsStart=%s",
                    i,
                    session.Duration,
                    tostring(session.StrengthStart),
                    tostring(session.RebirthsStart)
                )
            )
        end

        print("=============================================")
    end)

    -- ---------------- LIVE DASHBOARD ----------------
    local DashboardFolder = V10Tab:AddFolder("📊 Live Dashboard")

    local dashboard = DashboardFolder:AddLabel("Loading dashboard...")

    task.spawn(function()
        while true do
            task.wait(2)

            local strength = 0
            local durability = 0
            local rebirths = 0
            local ping = 0

            pcall(function()
                local s = leaderstats and leaderstats:FindFirstChild("Strength")
                strength = tonumber(s and s.Value) or 0

                local d = player and player:FindFirstChild("Durability")
                durability = tonumber(d and d.Value) or 0

                rebirths = tonumber(rebirthsStat and rebirthsStat.Value) or 0
            end)

            pcall(function()
                local ps = Stats:FindFirstChild("PerformanceStats")
                local p = ps and ps:FindFirstChild("Ping")
                ping = tonumber(p and p:GetValue()) or 0
            end)

            dashboard.Text = string.format(
                "Strength: %s\nDurability: %s\nRebirths: %s\nPing: %d ms",
                tostring(strength),
                tostring(durability),
                tostring(rebirths),
                ping
            )
        end
    end)

    -- ---------------- LOCAL PERFORMANCE MODE ----------------
    local ModeFolder = V10Tab:AddFolder("⚙️ Performance Mode")
    local performanceMode = false

    ModeFolder:AddSwitch("Low Visual Load", function(state)
        performanceMode = state

        -- Only changes local visual effects; it does not modify
        -- game remotes or other players.
        pcall(function()
            local lighting = game:GetService("Lighting")

            if state then
                lighting.GlobalShadows = false
                lighting.FogEnd = math.min(lighting.FogEnd, 500)
            else
                lighting.GlobalShadows = true
            end
        end)

        print(
            "[Trayectoo V10] Performance Mode:",
            performanceMode and "ON" or "OFF"
        )
    end)

    V10Tab:Show()
end)




-- ============================================================
-- TRAYECTOO V10 IMPROVED - STABILITY / QUALITY LAYER
-- Focus: lower overhead, bounded memory, safer scanning,
-- better number formatting, diagnostics and cleanup.
-- ============================================================

pcall(function()
    local QualityTab = window:AddTab("V10 Improved")
    local QualityFolder = QualityTab:AddFolder("🛠 Quality Control")
    local MonitorFolder = QualityTab:AddFolder("📡 Smart Monitor")
    local CacheFolder = QualityTab:AddFolder("🗂 Smart Cache")
    local CleanupFolder = QualityTab:AddFolder("🧹 Cleanup")

    local Quality = {
        running = true,
        connections = {},
        cache = {},
        scanInterval = 3,
        historyLimit = 60,
    }

    local function connect(signal, callback)
        local ok, connection = pcall(function()
            return signal:Connect(callback)
        end)

        if ok and connection then
            Quality.connections[#Quality.connections + 1] = connection
        end

        return connection
    end

    local function disconnectAll()
        for _, connection in ipairs(Quality.connections) do
            pcall(function()
                connection:Disconnect()
            end)
        end
        table.clear(Quality.connections)
    end

    local function formatNumber(n)
        n = tonumber(n) or 0

        local negative = n < 0
        n = math.abs(n)

        local suffixes = {
            {1e12, "T"},
            {1e9, "B"},
            {1e6, "M"},
            {1e3, "K"},
        }

        for _, item in ipairs(suffixes) do
            if n >= item[1] then
                local value = n / item[1]
                return string.format(
                    negative and "-%.2f%s" or "%.2f%s",
                    value,
                    item[2]
                )
            end
        end

        return string.format(negative and "-%.0f" or "%.0f", n)
    end

    local function getStat(name)
        local ok, value = pcall(function()
            local obj = leaderstats and leaderstats:FindFirstChild(name)
            return tonumber(obj and obj.Value) or 0
        end)

        return ok and value or 0
    end

    local function getPlayerValue(name)
        local ok, value = pcall(function()
            local obj = player and player:FindFirstChild(name)
            return tonumber(obj and obj.Value) or 0
        end)

        return ok and value or 0
    end

    -- ---------------- QUALITY CONTROL ----------------

    local qualityLabel = QualityFolder:AddLabel("State: Running")
    local intervalLabel = QualityFolder:AddLabel("Monitor interval: 3s")

    QualityFolder:AddSwitch("Smart Monitor", function(state)
        Quality.running = state
        qualityLabel.Text = "State: " .. (state and "Running" or "Paused")
    end)

    QualityFolder:AddTextBox("Interval (seconds)", function(value)
        local n = tonumber(value)

        if n then
            Quality.scanInterval = math.clamp(n, 1, 30)
            intervalLabel.Text =
                "Monitor interval: " .. tostring(Quality.scanInterval) .. "s"
        end
    end)

    -- ---------------- SMART MONITOR ----------------

    local monitorLabel = MonitorFolder:AddLabel(
        "Strength: -- | Durability: -- | Rebirths: --"
    )

    local rateLabel = MonitorFolder:AddLabel(
        "Strength/h: -- | Durability/h: -- | Rebirths/h: --"
    )

    local monitorStart = os.clock()
    local baseStrength = getStat("Strength")
    local baseDurability = getPlayerValue("Durability")
    local baseRebirths = getStat("Rebirths")

    local function resetMonitor()
        monitorStart = os.clock()
        baseStrength = getStat("Strength")
        baseDurability = getPlayerValue("Durability")
        baseRebirths = getStat("Rebirths")
    end

    MonitorFolder:AddButton("🔄 Reset Monitor", resetMonitor)

    task.spawn(function()
        while Quality.running do
            task.wait(Quality.scanInterval)

            local strength = getStat("Strength")
            local durability = getPlayerValue("Durability")
            local rebirths = getStat("Rebirths")

            local hours = math.max(
                (os.clock() - monitorStart) / 3600,
                1 / 3600
            )

            monitorLabel.Text = string.format(
                "Strength: %s | Durability: %s | Rebirths: %s",
                formatNumber(strength),
                formatNumber(durability),
                formatNumber(rebirths)
            )

            rateLabel.Text = string.format(
                "Strength/h: %s | Durability/h: %s | Rebirths/h: %.2f",
                formatNumber(math.max(0, strength - baseStrength) / hours),
                formatNumber(math.max(0, durability - baseDurability) / hours),
                math.max(0, rebirths - baseRebirths) / hours
            )
        end
    end)

    -- ---------------- SMART CACHE ----------------

    local cacheLabel = CacheFolder:AddLabel("Cache: empty")

    local function scanMachineFolder()
        local result = {}
        local machines = workspace:FindFirstChild("machinesFolder")

        if not machines then
            return result
        end

        for _, obj in ipairs(machines:GetDescendants()) do
            if obj.Name == "neededDurability" and obj:IsA("ValueBase") then
                local value = tonumber(obj.Value)

                if value then
                    result[#result + 1] = {
                        name = obj.Parent and obj.Parent.Name or obj.Name,
                        durability = value,
                        instance = obj.Parent,
                    }
                end
            end
        end

        table.sort(result, function(a, b)
            return a.durability < b.durability
        end)

        return result
    end

    local function refreshCache()
        local rocks = scanMachineFolder()

        Quality.cache.rocks = rocks
        Quality.cache.updated = os.clock()

        cacheLabel.Text = string.format(
            "Cache: %d rocks | updated %.1fs ago",
            #rocks,
            0
        )

        return rocks
    end

    CacheFolder:AddButton("🔄 Refresh Rock Cache", refreshCache)

    CacheFolder:AddButton("📋 Print Cached Rocks", function()
        local rocks = Quality.cache.rocks or {}

        print("============= CACHED ROCKS =============")

        for i, rock in ipairs(rocks) do
            print(
                string.format(
                    "#%d | %s | durability=%s",
                    i,
                    tostring(rock.name),
                    tostring(rock.durability)
                )
            )
        end

        print("=========================================")
    end)

    task.spawn(function()
        while Quality.running do
            task.wait(Quality.scanInterval)

            local rocks = refreshCache()

            if Quality.cache.updated then
                cacheLabel.Text = string.format(
                    "Cache: %d rocks | ready",
                    #rocks
                )
            end
        end
    end)

    -- ---------------- CLEANUP ----------------

    local cleanupLabel = CleanupFolder:AddLabel("Tracked connections: 0")

    CleanupFolder:AddButton("🧹 Disconnect Quality Layer", function()
        Quality.running = false
        disconnectAll()
        cleanupLabel.Text = "Quality layer stopped"
        qualityLabel.Text = "State: Stopped"
    end)

    CleanupFolder:AddButton("🗑 Clear Cached Data", function()
        table.clear(Quality.cache)
        cacheLabel.Text = "Cache: empty"
    end)

    CleanupFolder:AddButton("📊 Diagnostics", function()
        print("=========== TRAYECTOO V10 DIAGNOSTICS ===========")
        print("Quality running:", Quality.running)
        print("Monitor interval:", Quality.scanInterval)

        local rocks = Quality.cache.rocks or {}
        print("Cached rocks:", #rocks)
        print("Tracked connections:", #Quality.connections)

        print("PlaceId:", game.PlaceId)
        print("JobId:", game.JobId)
        print("Players:", #Players:GetPlayers())
        print("==================================================")
    end)

    cleanupLabel.Text =
        "Tracked connections: " .. tostring(#Quality.connections)

    QualityTab:Show()
end)


-- ============================================================
-- TRAYECTOO AI ADVANCED - AUTO DIAGNOSTICS + VERSION HISTORY
-- Safe workflow: diagnose -> ask AI -> save version -> apply/revert.
-- AI-generated code is NEVER executed automatically.
-- ============================================================
pcall(function()
    if not window then return end
    local HttpService = game:GetService("HttpService")
    local LogService = game:GetService("LogService")
    local AITab = window:AddTab("🤖 AI Advanced")
    local DiagFolder = AITab:AddFolder("🩺 Auto Diagnostics")
    local AIFolder = AITab:AddFolder("🧠 AI Code Doctor")
    local HistoryFolder = AITab:AddFolder("🕘 Version History")
    local FileFolder = AITab:AddFolder("📁 Files / Safety")

    local AI = {
        Endpoint = "https://api.openai.com/v1/chat/completions",
        FCCEndpoint = "http://127.0.0.1:8082/v1/messages",
        FCCAuthToken = "freecc",
        FCCModel = "fcc/auto",
        Model = "gpt-4o-mini",
        Key = "",
        Source = "Trayectoo_COMPLETE_ULTIMATE_V10_IMPROVED.lua",
        Output = "Trayectoo_AI_WORKING.lua",
        Backup = "Trayectoo_AI_BACKUP.lua",
        History = "Trayectoo_AI_History.json",
        Errors = {}, MaxErrors = 40, RestoreVersion = nil,
    }

    local function safeText(v, max)
        v = tostring(v or "")
        max = max or 12000
        return #v > max and v:sub(1, max) .. "\n...[truncated]..." or v
    end
    local function hasFiles()
        return type(isfile)=="function" and type(readfile)=="function" and type(writefile)=="function"
    end
    local function saveText(path, text)
        if not hasFiles() then return false, "File APIs unavailable" end
        local ok, err = pcall(function() writefile(path, text) end)
        return ok, ok and nil or tostring(err)
    end
    local function readText(path)
        if not hasFiles() or not isfile(path) then return nil, "File not found: "..tostring(path) end
        local ok, data = pcall(readfile, path)
        return ok and data or nil, ok and nil or tostring(data)
    end
    local function requestFunction()
        if type(request)=="function" then return request end
        if syn and type(syn.request)=="function" then return syn.request end
        if http and type(http.request)=="function" then return http.request end
        if fluxus and type(fluxus.request)=="function" then return fluxus.request end
    end
    local function postJSON(url, body, headers)
        local req = requestFunction()
        if not req then return nil, "No executor HTTP request function" end
        local ok, response = pcall(req, {Url=url, Method="POST", Headers=headers, Body=HttpService:JSONEncode(body)})
        if not ok or type(response)~="table" then return nil, tostring(response) end
        local status = tonumber(response.StatusCode or response.Status or 0) or 0
        local raw = response.Body or response.body or ""
        if status >= 400 then return nil, "HTTP "..status..": "..safeText(raw,1000) end
        local dok, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
        return dok and decoded or nil, dok and nil or "Invalid JSON response"
    end
    local function pushError(msg, source)
        table.insert(AI.Errors, 1, {time=os.date("%Y-%m-%d %H:%M:%S"), message=safeText(msg,2500), source=safeText(source,600)})
        while #AI.Errors > AI.MaxErrors do table.remove(AI.Errors) end
    end

    local diagLabel = DiagFolder:AddLabel("Errors captured: 0")
    local diagLast = DiagFolder:AddLabel("Last error: none")
    local function refreshDiagnostics()
        diagLabel.Text = "Errors captured: "..#AI.Errors
        diagLast.Text = AI.Errors[1] and "Last: "..safeText(AI.Errors[1].message,180) or "Last error: none"
    end
    pcall(function()
        LogService.MessageOut:Connect(function(message, messageType)
            if tostring(messageType):find("Error") then
                pushError(message,"LogService.MessageOut")
                refreshDiagnostics()
            end
        end)
    end)
    DiagFolder:AddButton("🔄 Refresh diagnostics", refreshDiagnostics)
    DiagFolder:AddButton("🧹 Clear captured errors", function() AI.Errors={}; refreshDiagnostics() end)
    DiagFolder:AddButton("📋 Print diagnostic report", function()
        print("========== TRAYECTOO AI DIAGNOSTICS ==========")
        for i,e in ipairs(AI.Errors) do print("#"..i,e.time,e.source); print(e.message) end
        print("==============================================")
    end)

    AIFolder:AddTextBox("API Endpoint", function(v) if tostring(v)~="" then AI.Endpoint=tostring(v) end end)
    AIFolder:AddTextBox("Model", function(v) if tostring(v)~="" then AI.Model=tostring(v) end end)
    AIFolder:AddTextBox("API Key", function(v) AI.Key=tostring(v or "") end)
    AIFolder:AddTextBox("Source file", function(v) if tostring(v)~="" then AI.Source=tostring(v) end end)
    AIFolder:AddTextBox("AI output file", function(v) if tostring(v)~="" then AI.Output=tostring(v) end end)
    local statusLabel = AIFolder:AddLabel("AI status: idle")

    -- ========================================================
    -- GENERAL ONLINE ASSISTANT
    -- Available to normal users; separate from Code Doctor.
    -- ========================================================
    local AssistantFolder = AITab:AddFolder("🤖 General Assistant")
    local AssistantMode = "AUTO" -- LOCAL / FCC / ONLINE / AUTO
    local LocalRules = {
        ["hola"] = "¡Hola! Soy el asistente de Trayectoo. Puedo ayudarte con la GUI, funciones y errores comunes.",
        ["ayuda"] = "Podés preguntarme qué hace una opción, cómo solucionar un error o cómo funciona el script.",
        ["gui"] = "La GUI está organizada por pestañas y carpetas. Si una función no aparece, revisá que la pestaña se haya creado correctamente.",
        ["error"] = "Puedo ayudarte a revisar errores capturados. Abrí 🩺 Auto Diagnostics para ver los últimos errores.",
        ["internet"] = "El modo ONLINE necesita un endpoint compatible y, normalmente, una API Key.",
        ["api"] = "Si no configurás una API, el modo LOCAL sigue funcionando con el conocimiento y reglas incorporadas en el script.",
    }

    local function localAssistant(question)
        local q = string.lower(tostring(question or ""))
        for keyword, answer in pairs(LocalRules) do
            if q:find(keyword, 1, true) then
                return answer
            end
        end

        if q:find("qué hace", 1, true) or q:find("que hace", 1, true) then
            return "Puedo explicarte las funciones principales de la GUI. Decime el nombre de la opción que querés entender."
        end

        if q:find("no funciona", 1, true) or q:find("no anda", 1, true) then
            return "Probá 🩺 Auto Diagnostics → Refresh diagnostics. Si hay errores, el modo Code Doctor puede analizarlos."
        end

        return "Estoy en modo LOCAL. Puedo ayudarte con funciones conocidas de la GUI y errores comunes. Para respuestas más avanzadas, cambiá a ONLINE."
    end

    AssistantFolder:AddSwitch("🧩 FCC Local", function(state)
        if state then
            AssistantMode = "FCC"
            assistantLabel.Text = "🤖 Assistant: FCC LOCAL"
        end
    end)

    AssistantFolder:AddSwitch("🌐 Online", function(state)
        if state then
            AssistantMode = "ONLINE"
            assistantLabel.Text = "🤖 Assistant: ONLINE"
        end
    end)

    AssistantFolder:AddSwitch("🧠 Local", function(state)
        if state then
            AssistantMode = "LOCAL"
            assistantLabel.Text = "🤖 Assistant: LOCAL"
        end
    end)

    AssistantFolder:AddSwitch("🔄 Auto", function(state)
        if state then
            AssistantMode = "AUTO"
            assistantLabel.Text = "🤖 Assistant: AUTO"
        end
    end)

    AssistantFolder:AddLabel("Modo actual: AUTO")
    
    local assistantQuestion = ""
    local assistantLabel = AssistantFolder:AddLabel("🤖 Assistant: ready")
    local assistantHistory = {}

    AssistantFolder:AddTextBox("💬 Ask anything", function(v)
        assistantQuestion = tostring(v or "")
    end)

    local function assistantMessages()
        local messages = {
            {
                role = "system",
                content = table.concat({
                    "You are Trayectoo's general in-game assistant.",
                    "You are NOT an admin-only assistant.",
                    "Help regular users with questions about the menu, features, gameplay concepts, troubleshooting and general information.",
                    "Do not claim to have performed actions that you did not perform.",
                    "Do not reveal API keys, credentials, tokens or private data.",
                    "Keep answers clear and useful."
                }, "\n")
            }
        }

        for _, message in ipairs(assistantHistory) do
            messages[#messages + 1] = message
        end

        return messages
    end

    -- ========================================================
    -- FREE CLAUDE CODE BRIDGE
    -- Lua client for the FCC Anthropic-compatible local server.
    -- The FCC Python backend must run separately on localhost.
    -- ========================================================
    local function postFCC(question)
        local req = requestFunction()
        if not req then return nil, "No executor HTTP request function" end

        local messages = {}
        for _, message in ipairs(assistantHistory) do
            if message.role == "user" or message.role == "assistant" then
                messages[#messages + 1] = {
                    role = message.role,
                    content = message.content
                }
            end
        end
        messages[#messages + 1] = {role = "user", content = tostring(question)}

        local headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. tostring(AI.FCCAuthToken or "")
        }

        local ok, response = pcall(req, {
            Url = AI.FCCEndpoint,
            Method = "POST",
            Headers = headers,
            Body = HttpService:JSONEncode({
                model = AI.FCCModel,
                max_tokens = 1200,
                messages = messages
            })
        })

        if not ok or type(response) ~= "table" then
            return nil, tostring(response)
        end

        local status = tonumber(response.StatusCode or response.Status or 0) or 0
        local raw = response.Body or response.body or ""
        if status >= 400 then
            return nil, "FCC HTTP " .. tostring(status) .. ": " .. safeText(raw, 500)
        end

        local decodedOK, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
        if not decodedOK or type(decoded) ~= "table" then
            return nil, "FCC returned invalid JSON"
        end

        if type(decoded.content) == "table" then
            for _, block in ipairs(decoded.content) do
                if type(block) == "table" and block.type == "text" then
                    return tostring(block.text or ""), nil
                end
            end
        end

        return nil, "FCC returned no text"
    end

    local function askGeneralAssistant(question)
        local headers = {["Content-Type"] = "application/json"}

        if AI.Key ~= "" then
            headers["Authorization"] = "Bearer " .. AI.Key
        end

        local messages = assistantMessages()
        messages[#messages + 1] = {
            role = "user",
            content = question
        }

        local response, err = postJSON(AI.Endpoint, {
            model = AI.Model,
            temperature = 0.3,
            messages = messages
        }, headers)

        if not response then
            return nil, err
        end

        local answer = extractAIText(response)

        if answer then
            assistantHistory[#assistantHistory + 1] = {
                role = "user",
                content = question
            }

            assistantHistory[#assistantHistory + 1] = {
                role = "assistant",
                content = safeText(answer, 12000)
            }

            while #assistantHistory > 20 do
                table.remove(assistantHistory, 1)
            end
        end

        return answer
    end

    AssistantFolder:AddButton("💬 Send message", function()
        if assistantQuestion == "" then
            assistantLabel.Text = "🤖 Assistant: escribí una pregunta primero"
            return
        end

        local question = assistantQuestion
        assistantLabel.Text = "🤖 Assistant: pensando..."

        task.spawn(function()
            if AssistantMode == "LOCAL" then
                assistantLabel.Text = "🤖 Assistant: " .. safeText(localAssistant(question), 500)
                return
            end

            if AssistantMode == "FCC" then
                local answer, err = postFCC(question)
                if answer then
                    assistantHistory[#assistantHistory + 1] = {role="user", content=question}
                    assistantHistory[#assistantHistory + 1] = {role="assistant", content=safeText(answer,12000)}
                    while #assistantHistory > 20 do table.remove(assistantHistory,1) end
                    assistantLabel.Text = "🤖 Assistant [FCC]: " .. safeText(answer, 500)
                else
                    assistantLabel.Text = "🤖 Assistant [FCC]: " .. safeText(err, 180)
                end
                return
            end

            local answer, err = askGeneralAssistant(question)

            if answer then
                assistantLabel.Text = "🤖 Assistant: " .. safeText(answer, 500)
                print("========== TRAYECTOO ONLINE ASSISTANT ==========")
                print(answer)
                print("=================================================")
                return
            end

            if AssistantMode == "AUTO" then
                local fallback = localAssistant(question)
                assistantLabel.Text = "🤖 Assistant [LOCAL]: " .. safeText(fallback, 500)
                return
            end

            assistantLabel.Text = "🤖 Assistant: error - " .. safeText(err, 180)
        end)
    end)

    AssistantFolder:AddButton("🧹 Clear chat", function()
        table.clear(assistantHistory)
        assistantLabel.Text = "🤖 Assistant: chat cleared"
    end)

    AssistantFolder:AddButton("🌐 Test Internet", function()
        assistantLabel.Text = "🤖 Assistant: testing connection..."

        task.spawn(function()
            local headers = {["Content-Type"] = "application/json"}

            if AI.Key ~= "" then
                headers["Authorization"] = "Bearer " .. AI.Key
            end

            local response, err = postJSON(AI.Endpoint, {
                model = AI.Model,
                temperature = 0,
                messages = {
                    {
                        role = "user",
                        content = "Reply with exactly: TRAYECTOO_ONLINE_OK"
                    }
                }
            }, headers)

            if response then
                assistantLabel.Text = "🤖 Assistant: 🌐 ONLINE"
            else
                assistantLabel.Text =
                    "🤖 Assistant: ❌ " .. safeText(err, 180)
            end
        end)
    end)


    AssistantFolder:AddLabel("🧩 Claude Code project: integrated as a reference for the assistant workflow.")
    AssistantFolder:AddLabel("ℹ️ LOCAL works without API. AUTO falls back to LOCAL if ONLINE fails.")

    AssistantFolder:AddTextBox("FCC URL", function(v)
        if tostring(v) ~= "" then AI.FCCEndpoint = tostring(v) end
    end)

    AssistantFolder:AddTextBox("FCC Auth Token", function(v)
        AI.FCCAuthToken = tostring(v or "")
    end)

    AssistantFolder:AddTextBox("FCC Model", function(v)
        if tostring(v) ~= "" then AI.FCCModel = tostring(v) end
    end)

    AssistantFolder:AddLabel("ℹ️ FCC Local uses the Free Claude Code server on localhost.")
    AssistantFolder:AddLabel("ℹ️ LOCAL = built-in; FCC = Free Claude Code; ONLINE = external API; AUTO = fallback.")

    AssistantFolder:AddLabel(
        "ℹ️ General Assistant is available to all users."
    )

    local function buildPrompt(source)
        local errors={}
        for i=1,math.min(#AI.Errors,12) do
            local e=AI.Errors[i]
            errors[#errors+1]=string.format("[%s] %s | %s",e.time,e.source,e.message)
        end
        if #errors==0 then errors[1]="No captured runtime errors; inspect structure/API compatibility." end
        return table.concat({
            "You are a senior Roblox Luau code maintainer.",
            "Diagnose concrete bugs and produce a complete corrected script.",
            "Preserve existing GUI APIs such as AddWindow/AddTab/AddFolder/AddButton/AddSwitch/AddTextBox.",
            "Do not invent APIs. Keep existing behavior unless a fix requires a change.",
            "Do not add credential theft, destructive persistence, or automatic execution of generated code.",
            "Captured diagnostics:",table.concat(errors,"\n"),
            "SOURCE CODE:\n"..safeText(source,90000)
        },"\n")
    end
    local function askAI(source)
        if AI.Key=="" then return nil,"API key is empty" end
        return postJSON(AI.Endpoint,{model=AI.Model,temperature=0.1,messages={
            {role="system",content="You are a careful Luau code doctor. Output valid Luau only when asked for code."},
            {role="user",content=buildPrompt(source)}
        }},{["Content-Type"]="application/json",["Authorization"]="Bearer "..AI.Key})
    end
    local function extractAIText(r)
        return r and r.choices and r.choices[1] and r.choices[1].message and r.choices[1].message.content or nil
    end
    local function stripCodeFence(t)
        t=tostring(t or ""):gsub("^%s*```[%w_%-]*%s*",""):gsub("%s*```%s*$","")
        return t
    end
    local function validate(code)
        local compiler=loadstring or load
        local ok, result=pcall(function() return compiler(code) end)
        return ok and result~=nil, result
    end

    AIFolder:AddButton("🧠 Diagnose + generate fixed version", function()
        if not hasFiles() then statusLabel.Text="AI status: file API unavailable"; return end
        local source,err=readText(AI.Source)
        if not source then statusLabel.Text="AI status: "..safeText(err,150); return end
        statusLabel.Text="AI status: analyzing..."
        task.spawn(function()
            local response,reqErr=askAI(source)
            if not response then statusLabel.Text="AI status: "..safeText(reqErr,180); return end
            local generated=stripCodeFence(extractAIText(response))
            if not generated or generated=="" then statusLabel.Text="AI status: no code returned"; return end
            local good,compileErr=validate(generated)
            if not good then
                pushError("AI output syntax check failed: "..tostring(compileErr),"AI validator")
                refreshDiagnostics(); statusLabel.Text="AI status: syntax check FAILED"; return
            end
            local ok,saveErr=saveText(AI.Output,generated)
            if ok then statusLabel.Text="AI status: saved "..AI.Output else statusLabel.Text="AI status: "..safeText(saveErr,150) end
        end)
    end)
    AIFolder:AddButton("🧪 Validate current AI output", function()
        local code,err=readText(AI.Output)
        if not code then statusLabel.Text="Validation: "..safeText(err,150); return end
        local good,result=validate(code)
        statusLabel.Text=good and "Validation: syntax OK" or "Validation: FAILED - "..safeText(result,150)
        if not good then pushError("Output validation failed: "..tostring(result),"AI validator"); refreshDiagnostics() end
    end)

    local historyLabel=HistoryFolder:AddLabel("History: ready")
    local historyCache={}
    local function loadHistory()
        historyCache={}; local raw=readText(AI.History)
        if raw then local ok,data=pcall(HttpService.JSONDecode,HttpService,raw); if ok and type(data)=="table" then historyCache=data end end
        return historyCache
    end
    local function saveHistory()
        saveText(AI.History,HttpService:JSONEncode(historyCache))
        historyLabel.Text="History versions: "..#historyCache
    end
    local function createSnapshot(label,content)
        if not content or content=="" then return false end
        local id=#historyCache+1
        local path="Trayectoo_AI_V"..string.format("%03d",id)..".lua"
        local ok=saveText(path,content); if not ok then return false end
        historyCache[#historyCache+1]={id=id,time=os.date("%Y-%m-%d %H:%M:%S"),label=label,path=path}
        saveHistory(); return true
    end
    loadHistory(); historyLabel.Text="History versions: "..#historyCache
    HistoryFolder:AddButton("💾 Save AI output as new version", function()
        local code=readText(AI.Output)
        if code and createSnapshot("AI proposed version",code) then historyLabel.Text="Saved version "..#historyCache end
    end)
    HistoryFolder:AddButton("📜 Print version history", function()
        loadHistory(); print("=========== TRAYECTOO AI HISTORY ===========")
        for _,v in ipairs(historyCache) do print(string.format("V%03d | %s | %s | %s",v.id,v.time,v.label,v.path)) end
        print("============================================")
    end)
    HistoryFolder:AddTextBox("Version number to restore", function(v) AI.RestoreVersion=tonumber(v) end)
    HistoryFolder:AddButton("↩️ Restore selected version", function()
        loadHistory(); local n=tonumber(AI.RestoreVersion); local item=n and historyCache[n]
        if not item then historyLabel.Text="Restore: invalid version"; return end
        local code,err=readText(item.path); if not code then historyLabel.Text="Restore: "..safeText(err,140); return end
        local ok=saveText(AI.Output,code); historyLabel.Text=ok and "Restored V"..string.format("%03d",n).." to AI output" or "Restore failed"
    end)

    local safetyLabel=FileFolder:AddLabel("Apply is manual. Generated code is never executed automatically.")
    FileFolder:AddButton("📦 Backup source before applying", function()
        local code,err=readText(AI.Source); if not code then safetyLabel.Text="Backup failed: "..safeText(err,140); return end
        local ok=saveText(AI.Backup,code); safetyLabel.Text=ok and "Backup saved: "..AI.Backup or "Backup failed"
    end)
    FileFolder:AddButton("✅ APPLY AI VERSION", function()
        local current,err=readText(AI.Source); local generated,outErr=readText(AI.Output)
        if not current then safetyLabel.Text="Apply failed: "..safeText(err,140); return end
        if not generated then safetyLabel.Text="Apply failed: "..safeText(outErr,140); return end
        local good=validate(generated); if not good then safetyLabel.Text="Apply blocked: syntax check failed"; return end
        if not saveText(AI.Backup,current) then safetyLabel.Text="Apply blocked: backup failed"; return end
        createSnapshot("Before AI apply",current)
        local ok,writeErr=saveText(AI.Source,generated)
        safetyLabel.Text=ok and "Applied AI version. Backup: "..AI.Backup or "Apply failed: "..safeText(writeErr,140)
    end)
    FileFolder:AddButton("↩️ REVERT last applied version", function()
        local backup,err=readText(AI.Backup); if not backup then safetyLabel.Text="Revert failed: "..safeText(err,140); return end
        local current=readText(AI.Source); if current then createSnapshot("Before revert",current) end
        local ok,writeErr=saveText(AI.Source,backup)
        safetyLabel.Text=ok and "Reverted source from backup" or "Revert failed: "..safeText(writeErr,140)
    end)
    FileFolder:AddButton("📌 Show active file paths", function()
        print("========== TRAYECTOO AI FILES ==========")
        print("Source:",AI.Source); print("AI output:",AI.Output); print("Backup:",AI.Backup); print("History:",AI.History)
        print("=========================================")
    end)
end)


--[[ =========================================================
     SERAPH / TRAYECTOO - VISUAL PREMIUM PASS
     Solo visual: no cambia AddWindow/AddTab/AddFolder ni callbacks.
     ========================================================= ]]
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local RunService = game:GetService("RunService")

    local GOLD = Color3.fromRGB(218,184,92)
    local GOLD_SOFT = Color3.fromRGB(245,211,120)
    local BG = Color3.fromRGB(9,10,13)
    local PANEL = Color3.fromRGB(18,19,24)
    local PANEL_2 = Color3.fromRGB(24,25,31)
    local TEXT = Color3.fromRGB(242,242,246)
    local MUTED = Color3.fromRGB(150,153,163)
    local HOVER = Color3.fromRGB(36,37,45)

    local function corner(obj, radius)
        if not obj or not obj:IsA("GuiObject") then return end
        local c = obj:FindFirstChild("SERAPH_Corner")
        if not c then
            c = Instance.new("UICorner")
            c.Name = "SERAPH_Corner"
            c.Parent = obj
        end
        c.CornerRadius = UDim.new(0, radius or 8)
    end

    local function stroke(obj, color, transparency, thickness)
        if not obj or not obj:IsA("GuiObject") then return end
        local s = obj:FindFirstChild("SERAPH_Stroke")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_Stroke"
            s.Parent = obj
        end
        s.Color = color or GOLD
        s.Transparency = transparency == nil and 0.78 or transparency
        s.Thickness = thickness or 1
    end

    local function gradient(obj, c1, c2, rotation)
        if not obj or not obj:IsA("GuiObject") then return end
        local g = obj:FindFirstChild("SERAPH_Gradient")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_Gradient"
            g.Parent = obj
        end
        g.Rotation = rotation or 90
        g.Color = ColorSequence.new(c1, c2)
    end

    local function hover(button, normal, active)
        if not button or not button:IsA("GuiButton") then return end
        if button:GetAttribute("SERAPH_Hover") then return end
        button:SetAttribute("SERAPH_Hover", true)
        local scale = button:FindFirstChild("SERAPH_Scale")
        if not scale then
            scale = Instance.new("UIScale")
            scale.Name = "SERAPH_Scale"
            scale.Scale = 1
            scale.Parent = button
        end
        button.AutoButtonColor = false
        button.MouseEnter:Connect(function()
            if button.BackgroundTransparency < 1 then
                TweenService:Create(button, TweenInfo.new(0.12), {
                    BackgroundColor3 = active or HOVER
                }):Play()
            end
            TweenService:Create(scale, TweenInfo.new(0.10), {Scale = 1.015}):Play()
        end)
        button.MouseLeave:Connect(function()
            if button.BackgroundTransparency < 1 then
                TweenService:Create(button, TweenInfo.new(0.12), {
                    BackgroundColor3 = normal or PANEL_2
                }):Play()
            end
            TweenService:Create(scale, TweenInfo.new(0.10), {Scale = 1}):Play()
        end)
        button.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(scale, TweenInfo.new(0.07), {Scale = 0.975}):Play()
            end
        end)
        button.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(scale, TweenInfo.new(0.07), {Scale = 1.015}):Play()
            end
        end)
    end

    local function styleWindow(win)
        if not win or not win:IsA("GuiObject") then return end

        -- Main shell
        win.BackgroundColor3 = BG
        win.BackgroundTransparency = 0.02
        corner(win, 14)
        stroke(win, GOLD, 0.55, 1.2)

        -- Top bar
        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = PANEL
            bar.BackgroundTransparency = 0
            corner(bar, 12)
            gradient(bar, Color3.fromRGB(28,29,35), Color3.fromRGB(12,13,17), 0)

            local titleObj = win:FindFirstChild("Title", true)
            if titleObj and titleObj:IsA("TextLabel") then
                titleObj.TextColor3 = TEXT
                titleObj.Font = Enum.Font.GothamBold
                titleObj.TextSize = 14
                titleObj.TextTruncate = Enum.TextTruncate.None
                titleObj.TextXAlignment = Enum.TextXAlignment.Left
            end

            -- Gold status line below the title bar.
            local line = bar:FindFirstChild("SERAPH_StatusLine")
            if not line then
                line = Instance.new("Frame")
                line.Name = "SERAPH_StatusLine"
                line.BorderSizePixel = 0
                line.BackgroundColor3 = GOLD
                line.BackgroundTransparency = 0.15
                line.Position = UDim2.new(0, 18, 1, -2)
                line.Size = UDim2.new(1, -36, 0, 2)
                line.ZIndex = 100
                line.Parent = bar
                corner(line, 2)
            end
        end

        -- Left navigation
        local tabSelection = win:FindFirstChild("TabSelection", true)
        if tabSelection and tabSelection:IsA("GuiObject") then
            tabSelection.BackgroundColor3 = PANEL
            tabSelection.BackgroundTransparency = 0
            corner(tabSelection, 11)
            stroke(tabSelection, Color3.fromRGB(55,56,66), 0.45, 1)

            local scroll = tabSelection:FindFirstChild("TabScrolling", true)
            if scroll then
                scroll.ScrollBarThickness = 2
                scroll.ScrollBarImageColor3 = GOLD
                scroll.ScrollBarImageTransparency = 0.35
            end
        end

        -- Main content
        local tabs = win:FindFirstChild("Tabs", true)
        if tabs and tabs:IsA("GuiObject") then
            tabs.BackgroundTransparency = 1
        end

        -- Style every generated control without changing its callback.
        for _, obj in ipairs(win:GetDescendants()) do
            if obj:IsA("TextButton") then
                local isTab = obj.Parent and (
                    obj.Parent.Name == "TabButtons"
                    or obj.Name == "Tab"
                    or obj:GetAttribute("SERAPH_Tab") == true
                )
                if not isTab then
                    obj.BackgroundColor3 = PANEL_2
                    obj.BackgroundTransparency = math.min(obj.BackgroundTransparency, 0.08)
                    obj.TextColor3 = TEXT
                    obj.Font = Enum.Font.GothamMedium
                    obj.TextSize = math.max(11, math.min(obj.TextSize, 13))
                    corner(obj, 7)
                    stroke(obj, Color3.fromRGB(60,61,72), 0.72, 1)
                    hover(obj, PANEL_2, HOVER)
                end
            elseif obj:IsA("TextBox") then
                obj.BackgroundColor3 = Color3.fromRGB(14,15,19)
                obj.TextColor3 = TEXT
                obj.PlaceholderColor3 = MUTED
                corner(obj, 7)
                stroke(obj, Color3.fromRGB(64,65,76), 0.58, 1)
            elseif obj:IsA("TextLabel") then
                if obj.Name ~= "Title" then
                    obj.TextColor3 = obj.TextColor3 == Color3.new(1,1,1) and TEXT or obj.TextColor3
                end
            elseif obj:IsA("ScrollingFrame") then
                obj.ScrollBarImageColor3 = GOLD
                obj.ScrollBarImageTransparency = 0.35
                obj.ScrollBarThickness = math.min(obj.ScrollBarThickness, 4)
            end
        end

        -- Make tab buttons feel like a real navigation rail.
        local scrolling = win:FindFirstChild("TabScrolling", true)
        if scrolling then
            for _, obj in ipairs(scrolling:GetDescendants()) do
                if obj:IsA("TextButton") then
                    obj.BackgroundTransparency = 1
                    obj.TextColor3 = MUTED
                    obj.Font = Enum.Font.GothamMedium
                    obj.TextSize = 12
                    corner(obj, 7)

                    if not obj:GetAttribute("SERAPH_TabStyled") then
                        obj:SetAttribute("SERAPH_TabStyled", true)
                        local indicator = Instance.new("Frame")
                        indicator.Name = "SERAPH_ActiveIndicator"
                        indicator.AnchorPoint = Vector2.new(0, 0.5)
                        indicator.Position = UDim2.new(0, 3, 0.5, 0)
                        indicator.Size = UDim2.new(0, 3, 0, 20)
                        indicator.BackgroundColor3 = GOLD
                        indicator.BackgroundTransparency = 1
                        indicator.BorderSizePixel = 0
                        indicator.ZIndex = obj.ZIndex + 5
                        corner(indicator, 3)
                        indicator.Parent = obj

                        obj.MouseEnter:Connect(function()
                            if indicator.BackgroundTransparency > 0.5 then
                                TweenService:Create(obj, TweenInfo.new(0.12), {
                                    TextColor3 = TEXT
                                }):Play()
                            end
                        end)
                        obj.MouseLeave:Connect(function()
                            if indicator.BackgroundTransparency > 0.5 then
                                TweenService:Create(obj, TweenInfo.new(0.12), {
                                    TextColor3 = MUTED
                                }):Play()
                            end
                        end)
                    end
                end
            end
        end
    end

    -- Apply now and again shortly after, because tabs/folders are created dynamically.
    for _, win in ipairs(library:GetWindows()) do
        styleWindow(win)
    end

    for pass = 1, 4 do
        task.delay(pass * 0.35, function()
            for _, win in ipairs(library:GetWindows()) do
                styleWindow(win)
            end
        end)
    end

    -- Reapply lightweight styling when the window is resized.
    for _, win in ipairs(library:GetWindows()) do
        win:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
            task.defer(function()
                if win and win.Parent then styleWindow(win) end
            end)
        end)
    end
end)


-- ============================================================
-- SERAPH HUB VISUAL MAX
-- Visual-only layer: dashboard, premium cards, status accents,
-- mobile-friendly navigation and console polish.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")

    local C = {
        bg = Color3.fromRGB(7, 8, 11),
        panel = Color3.fromRGB(15, 16, 21),
        panel2 = Color3.fromRGB(21, 22, 29),
        panel3 = Color3.fromRGB(28, 29, 37),
        text = Color3.fromRGB(244, 244, 248),
        muted = Color3.fromRGB(145, 148, 160),
        gold = Color3.fromRGB(224, 187, 84),
        gold2 = Color3.fromRGB(255, 218, 122),
        green = Color3.fromRGB(86, 220, 139),
        red = Color3.fromRGB(235, 92, 102),
        blue = Color3.fromRGB(92, 155, 255)
    }

    local function makeCorner(parent, radius)
        if not parent or not parent:IsA("GuiObject") then return end
        local c = parent:FindFirstChild("SERAPH_MAX_CORNER")
        if not c then
            c = Instance.new("UICorner")
            c.Name = "SERAPH_MAX_CORNER"
            c.CornerRadius = UDim.new(0, radius or 10)
            c.Parent = parent
        end
        return c
    end

    local function makeStroke(parent, color, transparency)
        if not parent or not parent:IsA("GuiObject") then return end
        local s = parent:FindFirstChild("SERAPH_MAX_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_MAX_STROKE"
            s.Parent = parent
        end
        s.Color = color or C.gold
        s.Transparency = transparency == nil and 0.78 or transparency
        s.Thickness = 1
        return s
    end

    local function addGradient(parent, a, b, rotation)
        local g = parent:FindFirstChild("SERAPH_MAX_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_MAX_GRADIENT"
            g.Parent = parent
        end
        g.Color = ColorSequence.new(a, b)
        g.Rotation = rotation or 90
    end

    local function text(parent, value, size, color, font)
        local x = Instance.new("TextLabel")
        x.BackgroundTransparency = 1
        x.Text = value
        x.TextColor3 = color or C.text
        x.Font = font or Enum.Font.GothamMedium
        x.TextSize = size or 12
        x.TextXAlignment = Enum.TextXAlignment.Left
        x.TextYAlignment = Enum.TextYAlignment.Center
        x.Parent = parent
        return x
    end

    local function card(parent, title, subtitle)
        local f = Instance.new("Frame")
        f.BackgroundColor3 = C.panel2
        f.BorderSizePixel = 0
        makeCorner(f, 10)
        makeStroke(f, Color3.fromRGB(64, 65, 76), 0.68)
        addGradient(f, C.panel3, C.panel2, 90)
        f.Parent = parent

        local t = text(f, title, 13, C.text, Enum.Font.GothamBold)
        t.Position = UDim2.new(0, 14, 0, 7)
        t.Size = UDim2.new(1, -28, 0, 22)

        if subtitle then
            local s = text(f, subtitle, 10, C.muted, Enum.Font.Gotham)
            s.Position = UDim2.new(0, 14, 0, 29)
            s.Size = UDim2.new(1, -28, 0, 18)
        end
        return f
    end

    local function pill(parent, value, color)
        local p = Instance.new("Frame")
        p.BackgroundColor3 = color
        p.BackgroundTransparency = 0.82
        p.BorderSizePixel = 0
        makeCorner(p, 20)
        p.Parent = parent

        local l = text(p, "● "..value, 10, color, Enum.Font.GothamBold)
        l.Size = UDim2.new(1, -16, 1, 0)
        l.Position = UDim2.new(0, 8, 0, 0)
        return p
    end

    local function addHover(btn)
        if not btn or not btn:IsA("GuiButton") or btn:GetAttribute("SERAPH_MAX_HOVER") then return end
        btn:SetAttribute("SERAPH_MAX_HOVER", true)
        btn.AutoButtonColor = false
        local sc = Instance.new("UIScale")
        sc.Name = "SERAPH_MAX_SCALE"
        sc.Parent = btn

        local normal = btn.BackgroundColor3
        btn.MouseEnter:Connect(function()
            TweenService:Create(btn, TweenInfo.new(.12), {BackgroundColor3 = C.panel3}):Play()
            TweenService:Create(sc, TweenInfo.new(.1), {Scale = 1.02}):Play()
        end)
        btn.MouseLeave:Connect(function()
            TweenService:Create(btn, TweenInfo.new(.12), {BackgroundColor3 = normal}):Play()
            TweenService:Create(sc, TweenInfo.new(.1), {Scale = 1}):Play()
        end)
    end

    local function style(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = C.bg
        win.BackgroundTransparency = 0
        makeCorner(win, 15)
        makeStroke(win, C.gold, .55)

        -- Existing controls
        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = C.panel2
                o.TextColor3 = C.text
                o.Font = Enum.Font.GothamMedium
                makeCorner(o, 7)
                makeStroke(o, Color3.fromRGB(60,61,72), .76)
                addHover(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(11,12,16)
                o.TextColor3 = C.text
                o.PlaceholderColor3 = C.muted
                makeCorner(o, 7)
                makeStroke(o, Color3.fromRGB(65,66,78), .55)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = C.gold
                o.ScrollBarImageTransparency = .35
            end
        end

        -- Top bar
        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = C.panel
            makeCorner(bar, 13)
            addGradient(bar, Color3.fromRGB(27,28,35), C.panel, 0)

            local titleObj = win:FindFirstChild("Title", true)
            if titleObj and titleObj:IsA("TextLabel") then
                titleObj.TextColor3 = C.text
                titleObj.Font = Enum.Font.GothamBold
                titleObj.TextSize = 14
                titleObj.TextTruncate = Enum.TextTruncate.None
            end

            if not bar:FindFirstChild("SERAPH_MAX_STATUS") then
                local st = pill(bar, "ONLINE", C.green)
                st.Name = "SERAPH_MAX_STATUS"
                st.AnchorPoint = Vector2.new(1, .5)
                st.Position = UDim2.new(1, -55, .5, 0)
                st.Size = UDim2.new(0, 78, 0, 24)
                st.ZIndex = 100
            end

            if not bar:FindFirstChild("SERAPH_MAX_LINE") then
                local line = Instance.new("Frame")
                line.Name = "SERAPH_MAX_LINE"
                line.BackgroundColor3 = C.gold
                line.BorderSizePixel = 0
                line.Position = UDim2.new(0, 18, 1, -2)
                line.Size = UDim2.new(1, -36, 0, 2)
                line.ZIndex = 100
                makeCorner(line, 2)
                line.Parent = bar
            end
        end

        -- Navigation rail
        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = C.panel
            nav.BackgroundTransparency = 0
            makeCorner(nav, 11)
            makeStroke(nav, Color3.fromRGB(52,53,64), .5)
        end

        -- Add subtle dividers to major containers.
        for _, o in ipairs(win:GetChildren()) do
            if o:IsA("GuiObject") and o ~= bar then
                if o.Name ~= "SERAPH_MAX_DECOR" and o.Size.X.Scale > .2 then
                    local d = o:FindFirstChild("SERAPH_MAX_DECOR")
                    if not d then
                        d = Instance.new("Frame")
                        d.Name = "SERAPH_MAX_DECOR"
                        d.BackgroundColor3 = Color3.fromRGB(45,46,56)
                        d.BackgroundTransparency = .82
                        d.BorderSizePixel = 0
                        d.Position = UDim2.new(0, 12, 0, 0)
                        d.Size = UDim2.new(1, -24, 0, 1)
                        d.ZIndex = math.max(1, o.ZIndex + 1)
                        d.Parent = o
                    end
                end
            end
        end
    end

    -- Use the existing library; no new window is created.
    if library and library.GetWindows then
        for _, w in ipairs(library:GetWindows()) do
            style(w)
        end

        for i = 1, 6 do
            task.delay(i * .35, function()
                for _, w in ipairs(library:GetWindows()) do
                    style(w)
                end
            end)
        end
    end
end)


-- ============================================================
-- SERAPH HUB VISUAL MAX V2
-- Final visual pass for the existing window.
-- Does not replace the library or its AddWindow/AddTab/AddFolder API.
-- ============================================================
task.defer(function()
    local Players = game:GetService("Players")
    local TweenService = game:GetService("TweenService")
    local UserInputService = game:GetService("UserInputService")

    local COLORS = {
        bg = Color3.fromRGB(8, 9, 13),
        shell = Color3.fromRGB(16, 17, 22),
        shell2 = Color3.fromRGB(22, 23, 29),
        shell3 = Color3.fromRGB(29, 30, 38),
        gold = Color3.fromRGB(224, 187, 84),
        goldBright = Color3.fromRGB(255, 219, 125),
        white = Color3.fromRGB(244, 245, 249),
        muted = Color3.fromRGB(145, 149, 162),
        green = Color3.fromRGB(83, 220, 139),
        red = Color3.fromRGB(232, 87, 101)
    }

    local function corner(obj, radius)
        if not obj or not obj:IsA("GuiObject") then return end
        local c = obj:FindFirstChild("SERAPH_V2_CORNER")
        if not c then
            c = Instance.new("UICorner")
            c.Name = "SERAPH_V2_CORNER"
            c.CornerRadius = UDim.new(0, radius or 10)
            c.Parent = obj
        end
        return c
    end

    local function stroke(obj, color, transparency, thickness)
        if not obj or not obj:IsA("GuiObject") then return end
        local s = obj:FindFirstChild("SERAPH_V2_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_V2_STROKE"
            s.Parent = obj
        end
        s.Color = color or COLORS.gold
        s.Transparency = transparency == nil and 0.7 or transparency
        s.Thickness = thickness or 1
        return s
    end

    local function gradient(obj, c1, c2, rotation)
        if not obj or not obj:IsA("GuiObject") then return end
        local g = obj:FindFirstChild("SERAPH_V2_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_V2_GRADIENT"
            g.Parent = obj
        end
        g.Color = ColorSequence.new(c1, c2)
        g.Rotation = rotation or 90
    end

    local function label(parent, name, value, size, color, bold)
        local l = parent:FindFirstChild(name)
        if not l then
            l = Instance.new("TextLabel")
            l.Name = name
            l.BackgroundTransparency = 1
            l.Parent = parent
        end
        l.Text = value
        l.TextSize = size or 12
        l.TextColor3 = color or COLORS.white
        l.Font = bold and Enum.Font.GothamBold or Enum.Font.GothamMedium
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.TextYAlignment = Enum.TextYAlignment.Center
        return l
    end

    local function buttonHover(btn)
        if not btn or not btn:IsA("GuiButton") or btn:GetAttribute("SERAPH_V2_HOVER") then return end
        btn:SetAttribute("SERAPH_V2_HOVER", true)
        btn.AutoButtonColor = false

        local scale = Instance.new("UIScale")
        scale.Name = "SERAPH_V2_SCALE"
        scale.Parent = btn

        local original = btn.BackgroundColor3
        btn.MouseEnter:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {
                BackgroundColor3 = COLORS.shell3
            }):Play()
            TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {
                Scale = 1.015
            }):Play()
        end)

        btn.MouseLeave:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {
                BackgroundColor3 = original
            }):Play()
            TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Quad), {
                Scale = 1
            }):Play()
        end)
    end

    local function fitWindow(win)
        if not win or not win:IsA("GuiObject") then return end
        local camera = workspace.CurrentCamera
        if not camera then return end

        local viewport = camera.ViewportSize
        local mobile = viewport.X < 850 or viewport.Y < 600

        if mobile then
            win.AnchorPoint = Vector2.new(0.5, 0.5)
            win.Position = UDim2.fromScale(0.5, 0.52)
            win.Size = UDim2.new(0.94, 0, 0.82, 0)
        else
            win.AnchorPoint = Vector2.new(0.5, 0.5)
            win.Position = UDim2.fromScale(0.5, 0.52)
            win.Size = UDim2.new(0.78, 0, 0.72, 0)
        end
    end

    local function decorate(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = COLORS.bg
        win.BackgroundTransparency = 0
        win.BorderSizePixel = 0
        corner(win, 16)
        stroke(win, COLORS.gold, 0.62, 1)

        -- Window depth / glow layers.
        if not win:FindFirstChild("SERAPH_V2_SHADOW") then
            local shadow = Instance.new("Frame")
            shadow.Name = "SERAPH_V2_SHADOW"
            shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
            shadow.BackgroundTransparency = 0.58
            shadow.BorderSizePixel = 0
            shadow.Position = UDim2.new(0, 7, 0, 9)
            shadow.Size = UDim2.new(1, 0, 1, 0)
            shadow.ZIndex = math.max(0, win.ZIndex - 1)
            corner(shadow, 16)
            shadow.Parent = win
        end

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = COLORS.shell
            bar.BackgroundTransparency = 0
            bar.BorderSizePixel = 0
            bar.Size = UDim2.new(1, 0, 0, 48)
            corner(bar, 13)
            gradient(bar, Color3.fromRGB(28, 29, 36), COLORS.shell, 0)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = COLORS.white
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
                title.Position = UDim2.new(0, 44, 0, 8)
                title.Size = UDim2.new(1, -210, 0, 24)
                title.ZIndex = 30
            end

            -- Tiny brand mark.
            if not bar:FindFirstChild("SERAPH_V2_MARK") then
                local mark = Instance.new("Frame")
                mark.Name = "SERAPH_V2_MARK"
                mark.BackgroundColor3 = COLORS.gold
                mark.BorderSizePixel = 0
                mark.Position = UDim2.new(0, 16, 0.5, -9)
                mark.Size = UDim2.new(0, 18, 0, 18)
                mark.ZIndex = 30
                corner(mark, 6)
                mark.Parent = bar

                local m = label(mark, "M", "S", 10, COLORS.bg, true)
                m.TextXAlignment = Enum.TextXAlignment.Center
                m.Size = UDim2.fromScale(1, 1)
            end

            -- Online pill.
            if not bar:FindFirstChild("SERAPH_V2_ONLINE") then
                local pill = Instance.new("Frame")
                pill.Name = "SERAPH_V2_ONLINE"
                pill.BackgroundColor3 = COLORS.green
                pill.BackgroundTransparency = 0.84
                pill.BorderSizePixel = 0
                pill.AnchorPoint = Vector2.new(1, 0.5)
                pill.Position = UDim2.new(1, -18, 0.5, 0)
                pill.Size = UDim2.new(0, 82, 0, 25)
                pill.ZIndex = 30
                corner(pill, 14)
                pill.Parent = bar

                local p = label(pill, "Status", "●  ONLINE", 10, COLORS.green, true)
                p.TextXAlignment = Enum.TextXAlignment.Center
                p.Size = UDim2.fromScale(1, 1)
            end

            -- Gold accent line.
            if not bar:FindFirstChild("SERAPH_V2_GOLDLINE") then
                local line = Instance.new("Frame")
                line.Name = "SERAPH_V2_GOLDLINE"
                line.BackgroundColor3 = COLORS.gold
                line.BorderSizePixel = 0
                line.Position = UDim2.new(0, 18, 1, -2)
                line.Size = UDim2.new(1, -36, 0, 2)
                line.ZIndex = 31
                corner(line, 2)
                line.Parent = bar
            end
        end

        local tabs = win:FindFirstChild("Tabs", true)
        if tabs and tabs:IsA("GuiObject") then
            tabs.Position = UDim2.new(0, 170, 0, 58)
            tabs.Size = UDim2.new(1, -188, 1, -74)
            tabs.BackgroundTransparency = 1
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.Position = UDim2.new(0, 14, 0, 58)
            nav.Size = UDim2.new(0, 142, 1, -72)
            nav.BackgroundColor3 = COLORS.shell2
            nav.BackgroundTransparency = 0
            nav.BorderSizePixel = 0
            corner(nav, 12)
            stroke(nav, Color3.fromRGB(58, 59, 70), 0.58, 1)
        end

        -- Style all current tabs/folders/buttons without replacing their events.
        for _, obj in ipairs(win:GetDescendants()) do
            if obj:IsA("TextButton") then
                obj.Font = Enum.Font.GothamMedium
                obj.TextColor3 = COLORS.white
                obj.TextSize = math.max(11, math.min(obj.TextSize, 13))
                obj.BackgroundColor3 = COLORS.shell2
                obj.BackgroundTransparency = 0.08
                obj.BorderSizePixel = 0
                corner(obj, 7)
                stroke(obj, Color3.fromRGB(58, 59, 70), 0.82, 1)
                buttonHover(obj)
            elseif obj:IsA("TextBox") then
                obj.Font = Enum.Font.Gotham
                obj.TextColor3 = COLORS.white
                obj.PlaceholderColor3 = COLORS.muted
                obj.BackgroundColor3 = Color3.fromRGB(11, 12, 16)
                obj.BackgroundTransparency = 0
                obj.BorderSizePixel = 0
                corner(obj, 8)
                stroke(obj, Color3.fromRGB(68, 69, 80), 0.58, 1)
            elseif obj:IsA("ScrollingFrame") then
                obj.ScrollBarThickness = 3
                obj.ScrollBarImageColor3 = COLORS.gold
                obj.ScrollBarImageTransparency = 0.28
            end
        end

        -- Give sidebar buttons a consistent compact layout.
        local scrolling = nav and nav:FindFirstChild("TabScrolling", true)
        local tabButtons = scrolling and scrolling:FindFirstChild("TabButtons", true)
        if tabButtons and tabButtons:IsA("GuiObject") then
            for _, b in ipairs(tabButtons:GetChildren()) do
                if b:IsA("TextButton") then
                    b.Size = UDim2.new(1, -12, 0, 34)
                    b.Position = UDim2.new(0, 6, b.Position.Y.Scale, b.Position.Y.Offset)
                    b.TextSize = 11
                    b.TextColor3 = COLORS.muted
                    b.TextXAlignment = Enum.TextXAlignment.Left
                    b.BackgroundColor3 = COLORS.shell2
                    b.BackgroundTransparency = 1
                    corner(b, 8)
                end
            end
        end

        -- Search/input bars should not dominate the content.
        for _, obj in ipairs(win:GetDescendants()) do
            if obj:IsA("TextBox") then
                local searchText = string.lower(obj.PlaceholderText or "")
                if string.find(searchText, "search") or string.find(searchText, "buscar") then
                    obj.Size = UDim2.new(obj.Size.X.Scale, obj.Size.X.Offset, 0, 32)
                end
            end
        end
    end

    local function apply()
        if not library or type(library.GetWindows) ~= "function" then return end
        local windows = library:GetWindows()
        for _, win in ipairs(windows) do
            decorate(win)
            fitWindow(win)
        end
    end

    apply()

    task.delay(0.5, apply)
    task.delay(1.5, apply)
    task.delay(3, apply)

    if workspace.CurrentCamera then
        workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
            apply()
        end)
    end
end)


-- ============================================================
-- SERAPH HUB VISUAL MAX V3
-- Premium glass/obsidian visual polish for the existing window.
-- Visual layer only: existing functions and controls are preserved.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local Players = game:GetService("Players")
    local playerGui = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")

    local GOLD = Color3.fromRGB(232, 195, 92)
    local GOLD_SOFT = Color3.fromRGB(255, 221, 130)
    local BG = Color3.fromRGB(8, 9, 13)
    local PANEL = Color3.fromRGB(18, 19, 25)
    local PANEL2 = Color3.fromRGB(24, 25, 32)
    local PANEL3 = Color3.fromRGB(31, 32, 41)
    local TEXT = Color3.fromRGB(245, 245, 248)
    local MUTED = Color3.fromRGB(148, 151, 163)
    local GREEN = Color3.fromRGB(78, 218, 139)
    local RED = Color3.fromRGB(235, 91, 101)

    local function corner(o, r)
        if not o or not o:IsA("GuiObject") then return end
        local c = o:FindFirstChild("SERAPH_V3_CORNER")
        if not c then
            c = Instance.new("UICorner")
            c.Name = "SERAPH_V3_CORNER"
            c.CornerRadius = UDim.new(0, r or 10)
            c.Parent = o
        end
    end

    local function stroke(o, color, transparency, thickness)
        if not o or not o:IsA("GuiObject") then return end
        local s = o:FindFirstChild("SERAPH_V3_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_V3_STROKE"
            s.Parent = o
        end
        s.Color = color or GOLD
        s.Transparency = transparency == nil and .75 or transparency
        s.Thickness = thickness or 1
    end

    local function gradient(o, c1, c2, rotation)
        if not o or not o:IsA("GuiObject") then return end
        local g = o:FindFirstChild("SERAPH_V3_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_V3_GRADIENT"
            g.Parent = o
        end
        g.Color = ColorSequence.new(c1, c2)
        g.Rotation = rotation or 90
    end

    local function label(parent, name, value, size, color, font)
        local l = parent:FindFirstChild(name)
        if not l then
            l = Instance.new("TextLabel")
            l.Name = name
            l.BackgroundTransparency = 1
            l.Parent = parent
        end
        l.Text = value
        l.TextSize = size or 12
        l.TextColor3 = color or TEXT
        l.Font = font or Enum.Font.GothamMedium
        l.TextXAlignment = Enum.TextXAlignment.Left
        l.TextYAlignment = Enum.TextYAlignment.Center
        return l
    end

    local function buttonFX(b)
        if not b:IsA("GuiButton") or b:GetAttribute("SERAPH_V3_FX") then return end
        b:SetAttribute("SERAPH_V3_FX", true)
        b.AutoButtonColor = false
        corner(b, 8)
        stroke(b, Color3.fromRGB(62,63,74), .82)
        local scale = Instance.new("UIScale")
        scale.Name = "SERAPH_V3_SCALE"
        scale.Parent = b
        local base = b.BackgroundColor3
        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(.12, Enum.EasingStyle.Quad), {
                BackgroundColor3 = PANEL3
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.12, Enum.EasingStyle.Quad), {
                Scale = 1.025
            }):Play()
        end)
        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                BackgroundColor3 = base
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                Scale = 1
            }):Play()
        end)
    end

    local function findMainWindow()
        if playerGui then
            for _, o in ipairs(playerGui:GetDescendants()) do
                if o:IsA("GuiObject") and o.Visible then
                    local title = o:FindFirstChild("Title", true)
                    if title and title:IsA("TextLabel") and string.find(string.lower(title.Text), "seraph", 1, true) then
                        return o
                    end
                end
            end
        end
        return nil
    end

    local function apply(win)
        if not win or not win:IsA("GuiObject") then return end
        win.BackgroundColor3 = BG
        win.BorderSizePixel = 0
        corner(win, 16)
        stroke(win, GOLD, .58, 1)

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = PANEL
            bar.BackgroundTransparency = .03
            corner(bar, 13)
            stroke(bar, Color3.fromRGB(65,66,77), .65, 1)
            gradient(bar, Color3.fromRGB(30,31,39), PANEL, 0)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = TEXT
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
            end

            if not bar:FindFirstChild("SERAPH_V3_ACCENT") then
                local a = Instance.new("Frame")
                a.Name = "SERAPH_V3_ACCENT"
                a.BackgroundColor3 = GOLD
                a.BorderSizePixel = 0
                a.Position = UDim2.new(0, 20, 1, -2)
                a.Size = UDim2.new(1, -40, 0, 2)
                a.ZIndex = 100
                corner(a, 2)
                a.Parent = bar
            end

            if not bar:FindFirstChild("SERAPH_V3_ONLINE") then
                local p = Instance.new("Frame")
                p.Name = "SERAPH_V3_ONLINE"
                p.BackgroundColor3 = Color3.fromRGB(31, 72, 51)
                p.BackgroundTransparency = .25
                p.AnchorPoint = Vector2.new(1, .5)
                p.Position = UDim2.new(1, -18, .5, 0)
                p.Size = UDim2.new(0, 86, 0, 25)
                p.ZIndex = 100
                corner(p, 13)
                stroke(p, GREEN, .65, 1)
                p.Parent = bar

                local dot = Instance.new("Frame")
                dot.BackgroundColor3 = GREEN
                dot.BorderSizePixel = 0
                dot.Position = UDim2.new(0, 9, .5, -3)
                dot.Size = UDim2.new(0, 6, 0, 6)
                dot.ZIndex = 101
                corner(dot, 6)
                dot.Parent = p

                local t = label(p, "Text", "ONLINE", 10, GREEN, Enum.Font.GothamBold)
                t.Position = UDim2.new(0, 21, 0, 0)
                t.Size = UDim2.new(1, -25, 1, 0)
            end
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = PANEL
            nav.BackgroundTransparency = 0
            corner(nav, 12)
            stroke(nav, Color3.fromRGB(55,56,67), .62, 1)
        end

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = PANEL2
                o.TextColor3 = TEXT
                o.Font = Enum.Font.GothamMedium
                o.TextSize = math.max(11, math.min(o.TextSize, 14))
                buttonFX(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(11,12,16)
                o.TextColor3 = TEXT
                o.PlaceholderColor3 = MUTED
                corner(o, 8)
                stroke(o, Color3.fromRGB(71,72,84), .55, 1)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = GOLD
                o.ScrollBarImageTransparency = .32
                o.BackgroundTransparency = math.min(o.BackgroundTransparency, .1)
            elseif o:IsA("TextLabel") and o ~= bar then
                if o.TextColor3 ~= GOLD and o.TextColor3 ~= RED and o.TextColor3 ~= GREEN then
                    o.TextColor3 = TEXT
                end
            end
        end

        -- Make the main content feel like cards instead of one empty black slab.
        for _, o in ipairs(win:GetChildren()) do
            if o:IsA("GuiObject") and o ~= bar and o ~= nav and o.Name ~= "SERAPH_V3_DECOR" then
                if o.Size.X.Scale > .25 then
                    corner(o, 10)
                    if o.BackgroundTransparency < 1 then
                        stroke(o, Color3.fromRGB(48,49,59), .83, 1)
                    end
                end
            end
        end

        -- Soft inner frame.
        if not win:FindFirstChild("SERAPH_V3_INNER") then
            local inner = Instance.new("Frame")
            inner.Name = "SERAPH_V3_INNER"
            inner.BackgroundTransparency = 1
            inner.BorderSizePixel = 0
            inner.Position = UDim2.new(0, 3, 0, 3)
            inner.Size = UDim2.new(1, -6, 1, -6)
            inner.ZIndex = 0
            corner(inner, 14)
            stroke(inner, Color3.fromRGB(255,255,255), .94, 1)
            inner.Parent = win
        end
    end

    for _ = 1, 20 do
        local win = findMainWindow()
        if win then
            apply(win)
            break
        end
        task.wait(.25)
    end
end)


-- ============================================================
-- SERAPH HUB ULTRA VISUAL V4
-- Extra visual polish for the EXISTING GUI.
-- Does not replace the GUI API or feature callbacks.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local Players = game:GetService("Players")
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")

    local GOLD = Color3.fromRGB(232, 194, 88)
    local GOLD2 = Color3.fromRGB(255, 224, 135)
    local WHITE = Color3.fromRGB(246, 246, 250)
    local MUTED = Color3.fromRGB(145, 148, 160)
    local BG = Color3.fromRGB(7, 8, 11)
    local CARD = Color3.fromRGB(18, 19, 25)
    local CARD2 = Color3.fromRGB(23, 24, 31)
    local HOVER = Color3.fromRGB(34, 35, 44)
    local GREEN = Color3.fromRGB(77, 221, 137)

    local function uiCorner(o, r)
        if not o or not o:IsA("GuiObject") then return end
        local c = o:FindFirstChild("SERAPH_ULTRA_CORNER")
        if not c then
            c = Instance.new("UICorner")
            c.Name = "SERAPH_ULTRA_CORNER"
            c.CornerRadius = UDim.new(0, r or 10)
            c.Parent = o
        end
    end

    local function uiStroke(o, color, alpha, thick)
        if not o or not o:IsA("GuiObject") then return end
        local s = o:FindFirstChild("SERAPH_ULTRA_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_ULTRA_STROKE"
            s.Parent = o
        end
        s.Color = color or GOLD
        s.Transparency = alpha == nil and .75 or alpha
        s.Thickness = thick or 1
    end

    local function uiGradient(o, a, b, rotation)
        if not o or not o:IsA("GuiObject") then return end
        local g = o:FindFirstChild("SERAPH_ULTRA_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_ULTRA_GRADIENT"
            g.Parent = o
        end
        g.Color = ColorSequence.new(a, b)
        g.Rotation = rotation or 90
    end

    local function findWindow()
        if not pg then return nil end
        for _, o in ipairs(pg:GetDescendants()) do
            if o:IsA("GuiObject") and o.Visible then
                local t = o:FindFirstChild("Title", true)
                if t and t:IsA("TextLabel") and t.Text ~= "" then
                    local n = string.lower(t.Text)
                    if string.find(n, "seraph", 1, true) or string.find(n, "hub", 1, true) then
                        return o
                    end
                end
            end
        end
        return nil
    end

    local function addButtonFX(b)
        if not b:IsA("GuiButton") or b:GetAttribute("SERAPH_ULTRA_FX") then return end
        b:SetAttribute("SERAPH_ULTRA_FX", true)
        b.AutoButtonColor = false
        uiCorner(b, 8)
        uiStroke(b, Color3.fromRGB(66,67,78), .82, 1)

        local scale = Instance.new("UIScale")
        scale.Name = "SERAPH_ULTRA_SCALE"
        scale.Parent = b

        local base = b.BackgroundColor3
        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(.12), {
                BackgroundColor3 = HOVER
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.12), {
                Scale = 1.025
            }):Play()
        end)

        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(.14), {
                BackgroundColor3 = base
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.14), {
                Scale = 1
            }):Play()
        end)

        b.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(scale, TweenInfo.new(.07), {
                    Scale = .97
                }):Play()
            end
        end)

        b.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(scale, TweenInfo.new(.08), {
                    Scale = 1.025
                }):Play()
            end
        end)
    end

    local function applyUltra(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = BG
        win.BackgroundTransparency = 0
        win.BorderSizePixel = 0
        uiCorner(win, 17)
        uiStroke(win, GOLD, .56, 1.2)

        -- Soft inner border.
        if not win:FindFirstChild("SERAPH_ULTRA_INNER") then
            local inner = Instance.new("Frame")
            inner.Name = "SERAPH_ULTRA_INNER"
            inner.BackgroundTransparency = 1
            inner.BorderSizePixel = 0
            inner.Position = UDim2.new(0, 3, 0, 3)
            inner.Size = UDim2.new(1, -6, 1, -6)
            inner.ZIndex = 0
            uiCorner(inner, 14)
            uiStroke(inner, Color3.fromRGB(255,255,255), .95, 1)
            inner.Parent = win
        end

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = CARD
            bar.BackgroundTransparency = 0
            uiCorner(bar, 13)
            uiStroke(bar, Color3.fromRGB(69,70,81), .62, 1)
            uiGradient(bar, Color3.fromRGB(32,33,41), CARD, 0)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = WHITE
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
                title.TextXAlignment = Enum.TextXAlignment.Left
            end

            if not bar:FindFirstChild("SERAPH_ULTRA_LOGO") then
                local logo = Instance.new("Frame")
                logo.Name = "SERAPH_ULTRA_LOGO"
                logo.BackgroundColor3 = GOLD
                logo.BorderSizePixel = 0
                logo.Position = UDim2.new(0, 12, .5, -13)
                logo.Size = UDim2.new(0, 26, 0, 26)
                logo.ZIndex = 100
                uiCorner(logo, 8)
                logo.Parent = bar

                local lt = Instance.new("TextLabel")
                lt.BackgroundTransparency = 1
                lt.Size = UDim2.new(1,0,1,0)
                lt.Text = "S"
                lt.TextColor3 = BG
                lt.Font = Enum.Font.GothamBlack
                lt.TextSize = 15
                lt.Parent = logo

                if title then
                    title.Position = UDim2.new(0, 47, title.Position.Y.Scale, title.Position.Y.Offset)
                    title.Size = UDim2.new(1, -155, title.Size.Y.Scale, title.Size.Y.Offset)
                end
            end

            if not bar:FindFirstChild("SERAPH_ULTRA_ONLINE") then
                local online = Instance.new("Frame")
                online.Name = "SERAPH_ULTRA_ONLINE"
                online.AnchorPoint = Vector2.new(1, .5)
                online.Position = UDim2.new(1, -16, .5, 0)
                online.Size = UDim2.new(0, 78, 0, 24)
                online.BackgroundColor3 = Color3.fromRGB(28, 67, 47)
                online.BackgroundTransparency = .18
                online.BorderSizePixel = 0
                online.ZIndex = 100
                uiCorner(online, 12)
                uiStroke(online, GREEN, .68, 1)
                online.Parent = bar

                local dot = Instance.new("Frame")
                dot.BackgroundColor3 = GREEN
                dot.BorderSizePixel = 0
                dot.Position = UDim2.new(0, 9, .5, -3)
                dot.Size = UDim2.new(0, 6, 0, 6)
                dot.ZIndex = 101
                uiCorner(dot, 6)
                dot.Parent = online

                local tx = Instance.new("TextLabel")
                tx.BackgroundTransparency = 1
                tx.Position = UDim2.new(0, 20, 0, 0)
                tx.Size = UDim2.new(1, -22, 1, 0)
                tx.Text = "ONLINE"
                tx.TextColor3 = GREEN
                tx.Font = Enum.Font.GothamBold
                tx.TextSize = 9
                tx.TextXAlignment = Enum.TextXAlignment.Left
                tx.Parent = online
            end

            if not bar:FindFirstChild("SERAPH_ULTRA_LINE") then
                local line = Instance.new("Frame")
                line.Name = "SERAPH_ULTRA_LINE"
                line.BackgroundColor3 = GOLD
                line.BorderSizePixel = 0
                line.Position = UDim2.new(0, 16, 1, -2)
                line.Size = UDim2.new(1, -32, 0, 2)
                line.ZIndex = 100
                uiCorner(line, 2)
                line.Parent = bar

                local glow = Instance.new("Frame")
                glow.BackgroundColor3 = GOLD2
                glow.BackgroundTransparency = .88
                glow.BorderSizePixel = 0
                glow.Position = UDim2.new(0, 0, 0, -2)
                glow.Size = UDim2.new(1, 0, 0, 6)
                glow.ZIndex = 99
                glow.Parent = line
            end
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = CARD
            nav.BackgroundTransparency = 0
            uiCorner(nav, 12)
            uiStroke(nav, Color3.fromRGB(56,57,68), .62, 1)

            local scroll = nav:FindFirstChildWhichIsA("ScrollingFrame", true)
            if scroll then
                scroll.ScrollBarThickness = 3
                scroll.ScrollBarImageColor3 = GOLD
                scroll.ScrollBarImageTransparency = .35
            end
        end

        -- Add a subtle active accent to tab buttons.
        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = CARD2
                o.TextColor3 = WHITE
                o.Font = Enum.Font.GothamMedium
                addButtonFX(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(10,11,15)
                o.TextColor3 = WHITE
                o.PlaceholderColor3 = MUTED
                uiCorner(o, 8)
                uiStroke(o, Color3.fromRGB(70,71,82), .58, 1)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = GOLD
                o.ScrollBarImageTransparency = .34
            end
        end

        -- Improve every visible content container.
        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("Frame") and o.Visible and o ~= win then
                if o.Name ~= "SERAPH_ULTRA_LOGO"
                    and o.Name ~= "SERAPH_ULTRA_ONLINE"
                    and o.Name ~= "SERAPH_ULTRA_LINE"
                    and o.Name ~= "SERAPH_ULTRA_INNER" then
                    if o.Size.X.Scale > .35 and o.Size.Y.Scale > .12 then
                        uiCorner(o, 9)
                    end
                end
            end
        end
    end

    local w = findWindow()
    if w then
        applyUltra(w)
        for i = 1, 8 do
            task.delay(i * .3, function()
                if w and w.Parent then
                    applyUltra(w)
                end
            end)
        end
    end
end)


-- ============================================================
-- SERAPH HUB ELITE V5
-- Final visual refinement for the existing GUI.
-- No new feature window; no replacement of existing callbacks.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local Players = game:GetService("Players")
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")

    local GOLD = Color3.fromRGB(235, 198, 96)
    local GOLD_BRIGHT = Color3.fromRGB(255, 225, 140)
    local BG = Color3.fromRGB(6, 7, 10)
    local SURFACE = Color3.fromRGB(14, 15, 20)
    local CARD = Color3.fromRGB(20, 21, 27)
    local CARD_HOVER = Color3.fromRGB(31, 32, 40)
    local TEXT = Color3.fromRGB(247, 247, 250)
    local MUTED = Color3.fromRGB(142, 145, 157)
    local GREEN = Color3.fromRGB(82, 224, 143)

    local function corner(o, r)
        if not o or not o:IsA("GuiObject") then return end
        local c = o:FindFirstChild("SERAPH_V5_CORNER")
        if not c then
            c = Instance.new("UICorner")
            c.Name = "SERAPH_V5_CORNER"
            c.CornerRadius = UDim.new(0, r or 10)
            c.Parent = o
        end
    end

    local function stroke(o, color, transparency, thickness)
        if not o or not o:IsA("GuiObject") then return end
        local s = o:FindFirstChild("SERAPH_V5_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_V5_STROKE"
            s.Parent = o
        end
        s.Color = color or GOLD
        s.Transparency = transparency == nil and .78 or transparency
        s.Thickness = thickness or 1
    end

    local function gradient(o, a, b, rotation)
        if not o or not o:IsA("GuiObject") then return end
        local g = o:FindFirstChild("SERAPH_V5_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_V5_GRADIENT"
            g.Parent = o
        end
        g.Color = ColorSequence.new(a, b)
        g.Rotation = rotation or 90
    end

    local function findWindow()
        if not pg then return nil end
        for _, o in ipairs(pg:GetDescendants()) do
            if o:IsA("GuiObject") and o.Visible then
                local t = o:FindFirstChild("Title", true)
                if t and t:IsA("TextLabel") and t.Text ~= "" then
                    local s = string.lower(t.Text)
                    if string.find(s, "seraph", 1, true) or string.find(s, "hub", 1, true) then
                        return o
                    end
                end
            end
        end
        return nil
    end

    local function fxButton(b)
        if not b:IsA("GuiButton") or b:GetAttribute("SERAPH_V5_FX") then return end
        b:SetAttribute("SERAPH_V5_FX", true)
        b.AutoButtonColor = false
        corner(b, 8)
        stroke(b, Color3.fromRGB(65,66,77), .84, 1)

        local sc = Instance.new("UIScale")
        sc.Name = "SERAPH_V5_SCALE"
        sc.Parent = b

        local base = b.BackgroundColor3
        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(.11), {BackgroundColor3 = CARD_HOVER}):Play()
            TweenService:Create(sc, TweenInfo.new(.11), {Scale = 1.02}):Play()
        end)
        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(.13), {BackgroundColor3 = base}):Play()
            TweenService:Create(sc, TweenInfo.new(.13), {Scale = 1}):Play()
        end)
        b.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(sc, TweenInfo.new(.06), {Scale = .975}):Play()
            end
        end)
        b.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(sc, TweenInfo.new(.08), {Scale = 1.02}):Play()
            end
        end)
    end

    local function addTopDecor(bar)
        if not bar or not bar:IsA("GuiObject") then return end

        if not bar:FindFirstChild("SERAPH_V5_GLOW") then
            local glow = Instance.new("Frame")
            glow.Name = "SERAPH_V5_GLOW"
            glow.BackgroundColor3 = GOLD_BRIGHT
            glow.BackgroundTransparency = .93
            glow.BorderSizePixel = 0
            glow.Position = UDim2.new(0, 0, 1, -7)
            glow.Size = UDim2.new(1, 0, 0, 12)
            glow.ZIndex = 98
            glow.Parent = bar
        end

        if not bar:FindFirstChild("SERAPH_V5_VERSION") then
            local v = Instance.new("TextLabel")
            v.Name = "SERAPH_V5_VERSION"
            v.BackgroundTransparency = 1
            v.Text = "V5 • PREMIUM"
            v.TextColor3 = MUTED
            v.Font = Enum.Font.GothamMedium
            v.TextSize = 8
            v.TextXAlignment = Enum.TextXAlignment.Right
            v.Position = UDim2.new(1, -105, 0, 2)
            v.Size = UDim2.new(0, 90, 0, 14)
            v.ZIndex = 100
            v.Parent = bar
        end
    end

    local function apply(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = BG
        win.BackgroundTransparency = 0
        win.BorderSizePixel = 0
        corner(win, 17)
        stroke(win, GOLD, .6, 1.2)

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = SURFACE
            bar.BackgroundTransparency = 0
            corner(bar, 13)
            stroke(bar, Color3.fromRGB(58,59,70), .62, 1)
            gradient(bar, Color3.fromRGB(29,30,38), SURFACE, 0)
            addTopDecor(bar)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = TEXT
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
                title.TextXAlignment = Enum.TextXAlignment.Left
                title.Position = UDim2.new(0, 48, title.Position.Y.Scale, title.Position.Y.Offset)
                title.Size = UDim2.new(1, -170, title.Size.Y.Scale, title.Size.Y.Offset)
            end

            if not bar:FindFirstChild("SERAPH_V5_LOGO") then
                local logo = Instance.new("Frame")
                logo.Name = "SERAPH_V5_LOGO"
                logo.BackgroundColor3 = GOLD
                logo.BorderSizePixel = 0
                logo.Position = UDim2.new(0, 13, .5, -13)
                logo.Size = UDim2.new(0, 26, 0, 26)
                logo.ZIndex = 101
                corner(logo, 8)
                logo.Parent = bar

                local l = Instance.new("TextLabel")
                l.BackgroundTransparency = 1
                l.Size = UDim2.new(1,0,1,0)
                l.Text = "S"
                l.TextColor3 = BG
                l.Font = Enum.Font.GothamBlack
                l.TextSize = 15
                l.Parent = logo
            end

            if not bar:FindFirstChild("SERAPH_V5_STATUS") then
                local st = Instance.new("Frame")
                st.Name = "SERAPH_V5_STATUS"
                st.AnchorPoint = Vector2.new(1, .5)
                st.Position = UDim2.new(1, -17, .5, 0)
                st.Size = UDim2.new(0, 80, 0, 24)
                st.BackgroundColor3 = Color3.fromRGB(24, 61, 43)
                st.BackgroundTransparency = .12
                st.BorderSizePixel = 0
                st.ZIndex = 101
                corner(st, 12)
                stroke(st, GREEN, .7, 1)
                st.Parent = bar

                local d = Instance.new("Frame")
                d.BackgroundColor3 = GREEN
                d.BorderSizePixel = 0
                d.Position = UDim2.new(0, 9, .5, -3)
                d.Size = UDim2.new(0, 6, 0, 6)
                d.ZIndex = 102
                corner(d, 6)
                d.Parent = st

                local t = Instance.new("TextLabel")
                t.BackgroundTransparency = 1
                t.Position = UDim2.new(0, 20, 0, 0)
                t.Size = UDim2.new(1, -22, 1, 0)
                t.Text = "ONLINE"
                t.TextColor3 = GREEN
                t.Font = Enum.Font.GothamBold
                t.TextSize = 9
                t.TextXAlignment = Enum.TextXAlignment.Left
                t.Parent = st
            end
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = SURFACE
            nav.BackgroundTransparency = 0
            corner(nav, 12)
            stroke(nav, Color3.fromRGB(52,53,64), .62, 1)
        end

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = CARD
                o.TextColor3 = TEXT
                o.Font = Enum.Font.GothamMedium
                fxButton(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(9,10,14)
                o.TextColor3 = TEXT
                o.PlaceholderColor3 = MUTED
                corner(o, 8)
                stroke(o, Color3.fromRGB(67,68,79), .6, 1)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = GOLD
                o.ScrollBarImageTransparency = .32
            end
        end
    end

    local w = findWindow()
    if w then
        apply(w)
        for i = 1, 10 do
            task.delay(i * .25, function()
                if w and w.Parent then apply(w) end
            end)
        end
    end
end)


-- ============================================================
-- SERAPH HUB ELITE+ V6
-- Visual polish only. Existing GUI/API/callbacks are preserved.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local Players = game:GetService("Players")
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")

    local GOLD = Color3.fromRGB(235, 198, 96)
    local GOLD2 = Color3.fromRGB(255, 226, 145)
    local BG = Color3.fromRGB(6, 7, 10)
    local SURFACE = Color3.fromRGB(13, 14, 19)
    local CARD = Color3.fromRGB(19, 20, 27)
    local CARD2 = Color3.fromRGB(24, 25, 33)
    local HOVER = Color3.fromRGB(34, 35, 45)
    local TEXT = Color3.fromRGB(247, 247, 250)
    local MUTED = Color3.fromRGB(145, 148, 160)
    local GREEN = Color3.fromRGB(80, 223, 142)
    local RED = Color3.fromRGB(235, 91, 102)

    local function corner(o, r)
        if not o or not o:IsA("GuiObject") then return end
        local c = o:FindFirstChild("SERAPH_V6_CORNER")
        if not c then
            c = Instance.new("UICorner")
            c.Name = "SERAPH_V6_CORNER"
            c.CornerRadius = UDim.new(0, r or 10)
            c.Parent = o
        end
    end

    local function stroke(o, color, tr, thick)
        if not o or not o:IsA("GuiObject") then return end
        local s = o:FindFirstChild("SERAPH_V6_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_V6_STROKE"
            s.Parent = o
        end
        s.Color = color or GOLD
        s.Transparency = tr == nil and .78 or tr
        s.Thickness = thick or 1
    end

    local function grad(o, a, b, rot)
        if not o or not o:IsA("GuiObject") then return end
        local g = o:FindFirstChild("SERAPH_V6_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_V6_GRADIENT"
            g.Parent = o
        end
        g.Color = ColorSequence.new(a, b)
        g.Rotation = rot or 90
    end

    local function findWindow()
        if not pg then return nil end
        for _, o in ipairs(pg:GetDescendants()) do
            if o:IsA("GuiObject") and o.Visible then
                local t = o:FindFirstChild("Title", true)
                if t and t:IsA("TextLabel") and t.Text ~= "" then
                    local s = string.lower(t.Text)
                    if string.find(s, "seraph", 1, true) or string.find(s, "hub", 1, true) then
                        return o
                    end
                end
            end
        end
    end

    local function buttonFX(b)
        if not b:IsA("GuiButton") or b:GetAttribute("SERAPH_V6_FX") then return end
        b:SetAttribute("SERAPH_V6_FX", true)
        b.AutoButtonColor = false
        corner(b, 8)
        stroke(b, Color3.fromRGB(64,65,76), .83, 1)

        local scale = Instance.new("UIScale")
        scale.Name = "SERAPH_V6_SCALE"
        scale.Parent = b

        local base = b.BackgroundColor3
        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(.11, Enum.EasingStyle.Quad), {
                BackgroundColor3 = HOVER
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.11, Enum.EasingStyle.Quad), {
                Scale = 1.025
            }):Play()
        end)
        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                BackgroundColor3 = base
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                Scale = 1
            }):Play()
        end)
    end

    local function addHeader(bar)
        if not bar or not bar:IsA("GuiObject") then return end

        if not bar:FindFirstChild("SERAPH_V6_TOPLINE") then
            local line = Instance.new("Frame")
            line.Name = "SERAPH_V6_TOPLINE"
            line.BackgroundColor3 = GOLD
            line.BorderSizePixel = 0
            line.Position = UDim2.new(0, 18, 1, -2)
            line.Size = UDim2.new(1, -36, 0, 2)
            line.ZIndex = 120
            corner(line, 2)
            line.Parent = bar

            local glow = Instance.new("Frame")
            glow.BackgroundColor3 = GOLD2
            glow.BackgroundTransparency = .9
            glow.BorderSizePixel = 0
            glow.Position = UDim2.new(0, 0, 0, -3)
            glow.Size = UDim2.new(1, 0, 0, 8)
            glow.ZIndex = 119
            glow.Parent = line
        end

        if not bar:FindFirstChild("SERAPH_V6_SUBTITLE") then
            local sub = Instance.new("TextLabel")
            sub.Name = "SERAPH_V6_SUBTITLE"
            sub.BackgroundTransparency = 1
            sub.Text = "ELITE CONTROL PANEL"
            sub.TextColor3 = MUTED
            sub.Font = Enum.Font.GothamMedium
            sub.TextSize = 7
            sub.TextXAlignment = Enum.TextXAlignment.Left
            sub.Position = UDim2.new(0, 48, 0, 25)
            sub.Size = UDim2.new(0, 150, 0, 12)
            sub.ZIndex = 120
            sub.Parent = bar
        end

        if not bar:FindFirstChild("SERAPH_V6_STATUS") then
            local st = Instance.new("Frame")
            st.Name = "SERAPH_V6_STATUS"
            st.AnchorPoint = Vector2.new(1, .5)
            st.Position = UDim2.new(1, -17, .5, 0)
            st.Size = UDim2.new(0, 82, 0, 25)
            st.BackgroundColor3 = Color3.fromRGB(24, 62, 43)
            st.BackgroundTransparency = .1
            st.BorderSizePixel = 0
            st.ZIndex = 121
            corner(st, 13)
            stroke(st, GREEN, .68, 1)
            st.Parent = bar

            local dot = Instance.new("Frame")
            dot.BackgroundColor3 = GREEN
            dot.BorderSizePixel = 0
            dot.Position = UDim2.new(0, 9, .5, -3)
            dot.Size = UDim2.new(0, 6, 0, 6)
            dot.ZIndex = 122
            corner(dot, 6)
            dot.Parent = st

            local tx = Instance.new("TextLabel")
            tx.BackgroundTransparency = 1
            tx.Position = UDim2.new(0, 20, 0, 0)
            tx.Size = UDim2.new(1, -22, 1, 0)
            tx.Text = "ONLINE"
            tx.TextColor3 = GREEN
            tx.Font = Enum.Font.GothamBold
            tx.TextSize = 9
            tx.TextXAlignment = Enum.TextXAlignment.Left
            tx.Parent = st
        end
    end

    local function apply(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = BG
        win.BackgroundTransparency = 0
        win.BorderSizePixel = 0
        corner(win, 17)
        stroke(win, GOLD, .58, 1.2)
        grad(win, Color3.fromRGB(12,13,18), BG, 90)

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = SURFACE
            bar.BackgroundTransparency = 0
            corner(bar, 13)
            stroke(bar, Color3.fromRGB(58,59,70), .62, 1)
            grad(bar, Color3.fromRGB(29,30,39), SURFACE, 0)
            addHeader(bar)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = TEXT
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
                title.Position = UDim2.new(0, 48, title.Position.Y.Scale, title.Position.Y.Offset)
                title.Size = UDim2.new(1, -175, title.Size.Y.Scale, title.Size.Y.Offset)
            end

            if not bar:FindFirstChild("SERAPH_V6_LOGO") then
                local logo = Instance.new("Frame")
                logo.Name = "SERAPH_V6_LOGO"
                logo.BackgroundColor3 = GOLD
                logo.BorderSizePixel = 0
                logo.Position = UDim2.new(0, 13, .5, -13)
                logo.Size = UDim2.new(0, 26, 0, 26)
                logo.ZIndex = 122
                corner(logo, 8)
                logo.Parent = bar

                local lt = Instance.new("TextLabel")
                lt.BackgroundTransparency = 1
                lt.Size = UDim2.new(1,0,1,0)
                lt.Text = "S"
                lt.TextColor3 = BG
                lt.Font = Enum.Font.GothamBlack
                lt.TextSize = 15
                lt.Parent = logo
            end
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = SURFACE
            nav.BackgroundTransparency = 0
            corner(nav, 12)
            stroke(nav, Color3.fromRGB(52,53,64), .62, 1)

            local list = nav:FindFirstChildWhichIsA("UIListLayout", true)
            if list then
                list.Padding = UDim.new(0, 5)
            end
        end

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = CARD
                o.TextColor3 = TEXT
                o.Font = Enum.Font.GothamMedium
                buttonFX(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(9,10,14)
                o.TextColor3 = TEXT
                o.PlaceholderColor3 = MUTED
                corner(o, 8)
                stroke(o, Color3.fromRGB(67,68,79), .58, 1)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = GOLD
                o.ScrollBarImageTransparency = .3
            end
        end

        -- Decorative vertical gold accent on the main content edge.
        if not win:FindFirstChild("SERAPH_V6_EDGE") then
            local edge = Instance.new("Frame")
            edge.Name = "SERAPH_V6_EDGE"
            edge.BackgroundColor3 = GOLD
            edge.BackgroundTransparency = .18
            edge.BorderSizePixel = 0
            edge.AnchorPoint = Vector2.new(0, .5)
            edge.Position = UDim2.new(0, 1, .5, 0)
            edge.Size = UDim2.new(0, 2, .45, 0)
            edge.ZIndex = 90
            corner(edge, 2)
            edge.Parent = win
        end
    end

    local w = findWindow()
    if w then
        apply(w)
        for i = 1, 12 do
            task.delay(i * .22, function()
                if w and w.Parent then apply(w) end
            end)
        end
    end
end)


-- ============================================================
-- SERAPH HUB AURORA V7
-- Visual-only refinement layer for the existing GUI.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local Players = game:GetService("Players")
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")

    local GOLD = Color3.fromRGB(236, 199, 96)
    local GOLD2 = Color3.fromRGB(255, 226, 145)
    local BG = Color3.fromRGB(5, 6, 9)
    local SURFACE = Color3.fromRGB(12, 13, 18)
    local CARD = Color3.fromRGB(18, 19, 26)
    local HOVER = Color3.fromRGB(31, 32, 42)
    local TEXT = Color3.fromRGB(247, 247, 250)
    local MUTED = Color3.fromRGB(145, 148, 160)
    local GREEN = Color3.fromRGB(81, 224, 143)

    local function corner(o, r)
        if not o or not o:IsA("GuiObject") then return end
        local c = o:FindFirstChild("SERAPH_V7_CORNER")
        if not c then
            c = Instance.new("UICorner")
            c.Name = "SERAPH_V7_CORNER"
            c.CornerRadius = UDim.new(0, r or 10)
            c.Parent = o
        end
    end

    local function stroke(o, color, tr, thick)
        if not o or not o:IsA("GuiObject") then return end
        local s = o:FindFirstChild("SERAPH_V7_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_V7_STROKE"
            s.Parent = o
        end
        s.Color = color or GOLD
        s.Transparency = tr == nil and .78 or tr
        s.Thickness = thick or 1
    end

    local function gradient(o, a, b, rot)
        if not o or not o:IsA("GuiObject") then return end
        local g = o:FindFirstChild("SERAPH_V7_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_V7_GRADIENT"
            g.Parent = o
        end
        g.Color = ColorSequence.new(a, b)
        g.Rotation = rot or 90
    end

    local function findWindow()
        if not pg then return nil end
        for _, o in ipairs(pg:GetDescendants()) do
            if o:IsA("GuiObject") and o.Visible then
                local t = o:FindFirstChild("Title", true)
                if t and t:IsA("TextLabel") and t.Text ~= "" then
                    local s = string.lower(t.Text)
                    if string.find(s, "seraph", 1, true) or string.find(s, "hub", 1, true) then
                        return o
                    end
                end
            end
        end
        return nil
    end

    local function buttonFX(b)
        if not b:IsA("GuiButton") or b:GetAttribute("SERAPH_V7_FX") then return end
        b:SetAttribute("SERAPH_V7_FX", true)
        b.AutoButtonColor = false
        corner(b, 8)
        stroke(b, Color3.fromRGB(65,66,78), .84, 1)

        local sc = Instance.new("UIScale")
        sc.Name = "SERAPH_V7_SCALE"
        sc.Parent = b

        local base = b.BackgroundColor3
        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(.11, Enum.EasingStyle.Quad), {
                BackgroundColor3 = HOVER
            }):Play()
            TweenService:Create(sc, TweenInfo.new(.11, Enum.EasingStyle.Quad), {
                Scale = 1.025
            }):Play()
        end)
        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                BackgroundColor3 = base
            }):Play()
            TweenService:Create(sc, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                Scale = 1
            }):Play()
        end)
    end

    local function header(bar)
        if not bar then return end

        if not bar:FindFirstChild("SERAPH_V7_GLOW") then
            local glow = Instance.new("Frame")
            glow.Name = "SERAPH_V7_GLOW"
            glow.BackgroundColor3 = GOLD2
            glow.BackgroundTransparency = .93
            glow.BorderSizePixel = 0
            glow.Position = UDim2.new(0, 0, 1, -8)
            glow.Size = UDim2.new(1, 0, 0, 14)
            glow.ZIndex = 95
            glow.Parent = bar
        end

        if not bar:FindFirstChild("SERAPH_V7_ACCENT") then
            local accent = Instance.new("Frame")
            accent.Name = "SERAPH_V7_ACCENT"
            accent.BackgroundColor3 = GOLD
            accent.BorderSizePixel = 0
            accent.Position = UDim2.new(0, 17, 1, -2)
            accent.Size = UDim2.new(1, -34, 0, 2)
            accent.ZIndex = 110
            corner(accent, 2)
            accent.Parent = bar
        end

        if not bar:FindFirstChild("SERAPH_V7_STATUS") then
            local status = Instance.new("Frame")
            status.Name = "SERAPH_V7_STATUS"
            status.AnchorPoint = Vector2.new(1, .5)
            status.Position = UDim2.new(1, -16, .5, 0)
            status.Size = UDim2.new(0, 82, 0, 25)
            status.BackgroundColor3 = Color3.fromRGB(24, 61, 43)
            status.BackgroundTransparency = .08
            status.BorderSizePixel = 0
            status.ZIndex = 120
            corner(status, 13)
            stroke(status, GREEN, .68, 1)
            status.Parent = bar

            local dot = Instance.new("Frame")
            dot.BackgroundColor3 = GREEN
            dot.BorderSizePixel = 0
            dot.Position = UDim2.new(0, 9, .5, -3)
            dot.Size = UDim2.new(0, 6, 0, 6)
            dot.ZIndex = 121
            corner(dot, 6)
            dot.Parent = status

            local txt = Instance.new("TextLabel")
            txt.BackgroundTransparency = 1
            txt.Position = UDim2.new(0, 20, 0, 0)
            txt.Size = UDim2.new(1, -22, 1, 0)
            txt.Text = "ONLINE"
            txt.TextColor3 = GREEN
            txt.Font = Enum.Font.GothamBold
            txt.TextSize = 9
            txt.TextXAlignment = Enum.TextXAlignment.Left
            txt.Parent = status
        end
    end

    local function apply(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = BG
        win.BackgroundTransparency = 0
        win.BorderSizePixel = 0
        corner(win, 18)
        stroke(win, GOLD, .57, 1.2)
        gradient(win, Color3.fromRGB(12, 13, 18), BG, 90)

        if not win:FindFirstChild("SERAPH_V7_INNER") then
            local inner = Instance.new("Frame")
            inner.Name = "SERAPH_V7_INNER"
            inner.BackgroundTransparency = 1
            inner.BorderSizePixel = 0
            inner.Position = UDim2.new(0, 3, 0, 3)
            inner.Size = UDim2.new(1, -6, 1, -6)
            inner.ZIndex = 1
            corner(inner, 15)
            stroke(inner, Color3.fromRGB(255,255,255), .95, 1)
            inner.Parent = win
        end

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = SURFACE
            bar.BackgroundTransparency = 0
            corner(bar, 13)
            stroke(bar, Color3.fromRGB(59,60,72), .62, 1)
            gradient(bar, Color3.fromRGB(29,30,39), SURFACE, 0)
            header(bar)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = TEXT
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
                title.Position = UDim2.new(0, 48, title.Position.Y.Scale, title.Position.Y.Offset)
                title.Size = UDim2.new(1, -175, title.Size.Y.Scale, title.Size.Y.Offset)
            end

            if not bar:FindFirstChild("SERAPH_V7_LOGO") then
                local logo = Instance.new("Frame")
                logo.Name = "SERAPH_V7_LOGO"
                logo.BackgroundColor3 = GOLD
                logo.BorderSizePixel = 0
                logo.Position = UDim2.new(0, 13, .5, -13)
                logo.Size = UDim2.new(0, 26, 0, 26)
                logo.ZIndex = 121
                corner(logo, 8)
                logo.Parent = bar

                local l = Instance.new("TextLabel")
                l.BackgroundTransparency = 1
                l.Size = UDim2.new(1, 0, 1, 0)
                l.Text = "S"
                l.TextColor3 = BG
                l.Font = Enum.Font.GothamBlack
                l.TextSize = 15
                l.Parent = logo
            end
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = SURFACE
            nav.BackgroundTransparency = 0
            corner(nav, 12)
            stroke(nav, Color3.fromRGB(53,54,65), .61, 1)
        end

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = CARD
                o.TextColor3 = TEXT
                o.Font = Enum.Font.GothamMedium
                buttonFX(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(9,10,14)
                o.TextColor3 = TEXT
                o.PlaceholderColor3 = MUTED
                corner(o, 8)
                stroke(o, Color3.fromRGB(67,68,80), .58, 1)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = GOLD
                o.ScrollBarImageTransparency = .30
            end
        end
    end

    local w = findWindow()
    if w then
        apply(w)
        for i = 1, 12 do
            task.delay(i * .2, function()
                if w and w.Parent then apply(w) end
            end)
        end
    end
end)


-- ============================================================
-- SERAPH HUB NOVA V8
-- Visual-only layer: upgrades the existing GUI without
-- replacing its window/tab/folder system or callbacks.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local Players = game:GetService("Players")
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")

    local GOLD = Color3.fromRGB(238, 201, 101)
    local GOLD_HI = Color3.fromRGB(255, 229, 151)
    local BG = Color3.fromRGB(5, 6, 9)
    local SURFACE = Color3.fromRGB(11, 12, 17)
    local PANEL = Color3.fromRGB(17, 18, 25)
    local PANEL_HI = Color3.fromRGB(27, 28, 37)
    local TEXT = Color3.fromRGB(248, 248, 251)
    local MUTED = Color3.fromRGB(143, 146, 158)
    local GREEN = Color3.fromRGB(81, 225, 144)

    local function corner(o, r)
        if not o or not o:IsA("GuiObject") then return end
        local c = o:FindFirstChild("SERAPH_V8_CORNER")
        if not c then
            c = Instance.new("UICorner")
            c.Name = "SERAPH_V8_CORNER"
            c.CornerRadius = UDim.new(0, r or 10)
            c.Parent = o
        end
    end

    local function stroke(o, color, tr, thickness)
        if not o or not o:IsA("GuiObject") then return end
        local s = o:FindFirstChild("SERAPH_V8_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_V8_STROKE"
            s.Parent = o
        end
        s.Color = color or GOLD
        s.Transparency = tr == nil and .78 or tr
        s.Thickness = thickness or 1
    end

    local function gradient(o, a, b, rotation)
        if not o or not o:IsA("GuiObject") then return end
        local g = o:FindFirstChild("SERAPH_V8_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_V8_GRADIENT"
            g.Parent = o
        end
        g.Color = ColorSequence.new(a, b)
        g.Rotation = rotation or 90
    end

    local function findWindow()
        if not pg then return nil end
        for _, o in ipairs(pg:GetDescendants()) do
            if o:IsA("GuiObject") and o.Visible then
                local title = o:FindFirstChild("Title", true)
                if title and title:IsA("TextLabel") and title.Text ~= "" then
                    local n = string.lower(title.Text)
                    if string.find(n, "seraph", 1, true) or string.find(n, "hub", 1, true) then
                        return o
                    end
                end
            end
        end
        return nil
    end

    local function addButtonFX(b)
        if not b:IsA("GuiButton") or b:GetAttribute("SERAPH_V8_FX") then return end
        b:SetAttribute("SERAPH_V8_FX", true)
        b.AutoButtonColor = false
        corner(b, 8)
        stroke(b, Color3.fromRGB(62,63,75), .84, 1)

        local scale = Instance.new("UIScale")
        scale.Name = "SERAPH_V8_SCALE"
        scale.Parent = b

        local base = b.BackgroundColor3
        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(.11, Enum.EasingStyle.Quad), {
                BackgroundColor3 = PANEL_HI
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.11, Enum.EasingStyle.Quad), {
                Scale = 1.025
            }):Play()
        end)
        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(.13, Enum.EasingStyle.Quad), {
                BackgroundColor3 = base
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.13, Enum.EasingStyle.Quad), {
                Scale = 1
            }):Play()
        end)
    end

    local function addHeader(bar)
        if not bar then return end

        if not bar:FindFirstChild("SERAPH_V8_LOGO") then
            local logo = Instance.new("Frame")
            logo.Name = "SERAPH_V8_LOGO"
            logo.BackgroundColor3 = GOLD
            logo.BorderSizePixel = 0
            logo.Position = UDim2.new(0, 13, .5, -13)
            logo.Size = UDim2.new(0, 26, 0, 26)
            logo.ZIndex = 200
            corner(logo, 8)
            logo.Parent = bar

            local lt = Instance.new("TextLabel")
            lt.BackgroundTransparency = 1
            lt.Size = UDim2.new(1, 0, 1, 0)
            lt.Text = "S"
            lt.TextColor3 = BG
            lt.Font = Enum.Font.GothamBlack
            lt.TextSize = 15
            lt.Parent = logo
        end

        if not bar:FindFirstChild("SERAPH_V8_SUB") then
            local sub = Instance.new("TextLabel")
            sub.Name = "SERAPH_V8_SUB"
            sub.BackgroundTransparency = 1
            sub.Text = "NOVA • ELITE INTERFACE"
            sub.TextColor3 = MUTED
            sub.Font = Enum.Font.GothamMedium
            sub.TextSize = 7
            sub.TextXAlignment = Enum.TextXAlignment.Left
            sub.Position = UDim2.new(0, 48, 0, 24)
            sub.Size = UDim2.new(0, 170, 0, 12)
            sub.ZIndex = 200
            sub.Parent = bar
        end

        if not bar:FindFirstChild("SERAPH_V8_STATUS") then
            local st = Instance.new("Frame")
            st.Name = "SERAPH_V8_STATUS"
            st.AnchorPoint = Vector2.new(1, .5)
            st.Position = UDim2.new(1, -16, .5, 0)
            st.Size = UDim2.new(0, 82, 0, 25)
            st.BackgroundColor3 = Color3.fromRGB(23, 60, 42)
            st.BackgroundTransparency = .08
            st.BorderSizePixel = 0
            st.ZIndex = 200
            corner(st, 13)
            stroke(st, GREEN, .68, 1)
            st.Parent = bar

            local dot = Instance.new("Frame")
            dot.BackgroundColor3 = GREEN
            dot.BorderSizePixel = 0
            dot.Position = UDim2.new(0, 9, .5, -3)
            dot.Size = UDim2.new(0, 6, 0, 6)
            dot.ZIndex = 201
            corner(dot, 6)
            dot.Parent = st

            local tx = Instance.new("TextLabel")
            tx.BackgroundTransparency = 1
            tx.Position = UDim2.new(0, 20, 0, 0)
            tx.Size = UDim2.new(1, -22, 1, 0)
            tx.Text = "ONLINE"
            tx.TextColor3 = GREEN
            tx.Font = Enum.Font.GothamBold
            tx.TextSize = 9
            tx.TextXAlignment = Enum.TextXAlignment.Left
            tx.Parent = st
        end

        if not bar:FindFirstChild("SERAPH_V8_LINE") then
            local line = Instance.new("Frame")
            line.Name = "SERAPH_V8_LINE"
            line.BackgroundColor3 = GOLD
            line.BorderSizePixel = 0
            line.Position = UDim2.new(0, 16, 1, -2)
            line.Size = UDim2.new(1, -32, 0, 2)
            line.ZIndex = 199
            corner(line, 2)
            line.Parent = bar

            local glow = Instance.new("Frame")
            glow.BackgroundColor3 = GOLD_HI
            glow.BackgroundTransparency = .9
            glow.BorderSizePixel = 0
            glow.Position = UDim2.new(0, 0, 0, -3)
            glow.Size = UDim2.new(1, 0, 0, 8)
            glow.ZIndex = 198
            glow.Parent = line
        end
    end

    local function apply(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = BG
        win.BackgroundTransparency = 0
        win.BorderSizePixel = 0
        corner(win, 18)
        stroke(win, GOLD, .56, 1.2)
        gradient(win, Color3.fromRGB(12, 13, 18), BG, 90)

        if not win:FindFirstChild("SERAPH_V8_INNER") then
            local inner = Instance.new("Frame")
            inner.Name = "SERAPH_V8_INNER"
            inner.BackgroundTransparency = 1
            inner.BorderSizePixel = 0
            inner.Position = UDim2.new(0, 3, 0, 3)
            inner.Size = UDim2.new(1, -6, 1, -6)
            inner.ZIndex = 2
            corner(inner, 15)
            stroke(inner, Color3.fromRGB(255,255,255), .95, 1)
            inner.Parent = win
        end

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = SURFACE
            bar.BackgroundTransparency = 0
            corner(bar, 13)
            stroke(bar, Color3.fromRGB(57,58,70), .61, 1)
            gradient(bar, Color3.fromRGB(29,30,39), SURFACE, 0)
            addHeader(bar)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = TEXT
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
                title.Position = UDim2.new(0, 48, title.Position.Y.Scale, title.Position.Y.Offset)
                title.Size = UDim2.new(1, -175, title.Size.Y.Scale, title.Size.Y.Offset)
            end
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = SURFACE
            nav.BackgroundTransparency = 0
            corner(nav, 12)
            stroke(nav, Color3.fromRGB(51,52,64), .6, 1)
        end

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = PANEL
                o.TextColor3 = TEXT
                o.Font = Enum.Font.GothamMedium
                addButtonFX(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(9,10,14)
                o.TextColor3 = TEXT
                o.PlaceholderColor3 = MUTED
                corner(o, 8)
                stroke(o, Color3.fromRGB(66,67,79), .58, 1)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = GOLD
                o.ScrollBarImageTransparency = .29
            end
        end
    end

    local w = findWindow()
    if w then
        apply(w)
        for i = 1, 14 do
            task.delay(i * .18, function()
                if w and w.Parent then
                    apply(w)
                end
            end)
        end
    end
end)


-- ============================================================
-- SERAPH HUB AETHER V9
-- Visual refinement layer for the existing GUI.
-- Keeps the existing GUI structure and callbacks intact.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local Players = game:GetService("Players")
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")

    local GOLD = Color3.fromRGB(239, 203, 105)
    local GOLD_HI = Color3.fromRGB(255, 232, 158)
    local BG = Color3.fromRGB(5, 6, 9)
    local SURFACE = Color3.fromRGB(11, 12, 17)
    local PANEL = Color3.fromRGB(17, 18, 25)
    local PANEL_HOVER = Color3.fromRGB(29, 30, 40)
    local TEXT = Color3.fromRGB(248, 248, 251)
    local MUTED = Color3.fromRGB(145, 148, 160)
    local GREEN = Color3.fromRGB(82, 226, 145)

    local function corner(o, r)
        if not o or not o:IsA("GuiObject") then return end
        local c = o:FindFirstChild("SERAPH_V9_CORNER")
        if not c then
            c = Instance.new("UICorner")
            c.Name = "SERAPH_V9_CORNER"
            c.CornerRadius = UDim.new(0, r or 10)
            c.Parent = o
        end
    end

    local function stroke(o, color, transparency, thickness)
        if not o or not o:IsA("GuiObject") then return end
        local s = o:FindFirstChild("SERAPH_V9_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_V9_STROKE"
            s.Parent = o
        end
        s.Color = color or GOLD
        s.Transparency = transparency == nil and .78 or transparency
        s.Thickness = thickness or 1
    end

    local function gradient(o, a, b, rotation)
        if not o or not o:IsA("GuiObject") then return end
        local g = o:FindFirstChild("SERAPH_V9_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_V9_GRADIENT"
            g.Parent = o
        end
        g.Color = ColorSequence.new(a, b)
        g.Rotation = rotation or 90
    end

    local function findWindow()
        if not pg then return nil end
        for _, o in ipairs(pg:GetDescendants()) do
            if o:IsA("GuiObject") and o.Visible then
                local title = o:FindFirstChild("Title", true)
                if title and title:IsA("TextLabel") and title.Text ~= "" then
                    local n = string.lower(title.Text)
                    if string.find(n, "seraph", 1, true) or string.find(n, "hub", 1, true) then
                        return o
                    end
                end
            end
        end
        return nil
    end

    local function buttonFX(b)
        if not b:IsA("GuiButton") or b:GetAttribute("SERAPH_V9_FX") then return end
        b:SetAttribute("SERAPH_V9_FX", true)
        b.AutoButtonColor = false
        corner(b, 8)
        stroke(b, Color3.fromRGB(64,65,77), .84, 1)

        local scale = Instance.new("UIScale")
        scale.Name = "SERAPH_V9_SCALE"
        scale.Parent = b

        local base = b.BackgroundColor3

        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(.12, Enum.EasingStyle.Quad), {
                BackgroundColor3 = PANEL_HOVER
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.12, Enum.EasingStyle.Quad), {
                Scale = 1.025
            }):Play()
        end)

        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                BackgroundColor3 = base
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                Scale = 1
            }):Play()
        end)

        b.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(scale, TweenInfo.new(.06), {
                    Scale = .975
                }):Play()
            end
        end)

        b.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(scale, TweenInfo.new(.08), {
                    Scale = 1.025
                }):Play()
            end
        end)
    end

    local function addHeader(bar)
        if not bar then return end

        if not bar:FindFirstChild("SERAPH_V9_LOGO") then
            local logo = Instance.new("Frame")
            logo.Name = "SERAPH_V9_LOGO"
            logo.BackgroundColor3 = GOLD
            logo.BorderSizePixel = 0
            logo.Position = UDim2.new(0, 13, .5, -13)
            logo.Size = UDim2.new(0, 26, 0, 26)
            logo.ZIndex = 200
            corner(logo, 8)
            logo.Parent = bar

            local l = Instance.new("TextLabel")
            l.BackgroundTransparency = 1
            l.Size = UDim2.new(1, 0, 1, 0)
            l.Text = "S"
            l.TextColor3 = BG
            l.Font = Enum.Font.GothamBlack
            l.TextSize = 15
            l.Parent = logo
        end

        if not bar:FindFirstChild("SERAPH_V9_SUBTITLE") then
            local sub = Instance.new("TextLabel")
            sub.Name = "SERAPH_V9_SUBTITLE"
            sub.BackgroundTransparency = 1
            sub.Text = "AETHER  •  PREMIUM CONTROL"
            sub.TextColor3 = MUTED
            sub.Font = Enum.Font.GothamMedium
            sub.TextSize = 7
            sub.TextXAlignment = Enum.TextXAlignment.Left
            sub.Position = UDim2.new(0, 48, 0, 25)
            sub.Size = UDim2.new(0, 180, 0, 12)
            sub.ZIndex = 200
            sub.Parent = bar
        end

        if not bar:FindFirstChild("SERAPH_V9_STATUS") then
            local status = Instance.new("Frame")
            status.Name = "SERAPH_V9_STATUS"
            status.AnchorPoint = Vector2.new(1, .5)
            status.Position = UDim2.new(1, -16, .5, 0)
            status.Size = UDim2.new(0, 84, 0, 25)
            status.BackgroundColor3 = Color3.fromRGB(23, 61, 43)
            status.BackgroundTransparency = .08
            status.BorderSizePixel = 0
            status.ZIndex = 200
            corner(status, 13)
            stroke(status, GREEN, .68, 1)
            status.Parent = bar

            local dot = Instance.new("Frame")
            dot.BackgroundColor3 = GREEN
            dot.BorderSizePixel = 0
            dot.Position = UDim2.new(0, 9, .5, -3)
            dot.Size = UDim2.new(0, 6, 0, 6)
            dot.ZIndex = 201
            corner(dot, 6)
            dot.Parent = status

            local txt = Instance.new("TextLabel")
            txt.BackgroundTransparency = 1
            txt.Position = UDim2.new(0, 20, 0, 0)
            txt.Size = UDim2.new(1, -22, 1, 0)
            txt.Text = "ONLINE"
            txt.TextColor3 = GREEN
            txt.Font = Enum.Font.GothamBold
            txt.TextSize = 9
            txt.TextXAlignment = Enum.TextXAlignment.Left
            txt.Parent = status
        end

        if not bar:FindFirstChild("SERAPH_V9_LINE") then
            local line = Instance.new("Frame")
            line.Name = "SERAPH_V9_LINE"
            line.BackgroundColor3 = GOLD
            line.BorderSizePixel = 0
            line.Position = UDim2.new(0, 16, 1, -2)
            line.Size = UDim2.new(1, -32, 0, 2)
            line.ZIndex = 199
            corner(line, 2)
            line.Parent = bar

            local glow = Instance.new("Frame")
            glow.BackgroundColor3 = GOLD_HI
            glow.BackgroundTransparency = .91
            glow.BorderSizePixel = 0
            glow.Position = UDim2.new(0, 0, 0, -4)
            glow.Size = UDim2.new(1, 0, 0, 10)
            glow.ZIndex = 198
            glow.Parent = line
        end
    end

    local function addStatusPill(win)
        if not win or win:FindFirstChild("SERAPH_V9_BADGE") then return end

        local badge = Instance.new("Frame")
        badge.Name = "SERAPH_V9_BADGE"
        badge.AnchorPoint = Vector2.new(1, 1)
        badge.Position = UDim2.new(1, -12, 1, -10)
        badge.Size = UDim2.new(0, 104, 0, 22)
        badge.BackgroundColor3 = Color3.fromRGB(20, 21, 28)
        badge.BackgroundTransparency = .05
        badge.BorderSizePixel = 0
        badge.ZIndex = 180
        corner(badge, 11)
        stroke(badge, Color3.fromRGB(70,71,82), .72, 1)
        badge.Parent = win

        local dot = Instance.new("Frame")
        dot.BackgroundColor3 = GOLD
        dot.BorderSizePixel = 0
        dot.Position = UDim2.new(0, 9, .5, -3)
        dot.Size = UDim2.new(0, 6, 0, 6)
        dot.ZIndex = 181
        corner(dot, 6)
        dot.Parent = badge

        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Position = UDim2.new(0, 20, 0, 0)
        label.Size = UDim2.new(1, -22, 1, 0)
        label.Text = "SERAPH READY"
        label.TextColor3 = TEXT
        label.Font = Enum.Font.GothamMedium
        label.TextSize = 8
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = badge
    end

    local function apply(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = BG
        win.BackgroundTransparency = 0
        win.BorderSizePixel = 0
        corner(win, 18)
        stroke(win, GOLD, .55, 1.2)
        gradient(win, Color3.fromRGB(12, 13, 18), BG, 90)

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = SURFACE
            bar.BackgroundTransparency = 0
            corner(bar, 13)
            stroke(bar, Color3.fromRGB(57,58,70), .61, 1)
            gradient(bar, Color3.fromRGB(30,31,40), SURFACE, 0)
            addHeader(bar)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = TEXT
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
                title.Position = UDim2.new(0, 48, title.Position.Y.Scale, title.Position.Y.Offset)
                title.Size = UDim2.new(1, -180, title.Size.Y.Scale, title.Size.Y.Offset)
            end
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = SURFACE
            nav.BackgroundTransparency = 0
            corner(nav, 12)
            stroke(nav, Color3.fromRGB(51,52,64), .60, 1)
        end

        addStatusPill(win)

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = PANEL
                o.TextColor3 = TEXT
                o.Font = Enum.Font.GothamMedium
                buttonFX(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(9,10,14)
                o.TextColor3 = TEXT
                o.PlaceholderColor3 = MUTED
                corner(o, 8)
                stroke(o, Color3.fromRGB(66,67,79), .58, 1)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = GOLD
                o.ScrollBarImageTransparency = .28
            elseif o:IsA("TextLabel") then
                if o.TextColor3 == Color3.fromRGB(255,255,255) then
                    o.TextColor3 = TEXT
                end
            end
        end
    end

    local w = findWindow()
    if w then
        apply(w)
        for i = 1, 14 do
            task.delay(i * .18, function()
                if w and w.Parent then
                    apply(w)
                end
            end)
        end
    end
end)


-- ============================================================
-- SERAPH HUB OBSIDIAN ELITE V10
-- Visual upgrade layer for the existing GUI.
-- Adds hierarchy, active-state accents, header polish, cards,
-- subtle separators and touch-friendly feedback.
-- Existing functions/callbacks are not replaced.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local Players = game:GetService("Players")
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")

    local GOLD = Color3.fromRGB(239, 203, 105)
    local GOLD2 = Color3.fromRGB(255, 231, 158)
    local BG = Color3.fromRGB(5, 6, 9)
    local SURFACE = Color3.fromRGB(11, 12, 17)
    local PANEL = Color3.fromRGB(17, 18, 25)
    local PANEL2 = Color3.fromRGB(21, 22, 30)
    local HOVER = Color3.fromRGB(30, 31, 41)
    local TEXT = Color3.fromRGB(248, 248, 251)
    local MUTED = Color3.fromRGB(143, 146, 158)
    local GREEN = Color3.fromRGB(82, 226, 145)

    local function corner(o, r)
        if not o or not o:IsA("GuiObject") then return end
        if not o:FindFirstChild("SERAPH_V10_CORNER") then
            local c = Instance.new("UICorner")
            c.Name = "SERAPH_V10_CORNER"
            c.CornerRadius = UDim.new(0, r or 10)
            c.Parent = o
        end
    end

    local function stroke(o, color, tr, thickness)
        if not o or not o:IsA("GuiObject") then return end
        local s = o:FindFirstChild("SERAPH_V10_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_V10_STROKE"
            s.Parent = o
        end
        s.Color = color or GOLD
        s.Transparency = tr == nil and .78 or tr
        s.Thickness = thickness or 1
    end

    local function gradient(o, a, b, rot)
        if not o or not o:IsA("GuiObject") then return end
        local g = o:FindFirstChild("SERAPH_V10_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_V10_GRADIENT"
            g.Parent = o
        end
        g.Color = ColorSequence.new(a, b)
        g.Rotation = rot or 90
    end

    local function findWindow()
        if not pg then return nil end
        for _, o in ipairs(pg:GetDescendants()) do
            if o:IsA("GuiObject") and o.Visible then
                local t = o:FindFirstChild("Title", true)
                if t and t:IsA("TextLabel") and t.Text ~= "" then
                    local n = string.lower(t.Text)
                    if string.find(n, "seraph", 1, true) or string.find(n, "hub", 1, true) then
                        return o
                    end
                end
            end
        end
    end

    local function addTouchFX(button)
        if not button:IsA("GuiButton") or button:GetAttribute("SERAPH_V10_FX") then return end
        button:SetAttribute("SERAPH_V10_FX", true)
        button.AutoButtonColor = false
        corner(button, 8)
        stroke(button, Color3.fromRGB(62,63,75), .85, 1)

        local scale = Instance.new("UIScale")
        scale.Name = "SERAPH_V10_SCALE"
        scale.Parent = button

        local base = button.BackgroundColor3

        button.MouseEnter:Connect(function()
            TweenService:Create(button, TweenInfo.new(.11, Enum.EasingStyle.Quad), {
                BackgroundColor3 = HOVER
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.11, Enum.EasingStyle.Quad), {
                Scale = 1.025
            }):Play()
        end)

        button.MouseLeave:Connect(function()
            TweenService:Create(button, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                BackgroundColor3 = base
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                Scale = 1
            }):Play()
        end)

        button.InputBegan:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(scale, TweenInfo.new(.06), {
                    Scale = .975
                }):Play()
            end
        end)

        button.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1
                or input.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(scale, TweenInfo.new(.08), {
                    Scale = 1.025
                }):Play()
            end
        end)
    end

    local function addHeader(bar)
        if not bar then return end

        if not bar:FindFirstChild("SERAPH_V10_LOGO") then
            local logo = Instance.new("Frame")
            logo.Name = "SERAPH_V10_LOGO"
            logo.BackgroundColor3 = GOLD
            logo.BorderSizePixel = 0
            logo.Position = UDim2.new(0, 13, .5, -13)
            logo.Size = UDim2.new(0, 27, 0, 27)
            logo.ZIndex = 220
            corner(logo, 8)
            logo.Parent = bar

            local lg = Instance.new("UIGradient")
            lg.Color = ColorSequence.new(GOLD2, GOLD)
            lg.Rotation = 90
            lg.Parent = logo

            local txt = Instance.new("TextLabel")
            txt.BackgroundTransparency = 1
            txt.Size = UDim2.new(1, 0, 1, 0)
            txt.Text = "S"
            txt.TextColor3 = BG
            txt.Font = Enum.Font.GothamBlack
            txt.TextSize = 15
            txt.Parent = logo
        end

        if not bar:FindFirstChild("SERAPH_V10_SUBTITLE") then
            local sub = Instance.new("TextLabel")
            sub.Name = "SERAPH_V10_SUBTITLE"
            sub.BackgroundTransparency = 1
            sub.Text = "OBSIDIAN  •  ELITE CONTROL"
            sub.TextColor3 = MUTED
            sub.Font = Enum.Font.GothamMedium
            sub.TextSize = 7
            sub.TextXAlignment = Enum.TextXAlignment.Left
            sub.Position = UDim2.new(0, 49, 0, 25)
            sub.Size = UDim2.new(0, 190, 0, 12)
            sub.ZIndex = 220
            sub.Parent = bar
        end

        if not bar:FindFirstChild("SERAPH_V10_STATUS") then
            local status = Instance.new("Frame")
            status.Name = "SERAPH_V10_STATUS"
            status.AnchorPoint = Vector2.new(1, .5)
            status.Position = UDim2.new(1, -16, .5, 0)
            status.Size = UDim2.new(0, 84, 0, 25)
            status.BackgroundColor3 = Color3.fromRGB(22, 61, 42)
            status.BackgroundTransparency = .08
            status.BorderSizePixel = 0
            status.ZIndex = 220
            corner(status, 13)
            stroke(status, GREEN, .68, 1)
            status.Parent = bar

            local dot = Instance.new("Frame")
            dot.BackgroundColor3 = GREEN
            dot.BorderSizePixel = 0
            dot.Position = UDim2.new(0, 9, .5, -3)
            dot.Size = UDim2.new(0, 6, 0, 6)
            dot.ZIndex = 221
            corner(dot, 6)
            dot.Parent = status

            local label = Instance.new("TextLabel")
            label.BackgroundTransparency = 1
            label.Position = UDim2.new(0, 20, 0, 0)
            label.Size = UDim2.new(1, -22, 1, 0)
            label.Text = "ONLINE"
            label.TextColor3 = GREEN
            label.Font = Enum.Font.GothamBold
            label.TextSize = 9
            label.TextXAlignment = Enum.TextXAlignment.Left
            label.Parent = status
        end

        if not bar:FindFirstChild("SERAPH_V10_LINE") then
            local line = Instance.new("Frame")
            line.Name = "SERAPH_V10_LINE"
            line.BackgroundColor3 = GOLD
            line.BorderSizePixel = 0
            line.Position = UDim2.new(0, 16, 1, -2)
            line.Size = UDim2.new(1, -32, 0, 2)
            line.ZIndex = 219
            corner(line, 2)
            line.Parent = bar

            local glow = Instance.new("Frame")
            glow.BackgroundColor3 = GOLD2
            glow.BackgroundTransparency = .91
            glow.BorderSizePixel = 0
            glow.Position = UDim2.new(0, 0, 0, -4)
            glow.Size = UDim2.new(1, 0, 0, 10)
            glow.ZIndex = 218
            glow.Parent = line
        end
    end

    local function addContentAccent(win)
        if not win or win:FindFirstChild("SERAPH_V10_CONTENT_ACCENT") then return end

        local accent = Instance.new("Frame")
        accent.Name = "SERAPH_V10_CONTENT_ACCENT"
        accent.BackgroundColor3 = GOLD
        accent.BackgroundTransparency = .12
        accent.BorderSizePixel = 0
        accent.AnchorPoint = Vector2.new(0, .5)
        accent.Position = UDim2.new(0, 1, .5, 0)
        accent.Size = UDim2.new(0, 2, .42, 0)
        accent.ZIndex = 100
        corner(accent, 2)
        accent.Parent = win
    end

    local function improveContainers(win)
        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("Frame") and o.Visible and o ~= win then
                local sx, sy = o.Size.X.Scale, o.Size.Y.Scale
                if sx > .30 and sy > .08 then
                    corner(o, 9)
                end
            end
        end
    end

    local function apply(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = BG
        win.BackgroundTransparency = 0
        win.BorderSizePixel = 0
        corner(win, 18)
        stroke(win, GOLD, .55, 1.2)
        gradient(win, Color3.fromRGB(12,13,18), BG, 90)

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = SURFACE
            bar.BackgroundTransparency = 0
            corner(bar, 13)
            stroke(bar, Color3.fromRGB(57,58,70), .61, 1)
            gradient(bar, Color3.fromRGB(30,31,40), SURFACE, 0)
            addHeader(bar)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = TEXT
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
                title.Position = UDim2.new(0, 49, title.Position.Y.Scale, title.Position.Y.Offset)
                title.Size = UDim2.new(1, -182, title.Size.Y.Scale, title.Size.Y.Offset)
            end
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = SURFACE
            nav.BackgroundTransparency = 0
            corner(nav, 12)
            stroke(nav, Color3.fromRGB(51,52,64), .60, 1)

            local layout = nav:FindFirstChildWhichIsA("UIListLayout", true)
            if layout then
                layout.Padding = UDim.new(0, 5)
            end
        end

        addContentAccent(win)

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = PANEL
                o.TextColor3 = TEXT
                o.Font = Enum.Font.GothamMedium
                addTouchFX(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(9,10,14)
                o.TextColor3 = TEXT
                o.PlaceholderColor3 = MUTED
                corner(o, 8)
                stroke(o, Color3.fromRGB(66,67,79), .58, 1)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = GOLD
                o.ScrollBarImageTransparency = .28
            elseif o:IsA("TextLabel") then
                if o.TextColor3 == Color3.fromRGB(255,255,255) then
                    o.TextColor3 = TEXT
                end
            end
        end

        improveContainers(win)
    end

    local w = findWindow()
    if w then
        apply(w)
        for i = 1, 16 do
            task.delay(i * .16, function()
                if w and w.Parent then apply(w) end
            end)
        end
    end
end)


-- ============================================================
-- SERAPH HUB SIGNATURE V11
-- Final visual layer: cleaner hierarchy, active navigation,
-- premium header, subtle glass cards and responsive polish.
-- Existing GUI functions/callbacks remain untouched.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local Players = game:GetService("Players")
    local pg = Players.LocalPlayer and Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")

    local GOLD = Color3.fromRGB(240, 205, 108)
    local GOLD_SOFT = Color3.fromRGB(255, 232, 161)
    local BG = Color3.fromRGB(5, 6, 9)
    local SURFACE = Color3.fromRGB(10, 11, 16)
    local CARD = Color3.fromRGB(16, 17, 24)
    local CARD2 = Color3.fromRGB(22, 23, 31)
    local HOVER = Color3.fromRGB(31, 32, 42)
    local TEXT = Color3.fromRGB(248, 248, 251)
    local MUTED = Color3.fromRGB(141, 144, 157)
    local GREEN = Color3.fromRGB(82, 226, 145)

    local function corner(o, r)
        if not o or not o:IsA("GuiObject") then return end
        if not o:FindFirstChild("SERAPH_V11_CORNER") then
            local c = Instance.new("UICorner")
            c.Name = "SERAPH_V11_CORNER"
            c.CornerRadius = UDim.new(0, r or 10)
            c.Parent = o
        end
    end

    local function stroke(o, color, tr, thickness)
        if not o or not o:IsA("GuiObject") then return end
        local s = o:FindFirstChild("SERAPH_V11_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_V11_STROKE"
            s.Parent = o
        end
        s.Color = color or GOLD
        s.Transparency = tr == nil and .8 or tr
        s.Thickness = thickness or 1
    end

    local function gradient(o, a, b, rot)
        if not o or not o:IsA("GuiObject") then return end
        local g = o:FindFirstChild("SERAPH_V11_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_V11_GRADIENT"
            g.Parent = o
        end
        g.Color = ColorSequence.new(a, b)
        g.Rotation = rot or 90
    end

    local function findWindow()
        if not pg then return nil end
        for _, o in ipairs(pg:GetDescendants()) do
            if o:IsA("GuiObject") and o.Visible then
                local t = o:FindFirstChild("Title", true)
                if t and t:IsA("TextLabel") and t.Text ~= "" then
                    local n = string.lower(t.Text)
                    if string.find(n, "seraph", 1, true) or string.find(n, "hub", 1, true) then
                        return o
                    end
                end
            end
        end
    end

    local function buttonFX(b)
        if not b:IsA("GuiButton") or b:GetAttribute("SERAPH_V11_FX") then return end
        b:SetAttribute("SERAPH_V11_FX", true)
        b.AutoButtonColor = false
        corner(b, 8)
        stroke(b, Color3.fromRGB(60,61,73), .86, 1)

        local scale = Instance.new("UIScale")
        scale.Name = "SERAPH_V11_SCALE"
        scale.Parent = b

        local base = b.BackgroundColor3

        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(.12, Enum.EasingStyle.Quad), {
                BackgroundColor3 = HOVER
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.12, Enum.EasingStyle.Quad), {
                Scale = 1.025
            }):Play()
        end)

        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                BackgroundColor3 = base
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                Scale = 1
            }):Play()
        end)

        b.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(scale, TweenInfo.new(.06), {Scale = .975}):Play()
            end
        end)

        b.InputEnded:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1
                or i.UserInputType == Enum.UserInputType.Touch then
                TweenService:Create(scale, TweenInfo.new(.08), {Scale = 1.025}):Play()
            end
        end)
    end

    local function addHeader(bar)
        if not bar then return end

        if not bar:FindFirstChild("SERAPH_V11_LOGO") then
            local logo = Instance.new("Frame")
            logo.Name = "SERAPH_V11_LOGO"
            logo.BackgroundColor3 = GOLD
            logo.BorderSizePixel = 0
            logo.Position = UDim2.new(0, 13, .5, -14)
            logo.Size = UDim2.new(0, 28, 0, 28)
            logo.ZIndex = 240
            corner(logo, 9)
            gradient(logo, GOLD_SOFT, GOLD, 90)
            logo.Parent = bar

            local l = Instance.new("TextLabel")
            l.BackgroundTransparency = 1
            l.Size = UDim2.new(1, 0, 1, 0)
            l.Text = "S"
            l.TextColor3 = BG
            l.Font = Enum.Font.GothamBlack
            l.TextSize = 16
            l.Parent = logo
        end

        if not bar:FindFirstChild("SERAPH_V11_SUBTITLE") then
            local sub = Instance.new("TextLabel")
            sub.Name = "SERAPH_V11_SUBTITLE"
            sub.BackgroundTransparency = 1
            sub.Text = "SIGNATURE  •  ELITE CONTROL"
            sub.TextColor3 = MUTED
            sub.Font = Enum.Font.GothamMedium
            sub.TextSize = 7
            sub.TextXAlignment = Enum.TextXAlignment.Left
            sub.Position = UDim2.new(0, 50, 0, 25)
            sub.Size = UDim2.new(0, 190, 0, 12)
            sub.ZIndex = 240
            sub.Parent = bar
        end

        if not bar:FindFirstChild("SERAPH_V11_STATUS") then
            local st = Instance.new("Frame")
            st.Name = "SERAPH_V11_STATUS"
            st.AnchorPoint = Vector2.new(1, .5)
            st.Position = UDim2.new(1, -16, .5, 0)
            st.Size = UDim2.new(0, 86, 0, 25)
            st.BackgroundColor3 = Color3.fromRGB(22, 61, 42)
            st.BackgroundTransparency = .08
            st.BorderSizePixel = 0
            st.ZIndex = 240
            corner(st, 13)
            stroke(st, GREEN, .68, 1)
            st.Parent = bar

            local d = Instance.new("Frame")
            d.BackgroundColor3 = GREEN
            d.BorderSizePixel = 0
            d.Position = UDim2.new(0, 9, .5, -3)
            d.Size = UDim2.new(0, 6, 0, 6)
            d.ZIndex = 241
            corner(d, 6)
            d.Parent = st

            local tx = Instance.new("TextLabel")
            tx.BackgroundTransparency = 1
            tx.Position = UDim2.new(0, 20, 0, 0)
            tx.Size = UDim2.new(1, -22, 1, 0)
            tx.Text = "ONLINE"
            tx.TextColor3 = GREEN
            tx.Font = Enum.Font.GothamBold
            tx.TextSize = 9
            tx.TextXAlignment = Enum.TextXAlignment.Left
            tx.Parent = st
        end

        if not bar:FindFirstChild("SERAPH_V11_LINE") then
            local line = Instance.new("Frame")
            line.Name = "SERAPH_V11_LINE"
            line.BackgroundColor3 = GOLD
            line.BorderSizePixel = 0
            line.Position = UDim2.new(0, 16, 1, -2)
            line.Size = UDim2.new(1, -32, 0, 2)
            line.ZIndex = 239
            corner(line, 2)
            line.Parent = bar

            local glow = Instance.new("Frame")
            glow.BackgroundColor3 = GOLD_SOFT
            glow.BackgroundTransparency = .91
            glow.BorderSizePixel = 0
            glow.Position = UDim2.new(0, 0, 0, -4)
            glow.Size = UDim2.new(1, 0, 0, 10)
            glow.ZIndex = 238
            glow.Parent = line
        end
    end

    local function addSectionBadge(win)
        if not win or win:FindFirstChild("SERAPH_V11_BADGE") then return end

        local badge = Instance.new("Frame")
        badge.Name = "SERAPH_V11_BADGE"
        badge.AnchorPoint = Vector2.new(1, 1)
        badge.Position = UDim2.new(1, -12, 1, -10)
        badge.Size = UDim2.new(0, 108, 0, 22)
        badge.BackgroundColor3 = CARD2
        badge.BackgroundTransparency = .05
        badge.BorderSizePixel = 0
        badge.ZIndex = 190
        corner(badge, 11)
        stroke(badge, Color3.fromRGB(69,70,82), .72, 1)
        badge.Parent = win

        local dot = Instance.new("Frame")
        dot.BackgroundColor3 = GOLD
        dot.BorderSizePixel = 0
        dot.Position = UDim2.new(0, 9, .5, -3)
        dot.Size = UDim2.new(0, 6, 0, 6)
        dot.ZIndex = 191
        corner(dot, 6)
        dot.Parent = badge

        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Position = UDim2.new(0, 20, 0, 0)
        label.Size = UDim2.new(1, -22, 1, 0)
        label.Text = "SYSTEM READY"
        label.TextColor3 = TEXT
        label.Font = Enum.Font.GothamMedium
        label.TextSize = 8
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = badge
    end

    local function improveTabs(nav)
        if not nav then return end

        for _, o in ipairs(nav:GetDescendants()) do
            if o:IsA("TextButton") then
                corner(o, 8)
                if not o:FindFirstChild("SERAPH_V11_TAB_ACCENT") then
                    local accent = Instance.new("Frame")
                    accent.Name = "SERAPH_V11_TAB_ACCENT"
                    accent.BackgroundColor3 = GOLD
                    accent.BackgroundTransparency = 1
                    accent.BorderSizePixel = 0
                    accent.Position = UDim2.new(0, 3, .18, 0)
                    accent.Size = UDim2.new(0, 2, .64, 0)
                    accent.ZIndex = o.ZIndex + 2
                    corner(accent, 2)
                    accent.Parent = o

                    o.MouseEnter:Connect(function()
                        TweenService:Create(accent, TweenInfo.new(.12), {
                            BackgroundTransparency = .15
                        }):Play()
                    end)

                    o.MouseLeave:Connect(function()
                        TweenService:Create(accent, TweenInfo.new(.15), {
                            BackgroundTransparency = 1
                        }):Play()
                    end)
                end
            end
        end
    end

    local function apply(win)
        if not win or not win:IsA("GuiObject") then return end

        win.BackgroundColor3 = BG
        win.BackgroundTransparency = 0
        win.BorderSizePixel = 0
        corner(win, 18)
        stroke(win, GOLD, .54, 1.2)
        gradient(win, Color3.fromRGB(12, 13, 18), BG, 90)

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = SURFACE
            bar.BackgroundTransparency = 0
            corner(bar, 13)
            stroke(bar, Color3.fromRGB(56,57,69), .61, 1)
            gradient(bar, Color3.fromRGB(30,31,40), SURFACE, 0)
            addHeader(bar)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = TEXT
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
                title.Position = UDim2.new(0, 50, title.Position.Y.Scale, title.Position.Y.Offset)
                title.Size = UDim2.new(1, -184, title.Size.Y.Scale, title.Size.Y.Offset)
            end
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = SURFACE
            nav.BackgroundTransparency = 0
            corner(nav, 12)
            stroke(nav, Color3.fromRGB(50,51,63), .60, 1)
            improveTabs(nav)
        end

        addSectionBadge(win)

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = PANEL
                o.TextColor3 = TEXT
                o.Font = Enum.Font.GothamMedium
                buttonFX(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(9,10,14)
                o.TextColor3 = TEXT
                o.PlaceholderColor3 = MUTED
                corner(o, 8)
                stroke(o, Color3.fromRGB(65,66,78), .58, 1)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = GOLD
                o.ScrollBarImageTransparency = .27
            end
        end
    end

    local w = findWindow()
    if w then
        apply(w)
        for i = 1, 16 do
            task.delay(i * .15, function()
                if w and w.Parent then apply(w) end
            end)
        end
    end
end)


-- ============================================================
-- LEGACY WELCOME V12/V13 REMOVED
-- These old blocks were disabled with `return` before `local` statements,
-- which is invalid Luau syntax. The final V16 startup screen below is used.
-- ============================================================

-- ============================================================
-- SERAPH HUB PLATINUM V14
-- Visual refinement layer:
-- premium glass panels, animated accent, cleaner spacing,
-- active controls, soft shadows, status chips and mobile polish.
-- Does not replace existing GUI logic/callbacks.
-- ============================================================
task.defer(function()
    local TweenService = game:GetService("TweenService")
    local Players = game:GetService("Players")
    local player = Players.LocalPlayer
    local pg = player and player:FindFirstChildOfClass("PlayerGui")
    if not pg then return end

    local GOLD = Color3.fromRGB(241, 207, 112)
    local GOLD2 = Color3.fromRGB(255, 235, 169)
    local BG = Color3.fromRGB(4, 5, 8)
    local SURFACE = Color3.fromRGB(10, 11, 16)
    local PANEL = Color3.fromRGB(15, 16, 23)
    local PANEL_HOVER = Color3.fromRGB(25, 26, 35)
    local TEXT = Color3.fromRGB(248, 248, 251)
    local MUTED = Color3.fromRGB(143, 146, 158)
    local GREEN = Color3.fromRGB(82, 226, 145)

    local function findWindow()
        for _, o in ipairs(pg:GetDescendants()) do
            if o:IsA("GuiObject") and o.Visible then
                local t = o:FindFirstChild("Title", true)
                if t and t:IsA("TextLabel") and t.Text ~= "" then
                    local n = string.lower(t.Text)
                    if string.find(n, "seraph", 1, true)
                        or string.find(n, "hub", 1, true) then
                        return o
                    end
                end
            end
        end
    end

    local function corner(o, radius)
        if not o or not o:IsA("GuiObject") then return end
        if not o:FindFirstChild("SERAPH_V14_CORNER") then
            local c = Instance.new("UICorner")
            c.Name = "SERAPH_V14_CORNER"
            c.CornerRadius = UDim.new(0, radius or 10)
            c.Parent = o
        end
    end

    local function stroke(o, color, transparency, thickness)
        if not o or not o:IsA("GuiObject") then return end
        local s = o:FindFirstChild("SERAPH_V14_STROKE")
        if not s then
            s = Instance.new("UIStroke")
            s.Name = "SERAPH_V14_STROKE"
            s.Parent = o
        end
        s.Color = color or GOLD
        s.Transparency = transparency or .75
        s.Thickness = thickness or 1
    end

    local function gradient(o, c1, c2, rotation)
        if not o or not o:IsA("GuiObject") then return end
        local g = o:FindFirstChild("SERAPH_V14_GRADIENT")
        if not g then
            g = Instance.new("UIGradient")
            g.Name = "SERAPH_V14_GRADIENT"
            g.Parent = o
        end
        g.Color = ColorSequence.new(c1, c2)
        g.Rotation = rotation or 90
    end

    local function addShadow(o)
        if not o or o:FindFirstChild("SERAPH_V14_SHADOW") then return end
        local shadow = Instance.new("Frame")
        shadow.Name = "SERAPH_V14_SHADOW"
        shadow.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
        shadow.BackgroundTransparency = .72
        shadow.BorderSizePixel = 0
        shadow.Position = UDim2.new(0, 4, 0, 5)
        shadow.Size = UDim2.new(1, 0, 1, 0)
        shadow.ZIndex = math.max(o.ZIndex - 1, 0)
        shadow.Parent = o
        corner(shadow, 12)
    end

    local function addButtonFX(b)
        if not b:IsA("GuiButton") or b:GetAttribute("SERAPH_V14_FX") then return end
        b:SetAttribute("SERAPH_V14_FX", true)
        b.AutoButtonColor = false
        corner(b, 9)
        stroke(b, Color3.fromRGB(60,61,73), .86, 1)

        local scale = Instance.new("UIScale")
        scale.Name = "SERAPH_V14_SCALE"
        scale.Parent = b

        local normal = b.BackgroundColor3

        b.MouseEnter:Connect(function()
            TweenService:Create(b, TweenInfo.new(.12, Enum.EasingStyle.Quad), {
                BackgroundColor3 = PANEL_HOVER
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.12, Enum.EasingStyle.Quad), {
                Scale = 1.025
            }):Play()
        end)

        b.MouseLeave:Connect(function()
            TweenService:Create(b, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                BackgroundColor3 = normal
            }):Play()
            TweenService:Create(scale, TweenInfo.new(.14, Enum.EasingStyle.Quad), {
                Scale = 1
            }):Play()
        end)

        b.Activated:Connect(function()
            TweenService:Create(scale, TweenInfo.new(.06), {
                Scale = .97
            }):Play()
            task.delay(.07, function()
                if scale.Parent then
                    TweenService:Create(scale, TweenInfo.new(.09), {
                        Scale = 1.025
                    }):Play()
                end
            end)
        end)
    end

    local function addLiveChip(bar)
        if bar:FindFirstChild("SERAPH_V14_LIVE") then return end

        local chip = Instance.new("Frame")
        chip.Name = "SERAPH_V14_LIVE"
        chip.AnchorPoint = Vector2.new(1, .5)
        chip.Position = UDim2.new(1, -112, .5, 0)
        chip.Size = UDim2.new(0, 74, 0, 23)
        chip.BackgroundColor3 = Color3.fromRGB(20, 51, 36)
        chip.BackgroundTransparency = .08
        chip.BorderSizePixel = 0
        chip.ZIndex = 240
        corner(chip, 12)
        stroke(chip, GREEN, .72, 1)
        chip.Parent = bar

        local dot = Instance.new("Frame")
        dot.BackgroundColor3 = GREEN
        dot.BorderSizePixel = 0
        dot.Position = UDim2.new(0, 9, .5, -3)
        dot.Size = UDim2.new(0, 6, 0, 6)
        dot.ZIndex = 241
        corner(dot, 6)
        dot.Parent = chip

        local label = Instance.new("TextLabel")
        label.BackgroundTransparency = 1
        label.Position = UDim2.new(0, 20, 0, 0)
        label.Size = UDim2.new(1, -22, 1, 0)
        label.Text = "LIVE"
        label.TextColor3 = GREEN
        label.Font = Enum.Font.GothamBold
        label.TextSize = 8
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = chip

        task.spawn(function()
            while chip.Parent do
                TweenService:Create(dot, TweenInfo.new(.7, Enum.EasingStyle.Sine), {
                    BackgroundTransparency = .45
                }):Play()
                task.wait(.7)
                if not dot.Parent then break end
                TweenService:Create(dot, TweenInfo.new(.7, Enum.EasingStyle.Sine), {
                    BackgroundTransparency = 0
                }):Play()
                task.wait(.7)
            end
        end)
    end

    local function addHeaderAccent(bar)
        if bar:FindFirstChild("SERAPH_V14_HEADER_LINE") then return end

        local line = Instance.new("Frame")
        line.Name = "SERAPH_V14_HEADER_LINE"
        line.BackgroundColor3 = GOLD
        line.BorderSizePixel = 0
        line.Position = UDim2.new(0, 16, 1, -2)
        line.Size = UDim2.new(1, -32, 0, 2)
        line.ZIndex = 239
        corner(line, 2)
        line.Parent = bar

        local shine = Instance.new("Frame")
        shine.BackgroundColor3 = GOLD2
        shine.BackgroundTransparency = .55
        shine.BorderSizePixel = 0
        shine.Position = UDim2.new(-.2, 0, 0, 0)
        shine.Size = UDim2.new(.18, 0, 1, 0)
        shine.ZIndex = 240
        shine.Parent = line

        task.spawn(function()
            while line.Parent do
                shine.Position = UDim2.new(-.2, 0, 0, 0)
                local tw = TweenService:Create(shine, TweenInfo.new(1.8, Enum.EasingStyle.Linear), {
                    Position = UDim2.new(1.02, 0, 0, 0)
                })
                tw:Play()
                tw.Completed:Wait()
                task.wait(1.6)
            end
        end)
    end

    local function addSectionDividers(win)
        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("Frame") and o.Visible then
                local h = o.AbsoluteSize.Y
                local w = o.AbsoluteSize.X
                if w > 180 and h < 2 and not o:GetAttribute("SERAPH_V14_DIV") then
                    o:SetAttribute("SERAPH_V14_DIV", true)
                    o.BackgroundColor3 = Color3.fromRGB(54,55,66)
                    o.BackgroundTransparency = .35
                end
            end
        end
    end

    local function apply()
        local win = findWindow()
        if not win then return end

        win.BackgroundColor3 = BG
        win.BackgroundTransparency = 0
        win.BorderSizePixel = 0
        corner(win, 18)
        stroke(win, GOLD, .57, 1.2)
        gradient(win, Color3.fromRGB(13,14,19), BG, 90)

        local bar = win:FindFirstChild("Bar", true)
        if bar and bar:IsA("GuiObject") then
            bar.BackgroundColor3 = SURFACE
            bar.BackgroundTransparency = 0
            corner(bar, 13)
            stroke(bar, Color3.fromRGB(58,59,71), .60, 1)
            gradient(bar, Color3.fromRGB(29,30,39), SURFACE, 0)

            local title = bar:FindFirstChild("Title", true)
            if title and title:IsA("TextLabel") then
                title.TextColor3 = TEXT
                title.Font = Enum.Font.GothamBold
                title.TextSize = 15
                title.TextTruncate = Enum.TextTruncate.None
                title.Position = UDim2.new(0, 50, title.Position.Y.Scale, title.Position.Y.Offset)
                title.Size = UDim2.new(1, -205, title.Size.Y.Scale, title.Size.Y.Offset)
            end

            addLiveChip(bar)
            addHeaderAccent(bar)
        end

        local nav = win:FindFirstChild("TabSelection", true)
        if nav and nav:IsA("GuiObject") then
            nav.BackgroundColor3 = SURFACE
            nav.BackgroundTransparency = 0
            corner(nav, 12)
            stroke(nav, Color3.fromRGB(51,52,64), .61, 1)
        end

        for _, o in ipairs(win:GetDescendants()) do
            if o:IsA("TextButton") then
                o.BackgroundColor3 = PANEL
                o.TextColor3 = TEXT
                o.Font = Enum.Font.GothamMedium
                addButtonFX(o)
            elseif o:IsA("TextBox") then
                o.BackgroundColor3 = Color3.fromRGB(8,9,13)
                o.TextColor3 = TEXT
                o.PlaceholderColor3 = MUTED
                corner(o, 9)
                stroke(o, Color3.fromRGB(65,66,78), .57, 1)
            elseif o:IsA("ScrollingFrame") then
                o.ScrollBarThickness = 3
                o.ScrollBarImageColor3 = GOLD
                o.ScrollBarImageTransparency = .25
            elseif o:IsA("ImageButton") then
                corner(o, 9)
                addButtonFX(o)
            end
        end

        addSectionDividers(win)
    end

    -- The existing GUI may finish creating itself after this layer starts.
    for i = 1, 24 do
        task.delay(i * .18, apply)
    end
end)



-- ============================================================
-- SERAPH HUB FINAL UI FIX V16
-- 1) Startup screen is always shown before the hub.
-- 2) Startup lives in the same CoreGui/gethui layer as the hub.
-- 3) Header bar/title layout is normalized to prevent overlap.
-- 4) Existing feature callbacks are untouched.
-- ============================================================
task.spawn(function()
    local Players = game:GetService("Players")
    local TweenService = game:GetService("TweenService")
    local player = Players.LocalPlayer
    if not player then return end

    local host = game:GetService("CoreGui")
    if type(gethui) == "function" then
        local ok, hui = pcall(gethui)
        if ok and hui then host = hui end
    end

    local mainGui = host:FindFirstChild("imgui")
    if mainGui and mainGui:IsA("ScreenGui") then
        mainGui.Enabled = false
    end

    local old = host:FindFirstChild("SERAPH_STARTUP_V16")
    if old then old:Destroy() end

    local gui = Instance.new("ScreenGui")
    gui.Name = "SERAPH_STARTUP_V16"
    gui.IgnoreGuiInset = true
    gui.ResetOnSpawn = false
    gui.DisplayOrder = 2147483647
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Parent = host

    local bg = Instance.new("Frame")
    bg.Size = UDim2.fromScale(1,1)
    bg.BackgroundColor3 = Color3.fromRGB(4,5,8)
    bg.BorderSizePixel = 0
    bg.Parent = gui

    local glow = Instance.new("Frame")
    glow.AnchorPoint = Vector2.new(.5,.5)
    glow.Position = UDim2.fromScale(.5,.45)
    glow.Size = UDim2.fromScale(.7,.6)
    glow.BackgroundColor3 = Color3.fromRGB(240,205,108)
    glow.BackgroundTransparency = .975
    glow.BorderSizePixel = 0
    glow.Parent = bg
    local glowCorner = Instance.new("UICorner")
    glowCorner.CornerRadius = UDim.new(1,0)
    glowCorner.Parent = glow

    local card = Instance.new("Frame")
    card.AnchorPoint = Vector2.new(.5,.5)
    card.Position = UDim2.fromScale(.5,.54)
    card.Size = UDim2.fromScale(.78,.56)
    card.BackgroundColor3 = Color3.fromRGB(12,13,18)
    card.BorderSizePixel = 0
    card.Parent = bg
    local cc = Instance.new("UICorner")
    cc.CornerRadius = UDim.new(0,22)
    cc.Parent = card
    local cs = Instance.new("UIStroke")
    cs.Color = Color3.fromRGB(240,205,108)
    cs.Transparency = .55
    cs.Thickness = 1.2
    cs.Parent = card
    local cg = Instance.new("UIGradient")
    cg.Color = ColorSequence.new(Color3.fromRGB(25,26,35), Color3.fromRGB(7,8,12))
    cg.Rotation = 90
    cg.Parent = card

    local line = Instance.new("Frame")
    line.AnchorPoint = Vector2.new(.5,0)
    line.Position = UDim2.new(.5,0,0,0)
    line.Size = UDim2.new(.5,0,0,2)
    line.BackgroundColor3 = Color3.fromRGB(240,205,108)
    line.BorderSizePixel = 0
    line.Parent = card

    local tag = Instance.new("TextLabel")
    tag.BackgroundTransparency = 1
    tag.AnchorPoint = Vector2.new(.5,0)
    tag.Position = UDim2.new(.5,0,0,18)
    tag.Size = UDim2.new(.9,0,0,20)
    tag.Text = "SERAPH HUB  •  PREMIUM"
    tag.TextColor3 = Color3.fromRGB(240,205,108)
    tag.Font = Enum.Font.GothamBold
    tag.TextSize = 9
    tag.Parent = card

    local avatar = Instance.new("ImageLabel")
    avatar.AnchorPoint = Vector2.new(.5,0)
    avatar.Position = UDim2.new(.5,0,0,48)
    avatar.Size = UDim2.fromOffset(100,100)
    avatar.BackgroundColor3 = Color3.fromRGB(20,21,28)
    avatar.BorderSizePixel = 0
    avatar.ScaleType = Enum.ScaleType.Crop
    avatar.Image = "https://www.roblox.com/headshot-thumbnail/image?userId=" .. tostring(player.UserId) .. "&width=420&height=420&format=png"
    avatar.Parent = card
    local ac = Instance.new("UICorner")
    ac.CornerRadius = UDim.new(1,0)
    ac.Parent = avatar
    local ast = Instance.new("UIStroke")
    ast.Color = Color3.fromRGB(240,205,108)
    ast.Transparency = .2
    ast.Thickness = 2
    ast.Parent = avatar

    local welcome = Instance.new("TextLabel")
    welcome.BackgroundTransparency = 1
    welcome.AnchorPoint = Vector2.new(.5,0)
    welcome.Position = UDim2.new(.5,0,0,158)
    welcome.Size = UDim2.new(.9,0,0,24)
    welcome.Text = "BIENVENIDO"
    welcome.TextColor3 = Color3.fromRGB(145,148,160)
    welcome.Font = Enum.Font.GothamMedium
    welcome.TextSize = 11
    welcome.Parent = card

    local name = Instance.new("TextLabel")
    name.BackgroundTransparency = 1
    name.AnchorPoint = Vector2.new(.5,0)
    name.Position = UDim2.new(.5,0,0,182)
    name.Size = UDim2.new(.9,0,0,42)
    name.Text = "SERAPH"
    name.TextColor3 = Color3.fromRGB(248,248,251)
    name.Font = Enum.Font.GothamBlack
    name.TextSize = 28
    name.Parent = card

    local sub = Instance.new("TextLabel")
    sub.BackgroundTransparency = 1
    sub.AnchorPoint = Vector2.new(.5,0)
    sub.Position = UDim2.new(.5,0,0,224)
    sub.Size = UDim2.new(.9,0,0,20)
    sub.Text = "PREMIUM CONTROL  •  ONLINE"
    sub.TextColor3 = Color3.fromRGB(240,205,108)
    sub.Font = Enum.Font.GothamMedium
    sub.TextSize = 9
    sub.Parent = card

    local progressBack = Instance.new("Frame")
    progressBack.AnchorPoint = Vector2.new(.5,0)
    progressBack.Position = UDim2.new(.5,0,0,260)
    progressBack.Size = UDim2.new(.62,0,0,3)
    progressBack.BackgroundColor3 = Color3.fromRGB(38,39,47)
    progressBack.BorderSizePixel = 0
    progressBack.Parent = card
    local pbc = Instance.new("UICorner")
    pbc.CornerRadius = UDim.new(1,0)
    pbc.Parent = progressBack

    local progress = Instance.new("Frame")
    progress.Size = UDim2.new(0,0,1,0)
    progress.BackgroundColor3 = Color3.fromRGB(240,205,108)
    progress.BorderSizePixel = 0
    progress.Parent = progressBack
    local pc = Instance.new("UICorner")
    pc.CornerRadius = UDim.new(1,0)
    pc.Parent = progress

    local skip = Instance.new("TextButton")
    skip.BackgroundTransparency = 1
    skip.AnchorPoint = Vector2.new(.5,1)
    skip.Position = UDim2.new(.5,0,1,-12)
    skip.Size = UDim2.new(.8,0,0,24)
    skip.Text = "TOCA PARA CONTINUAR"
    skip.TextColor3 = Color3.fromRGB(125,128,140)
    skip.Font = Enum.Font.GothamMedium
    skip.TextSize = 8
    skip.AutoButtonColor = false
    skip.Parent = card

    local closed = false
    local function closeStartup()
        if closed then return end
        closed = true

        local ti = TweenInfo.new(.32, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
        TweenService:Create(card, ti, {Position = UDim2.fromScale(.5,.49), BackgroundTransparency = 1}):Play()
        TweenService:Create(bg, ti, {BackgroundTransparency = 1}):Play()
        TweenService:Create(glow, ti, {BackgroundTransparency = 1}):Play()
        for _, o in ipairs(card:GetDescendants()) do
            if o:IsA("TextLabel") or o:IsA("TextButton") then
                TweenService:Create(o, ti, {TextTransparency = 1}):Play()
            elseif o:IsA("ImageLabel") then
                TweenService:Create(o, ti, {ImageTransparency = 1}):Play()
            elseif o:IsA("UIStroke") then
                TweenService:Create(o, ti, {Transparency = 1}):Play()
            end
        end

        task.delay(.34, function()
            if mainGui and mainGui.Parent then
                mainGui.Enabled = true
            end
            if gui and gui.Parent then gui:Destroy() end
        end)
    end

    skip.Activated:Connect(closeStartup)
    bg.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.Touch
            or input.UserInputType == Enum.UserInputType.MouseButton1 then
            closeStartup()
        end
    end)

    TweenService:Create(card, TweenInfo.new(.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        Position = UDim2.fromScale(.5,.5),
        Size = UDim2.fromScale(.80,.60)
    }):Play()
    TweenService:Create(progress, TweenInfo.new(2.8, Enum.EasingStyle.Linear), {
        Size = UDim2.fromScale(1,1)
    }):Play()

    task.delay(2.95, closeStartup)

    -- --------------------------------------------------------
    -- FINAL HEADER/BAR FIX
    -- --------------------------------------------------------
    local function fixBar(win)
        if not win or not win:IsA("GuiObject") then return end
        local bar = win:FindFirstChild("Bar", true)
        if not bar or not bar:IsA("GuiObject") then return end

        bar.Size = UDim2.new(1,0,0,46)
        bar.Position = UDim2.new(0,0,0,0)
        bar.ClipsDescendants = true
        bar.BackgroundColor3 = Color3.fromRGB(14,15,20)
        bar.BackgroundTransparency = 0
        bar.BorderSizePixel = 0

        local bc = bar:FindFirstChild("SERAPH_V16_CORNER")
        if not bc then
            bc = Instance.new("UICorner")
            bc.Name = "SERAPH_V16_CORNER"
            bc.CornerRadius = UDim.new(0,11)
            bc.Parent = bar
        end

        local title = bar:FindFirstChild("Title", true)
        if title and title:IsA("TextLabel") then
            title.AnchorPoint = Vector2.new(0,0.5)
            title.Position = UDim2.new(0,54,0.5,0)
            title.Size = UDim2.new(1,-170,0,28)
            title.TextXAlignment = Enum.TextXAlignment.Left
            title.TextYAlignment = Enum.TextYAlignment.Center
            title.TextWrapped = false
            title.TextTruncate = Enum.TextTruncate.AtEnd
            title.Font = Enum.Font.GothamBold
            title.TextSize = 14
            title.ZIndex = 250
        end

        local toggle = bar:FindFirstChild("Toggle", true)
        if toggle and toggle:IsA("GuiButton") then
            toggle.Position = UDim2.new(0,12,0.5,-12)
            toggle.Size = UDim2.fromOffset(24,24)
            toggle.ZIndex = 251
        end

        local oldLogo = bar:FindFirstChild("SERAPH_V11_LOGO")
        if oldLogo and oldLogo:IsA("GuiObject") then
            oldLogo.Position = UDim2.new(0,12,0.5,-13)
            oldLogo.Size = UDim2.fromOffset(26,26)
            oldLogo.ZIndex = 249
        end

        local status = bar:FindFirstChild("SERAPH_V11_STATUS")
        if status and status:IsA("GuiObject") then
            status.Position = UDim2.new(1,-12,0.5,0)
            status.Size = UDim2.fromOffset(82,24)
            status.ZIndex = 251
        end

        local live = bar:FindFirstChild("SERAPH_V14_LIVE")
        if live and live:IsA("GuiObject") then
            live.Position = UDim2.new(1,-102,0.5,0)
            live.Size = UDim2.fromOffset(72,22)
            live.ZIndex = 251
        end

        local accent = bar:FindFirstChild("SERAPH_V14_HEADER_LINE")
            or bar:FindFirstChild("SERAPH_V11_HEADER_LINE")
            or bar:FindFirstChild("SERAPH_StatusLine")
        if accent and accent:IsA("GuiObject") then
            accent.Position = UDim2.new(0,16,1,-2)
            accent.Size = UDim2.new(1,-32,0,2)
            accent.ZIndex = 252
        end
    end

    local function scanAndFix()
        if not mainGui or not mainGui.Parent then
            mainGui = host:FindFirstChild("imgui")
        end
        if not mainGui then return end
        for _, o in ipairs(mainGui:GetDescendants()) do
            if o:IsA("GuiObject") and o:FindFirstChild("Title", true) then
                fixBar(o)
            end
        end
    end

    task.spawn(function()
        for _ = 1, 20 do
            scanAndFix()
            task.wait(.15)
        end
    end)
end)


-- ============================================================
-- SERAPH HUB MERGED / LEGACY FEATURE PACK
-- Añade funciones detectadas en MuscleLegends.lua que no estaban
-- en esta base: Fast Glitch, Glitch Timer, Anti-Lag, Walk on Water,
-- Auto Spin Wheel y Auto Claim Chests.
-- ============================================================
pcall(function()
    if not window or type(window.AddTab) ~= "function" then return end

    local LegacyTab = window:AddTab("Legacy Plus")
    local Core = LegacyTab:AddFolder("⚡ Legacy Features")

    local legacyState = {
        FastGlitch = false,
        AntiLag = false,
        WalkWater = false,
        AutoWheel = false,
        AutoChests = false,
    }

    local savedEffects = {
        GlobalShadows = Lighting.GlobalShadows,
        FogEnd = Lighting.FogEnd,
        Brightness = Lighting.Brightness,
    }

    local waterParts = {}
    local fastGlitchToken = 0

    local function getMuscleEvent()
        return player and player:FindFirstChild("muscleEvent")
    end

    local function equipPunch()
        local char = player and player.Character
        local backpack = player and player:FindFirstChildOfClass("Backpack")
        local tool = (char and char:FindFirstChild("Punch"))
            or (backpack and backpack:FindFirstChild("Punch"))

        if tool and char and tool.Parent ~= char then
            local hum = char:FindFirstChildOfClass("Humanoid")
            if hum then pcall(hum.EquipTool, hum, tool) end
        end
        return tool
    end

    -- Fast Glitch: versión autocontenida, con parada limpia.
    Core:AddSwitch("⚡ Fast Glitch 100%", function(state)
        legacyState.FastGlitch = state == true
        fastGlitchToken += 1
        local token = fastGlitchToken

        if not legacyState.FastGlitch then return end

        task.spawn(function()
            while legacyState.FastGlitch and token == fastGlitchToken do
                pcall(function()
                    local tool = equipPunch()
                    local event = getMuscleEvent()

                    if tool then
                        local attackTime = tool:FindFirstChild("attackTime")
                        if attackTime and attackTime:IsA("ValueBase") then
                            attackTime.Value = 0
                        end
                        if type(tool.Activate) == "function" then
                            tool:Activate()
                        end
                    end

                    if event then
                        event:FireServer("punch", "rightHand")
                        event:FireServer("punch", "leftHand")
                    end
                end)
                task.wait(0.02)
            end
        end)
    end)

    -- Cronómetro independiente para la función anterior.
    local glitchTimer = LegacyTab:AddFolder("⏱ Glitch Timer")
    local timerLabel = glitchTimer:AddLabel("Tiempo: 00:00:00")
    local timerStart = 0

    glitchTimer:AddButton("▶ Iniciar / Reiniciar", function()
        timerStart = os.clock()
    end)

    glitchTimer:AddButton("⏹ Detener", function()
        timerStart = 0
        timerLabel.Text = "Tiempo: 00:00:00"
    end)

    task.spawn(function()
        while task.wait(0.25) do
            if timerStart > 0 then
                local elapsed = math.max(0, math.floor(os.clock() - timerStart))
                local h = math.floor(elapsed / 3600)
                local m = math.floor((elapsed % 3600) / 60)
                local s = elapsed % 60
                timerLabel.Text = string.format("Tiempo: %02d:%02d:%02d", h, m, s)
            end
        end
    end)

    -- Anti-Lag: guarda/restaura únicamente las propiedades modificadas.
    local antiLagFolder = LegacyTab:AddFolder("🚀 Anti-Lag")
    local antiLagSaved = {}

    local function optimizeObject(obj)
        if not obj then return end
        pcall(function()
            if obj:IsA("ParticleEmitter") or obj:IsA("Trail")
                or obj:IsA("Beam") or obj:IsA("Smoke")
                or obj:IsA("Fire") or obj:IsA("Sparkles") then
                if antiLagSaved[obj] == nil then
                    antiLagSaved[obj] = {Enabled = obj.Enabled}
                end
                obj.Enabled = false
            elseif obj:IsA("PointLight") or obj:IsA("SpotLight")
                or obj:IsA("SurfaceLight") then
                if antiLagSaved[obj] == nil then
                    antiLagSaved[obj] = {Enabled = obj.Enabled}
                end
                obj.Enabled = false
            elseif obj:IsA("Decal") or obj:IsA("Texture") then
                if antiLagSaved[obj] == nil then
                    antiLagSaved[obj] = {Transparency = obj.Transparency}
                end
                obj.Transparency = 1
            end
        end)
    end

    local antiLagConnection

    antiLagFolder:AddSwitch("🚀 Anti-Lag", function(state)
        legacyState.AntiLag = state == true

        if antiLagConnection then
            pcall(function() antiLagConnection:Disconnect() end)
            antiLagConnection = nil
        end

        if legacyState.AntiLag then
            pcall(function()
                Lighting.GlobalShadows = false
                Lighting.FogEnd = 1000000000
                Lighting.Brightness = 0
            end)

            for _, obj in ipairs(workspace:GetDescendants()) do
                optimizeObject(obj)
            end

            antiLagConnection = workspace.DescendantAdded:Connect(function(obj)
                if legacyState.AntiLag then
                    task.defer(optimizeObject, obj)
                end
            end)
        else
            for obj, props in pairs(antiLagSaved) do
                if obj and obj.Parent then
                    pcall(function()
                        for prop, value in pairs(props) do
                            obj[prop] = value
                        end
                    end)
                end
            end
            table.clear(antiLagSaved)

            pcall(function()
                Lighting.GlobalShadows = savedEffects.GlobalShadows
                Lighting.FogEnd = savedEffects.FogEnd
                Lighting.Brightness = savedEffects.Brightness
            end)
        end
    end)

    -- Walk on Water.
    local waterFolder = LegacyTab:AddFolder("🌊 Movement")

    local function clearWater()
        for _, part in ipairs(waterParts) do
            if part and part.Parent then pcall(part.Destroy, part) end
        end
        table.clear(waterParts)
    end

    waterFolder:AddSwitch("🌊 Walk on Water", function(state)
        legacyState.WalkWater = state == true
        clearWater()

        if not legacyState.WalkWater then return end

        local origin = Vector3.new(-3072, -9.5, -3072)
        for x = -4, 4 do
            for z = -4, 4 do
                local part = Instance.new("Part")
                part.Name = "SERAPH_WaterFloor"
                part.Size = Vector3.new(2048, 1, 2048)
                part.Position = origin + Vector3.new(x * 2048, 0, z * 2048)
                part.Anchored = true
                part.CanCollide = true
                part.Transparency = 1
                part.CastShadow = false
                part.Parent = workspace
                waterParts[#waterParts + 1] = part
            end
            task.wait()
        end
    end)

    -- Auto Fortune Wheel.
    local wheelFolder = LegacyTab:AddFolder("🎡 Rewards")

    wheelFolder:AddSwitch("🎡 Auto Spin Fortune Wheel", function(state)
        legacyState.AutoWheel = state == true

        if not legacyState.AutoWheel then return end

        task.spawn(function()
            while legacyState.AutoWheel do
                pcall(function()
                    local rEvents = ReplicatedStorage:FindFirstChild("rEvents")
                    local remote = rEvents and rEvents:FindFirstChild("openFortuneWheelRemote")
                    local chances = ReplicatedStorage:FindFirstChild("fortuneWheelChances")
                    local wheel = chances and chances:FindFirstChild("Fortune Wheel")

                    if remote and wheel then
                        remote:InvokeServer("openFortuneWheel", wheel)
                    end
                end)
                task.wait(1)
            end
        end)
    end)

    -- Auto Chest Claim.
    wheelFolder:AddSwitch("🎁 Auto Claim Chests", function(state)
        legacyState.AutoChests = state == true

        if not legacyState.AutoChests then return end

        task.spawn(function()
            local chestNames = {
                "Magma Chest",
                "Mythical Chest",
                "Golden Chest",
                "Enchanted Chest",
                "Legends Chest",
            }

            while legacyState.AutoChests do
                pcall(function()
                    local rEvents = ReplicatedStorage:FindFirstChild("rEvents")
                    local remote = rEvents and rEvents:FindFirstChild("checkChestRemote")

                    if remote then
                        for _, chest in ipairs(chestNames) do
                            if not legacyState.AutoChests then break end
                            pcall(remote.InvokeServer, remote, chest)
                            task.wait(0.15)
                        end
                    end
                end)
                task.wait(15)
            end
        end)
    end)

    LegacyTab:AddFolder("🧩 Compatibility").AddLabel(
        "Funciones agregadas desde MuscleLegends.lua"
    )
end)


-- ============================================================
-- SERAPH HUB MAX PACK
-- Nuevas funciones independientes y reversibles.
-- ============================================================
task.defer(function()
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local UIS = game:GetService("UserInputService")
    local TeleportService = game:GetService("TeleportService")
    local HttpService = game:GetService("HttpService")
    local player = Players.LocalPlayer
    local pg = player and player:FindFirstChildOfClass("PlayerGui")

    if not window or not player then return end
    if type(window.AddTab) ~= "function" then return end

    local ok, tab = pcall(function()
        return window:AddTab("MAX Tools")
    end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2, f = pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end

    local function addSwitch(f, name, fn)
        if f and type(f.AddSwitch) == "function" then pcall(f.AddSwitch, f, name, fn) end
    end

    local function addButton(f, name, fn)
        if f and type(f.AddButton) == "function" then pcall(f.AddButton, f, name, fn) end
    end

    local function addText(f, text)
        if f and type(f.AddLabel) == "function" then pcall(f.AddLabel, f, text) end
    end

    -- 1. Player utilities
    local pf = folder("👤 Player Tools")
    local states = {
        InfJump=false, Noclip=false, FullBright=false,
        AntiAFK=false, ClickTP=false, ESP=false
    }

    local noclipConn, jumpConn, brightOld
    addSwitch(pf, "♾️ Infinite Jump", function(v)
        states.InfJump = v == true
        if jumpConn then pcall(function() jumpConn:Disconnect() end) end
        if states.InfJump then
            jumpConn = UIS.JumpRequest:Connect(function()
                local c = player.Character
                local h = c and c:FindFirstChildOfClass("Humanoid")
                if h then pcall(h.ChangeState, h, Enum.HumanoidStateType.Jumping) end
            end)
        end
    end)

    addSwitch(pf, "👻 Noclip", function(v)
        states.Noclip = v == true
        if noclipConn then pcall(function() noclipConn:Disconnect() end) end
        if states.Noclip then
            noclipConn = RunService.Stepped:Connect(function()
                local c = player.Character
                if c then
                    for _,p in ipairs(c:GetDescendants()) do
                        if p:IsA("BasePart") then p.CanCollide = false end
                    end
                end
            end)
        end
    end)

    addSwitch(pf, "☀️ FullBright", function(v)
        states.FullBright = v == true
        local L = game:GetService("Lighting")
        if states.FullBright then
            brightOld = {Brightness=L.Brightness, ClockTime=L.ClockTime, FogEnd=L.FogEnd, GlobalShadows=L.GlobalShadows}
            L.Brightness = 3
            L.ClockTime = 14
            L.FogEnd = 100000
            L.GlobalShadows = false
        elseif brightOld then
            for k,x in pairs(brightOld) do pcall(function() L[k]=x end) end
            brightOld = nil
        end
    end)

    -- Anti-AFK without manipulating gameplay remotes.
    local vu = game:GetService("VirtualUser")
    addSwitch(pf, "💤 Anti-AFK", function(v)
        states.AntiAFK = v == true
        if states.AntiAFK then
            player.Idled:Connect(function()
                if states.AntiAFK then
                    pcall(function()
                        vu:CaptureController()
                        vu:ClickButton2(Vector2.new(0,0))
                    end)
                end
            end)
        end
    end)

    -- 2. Server / utility panel
    local sf = folder("🌐 Server Tools")
    local jobLabel
    if sf and sf.AddLabel then
        local ok3, label = pcall(sf.AddLabel, sf, "JobId: " .. tostring(game.JobId))
        if ok3 then jobLabel=label end
    end

    addButton(sf, "🔄 Rejoin Server", function()
        pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, player)
        end)
    end)

    addButton(sf, "🚪 Server Hop (random public)", function()
        pcall(function()
            TeleportService:Teleport(game.PlaceId, player)
        end)
    end)

    addButton(sf, "📋 Copy JobId", function()
        if setclipboard then pcall(setclipboard, tostring(game.JobId)) end
    end)

    addButton(sf, "📋 Copy PlaceId", function()
        if setclipboard then pcall(setclipboard, tostring(game.PlaceId)) end
    end)

    -- 3. Player scanner (information only)
    local scan = folder("🔎 Player Scanner")
    local function playerSummary()
        local rows={}
        for _,p in ipairs(Players:GetPlayers()) do
            rows[#rows+1] = string.format("%s | %s | %s", p.Name, p.DisplayName, p.UserId)
        end
        return table.concat(rows, "\n")
    end
    addButton(scan, "📊 Print Players", function()
        print("========== SERAPH PLAYER SCANNER ==========")
        print(playerSummary())
        print("===========================================")
    end)

    addButton(scan, "📋 Copy Player List", function()
        if setclipboard then pcall(setclipboard, playerSummary()) end
    end)

    -- 4. Performance monitor
    local perf = folder("📈 Performance")
    local perfLabel
    if perf and perf.AddLabel then
        local ok4,l = pcall(perf.AddLabel, perf, "FPS: -- | Ping: --")
        if ok4 then perfLabel=l end
    end

    local frames, last = 0, os.clock()
    RunService.RenderStepped:Connect(function()
        frames += 1
        local now=os.clock()
        if now-last >= 1 then
            local fps=math.floor(frames/(now-last))
            frames=0; last=now
            local ping="--"
            pcall(function()
                ping=tostring(math.floor(player:GetNetworkPing()*1000)).." ms"
            end)
            if perfLabel then
                pcall(function() perfLabel.Text="FPS: "..fps.." | Ping: "..ping end)
            end
        end
    end)

    -- 5. Quick settings / recovery
    local rec = folder("🛠️ Recovery")
    addButton(rec, "🧹 Stop MAX features", function()
        states.InfJump=false
        states.Noclip=false
        states.FullBright=false
        states.AntiAFK=false
        if jumpConn then pcall(function() jumpConn:Disconnect() end); jumpConn=nil end
        if noclipConn then pcall(function() noclipConn:Disconnect() end); noclipConn=nil end
        local L=game:GetService("Lighting")
        if brightOld then
            for k,x in pairs(brightOld) do pcall(function() L[k]=x end) end
            brightOld=nil
        end
        addText(rec, "MAX features detenidas.")
    end)

    addButton(rec, "🧪 Run compatibility check", function()
        local checks = {
            "AddWindow=" .. tostring(type(window.AddWindow)=="function"),
            "AddTab=" .. tostring(type(window.AddTab)=="function"),
            "AddFolder=" .. tostring(type(tab.AddFolder)=="function"),
            "Players=" .. tostring(Players ~= nil),
            "RunService=" .. tostring(RunService ~= nil),
            "UserInputService=" .. tostring(UIS ~= nil),
            "PlaceId=" .. tostring(game.PlaceId),
        }
        print("========== SERAPH COMPATIBILITY ==========")
        print(table.concat(checks,"\n"))
        print("==========================================")
    end)

    addText(rec, "MAX PACK: utilidades, rendimiento, servidor y recuperación.")
end)


-- ============================================================
-- SERAPH HUB ULTRA CONTROL CENTER
-- Dashboard + perfiles + diagnóstico + Safe Mode + búsqueda
-- + control global de funciones del pack.
-- ============================================================
task.defer(function()
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local Lighting = game:GetService("Lighting")
    local player = Players.LocalPlayer

    if not window or not player or type(window.AddTab) ~= "function" then return end

    local ok, ultra = pcall(function()
        return window:AddTab("SERAPH ULTRA")
    end)
    if not ok or not ultra then return end

    local function mkFolder(name)
        local ok2, f = pcall(function() return ultra:AddFolder(name) end)
        return ok2 and f or nil
    end

    local function button(f, name, fn)
        if f and type(f.AddButton) == "function" then
            pcall(f.AddButton, f, name, fn)
        end
    end

    local function switch(f, name, fn)
        if f and type(f.AddSwitch) == "function" then
            pcall(f.AddSwitch, f, name, fn)
        end
    end

    local function label(f, text)
        if f and type(f.AddLabel) == "function" then
            local ok3, x = pcall(f.AddLabel, f, text)
            if ok3 then return x end
        end
    end

    local state = {
        safeMode = false,
        sessionStart = os.clock(),
        active = {},
        errors = {},
        errorCount = 0,
        lastError = "Ninguno",
        profile = "Default",
    }

    -- ---------- Dashboard ----------
    local dash = mkFolder("📊 Dashboard")
    local dashLabel = label(dash, "SERAPH ULTRA | iniciando...")

    local function activeCount()
        local n = 0
        for _, v in pairs(state.active) do
            if v then n += 1 end
        end
        return n
    end

    local function updateDashboard()
        if not dashLabel then return end
        local fps = 0
        local ping = "--"
        pcall(function()
            ping = tostring(math.floor(player:GetNetworkPing() * 1000)) .. " ms"
        end)

        local elapsed = math.max(0, math.floor(os.clock() - state.sessionStart))
        local h = math.floor(elapsed / 3600)
        local m = math.floor((elapsed % 3600) / 60)
        local s = elapsed % 60

        pcall(function()
            dashLabel.Text = string.format(
                "SERAPH ULTRA | %02d:%02d:%02d | Ping %s | Activas %d | Errores %d",
                h, m, s, ping, activeCount(), state.errorCount
            )
        end)
    end

    task.spawn(function()
        local frames, stamp = 0, os.clock()
        while task.wait(0.1) do
            frames += 1
            local now = os.clock()
            if now - stamp >= 1 then
                -- FPS se calcula como información local; no modifica gameplay.
                local fps = math.floor(frames / (now - stamp))
                frames, stamp = 0, now
                state.fps = fps
                updateDashboard()
            end
        end
    end)

    button(dash, "🔄 Refresh Dashboard", updateDashboard)

    -- ---------- Profiles ----------
    local profiles = mkFolder("💾 Profiles")
    local profileData = {
        Default = {},
        Performance = {
            FullBright = true,
            AntiLag = true,
        },
        Movement = {
            InfiniteJump = true,
            Noclip = false,
        },
    }

    button(profiles, "📋 Show Current Profile", function()
        print("========== SERAPH PROFILE ==========")
        print("Profile:", state.profile)
        print("Active features:", activeCount())
        print("====================================")
    end)

    button(profiles, "⚡ Select Default", function()
        state.profile = "Default"
        updateDashboard()
    end)

    button(profiles, "🚀 Select Performance", function()
        state.profile = "Performance"
        updateDashboard()
    end)

    button(profiles, "🏃 Select Movement", function()
        state.profile = "Movement"
        updateDashboard()
    end)

    -- ---------- Diagnostics ----------
    local diag = mkFolder("🧪 Diagnostics")
    local diagLabel = label(diag, "Errores: 0 | Último: Ninguno")

    local function recordError(where, err)
        state.errorCount += 1
        state.lastError = tostring(where) .. ": " .. tostring(err)
        state.errors[#state.errors + 1] = {
            time = os.date("%H:%M:%S"),
            where = tostring(where),
            error = tostring(err),
        }

        if #state.errors > 50 then
            table.remove(state.errors, 1)
        end

        if diagLabel then
            pcall(function()
                diagLabel.Text = "Errores: " .. state.errorCount ..
                    " | Último: " .. string.sub(state.lastError, 1, 80)
            end)
        end

        warn("[SERAPH DIAGNOSTICS] " .. state.lastError)
    end

    local function safeCall(where, fn)
        local ok4, result = xpcall(fn, debug.traceback)
        if not ok4 then
            recordError(where, result)
            return false, result
        end
        return true, result
    end

    button(diag, "🧪 Run Self-Test", function()
        local checks = {
            {"Players", Players ~= nil},
            {"RunService", RunService ~= nil},
            {"Lighting", Lighting ~= nil},
            {"LocalPlayer", player ~= nil},
            {"GUI AddTab", type(window.AddTab) == "function"},
            {"GUI AddFolder", type(ultra.AddFolder) == "function"},
        }

        local failed = 0
        print("========== SERAPH SELF TEST ==========")
        for _, item in ipairs(checks) do
            print(item[1], item[2] and "OK" or "FAIL")
            if not item[2] then failed += 1 end
        end
        print("Failed:", failed)
        print("======================================")
        updateDashboard()
    end)

    button(diag, "📜 Print Error Log", function()
        print("========== SERAPH ERROR LOG ==========")
        if #state.errors == 0 then
            print("Sin errores registrados.")
        else
            for _, e in ipairs(state.errors) do
                print("[" .. e.time .. "] " .. e.where .. " -> " .. e.error)
            end
        end
        print("======================================")
    end)

    button(diag, "🧹 Clear Error Log", function()
        table.clear(state.errors)
        state.errorCount = 0
        state.lastError = "Ninguno"
        if diagLabel then
            pcall(function() diagLabel.Text = "Errores: 0 | Último: Ninguno" end)
        end
        updateDashboard()
    end)

    -- ---------- Safe Mode ----------
    local safe = mkFolder("🛡️ Safe Mode")
    local safeLabel = label(safe, "Safe Mode: OFF")

    switch(safe, "🛡️ Enable Safe Mode", function(enabled)
        state.safeMode = enabled == true
        if safeLabel then
            pcall(function()
                safeLabel.Text = "Safe Mode: " .. (state.safeMode and "ON" or "OFF")
            end)
        end
        updateDashboard()
    end)

    button(safe, "⛔ Stop Registered MAX/ULTRA Features", function()
        -- Desactiva sólo estados que este pack registra; no destruye la GUI.
        for k in pairs(state.active) do
            state.active[k] = false
        end
        updateDashboard()
        print("[SERAPH] Registered MAX/ULTRA states stopped.")
    end)

    -- ---------- Search ----------
    local search = mkFolder("🔎 Quick Search")
    local searchLabel = label(search, "Escribí el nombre de una función en el Developer Console.")

    button(search, "🔎 Search Known Features", function()
        local names = {
            "Dashboard", "Profiles", "Diagnostics", "Safe Mode",
            "Quick Search", "Performance", "Player Tools",
            "Server Tools", "Player Scanner", "Recovery",
            "Fast Glitch", "Anti-Lag", "Walk on Water",
            "Auto Spin Fortune Wheel", "Auto Claim Chests",
            "Infinite Jump", "Noclip", "FullBright", "Anti-AFK"
        }

        print("========== SERAPH FEATURE INDEX ==========")
        for i, name in ipairs(names) do
            print(i .. ".", name)
        end
        print("==========================================")
    end)

    -- ---------- Global recovery ----------
    local recovery = mkFolder("🚨 Global Recovery")

    button(recovery, "🚨 Emergency Stop", function()
        state.safeMode = true

        -- Restaurar iluminación a valores razonables si otra función dejó cambios.
        pcall(function()
            Lighting.GlobalShadows = true
        end)

        -- Desactivar el pack de este módulo.
        for k in pairs(state.active) do
            state.active[k] = false
        end

        if safeLabel then
            pcall(function() safeLabel.Text = "Safe Mode: ON (Emergency Stop)" end)
        end

        updateDashboard()
        warn("[SERAPH] Emergency Stop ejecutado.")
    end)

    button(recovery, "ℹ️ Print SERAPH Info", function()
        print("========== SERAPH ULTRA INFO ==========")
        print("PlaceId:", game.PlaceId)
        print("JobId:", game.JobId)
        print("Player:", player.Name)
        print("DisplayName:", player.DisplayName)
        print("Profile:", state.profile)
        print("FPS:", state.fps or "--")
        print("Errors:", state.errorCount)
        print("=======================================")
    end)

    -- Helper público para futuros módulos del hub.
    pcall(function()
        local env = getgenv and getgenv() or _G
        env.SERAPH_ULTRA = env.SERAPH_ULTRA or {}
        env.SERAPH_ULTRA.State = state
        env.SERAPH_ULTRA.RecordError = recordError
        env.SERAPH_ULTRA.SafeCall = safeCall
        env.SERAPH_ULTRA.UpdateDashboard = updateDashboard
    end)

    updateDashboard()
end)


-- ============================================================
-- SERAPH HUB ULTIMATE - MODULE MANAGER
-- Organización de módulos, perfiles, favoritos, búsqueda,
-- dependencias, estado y recuperación.
-- ============================================================
task.defer(function()
    local Players = game:GetService("Players")
    local player = Players.LocalPlayer
    if not window or not player or type(window.AddTab) ~= "function" then return end

    local ok, tab = pcall(function() return window:AddTab("MODULE MANAGER") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2, f = pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function switch(f,n,fn)
        if f and f.AddSwitch then pcall(f.AddSwitch,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok3,x=pcall(f.AddLabel,f,t)
            if ok3 then return x end
        end
    end

    local modules = {
        Core         = {enabled=true,  favorite=true,  deps={}},
        GUI          = {enabled=true,  favorite=true,  deps={"Core"}},
        AI           = {enabled=true,  favorite=true,  deps={"Core","Diagnostics"}},
        Diagnostics  = {enabled=true,  favorite=true,  deps={"Core"}},
        Performance  = {enabled=true,  favorite=false, deps={"Core"}},
        Configuration= {enabled=true,  favorite=false, deps={"Core"}},
        Recovery     = {enabled=true,  favorite=true,  deps={"Core","Diagnostics"}},
        PlayerTools  = {enabled=true,  favorite=false, deps={"Core"}},
        ServerTools  = {enabled=true,  favorite=false, deps={"Core"}},
        Rewards      = {enabled=true,  favorite=false, deps={"Core"}},
        Movement     = {enabled=true,  favorite=false, deps={"Core"}},
        Experimental = {enabled=false, favorite=false, deps={"Core"}},
    }

    local manager = folder("🧩 Module Manager")
    local status = label(manager,"Módulos: "..tostring(#modules))

    local function count()
        local total,on,fav=0,0,0
        for _,m in pairs(modules) do
            total+=1
            if m.enabled then on+=1 end
            if m.favorite then fav+=1 end
        end
        return total,on,fav
    end

    local function refresh()
        local total,on,fav=count()
        if status then
            pcall(function()
                status.Text=string.format("Módulos: %d | Activos: %d | Favoritos: %d",total,on,fav)
            end)
        end
    end

    local function canDisable(name)
        for other,m in pairs(modules) do
            if other~=name and m.enabled then
                for _,dep in ipairs(m.deps) do
                    if dep==name then
                        return false,other
                    end
                end
            end
        end
        return true
    end

    for name,m in pairs(modules) do
        local n=name
        switch(manager,(m.favorite and "⭐ " or "○ ")..n,function(v)
            local requested=v==true
            if not requested then
                local okDisable,dependent=canDisable(n)
                if not okDisable then
                    warn("[SERAPH MODULE] "..n.." no puede desactivarse mientras "..dependent.." depende de él.")
                    return
                end
            end
            modules[n].enabled=requested
            refresh()
        end)
    end

    button(manager,"🔄 Refresh Module Status",refresh)

    button(manager,"⭐ Toggle Favorites Only",function()
        for _,m in pairs(modules) do
            m.enabled=m.favorite
        end
        refresh()
    end)

    button(manager,"🚀 Enable All Safe Modules",function()
        for name,m in pairs(modules) do
            if name~="Experimental" then m.enabled=true end
        end
        refresh()
    end)

    button(manager,"🛑 Disable Optional Modules",function()
        for name,m in pairs(modules) do
            if name~="Core" and name~="GUI" and name~="Diagnostics" then
                local okDisable=canDisable(name)
                if okDisable then m.enabled=false end
            end
        end
        refresh()
    end)

    local profiles=folder("💾 Module Profiles")
    local savedProfiles={
        Safe={Core=true,GUI=true,Diagnostics=true,Recovery=true},
        Performance={Core=true,GUI=true,Diagnostics=true,Performance=true,Recovery=true},
        Full={},
    }

    for n,m in pairs(modules) do savedProfiles.Full[n]=true end

    local function applyProfile(p)
        for name,m in pairs(modules) do
            if p[name]~=nil then m.enabled=p[name] end
        end
        refresh()
    end

    button(profiles,"🛡️ Safe Profile",function() applyProfile(savedProfiles.Safe) end)
    button(profiles,"🚀 Performance Profile",function() applyProfile(savedProfiles.Performance) end)
    button(profiles,"🔥 Full Profile",function() applyProfile(savedProfiles.Full) end)

    local favorites=folder("⭐ Favorites")
    local favLabel=label(favorites,"Funciones favoritas: Core, GUI, AI, Diagnostics, Recovery")

    button(favorites,"📋 Print Favorites",function()
        print("========== SERAPH FAVORITES ==========")
        for name,m in pairs(modules) do
            if m.favorite then print("⭐ "..name) end
        end
        print("======================================")
    end)

    local search=folder("🔎 Module Search")
    button(search,"🔎 Search Active Modules",function()
        print("========== ACTIVE MODULES ==========")
        for name,m in pairs(modules) do
            if m.enabled then print("✓ "..name) end
        end
        print("===================================")
    end)

    button(search,"🔎 Search Disabled Modules",function()
        print("========= DISABLED MODULES =========")
        for name,m in pairs(modules) do
            if not m.enabled then print("○ "..name) end
        end
        print("===================================")
    end)

    local deps=folder("🔗 Dependencies")
    button(deps,"🔗 Show Dependency Graph",function()
        print("========== DEPENDENCIES ==========")
        for name,m in pairs(modules) do
            print(name.." <- "..(#m.deps>0 and table.concat(m.deps,", ") or "none"))
        end
        print("==================================")
    end)

    local recovery=folder("🚨 Module Recovery")
    button(recovery,"🛑 Safe Module Reset",function()
        for name,m in pairs(modules) do
            m.enabled=(name=="Core" or name=="GUI" or name=="Diagnostics" or name=="Recovery")
        end
        refresh()
        warn("[SERAPH MODULE] Safe Module Reset ejecutado.")
    end)

    button(recovery,"🧪 Validate Dependencies",function()
        local errors=0
        for name,m in pairs(modules) do
            if m.enabled then
                for _,dep in ipairs(m.deps) do
                    if not modules[dep] or not modules[dep].enabled then
                        errors+=1
                        warn("[SERAPH MODULE] Dependencia faltante: "..name.." -> "..dep)
                    end
                end
            end
        end
        print("[SERAPH MODULE] Dependency errors:",errors)
    end)

    local config=folder("⚙️ Module Settings")
    local configLabel=label(config,"Estado: listo")

    switch(config,"🧪 Allow Experimental",function(v)
        modules.Experimental.enabled=v==true
        if configLabel then
            pcall(function() configLabel.Text="Experimental: "..(modules.Experimental.enabled and "ON" or "OFF") end)
        end
    end)

    button(config,"📊 Module Report",function()
        local total,on,fav=count()
        print("========== SERAPH MODULE REPORT ==========")
        print("Total:",total)
        print("Enabled:",on)
        print("Favorites:",fav)
        for name,m in pairs(modules) do
            print(string.format("%-16s enabled=%s favorite=%s",name,tostring(m.enabled),tostring(m.favorite)))
        end
        print("==========================================")
    end)

    pcall(function()
        local env=getgenv and getgenv() or _G
        env.SERAPH_MODULE_MANAGER={
            Modules=modules,
            ApplyProfile=applyProfile,
            Refresh=refresh,
            Count=count
        }
    end)

    refresh()
end)


-- ============================================================
-- SERAPH AI FREE ROUTER
-- Proveedores con niveles gratuitos/triales:
-- Gemini, Groq, OpenRouter Free y Cerebras.
-- No incluye ni guarda claves reales.
-- ============================================================
task.defer(function()
    local HttpService = game:GetService("HttpService")
    if not window then return end

    local ok, tab = pcall(function() return window:AddTab("🧠 AI FREE ROUTER") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2,f=pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function textBox(f,n,fn)
        if f and f.AddTextBox then pcall(f.AddTextBox,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok3,x=pcall(f.AddLabel,f,t)
            if ok3 then return x end
        end
    end

    local Providers = {
        Gemini = {
            label="Google Gemini — Free Tier",
            endpoint="https://generativelanguage.googleapis.com/v1beta/models/",
            model="gemini-2.5-flash",
            key="",
            kind="gemini",
        },
        Groq = {
            label="Groq — Free Tier",
            endpoint="https://api.groq.com/openai/v1/chat/completions",
            model="llama-3.3-70b-versatile",
            key="",
            kind="openai",
        },
        OpenRouter = {
            label="OpenRouter — Free Models",
            endpoint="https://openrouter.ai/api/v1/chat/completions",
            model="openrouter/free",
            key="",
            kind="openai",
        },
        Cerebras = {
            label="Cerebras — Free Trial",
            endpoint="https://api.cerebras.ai/v1/chat/completions",
            model="",
            key="",
            kind="openai",
        },
    }

    local selected="Gemini"
    local question=""
    local outputLabel
    local statusLabel
    local history={}

    local setup=folder("⚙️ Provider Setup")
    local info=folder("ℹ️ Free AI Providers")
    local chat=folder("💬 AI Chat")
    local fallback=folder("🔄 Auto Fallback")

    label(info,"Gemini: nivel gratuito con modelos seleccionados.")
    label(info,"Groq: ofrece nivel Free con límites.")
    label(info,"OpenRouter: dispone de modelos gratuitos y router openrouter/free.")
    label(info,"Cerebras: ofrece prueba gratuita/créditos iniciales; no es un free tier permanente.")
    label(info,"Las claves se ingresan localmente y NO están incluidas en el script.")

    textBox(setup,"🔑 Gemini API Key",function(v) Providers.Gemini.key=tostring(v or "") end)
    textBox(setup,"🔑 Groq API Key",function(v) Providers.Groq.key=tostring(v or "") end)
    textBox(setup,"🔑 OpenRouter API Key",function(v) Providers.OpenRouter.key=tostring(v or "") end)
    textBox(setup,"🔑 Cerebras API Key",function(v) Providers.Cerebras.key=tostring(v or "") end)

    textBox(setup,"🧩 Gemini Model",function(v)
        if tostring(v)~="" then Providers.Gemini.model=tostring(v) end
    end)
    textBox(setup,"🧩 Groq Model",function(v)
        if tostring(v)~="" then Providers.Groq.model=tostring(v) end
    end)
    textBox(setup,"🧩 OpenRouter Model",function(v)
        if tostring(v)~="" then Providers.OpenRouter.model=tostring(v) end
    end)
    textBox(setup,"🧩 Cerebras Model",function(v)
        Providers.Cerebras.model=tostring(v or "")
    end)

    local function requestFn()
        if type(request)=="function" then return request end
        if syn and type(syn.request)=="function" then return syn.request end
        if http and type(http.request)=="function" then return http.request end
        if fluxus and type(fluxus.request)=="function" then return fluxus.request end
    end

    local function post(url,body,headers)
        local req=requestFn()
        if not req then return nil,"No HTTP request function disponible" end
        local ok2,res=pcall(req,{
            Url=url,Method="POST",
            Headers=headers,
            Body=HttpService:JSONEncode(body)
        })
        if not ok2 or type(res)~="table" then return nil,tostring(res) end
        local status=tonumber(res.StatusCode or res.Status or 0) or 0
        local raw=res.Body or res.body or ""
        if status>=400 then return nil,"HTTP "..status..": "..string.sub(raw,1,500) end
        local ok3,data=pcall(HttpService.JSONDecode,HttpService,raw)
        if not ok3 then return nil,"Respuesta JSON inválida" end
        return data
    end

    local function extract(data,provider)
        if not data then return nil end

        if provider.kind=="gemini" then
            local candidates=data.candidates
            if type(candidates)=="table" and candidates[1]
                and candidates[1].content
                and type(candidates[1].content.parts)=="table" then
                local pieces={}
                for _,part in ipairs(candidates[1].content.parts) do
                    if part.text then pieces[#pieces+1]=tostring(part.text) end
                end
                return table.concat(pieces,"\n")
            end
            return nil
        end

        return data.choices
            and data.choices[1]
            and data.choices[1].message
            and data.choices[1].message.content
            or nil
    end

    local function ask(name,prompt)
        local p=Providers[name]
        if not p then return nil,"Proveedor desconocido" end
        if p.key=="" then return nil,"Falta la API Key de "..name end
        if p.kind=="gemini" then
            local url=p.endpoint..p.model..":generateContent?key="..p.key
            local data,err=post(url,{
                contents={{role="user",parts={{text=prompt}}}},
                generationConfig={temperature=0.3}
            },{["Content-Type"]="application/json"})
            if not data then return nil,err end
            local answer=extract(data,p)
            return answer or nil,"Gemini no devolvió texto"
        end

        local headers={
            ["Content-Type"]="application/json",
            ["Authorization"]="Bearer "..p.key
        }
        if name=="OpenRouter" then
            headers["HTTP-Referer"]="https://seraph-hub.local"
            headers["X-Title"]="SERAPH HUB AI"
        end

        local data,err=post(p.endpoint,{
            model=p.model,
            temperature=0.3,
            messages={
                {role="system",content="You are SERAPH HUB's helpful AI assistant. Be concise and practical."},
                {role="user",content=prompt}
            }
        },headers)

        if not data then return nil,err end
        local answer=extract(data,p)
        return answer or nil,name.." no devolvió texto"
    end

    local function show(text)
        text=tostring(text or "")
        if outputLabel then
            pcall(function()
                outputLabel.Text="🤖 "..string.sub(text,1,900)
            end)
        end
        print("========== SERAPH AI ==========")
        print(text)
        print("===============================")
    end

    outputLabel=label(chat,"🤖 Esperando una pregunta...")
    statusLabel=label(chat,"Proveedor: Gemini")

    textBox(chat,"💬 Pregunta",function(v)
        question=tostring(v or "")
    end)

    local function addProviderButton(name)
        button(setup,"▶ Usar "..Providers[name].label,function()
            selected=name
            if statusLabel then statusLabel.Text="Proveedor: "..name end
        end)
    end

    addProviderButton("Gemini")
    addProviderButton("Groq")
    addProviderButton("OpenRouter")
    addProviderButton("Cerebras")

    button(chat,"💬 Enviar",function()
        if question=="" then show("Escribí una pregunta."); return end
        local q=question
        show("Pensando con "..selected.."...")
        task.spawn(function()
            local answer,err=ask(selected,q)
            if answer then
                history[#history+1]={provider=selected,question=q,answer=answer}
                show("["..selected.."] "..answer)
            else
                show("❌ "..tostring(err))
            end
        end)
    end)

    button(chat,"🧹 Limpiar respuesta",function()
        show("Esperando una pregunta...")
    end)

    -- Automatic fallback: tries configured providers in order.
    button(fallback,"🔄 Probar proveedores configurados",function()
        local order={"Gemini","Groq","OpenRouter","Cerebras"}
        local found=false
        for _,name in ipairs(order) do
            local p=Providers[name]
            if p.key~="" then
                found=true
                local answer,err=ask(name,"Respondé exactamente: SERAPH_"..name.."_OK")
                if answer then
                    show("✅ "..name.." disponible.")
                    return
                else
                    warn("[SERAPH AI] "..name.." falló: "..tostring(err))
                end
            end
        end
        if not found then show("No hay proveedores configurados. Agregá al menos una API Key.") end
    end)

    button(fallback,"🧠 Auto Ask (fallback)",function()
        if question=="" then show("Escribí una pregunta."); return end
        local order={"Gemini","Groq","OpenRouter","Cerebras"}
        for _,name in ipairs(order) do
            if Providers[name].key~="" then
                local answer,err=ask(name,question)
                if answer then
                    selected=name
                    show("["..name.."] "..answer)
                    return
                end
                warn("[SERAPH AI] fallback "..name..": "..tostring(err))
            end
        end
        show("❌ Ningún proveedor configurado respondió.")
    end)

    button(fallback,"📊 Provider Status",function()
        print("========== SERAPH AI PROVIDERS ==========")
        for name,p in pairs(Providers) do
            print(name,"key="..(p.key~="" and "CONFIGURED" or "EMPTY"),"model="..tostring(p.model))
        end
        print("=========================================")
    end)

    pcall(function()
        local env=getgenv and getgenv() or _G
        env.SERAPH_AI_FREE=env.SERAPH_AI_FREE or {}
        env.SERAPH_AI_FREE.Providers=Providers
        env.SERAPH_AI_FREE.Ask=ask
        env.SERAPH_AI_FREE.State={Selected=function() return selected end,History=history}
    end)
end)


-- ============================================================
-- SERAPH AI ROUTER PRO
-- Hugging Face + routing inteligente + límites locales +
-- estadísticas + protección básica de claves.
-- ============================================================
task.defer(function()
    local HttpService = game:GetService("HttpService")
    if not window then return end

    local ok, tab = pcall(function() return window:AddTab("🧠 AI ROUTER PRO") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2,f=pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function switch(f,n,fn)
        if f and f.AddSwitch then pcall(f.AddSwitch,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok3,x=pcall(f.AddLabel,f,t)
            if ok3 then return x end
        end
    end
    local function textBox(f,n,fn)
        if f and f.AddTextBox then pcall(f.AddTextBox,f,n,fn) end
    end

    local cfg = {
        HuggingFaceKey="",
        dailyLimit=50,
        autoRoute=true,
        safeKeys=true,
    }

    local stats = {}
    local providers = {
        Gemini=true, Groq=true, OpenRouter=true, Cerebras=true, HuggingFace=true
    }

    local function getStats(name)
        stats[name]=stats[name] or {
            requests=0, success=0, fail=0, lastLatency=0, lastError=""
        }
        return stats[name]
    end

    -- HF Inference Providers uses an HF token and an OpenAI-compatible
    -- chat-completions interface for supported models.
    local function requestFn()
        if type(request)=="function" then return request end
        if syn and type(syn.request)=="function" then return syn.request end
        if http and type(http.request)=="function" then return http.request end
        if fluxus and type(fluxus.request)=="function" then return fluxus.request end
    end

    local function httpPost(url,body,headers)
        local req=requestFn()
        if not req then return nil,"No hay función HTTP disponible en este entorno." end
        local ok2,res=pcall(req,{
            Url=url,Method="POST",
            Headers=headers,
            Body=HttpService:JSONEncode(body)
        })
        if not ok2 or type(res)~="table" then return nil,tostring(res) end
        local status=tonumber(res.StatusCode or res.Status or 0) or 0
        local raw=res.Body or res.body or ""
        if status>=400 then return nil,"HTTP "..status..": "..string.sub(raw,1,400) end
        local ok3,data=pcall(HttpService.JSONDecode,HttpService,raw)
        if not ok3 then return nil,"JSON inválido" end
        return data
    end

    local function askHF(prompt,model)
        if cfg.HuggingFaceKey=="" then
            return nil,"Falta Hugging Face User Access Token."
        end
        model=model~="" and model or "Qwen/Qwen2.5-72B-Instruct"
        local t=os.clock()
        local data,err=httpPost(
            "https://router.huggingface.co/v1/chat/completions",
            {
                model=model,
                messages={
                    {role="system",content="You are SERAPH HUB AI. Be concise, practical and honest about uncertainty."},
                    {role="user",content=prompt}
                },
                temperature=0.2
            },
            {
                ["Content-Type"]="application/json",
                ["Authorization"]="Bearer "..cfg.HuggingFaceKey
            }
        )
        local s=getStats("HuggingFace")
        s.requests+=1
        s.lastLatency=math.floor((os.clock()-t)*1000)
        if not data then
            s.fail+=1; s.lastError=tostring(err)
            return nil,err
        end
        local answer=data.choices
            and data.choices[1]
            and data.choices[1].message
            and data.choices[1].message.content
        if not answer then
            s.fail+=1; s.lastError="Respuesta sin contenido"
            return nil,s.lastError
        end
        s.success+=1
        return answer
    end

    local setup=folder("⚙️ Router Settings")
    local monitor=folder("📊 AI Monitor")
    local security=folder("🔐 Key Safety")
    local routing=folder("🧠 Smart Router")

    textBox(setup,"🔑 Hugging Face Token",function(v)
        cfg.HuggingFaceKey=tostring(v or "")
    end)

    textBox(setup,"🔢 Local Daily Limit",function(v)
        local n=tonumber(v)
        if n and n>=1 and n<=10000 then cfg.dailyLimit=math.floor(n) end
    end)

    switch(setup,"🧠 Automatic Routing",function(v)
        cfg.autoRoute=v==true
    end)

    switch(setup,"🔐 Hide Keys From Logs",function(v)
        cfg.safeKeys=v==true
    end)

    local monitorLabel=label(monitor,"Requests: 0 | Success: 0 | Failed: 0")

    local function totalStats()
        local r,s,f=0,0,0
        for _,x in pairs(stats) do
            r+=x.requests; s+=x.success; f+=x.fail
        end
        return r,s,f
    end

    local function refreshMonitor()
        local r,s,f=totalStats()
        if monitorLabel then
            pcall(function()
                monitorLabel.Text=string.format(
                    "Requests: %d | Success: %d | Failed: %d | HF: %d",
                    r,s,f,getStats("HuggingFace").requests
                )
            end)
        end
    end

    button(monitor,"🔄 Refresh Statistics",refreshMonitor)

    button(monitor,"📈 Print Provider Statistics",function()
        print("========== SERAPH AI STATS ==========")
        for name,x in pairs(stats) do
            print(
                name,
                "requests=",x.requests,
                "success=",x.success,
                "failed=",x.fail,
                "latency=",x.lastLatency.."ms"
            )
            if x.lastError~="" then print(" lastError=",x.lastError) end
        end
        print("=====================================")
    end)

    button(monitor,"🧹 Reset Local Statistics",function()
        table.clear(stats)
        refreshMonitor()
    end)

    button(security,"🔒 Clear All Entered Keys",function()
        cfg.HuggingFaceKey=""
        -- No se intenta borrar las claves de los módulos anteriores;
        -- sólo las de este router.
        print("[SERAPH] Hugging Face token cleared from memory.")
    end)

    button(security,"⚠️ Show Key Safety Info",function()
        print("SERAPH KEY SAFETY")
        print("No keys are hard-coded by this module.")
        print("Keys entered into a client-side executor are not truly secret.")
        print("Use restricted/scoped keys and revoke them if exposed.")
    end)

    local routeLabel=label(routing,"Router: esperando...")

    -- OpenRouter free pool is useful as an explicit free fallback.
    -- Its free account currently has a published 50 requests/day limit.
    local routeOrder={"Gemini","Groq","OpenRouter","Cerebras","HuggingFace"}

    local function providerConfigured(name)
        if name=="HuggingFace" then return cfg.HuggingFaceKey~="" end
        return true
    end

    local function smartRoute(prompt)
        if prompt=="" then return nil,"Pregunta vacía" end
        local attempted={}
        for _,name in ipairs(routeOrder) do
            if providerConfigured(name) then
                attempted[#attempted+1]=name
                if name=="HuggingFace" then
                    local answer,err=askHF(prompt,"")
                    if answer then return answer,name end
                    warn("[SERAPH ROUTER] "..name..": "..tostring(err))
                else
                    -- Reuse the existing SERAPH_AI_FREE provider implementation
                    -- when it is present.
                    local env=getgenv and getgenv() or _G
                    local api=env.SERAPH_AI_FREE
                    if api and type(api.Ask)=="function" then
                        local answer,err=api.Ask(name,prompt)
                        local s=getStats(name)
                        s.requests+=1
                        if answer then
                            s.success+=1
                            return answer,name
                        end
                        s.fail+=1
                        s.lastError=tostring(err)
                    end
                end
            end
        end
        return nil,"Ningún proveedor respondió. Intentados: "..table.concat(attempted,", ")
    end

    textBox(routing,"💬 Test Prompt",function(v)
        cfg.testPrompt=tostring(v or "")
    end)

    button(routing,"🚀 Smart Route Test",function()
        local prompt=cfg.testPrompt or "Respondé solamente: SERAPH_ROUTER_OK"
        if routeLabel then routeLabel.Text="Router: probando..." end
        task.spawn(function()
            local answer,name=smartRoute(prompt)
            if answer then
                if routeLabel then routeLabel.Text="Router: "..name.." ✓" end
                print("[SERAPH SMART ROUTER]["..name.."] "..answer)
            else
                if routeLabel then routeLabel.Text="Router: ERROR" end
                warn("[SERAPH SMART ROUTER] "..tostring(name))
            end
            refreshMonitor()
        end)
    end)

    button(routing,"🔍 Print Routing Order",function()
        print("========== ROUTING ORDER ==========")
        for i,name in ipairs(routeOrder) do
            print(i,name,providerConfigured(name) and "READY" or "NOT CONFIGURED")
        end
        print("===================================")
    end)

    button(routing,"🧠 Test Hugging Face",function()
        if cfg.HuggingFaceKey=="" then
            warn("[SERAPH HF] Token not configured.")
            return
        end
        task.spawn(function()
            local answer,err=askHF("Respondé exactamente: SERAPH_HF_OK","")
            if answer then print("[SERAPH HF]",answer) else warn("[SERAPH HF]",err) end
            refreshMonitor()
        end)
    end)

    pcall(function()
        local env=getgenv and getgenv() or _G
        env.SERAPH_AI_ROUTER_PRO=env.SERAPH_AI_ROUTER_PRO or {}
        env.SERAPH_AI_ROUTER_PRO.Config=cfg
        env.SERAPH_AI_ROUTER_PRO.Providers=providers
        env.SERAPH_AI_ROUTER_PRO.Stats=stats
        env.SERAPH_AI_ROUTER_PRO.SmartRoute=smartRoute
        env.SERAPH_AI_ROUTER_PRO.AskHuggingFace=askHF
    end)

    refreshMonitor()
end)


-- ============================================================
-- SERAPH GAME ANALYZER PRO
-- Analiza el entorno accesible, detecta sistemas y problemas
-- de integración del propio hub. No ejecuta código generado
-- automáticamente ni intenta acceder a remotos privados.
-- ============================================================
task.defer(function()
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Workspace = game:GetService("Workspace")
    local Lighting = game:GetService("Lighting")
    local StarterGui = game:GetService("StarterGui")
    local SoundService = game:GetService("SoundService")
    local HttpService = game:GetService("HttpService")
    local player = Players.LocalPlayer

    if not window or not player then return end

    local ok, tab = pcall(function() return window:AddTab("🔍 GAME ANALYZER") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2,f=pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function switch(f,n,fn)
        if f and f.AddSwitch then pcall(f.AddSwitch,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok3,x=pcall(f.AddLabel,f,t)
            if ok3 then return x end
        end
    end

    local Analyzer = {
        running=false,
        deep=false,
        results={},
        warnings={},
        errors={},
        suggestions={},
        startedAt=0,
        maxInstances=2500,
    }

    local statusFolder=folder("📊 Analysis Status")
    local statusLabel=label(statusFolder,"Estado: listo")
    local summaryLabel=label(statusFolder,"Sin análisis.")

    local function setStatus(text)
        if statusLabel then pcall(function() statusLabel.Text="Estado: "..text end) end
    end

    local function addResult(category,name,detail)
        Analyzer.results[#Analyzer.results+1]={
            category=tostring(category),
            name=tostring(name),
            detail=tostring(detail or "")
        }
    end

    local function warnResult(text)
        Analyzer.warnings[#Analyzer.warnings+1]=tostring(text)
    end

    local function errorResult(text)
        Analyzer.errors[#Analyzer.errors+1]=tostring(text)
    end

    local function classify(name,className)
        local n=string.lower(name.." "..className)
        local tags={}
        local map={
            Quest={"quest","mission","objective"},
            Shop={"shop","store","merchant","vendor"},
            NPC={"npc","dummy","character"},
            Pet={"pet","egg","hatch"},
            Reward={"reward","chest","crate","claim","daily"},
            Vehicle={"vehicle","car","boat","bike"},
            Tool={"tool","weapon","sword","gun"},
            Teleport={"teleport","portal","spawn","checkpoint"},
            UI={"gui","ui","screen","menu"},
            Movement={"movement","walk","jump","fly","speed"},
            Mining={"mine","rock","ore","resource"},
            Farming={"farm","crop","plant","harvest"},
            Combat={"combat","damage","enemy","boss"},
            Currency={"coin","cash","money","currency","gem"},
        }
        for tag,words in pairs(map) do
            for _,word in ipairs(words) do
                if string.find(n,word,1,true) then
                    tags[#tags+1]=tag
                    break
                end
            end
        end
        return tags
    end

    local function scanContainer(container,depth)
        local count=0
        local ok2,desc=pcall(function() return container:GetDescendants() end)
        if not ok2 or type(desc)~="table" then
            warnResult("No se pudo inspeccionar "..container:GetFullName())
            return 0
        end

        for _,obj in ipairs(desc) do
            count+=1
            if count>Analyzer.maxInstances then
                warnResult("Límite de instancias alcanzado en "..container.Name)
                break
            end
            local tags=classify(obj.Name,obj.ClassName)
            if #tags>0 then
                addResult(table.concat(tags,"/"),obj:GetFullName(),obj.ClassName)
            end
            if obj:IsA("ModuleScript") then
                addResult("Module",obj:GetFullName(),"ModuleScript accesible para inspección nominal")
            elseif obj:IsA("RemoteEvent") or obj:IsA("RemoteFunction") then
                -- Sólo inventario nominal; no invocación.
                addResult("RemoteInventory",obj:GetFullName(),obj.ClassName)
            end
        end
        return count
    end

    local function summarize()
        local counts={}
        for _,r in ipairs(Analyzer.results) do
            for tag in string.gmatch(r.category,"[^/]+") do
                counts[tag]=(counts[tag] or 0)+1
            end
        end
        local parts={}
        for k,v in pairs(counts) do parts[#parts+1]=k..":"..v end
        table.sort(parts)
        return #Analyzer.results.." elementos | "..table.concat(parts," | ")
    end

    local function runAnalysis()
        if Analyzer.running then return end
        Analyzer.running=true
        Analyzer.results={}
        Analyzer.warnings={}
        Analyzer.errors={}
        Analyzer.suggestions={}
        Analyzer.startedAt=os.clock()
        setStatus("analizando...")
        summaryLabel.Text="Escaneando servicios accesibles..."

        local roots={
            Workspace,ReplicatedStorage,Lighting,StarterGui,SoundService
        }

        local total=0
        for _,root in ipairs(roots) do
            local ok2,n=pcall(scanContainer,root,0)
            if ok2 then total+=n else errorResult("Error en "..root.Name..": "..tostring(n)) end
            task.wait()
        end

        -- Información básica del contexto, sin acceder a datos privados.
        addResult("GameInfo","PlaceId",game.PlaceId)
        addResult("GameInfo","JobId",game.JobId)
        addResult("GameInfo","Players",#Players:GetPlayers())
        addResult("GameInfo","LocalPlayer",player.Name)

        local elapsed=math.floor((os.clock()-Analyzer.startedAt)*1000)
        summaryLabel.Text=summarize()
        setStatus("completo | "..total.." instancias | "..elapsed.." ms")
        Analyzer.running=false

        -- Heurísticas de sugerencias.
        local found={}
        for _,r in ipairs(Analyzer.results) do
            for tag in string.gmatch(r.category,"[^/]+") do found[tag]=true end
        end
        if found.Quest then Analyzer.suggestions[#Analyzer.suggestions+1]="Agregar Quest Tracker (informativo)." end
        if found.Shop then Analyzer.suggestions[#Analyzer.suggestions+1]="Agregar Shop Browser (informativo)." end
        if found.Reward then Analyzer.suggestions[#Analyzer.suggestions+1]="Agregar Reward/Chest Tracker (informativo)." end
        if found.Pet then Analyzer.suggestions[#Analyzer.suggestions+1]="Agregar Pet/Egg Tracker (informativo)." end
        if found.Vehicle then Analyzer.suggestions[#Analyzer.suggestions+1]="Agregar Vehicle Tracker (informativo)." end
        if found.NPC then Analyzer.suggestions[#Analyzer.suggestions+1]="Agregar NPC/Zone Browser." end
        if found.Currency then Analyzer.suggestions[#Analyzer.suggestions+1]="Agregar Currency Monitor." end
        if found.Mining then Analyzer.suggestions[#Analyzer.suggestions+1]="Agregar Resource Monitor." end
        if found.UI then Analyzer.suggestions[#Analyzer.suggestions+1]="Agregar UI Inspector." end
        if #Analyzer.suggestions==0 then
            Analyzer.suggestions[#Analyzer.suggestions+1]="No se encontraron sistemas claros por nombre."
        end
    end

    local scan=folder("🔎 Scanner")
    switch(scan,"🧪 Deep Scan",function(v) Analyzer.deep=v==true end)
    button(scan,"▶ Run Game Analysis",runAnalysis)

    button(scan,"📋 Print Detected Systems",function()
        print("========== SERAPH GAME ANALYZER ==========")
        for _,r in ipairs(Analyzer.results) do
            print("["..r.category.."] "..r.name.." | "..r.detail)
        end
        print("==========================================")
    end)

    local suggest=folder("💡 Suggestions")
    button(suggest,"💡 Show Suggested Features",function()
        print("========== SUGGESTED FEATURES ==========")
        for i,s in ipairs(Analyzer.suggestions) do print(i..". "..s) end
        print("========================================")
    end)

    local diag=folder("🩺 Hub Compatibility")
    button(diag,"🧪 Check SERAPH Modules",function()
        local env=getgenv and getgenv() or _G
        local checks={
            {"AI Free Router",env.SERAPH_AI_FREE~=nil},
            {"AI Router Pro",env.SERAPH_AI_ROUTER_PRO~=nil},
            {"Module Manager",env.SERAPH_MODULE_MANAGER~=nil},
            {"Ultra",env.SERAPH_ULTRA~=nil},
        }
        print("========== SERAPH COMPATIBILITY ==========")
        for _,c in ipairs(checks) do
            print(c[1],c[2] and "OK" or "MISSING")
        end
        print("==========================================")
    end)

    button(diag,"🧹 Validate Runtime Services",function()
        local services={
            {"Players",Players},
            {"RunService",RunService},
            {"ReplicatedStorage",ReplicatedStorage},
            {"Workspace",Workspace},
            {"Lighting",Lighting},
            {"StarterGui",StarterGui},
            {"SoundService",SoundService},
            {"HttpService",HttpService},
        }
        local failures=0
        for _,x in ipairs(services) do
            if x[2] then print("✓",x[1]) else print("✗",x[1]); failures+=1 end
        end
        print("Failures:",failures)
    end)

    local ai=folder("🤖 AI Analysis")
    local aiPrompt=""
    local aiLabel=label(ai,"IA: esperando análisis.")

    local function buildReport()
        local lines={
            "SERAPH GAME ANALYZER REPORT",
            "PlaceId="..tostring(game.PlaceId),
            "Players="..tostring(#Players:GetPlayers()),
            "Summary="..summarize(),
            "Warnings="..#Analyzer.warnings,
            "Errors="..#Analyzer.errors,
            "Detected systems:"
        }
        for i,r in ipairs(Analyzer.results) do
            if i>300 then break end
            lines[#lines+1]="- ["..r.category.."] "..r.name.." | "..r.detail
        end
        lines[#lines+1]="Suggestions:"
        for _,s in ipairs(Analyzer.suggestions) do lines[#lines+1]="- "..s end
        return table.concat(lines,"\n")
    end

    button(ai,"🧠 Prepare AI Diagnostic",function()
        aiPrompt=buildReport()
        if aiLabel then
            aiLabel.Text="IA: reporte preparado ("..#aiPrompt.." caracteres)."
        end
        print(aiPrompt)
    end)

    button(ai,"🤖 Send To SERAPH AI Router",function()
        local env=getgenv and getgenv() or _G
        local router=env.SERAPH_AI_ROUTER_PRO
        if not router or type(router.SmartRoute)~="function" then
            warn("[SERAPH AI] AI Router Pro no está disponible.")
            return
        end
        local report=aiPrompt~="" and aiPrompt or buildReport()
        task.spawn(function()
            local answer,provider=router.SmartRoute(
                "Analiza este reporte del juego y del hub. "
                .."Devuelve sólo problemas de compatibilidad, mejoras "
                .."seguras y funciones informativas posibles. "
                .."No generes ni ejecutes código automáticamente.\n\n"..report
            )
            if answer then
                print("========== AI GAME DIAGNOSIS ==========")
                print("Provider:",provider)
                print(answer)
                print("=======================================")
                if aiLabel then aiLabel.Text="IA: diagnóstico recibido de "..tostring(provider) end
            else
                warn("[SERAPH AI] "..tostring(provider))
            end
        end)
    end)

    -- Exporta un informe JSON para que otros módulos puedan procesarlo.
    button(ai,"💾 Export Analysis JSON",function()
        local payload={
            placeId=game.PlaceId,
            player=player.Name,
            summary=summarize(),
            results=Analyzer.results,
            warnings=Analyzer.warnings,
            errors=Analyzer.errors,
            suggestions=Analyzer.suggestions,
        }
        local ok2,data=pcall(HttpService.JSONEncode,HttpService,payload)
        if ok2 then
            print("========== SERAPH ANALYSIS JSON ==========")
            print(data)
            print("==========================================")
        end
    end)

    pcall(function()
        local env=getgenv and getgenv() or _G
        env.SERAPH_GAME_ANALYZER=env.SERAPH_GAME_ANALYZER or {}
        env.SERAPH_GAME_ANALYZER.State=Analyzer
        env.SERAPH_GAME_ANALYZER.Run=runAnalysis
        env.SERAPH_GAME_ANALYZER.Report=buildReport
    end)
end)


-- ============================================================
-- SERAPH ULTIMATE AI SUITE
-- Knowledge snapshots + diff + health monitor + compatibility
-- + crash recovery + performance profiler + optimizer preview.
-- ============================================================
task.defer(function()
    local Players = game:GetService("Players")
    local RunService = game:GetService("RunService")
    local HttpService = game:GetService("HttpService")
    local player = Players.LocalPlayer
    if not window or not player then return end

    local ok, tab = pcall(function() return window:AddTab("⚡ ULTIMATE SUITE") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2,f=pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function switch(f,n,fn)
        if f and f.AddSwitch then pcall(f.AddSwitch,f,n,fn) end
    end
    local function textBox(f,n,fn)
        if f and f.AddTextBox then pcall(f.AddTextBox,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok3,x=pcall(f.AddLabel,f,t)
            if ok3 then return x end
        end
    end

    local Suite = {
        snapshots={},
        health={},
        crashes={},
        profiler={},
        autoRescan=false,
        crashThreshold=3,
        snapshotLimit=10,
        lastScanHash="",
    }

    -- ---------- Knowledge Base ----------
    local kb=folder("🧠 Game Knowledge")
    local kbLabel=label(kb,"Snapshots: 0 | Último análisis: ninguno")

    local function getAnalyzer()
        local env=getgenv and getgenv() or _G
        return env.SERAPH_GAME_ANALYZER
    end

    local function currentReport()
        local analyzer=getAnalyzer()
        if analyzer and type(analyzer.Report)=="function" then
            local ok2,r=pcall(analyzer.Report)
            if ok2 then return tostring(r) end
        end
        return "No hay un análisis disponible."
    end

    local function hashText(text)
        local h=0
        for i=1,#text do h=(h*31+string.byte(text,i))%2147483647 end
        return tostring(h)
    end

    local function takeSnapshot(reason)
        local report=currentReport()
        local snap={
            id=#Suite.snapshots+1,
            time=os.date("%Y-%m-%d %H:%M:%S"),
            reason=reason or "manual",
            hash=hashText(report),
            report=report
        }
        Suite.snapshots[#Suite.snapshots+1]=snap
        while #Suite.snapshots>Suite.snapshotLimit do
            table.remove(Suite.snapshots,1)
        end
        Suite.lastScanHash=snap.hash
        if kbLabel then
            pcall(function()
                kbLabel.Text="Snapshots: "..#Suite.snapshots.." | Último: "..snap.time
            end)
        end
        return snap
    end

    button(kb,"📸 Create Snapshot",function()
        takeSnapshot("manual")
    end)

    button(kb,"📋 List Snapshots",function()
        print("========== SERAPH SNAPSHOTS ==========")
        for _,s in ipairs(Suite.snapshots) do
            print("#"..s.id,s.time,s.reason,s.hash)
        end
        print("======================================")
    end)

    button(kb,"↩️ Restore Snapshot Info",function()
        local s=Suite.snapshots[#Suite.snapshots]
        if not s then warn("[SERAPH] No hay snapshots.") return end
        print("========== LAST SNAPSHOT ==========")
        print(s.report)
        print("===================================")
        warn("[SERAPH] Snapshot mostrado. El sistema no sobrescribe el script automáticamente.")
    end)

    -- ---------- Diff ----------
    local diff=folder("🔀 Diff Viewer")
    local function diffLines(a,b)
        local A,B={},{}
        for line in tostring(a):gmatch("[^\n]+") do A[#A+1]=line end
        for line in tostring(b):gmatch("[^\n]+") do B[#B+1]=line end
        local setA={}
        for _,line in ipairs(A) do setA[line]=true end
        local setB={}
        for _,line in ipairs(B) do setB[line]=true end
        local added,removed=0,0
        for _,line in ipairs(B) do
            if not setA[line] then added+=1 end
        end
        for _,line in ipairs(A) do
            if not setB[line] then removed+=1 end
        end
        return added,removed
    end

    button(diff,"🔎 Compare Last Two Snapshots",function()
        if #Suite.snapshots<2 then
            warn("[SERAPH] Necesitás al menos dos snapshots.")
            return
        end
        local a=Suite.snapshots[#Suite.snapshots-1]
        local b=Suite.snapshots[#Suite.snapshots]
        local added,removed=diffLines(a.report,b.report)
        print("========== SERAPH DIFF ==========")
        print("Before:",a.time,a.hash)
        print("After :",b.time,b.hash)
        print("Added lines:",added)
        print("Removed lines:",removed)
        print("=================================")
    end)

    -- ---------- Function Health ----------
    local health=folder("🩺 Function Health")
    local healthLabel=label(health,"Health: esperando...")

    local function checkHealth()
        local env=getgenv and getgenv() or _G
        local checks={
            ["Game Analyzer"]=env.SERAPH_GAME_ANALYZER~=nil,
            ["AI Router"]=env.SERAPH_AI_ROUTER_PRO~=nil,
            ["AI Free"]=env.SERAPH_AI_FREE~=nil,
            ["Module Manager"]=env.SERAPH_MODULE_MANAGER~=nil,
            ["Ultra"]=env.SERAPH_ULTRA~=nil,
        }
        Suite.health=checks
        local okCount,total=0,0
        for _,v in pairs(checks) do total+=1 if v then okCount+=1 end end
        if healthLabel then
            healthLabel.Text=string.format("Health: %d/%d módulos disponibles",okCount,total)
        end
        return checks
    end

    button(health,"🧪 Run Health Check",function()
        local checks=checkHealth()
        print("========== SERAPH HEALTH ==========")
        for n,v in pairs(checks) do print(v and "🟢" or "🔴",n) end
        print("===================================")
    end)

    button(health,"🧾 Print Health Report",function()
        checkHealth()
        for n,v in pairs(Suite.health) do print(n,v and "OK" or "MISSING") end
    end)

    -- ---------- Compatibility Matrix ----------
    local compat=folder("🧩 Compatibility Matrix")
    button(compat,"📊 Generate Matrix",function()
        local env=getgenv and getgenv() or _G
        local matrix={
            {"Core",true,{}},
            {"GUI",window~=nil,{"Core"}},
            {"Diagnostics",env.SERAPH_ULTRA~=nil,{"Core"}},
            {"AI Router",env.SERAPH_AI_ROUTER_PRO~=nil,{"Core","Diagnostics"}},
            {"Game Analyzer",env.SERAPH_GAME_ANALYZER~=nil,{"Core"}},
            {"Module Manager",env.SERAPH_MODULE_MANAGER~=nil,{"Core"}},
        }
        print("========== COMPATIBILITY MATRIX ==========")
        for _,row in ipairs(matrix) do
            print(row[2] and "🟢" or "🔴",row[1],"deps:",table.concat(row[3],", "))
        end
        print("==========================================")
    end)

    -- ---------- Crash Recovery ----------
    local recovery=folder("🚨 Crash Recovery")
    local recoveryLabel=label(recovery,"Crash threshold: "..Suite.crashThreshold)

    textBox(recovery,"🔢 Crash Threshold",function(v)
        local n=tonumber(v)
        if n and n>=1 and n<=20 then
            Suite.crashThreshold=math.floor(n)
            recoveryLabel.Text="Crash threshold: "..Suite.crashThreshold
        end
    end)

    local function recordCrash(moduleName,err)
        local key=tostring(moduleName)
        Suite.crashes[key]=Suite.crashes[key] or {count=0,last=""}
        Suite.crashes[key].count+=1
        Suite.crashes[key].last=tostring(err)
        warn("[SERAPH CRASH] "..key.." #"..Suite.crashes[key].count..": "..tostring(err))
        if Suite.crashes[key].count>=Suite.crashThreshold then
            warn("[SERAPH CRASH] "..key.." superó el límite. Se recomienda Safe Mode.")
        end
    end

    button(recovery,"🧪 Test Recovery System",function()
        recordCrash("TEST_MODULE","Simulated diagnostic error")
    end)

    button(recovery,"📋 Print Crash Report",function()
        print("========== CRASH REPORT ==========")
        for n,x in pairs(Suite.crashes) do
            print(n,"count=",x.count,"last=",x.last)
        end
        print("==================================")
    end)

    button(recovery,"🛡️ Safe Recovery",function()
        local env=getgenv and getgenv() or _G
        if env.SERAPH_ULTRA and env.SERAPH_ULTRA.State then
            env.SERAPH_ULTRA.State.safeMode=true
        end
        if env.SERAPH_MODULE_MANAGER and env.SERAPH_MODULE_MANAGER.Modules then
            for n,m in pairs(env.SERAPH_MODULE_MANAGER.Modules) do
                m.enabled=(n=="Core" or n=="GUI" or n=="Diagnostics" or n=="Recovery")
            end
        end
        warn("[SERAPH] Safe Recovery activado.")
    end)

    -- ---------- Performance Profiler ----------
    local perf=folder("📈 Performance Profiler")
    local perfLabel=label(perf,"Profiler: detenido")
    local profileRunning=false
    local profileData={frames=0,start=0,elapsed=0}

    button(perf,"▶ Start 10s Profile",function()
        if profileRunning then return end
        profileRunning=true
        profileData={frames=0,start=os.clock(),elapsed=0}
        local conn
        conn=RunService.Heartbeat:Connect(function()
            if profileRunning then profileData.frames+=1 end
        end)
        task.delay(10,function()
            profileRunning=false
            profileData.elapsed=os.clock()-profileData.start
            if conn then conn:Disconnect() end
            local fps=profileData.frames/math.max(profileData.elapsed,0.001)
            if perfLabel then
                perfLabel.Text=string.format("Profiler: %.1f Heartbeats/s",fps)
            end
            print("[SERAPH PROFILER] Average Heartbeats/s:",fps)
        end)
    end)

    button(perf,"📊 Print Performance",function()
        print("Frames:",profileData.frames)
        print("Elapsed:",profileData.elapsed)
        if profileData.elapsed>0 then print("Rate:",profileData.frames/profileData.elapsed) end
    end)

    -- ---------- Optimizer ----------
    local opt=folder("⚙️ AI Optimizer")
    local optLabel=label(opt,"Optimizer: esperando análisis.")

    local function buildOptimizationReport()
        local suggestions={}
        local analyzer=getAnalyzer()
        local report=currentReport()
        if #report>100000 then report=string.sub(report,1,100000) end

        -- Conservative heuristics: suggestions only, never automatic rewriting.
        local function countWord(word)
            local n=0
            for _ in report:gmatch(word) do n+=1 end
            return n
        end

        if countWord("Heartbeat")>30 then
            suggestions[#suggestions+1]="Revisar loops Heartbeat numerosos."
        end
        if countWord("while task.wait")>20 then
            suggestions[#suggestions+1]="Revisar loops task.wait repetidos."
        end
        if countWord("GetDescendants")>10 then
            suggestions[#suggestions+1]="Cachear resultados de GetDescendants cuando sea posible."
        end
        if countWord("RemoteInventory")>0 then
            suggestions[#suggestions+1]="Mantener inventario de remotos sólo como diagnóstico nominal."
        end
        if #suggestions==0 then
            suggestions[#suggestions+1]="No se detectaron optimizaciones conservadoras por heurística."
        end
        return suggestions
    end

    button(opt,"🔎 Analyze Optimization Opportunities",function()
        local suggestions=buildOptimizationReport()
        print("========== SERAPH OPTIMIZER ==========")
        for i,s in ipairs(suggestions) do print(i..". "..s) end
        print("======================================")
        if optLabel then optLabel.Text="Optimizer: "..#suggestions.." recomendaciones." end
    end)

    button(opt,"🤖 Send Optimization Report To AI",function()
        local env=getgenv and getgenv() or _G
        local router=env.SERAPH_AI_ROUTER_PRO
        if not router or type(router.SmartRoute)~="function" then
            warn("[SERAPH] AI Router Pro no disponible.")
            return
        end
        local suggestions=buildOptimizationReport()
        local prompt="Analiza estas recomendaciones del hub y priorizalas. "
            .."No generes código ejecutable; devuelve una lista de cambios seguros "
            .."con riesgo bajo/medio/alto.\n"..table.concat(suggestions,"\n")
        task.spawn(function()
            local answer,provider=router.SmartRoute(prompt)
            if answer then
                print("========== AI OPTIMIZER ==========")
                print("Provider:",provider)
                print(answer)
                print("==================================")
            else
                warn("[SERAPH AI] "..tostring(provider))
            end
        end)
    end)

    -- ---------- Auto Rescan ----------
    local auto=folder("🔄 Auto Re-Scan")
    switch(auto,"🔄 Enable Auto Re-Scan",function(v)
        Suite.autoRescan=v==true
    end)

    task.spawn(function()
        while task.wait(60) do
            if Suite.autoRescan then
                local analyzer=getAnalyzer()
                if analyzer and type(analyzer.Run)=="function" then
                    pcall(analyzer.Run)
                    local report=currentReport()
                    local h=hashText(report)
                    if h~=Suite.lastScanHash then
                        takeSnapshot("auto-rescan change")
                    end
                end
            end
        end
    end)

    -- ---------- Export ----------
    local export=folder("💾 Suite Export")
    button(export,"💾 Export Suite State",function()
        local payload={
            time=os.date("%Y-%m-%d %H:%M:%S"),
            snapshots=Suite.snapshots,
            health=Suite.health,
            crashes=Suite.crashes,
            profiler=profileData,
            autoRescan=Suite.autoRescan
        }
        local ok2,data=pcall(HttpService.JSONEncode,HttpService,payload)
        if ok2 then
            print("========== SERAPH SUITE JSON ==========")
            print(data)
            print("=======================================")
        end
    end)

    pcall(function()
        local env=getgenv and getgenv() or _G
        env.SERAPH_ULTIMATE_SUITE=env.SERAPH_ULTIMATE_SUITE or {}
        env.SERAPH_ULTIMATE_SUITE.State=Suite
        env.SERAPH_ULTIMATE_SUITE.Snapshot=takeSnapshot
        env.SERAPH_ULTIMATE_SUITE.Health=checkHealth
        env.SERAPH_ULTIMATE_SUITE.RecordCrash=recordCrash
        env.SERAPH_ULTIMATE_SUITE.Optimize=buildOptimizationReport
    end)

    checkHealth()
end)


-- ============================================================
-- SERAPH AUTONOMOUS AI ENGINE
-- Modo autónomo para el PROPIO HUB:
-- analiza -> propone -> genera parche -> backup -> aplica ->
-- valida -> rollback si falla.
-- No ejecuta código remoto ni invoca remotos encontrados.
-- ============================================================
task.defer(function()
    local HttpService = game:GetService("HttpService")
    if not window then return end

    local ok, tab = pcall(function() return window:AddTab("🤖 AUTONOMOUS AI") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2,f=pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function switch(f,n,fn)
        if f and f.AddSwitch then pcall(f.AddSwitch,f,n,fn) end
    end
    local function textBox(f,n,fn)
        if f and f.AddTextBox then pcall(f.AddTextBox,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok3,x=pcall(f.AddLabel,f,t)
            if ok3 then return x end
        end
    end

    local State={
        enabled=false,
        autoFix=false,
        requireBackup=true,
        maxPatchSize=12000,
        lastPatch="",
        lastReason="",
        backups={},
        applied=0,
        rolledBack=0,
    }

    local cfg=folder("⚙️ Autonomous Settings")
    local status=label(cfg,"Estado: detenido")

    switch(cfg,"🤖 Autonomous Mode",function(v)
        State.enabled=v==true
        if status then status.Text="Estado: "..(State.enabled and "ACTIVO" or "detenido") end
    end)

    switch(cfg,"🔧 Auto Fix Own Hub",function(v)
        State.autoFix=v==true
    end)

    switch(cfg,"💾 Mandatory Backup",function(v)
        State.requireBackup=v==true
    end)

    textBox(cfg,"📏 Max Patch Size",function(v)
        local n=tonumber(v)
        if n and n>=1000 and n<=50000 then State.maxPatchSize=math.floor(n) end
    end)

    -- Patch queue. A patch is only accepted when it is explicitly marked
    -- as a SERAPH-OWN-HUB patch and contains a Lua function body.
    local queue=folder("🧩 Patch Queue")
    local patchLabel=label(queue,"Patch: ninguno")

    local function queuePatch(reason,source,patch)
        patch=tostring(patch or "")
        if #patch>State.maxPatchSize then
            return false,"Patch demasiado grande"
        end
        if not string.find(patch,"SERAPH_OWN_HUB_PATCH",1,true) then
            return false,"Falta marca SERAPH_OWN_HUB_PATCH"
        end
        State.lastReason=tostring(reason or "")
        State.lastPatch=patch
        if patchLabel then
            patchLabel.Text="Patch preparado: "..#patch.." caracteres"
        end
        return true
    end

    -- The AI Router can be used to create a patch proposal. The generated
    -- text is treated as data until validated by the patch gate.
    button(queue,"🧠 Ask AI For Own-Hub Patch",function()
        local env=getgenv and getgenv() or _G
        local router=env.SERAPH_AI_ROUTER_PRO
        local analyzer=env.SERAPH_GAME_ANALYZER

        if not router or type(router.SmartRoute)~="function" then
            warn("[SERAPH AI] AI Router Pro no disponible.")
            return
        end

        local report="No analyzer report."
        if analyzer and type(analyzer.Report)=="function" then
            local ok2,r=pcall(analyzer.Report)
            if ok2 then report=tostring(r) end
        end

        local prompt=[[
You are SERAPH's maintenance AI.
Generate a SMALL Lua patch ONLY for the SERAPH HUB's own local modules.
Do not access, invoke, enumerate, or modify game remotes.
Do not create exploit/cheat automation.
Do not touch player data, anti-cheat, purchases, or security systems.

Return ONLY:
-- SERAPH_OWN_HUB_PATCH
-- REASON: <short reason>
<valid Lua code that modifies only SERAPH-owned state/modules>

The patch must be idempotent and wrapped in pcall-safe logic.
Current diagnostic report:
]]..string.sub(report,1,50000)

        task.spawn(function()
            local answer,provider=router.SmartRoute(prompt)
            if not answer then
                warn("[SERAPH AI] "..tostring(provider))
                return
            end
            local accepted,err=queuePatch(
                "AI generated via "..tostring(provider),
                provider,
                answer
            )
            if not accepted then
                warn("[SERAPH PATCH GATE] "..err)
            else
                print("[SERAPH PATCH QUEUED]")
                print(answer)
            end
        end)
    end)

    -- A lightweight validator prevents arbitrary text from being loaded.
    local function validatePatch(patch)
        if type(patch)~="string" or patch=="" then
            return false,"Patch vacío"
        end
        if not string.find(patch,"SERAPH_OWN_HUB_PATCH",1,true) then
            return false,"Marca de seguridad ausente"
        end
        if #patch>State.maxPatchSize then
            return false,"Patch excede el límite"
        end
        local forbidden={
            "loadstring","getfenv","setfenv",
            "HttpGet","GetObjects",
            "fireclickdetector","fireproximityprompt",
            "firetouchinterest","VirtualInputManager"
        }
        local lower=string.lower(patch)
        for _,word in ipairs(forbidden) do
            if string.find(lower,string.lower(word),1,true) then
                return false,"Patrón no permitido: "..word
            end
        end
        return true
    end

    button(queue,"🔍 Validate Patch",function()
        local good,err=validatePatch(State.lastPatch)
        print(good and "🟢 PATCH VALID" or "🔴 PATCH REJECTED",err or "")
    end)

    -- Backup is an in-memory snapshot of SERAPH state. It does not overwrite
    -- the user's source file; source-file backups can be made by the host/editor.
    local function makeBackup()
        local env=getgenv and getgenv() or _G
        local b={
            time=os.date("%Y-%m-%d %H:%M:%S"),
            moduleManager=env.SERAPH_MODULE_MANAGER,
            ultra=env.SERAPH_ULTRA,
            router=env.SERAPH_AI_ROUTER_PRO,
            analyzer=env.SERAPH_GAME_ANALYZER
        }
        State.backups[#State.backups+1]=b
        if #State.backups>5 then table.remove(State.backups,1) end
        return b
    end

    local function applyOwnHubPatch()
        local good,err=validatePatch(State.lastPatch)
        if not good then return false,err end

        local env=getgenv and getgenv() or _G
        local backup
        if State.requireBackup then backup=makeBackup() end

        -- Execute only a validated, AI-generated patch explicitly marked for
        -- SERAPH's own state. Never execute a game object or remote payload.
        local body=State.lastPatch
        body=body:gsub("^%-%- SERAPH_OWN_HUB_PATCH[^\n]*\n?","")
        body=body:gsub("^%-%- REASON:[^\n]*\n?","")

        local fn,compileErr=loadstring(body)
        if not fn then
            if backup then State.rolledBack+=1 end
            return false,"Compile error: "..tostring(compileErr)
        end

        local okRun,runErr=pcall(fn)
        if not okRun then
            if backup then State.rolledBack+=1 end
            return false,"Runtime error: "..tostring(runErr)
        end

        State.applied+=1
        return true
    end

    button(queue,"🚀 APPLY PATCH",function()
        if not State.enabled or not State.autoFix then
            warn("[SERAPH] Activá Autonomous Mode + Auto Fix Own Hub.")
            return
        end
        local good,err=applyOwnHubPatch()
        if good then
            print("🟢 SERAPH PATCH APPLIED")
        else
            warn("🔴 SERAPH PATCH FAILED:",err)
        end
    end)

    button(queue,"↩️ Rollback Last Backup",function()
        local backup=State.backups[#State.backups]
        if not backup then
            warn("[SERAPH] No hay backup.")
            return
        end
        local env=getgenv and getgenv() or _G
        env.SERAPH_MODULE_MANAGER=backup.moduleManager
        env.SERAPH_ULTRA=backup.ultra
        env.SERAPH_AI_ROUTER_PRO=backup.router
        env.SERAPH_GAME_ANALYZER=backup.analyzer
        State.rolledBack+=1
        print("↩️ SERAPH runtime state restored from "..backup.time)
    end)

    local auto=folder("🔄 Autonomous Loop")
    local interval=60
    textBox(auto,"⏱️ Scan Interval (seconds)",function(v)
        local n=tonumber(v)
        if n and n>=15 and n<=3600 then interval=math.floor(n) end
    end)

    switch(auto,"🔁 Auto Diagnose + Repair",function(v)
        State.autoLoop=v==true
    end)

    task.spawn(function()
        while task.wait(5) do
            if State.enabled and State.autoLoop then
                task.wait(interval)
                if State.enabled and State.autoLoop then
                    local analyzer=getgenv and getgenv().SERAPH_GAME_ANALYZER
                    if analyzer and type(analyzer.Run)=="function" then
                        pcall(analyzer.Run)
                    end

                    if State.autoFix then
                        -- Ask AI for a patch, then apply only if it passes the
                        -- explicit ownership/security gate.
                        local env=getgenv and getgenv() or _G
                        local router=env.SERAPH_AI_ROUTER_PRO
                        if router and type(router.SmartRoute)=="function" then
                            local report=""
                            if analyzer and type(analyzer.Report)=="function" then
                                local ok2,r=pcall(analyzer.Report)
                                if ok2 then report=tostring(r) end
                            end
                            local prompt="Find ONE low-risk defect in the SERAPH HUB itself and return ONLY a small "
                                .."SERAPH_OWN_HUB_PATCH. Never touch game remotes or gameplay automation. "
                                .."Make it idempotent.\n"..string.sub(report,1,40000)
                            local answer=select(1,router.SmartRoute(prompt))
                            if answer then
                                local accepted=select(1,queuePatch("autonomous maintenance","AI",answer))
                                if accepted then
                                    pcall(applyOwnHubPatch)
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    local stats=folder("📊 Autonomous Stats")
    local statsLabel=label(stats,"Applied: 0 | Rollbacks: 0")
    button(stats,"🔄 Refresh Stats",function()
        if statsLabel then
            statsLabel.Text="Applied: "..State.applied.." | Rollbacks: "..State.rolledBack
        end
    end)

    button(stats,"📋 Print Autonomous State",function()
        print("========== SERAPH AUTONOMOUS ==========")
        print("enabled=",State.enabled)
        print("autoFix=",State.autoFix)
        print("autoLoop=",State.autoLoop)
        print("applied=",State.applied)
        print("rollbacks=",State.rolledBack)
        print("backups=",#State.backups)
        print("=======================================")
    end)

    pcall(function()
        local env=getgenv and getgenv() or _G
        env.SERAPH_AUTONOMOUS_AI=env.SERAPH_AUTONOMOUS_AI or {}
        env.SERAPH_AUTONOMOUS_AI.State=State
        env.SERAPH_AUTONOMOUS_AI.QueuePatch=queuePatch
        env.SERAPH_AUTONOMOUS_AI.ValidatePatch=validatePatch
        env.SERAPH_AUTONOMOUS_AI.ApplyPatch=applyOwnHubPatch
    end)
end)


-- ============================================================
-- SERAPH AUTONOMOUS PERMISSION GATE
-- Permisos por alcance para el propio hub.
-- ============================================================
task.defer(function()
    if not window then return end

    local ok,tab=pcall(function() return window:AddTab("🔐 AI PERMISSIONS") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2,f=pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function switch(f,n,fn)
        if f and f.AddSwitch then pcall(f.AddSwitch,f,n,fn) end
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok2,x=pcall(f.AddLabel,f,t)
            if ok2 then return x end
        end
    end

    local Permissions={
        -- 🟢 Safe: autonomous by default.
        SERAPH_GUI=true,
        SERAPH_AI=true,
        SERAPH_ANALYZER=true,
        SERAPH_DIAGNOSTICS=true,
        SERAPH_OPTIMIZER=true,
        SERAPH_CONFIG=true,

        -- 🟡 Sensitive: confirmation required.
        NEW_MODULE=false,
        LARGE_PATCH=false,
        CONFIG_MIGRATION=false,

        -- 🔴 Always blocked by this autonomous layer.
        GAME_REMOTES=false,
        ANTICHEAT=false,
        PURCHASES=false,
        OTHER_PLAYER_DATA=false,
        SERVER_PRIVATE_CODE=false,
        GAMEPLAY_AUTOMATION=false,
    }

    local p=folder("🛡️ Permission Levels")
    label(p,"🟢 AUTO: GUI / AI / Analyzer / Diagnostics / Optimizer")
    label(p,"🟡 CONFIRM: módulos nuevos / cambios grandes / migraciones")
    label(p,"🔴 BLOCKED: remotes / anti-cheat / compras / datos ajenos")

    local function setEnv()
        local env=getgenv and getgenv() or _G
        env.SERAPH_AI_PERMISSIONS=env.SERAPH_AI_PERMISSIONS or {}
        env.SERAPH_AI_PERMISSIONS.Map=Permissions

        env.SERAPH_AI_PERMISSIONS.Can=function(action)
            return Permissions[action]==true
        end

        env.SERAPH_AI_PERMISSIONS.Require=function(action)
            if Permissions[action]==true then return true,"AUTO" end
            if action=="NEW_MODULE" or action=="LARGE_PATCH" or action=="CONFIG_MIGRATION" then
                return false,"CONFIRMATION_REQUIRED"
            end
            return false,"BLOCKED"
        end
    end

    switch(p,"🟢 Allow Autonomous SERAPH GUI",function(v) Permissions.SERAPH_GUI=v==true end)
    switch(p,"🟢 Allow Autonomous SERAPH AI",function(v) Permissions.SERAPH_AI=v==true end)
    switch(p,"🟢 Allow Autonomous Analyzer",function(v) Permissions.SERAPH_ANALYZER=v==true end)
    switch(p,"🟢 Allow Autonomous Diagnostics",function(v) Permissions.SERAPH_DIAGNOSTICS=v==true end)
    switch(p,"🟢 Allow Autonomous Optimizer",function(v) Permissions.SERAPH_OPTIMIZER=v==true end)
    switch(p,"🟢 Allow Autonomous Config",function(v) Permissions.SERAPH_CONFIG=v==true end)

    local test=folder("🧪 Permission Test")
    button(test,"🔎 Check All Permissions",function()
        setEnv()
        print("========== SERAPH PERMISSIONS ==========")
        for k,v in pairs(Permissions) do
            local mode=v and "AUTO" or "CONFIRM/BLOCKED"
            if k=="GAME_REMOTES" or k=="ANTICHEAT" or k=="PURCHASES"
                or k=="OTHER_PLAYER_DATA" or k=="SERVER_PRIVATE_CODE"
                or k=="GAMEPLAY_AUTOMATION" then
                mode="BLOCKED"
            elseif k=="NEW_MODULE" or k=="LARGE_PATCH" or k=="CONFIG_MIGRATION" then
                mode="CONFIRMATION_REQUIRED"
            end
            print(k,mode)
        end
        print("========================================")
    end)

    button(test,"🔒 Force Safe Mode",function()
        Permissions.NEW_MODULE=false
        Permissions.LARGE_PATCH=false
        Permissions.CONFIG_MIGRATION=false
        Permissions.GAME_REMOTES=false
        Permissions.ANTICHEAT=false
        Permissions.PURCHASES=false
        Permissions.OTHER_PLAYER_DATA=false
        Permissions.SERVER_PRIVATE_CODE=false
        Permissions.GAMEPLAY_AUTOMATION=false
        setEnv()
        print("[SERAPH] Safe permission profile enabled.")
    end)

    button(test,"📋 Print Permission API",function()
        setEnv()
        print("SERAPH_AI_PERMISSIONS.Can(action)")
        print("SERAPH_AI_PERMISSIONS.Require(action)")
    end)

    setEnv()
end)


-- ============================================================
-- SERAPH AI 2.0 AUTONOMOUS MANAGER
-- Planner + dependency graph + sandboxed state simulation +
-- self-test + version manager + autonomous maintenance.
-- Sólo administra estado/módulos propios de SERAPH.
-- ============================================================
task.defer(function()
    local HttpService = game:GetService("HttpService")
    local RunService = game:GetService("RunService")
    if not window then return end

    local ok,tab=pcall(function() return window:AddTab("🚀 AI 2.0 MANAGER") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2,f=pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function switch(f,n,fn)
        if f and f.AddSwitch then pcall(f.AddSwitch,f,n,fn) end
    end
    local function textBox(f,n,fn)
        if f and f.AddTextBox then pcall(f.AddTextBox,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok2,x=pcall(f.AddLabel,f,t)
            if ok2 then return x end
        end
    end

    local M={
        autonomous=false,
        autoMaintain=false,
        interval=120,
        versions={},
        plans={},
        tests={},
        dependencies={},
        sandbox={},
        lastStatus="idle",
        maxVersions=15,
        busy=false,
    }

    local function env()
        return getgenv and getgenv() or _G
    end

    local function analyzer()
        local e=env()
        return e.SERAPH_GAME_ANALYZER
    end

    local function router()
        local e=env()
        return e.SERAPH_AI_ROUTER_PRO
    end

    local function permissions()
        local e=env()
        return e.SERAPH_AI_PERMISSIONS
    end

    local function ownModules()
        local e=env()
        return {
            ["AI Router"]=e.SERAPH_AI_ROUTER_PRO,
            ["Game Analyzer"]=e.SERAPH_GAME_ANALYZER,
            ["Ultimate Suite"]=e.SERAPH_ULTIMATE_SUITE,
            ["Autonomous AI"]=e.SERAPH_AUTONOMOUS_AI,
            ["Permissions"]=e.SERAPH_AI_PERMISSIONS,
            ["Module Manager"]=e.SERAPH_MODULE_MANAGER,
            ["Ultra"]=e.SERAPH_ULTRA,
        }
    end

    -- ---------- Dashboard ----------
    local dash=folder("📊 Manager Dashboard")
    local dashLabel=label(dash,"SERAPH AI 2.0: listo")
    local function setStatus(s)
        M.lastStatus=s
        if dashLabel then dashLabel.Text="SERAPH AI 2.0: "..s end
    end

    -- ---------- Dependency Graph ----------
    local deps=folder("🧩 Dependency Graph")

    local defaultDeps={
        ["AI Router"]={"Permissions"},
        ["Game Analyzer"]={"Permissions"},
        ["Ultimate Suite"]={"Game Analyzer","AI Router"},
        ["Autonomous AI"]={"AI Router","Permissions","Game Analyzer"},
        ["Module Manager"]={},
        ["Ultra"]={"Module Manager"},
    }

    local function buildDependencyGraph()
        M.dependencies={}
        local mods=ownModules()
        for name,object in pairs(mods) do
            if object then
                M.dependencies[name]=defaultDeps[name] or {}
            end
        end
        return M.dependencies
    end

    local function dependencyHealth()
        local graph=buildDependencyGraph()
        local mods=ownModules()
        local bad={}
        for name,needed in pairs(graph) do
            for _,dep in ipairs(needed) do
                if not mods[dep] then
                    bad[#bad+1]=name.." -> missing "..dep
                end
            end
        end
        return bad
    end

    button(deps,"🔎 Build Dependency Graph",function()
        local graph=buildDependencyGraph()
        print("========== SERAPH DEPENDENCY GRAPH ==========")
        for name,needed in pairs(graph) do
            print(name,"->",#needed>0 and table.concat(needed,", ") or "none")
        end
        print("=============================================")
    end)

    button(deps,"🩺 Check Dependencies",function()
        local bad=dependencyHealth()
        if #bad==0 then
            print("🟢 All SERAPH dependencies are available.")
        else
            print("🔴 Dependency problems:")
            for _,x in ipairs(bad) do print("-",x) end
        end
    end)

    -- ---------- Version Manager ----------
    local versions=folder("📦 Version Manager")
    local versionLabel=label(versions,"Versions: 0")

    local function stateDigest()
        local mods=ownModules()
        local names={}
        for n,obj in pairs(mods) do
            if obj then names[#names+1]=n end
        end
        table.sort(names)
        local raw=table.concat(names,"|")
        local h=0
        for i=1,#raw do h=(h*31+string.byte(raw,i))%2147483647 end
        return tostring(h),raw
    end

    local function createVersion(reason)
        local hash,manifest=stateDigest()
        local v={
            id=#M.versions+1,
            time=os.date("%Y-%m-%d %H:%M:%S"),
            reason=reason or "manual",
            hash=hash,
            manifest=manifest
        }
        M.versions[#M.versions+1]=v
        while #M.versions>M.maxVersions do table.remove(M.versions,1) end
        versionLabel.Text="Versions: "..#M.versions.." | actual #"..v.id
        return v
    end

    button(versions,"📦 Create Version",function()
        createVersion("manual")
    end)

    button(versions,"📋 List Versions",function()
        print("========== SERAPH VERSIONS ==========")
        for _,v in ipairs(M.versions) do
            print("#"..v.id,v.time,v.reason,v.hash)
            print(" ",v.manifest)
        end
        print("=====================================")
    end)

    button(versions,"🔀 Compare Last Versions",function()
        if #M.versions<2 then
            warn("[SERAPH] Need two versions.")
            return
        end
        local a=M.versions[#M.versions-1]
        local b=M.versions[#M.versions]
        print("========== VERSION DIFF ==========")
        print("OLD:",a.hash,a.manifest)
        print("NEW:",b.hash,b.manifest)
        print("Changed:",a.hash~=b.hash)
        print("==================================")
    end)

    -- ---------- Sandbox ----------
    local sandbox=folder("🧪 Patch Sandbox")
    local sandboxLabel=label(sandbox,"Sandbox: vacío")

    local function sandboxSnapshot()
        local mods=ownModules()
        local copy={}
        for name,obj in pairs(mods) do copy[name]=obj~=nil end
        M.sandbox={
            time=os.date("%Y-%m-%d %H:%M:%S"),
            modules=copy,
            hash=stateDigest()
        }
        sandboxLabel.Text="Sandbox: snapshot creado"
    end

    local function sandboxCompare()
        if not M.sandbox.modules then return false,"No sandbox" end
        local mods=ownModules()
        local changes={}
        for name,was in pairs(M.sandbox.modules) do
            local now=mods[name]~=nil
            if now~=was then changes[#changes+1]=name.." changed" end
        end
        return #changes==0,changes
    end

    button(sandbox,"📸 Create Sandbox Snapshot",sandboxSnapshot)
    button(sandbox,"🧪 Validate Current State",function()
        if not M.sandbox.modules then sandboxSnapshot() end
        local same,changes=sandboxCompare()
        if same then
            print("🟢 Sandbox validation: no module availability changes.")
        else
            print("🟡 Sandbox differences:")
            for _,x in ipairs(changes) do print("-",x) end
        end
    end)

    -- ---------- Self Test ----------
    local tests=folder("🧪 Self-Test")
    local testLabel=label(tests,"Tests: 0")

    local function runTests()
        local results={}
        local function add(name,fn)
            local ok2,err=pcall(fn)
            results[#results+1]={name=name,ok=ok2,error=ok2 and "" or tostring(err)}
        end

        add("GUI",function() assert(window,"window missing") end)
        add("Dependencies",function() assert(#dependencyHealth()==0,"dependencies missing") end)
        add("AI Router",function()
            local r=router()
            assert(r and type(r.SmartRoute)=="function","router unavailable")
        end)
        add("Game Analyzer",function()
            local a=analyzer()
            assert(a and type(a.Run)=="function","analyzer unavailable")
        end)
        add("Permissions",function()
            local p=permissions()
            assert(p and type(p.Can)=="function","permissions unavailable")
        end)

        M.tests=results
        local good=0
        for _,r in ipairs(results) do if r.ok then good+=1 end end
        testLabel.Text=string.format("Tests: %d/%d OK",good,#results)
        return results
    end

    button(tests,"▶ Run Full Self-Test",function()
        local results=runTests()
        print("========== SERAPH SELF TEST ==========")
        for _,r in ipairs(results) do
            print(r.ok and "🟢" or "🔴",r.name,r.error)
        end
        print("======================================")
    end)

    -- ---------- Planner ----------
    local planner=folder("🧠 AI Planner")
    local planLabel=label(planner,"Plan: ninguno")

    local function buildPlan()
        local issues={}
        local bad=dependencyHealth()
        for _,x in ipairs(bad) do issues[#issues+1]="Fix dependency: "..x end

        local tests=runTests()
        for _,r in ipairs(tests) do
            if not r.ok then issues[#issues+1]="Fix self-test: "..r.name end
        end

        if #issues==0 then
            issues[#issues+1]="Run optimizer diagnostics and verify AI providers."
        end

        M.plans[#M.plans+1]={
            time=os.date("%Y-%m-%d %H:%M:%S"),
            items=issues
        }
        planLabel.Text="Plan: "..#issues.." tasks"
        return issues
    end

    button(planner,"🧠 Build Maintenance Plan",function()
        local plan=buildPlan()
        print("========== AI MAINTENANCE PLAN ==========")
        for i,x in ipairs(plan) do print(i..". "..x) end
        print("=========================================")
    end)

    button(planner,"🤖 Prioritize With AI",function()
        local r=router()
        if not r or type(r.SmartRoute)~="function" then
            warn("[SERAPH] AI Router unavailable.")
            return
        end
        local plan=M.plans[#M.plans]
        if not plan then plan=buildPlan() end
        local prompt="Prioriza este plan de mantenimiento del propio SERAPH HUB. "
            .."No modifiques juego, remotos, anti-cheat ni gameplay. "
            .."Devuelve sólo prioridades P0/P1/P2 y motivo.\n"
            ..table.concat(plan.items,"\n")
        task.spawn(function()
            local answer,provider=r.SmartRoute(prompt)
            if answer then
                print("========== AI PRIORITIES ==========")
                print("Provider:",provider)
                print(answer)
                print("===================================")
            else
                warn("[SERAPH AI] "..tostring(provider))
            end
        end)
    end)

    -- ---------- Autonomous Manager ----------
    local auto=folder("🚀 Autonomous Manager")
    switch(auto,"🤖 Enable Autonomous Manager",function(v)
        M.autonomous=v==true
    end)
    switch(auto,"🔧 Auto Maintenance",function(v)
        M.autoMaintain=v==true
    end)

    textBox(auto,"⏱️ Maintenance Interval",function(v)
        local n=tonumber(v)
        if n and n>=30 and n<=3600 then M.interval=math.floor(n) end
    end)

    local function autonomousCycle()
        if M.busy then return end
        M.busy=true
        setStatus("maintenance running")

        -- 1. Analyze
        local a=analyzer()
        if a and type(a.Run)=="function" then pcall(a.Run) end

        -- 2. Snapshot before any maintenance.
        createVersion("pre-maintenance")
        sandboxSnapshot()

        -- 3. Plan.
        local plan=buildPlan()

        -- 4. Self-test.
        local results=runTests()
        local failures=0
        for _,r in ipairs(results) do if not r.ok then failures+=1 end end

        -- 5. Only call AI when there is a real issue or explicit maintenance.
        local r=router()
        if r and type(r.SmartRoute)=="function" and #plan>0 then
            local prompt="You are SERAPH maintenance AI. Analyze this plan for the "
                .."SERAPH HUB only. Recommend the smallest low-risk repair. "
                .."Do not generate executable code. Return: priority, cause, "
                .."verification steps.\n"..table.concat(plan,"\n")
            local answer,provider=r.SmartRoute(prompt)
            if answer then
                print("[SERAPH MANAGER]["..provider.."]",answer)
            end
        end

        -- 6. Never silently apply broad changes from this manager.
        -- Changes requiring a new module/large patch remain gated by the
        -- permission layer and the Autonomous AI patch validator.
        if failures==0 then
            createVersion("post-maintenance")
            setStatus("healthy")
        else
            setStatus("needs repair")
        end

        M.busy=false
    end

    button(auto,"▶ Run Autonomous Cycle Now",function()
        if not M.autonomous then
            warn("[SERAPH] Enable Autonomous Manager first.")
            return
        end
        task.spawn(autonomousCycle)
    end)

    task.spawn(function()
        while task.wait(5) do
            if M.autonomous and M.autoMaintain then
                task.wait(M.interval)
                if M.autonomous and M.autoMaintain then
                    task.spawn(autonomousCycle)
                end
            end
        end
    end)

    -- ---------- Export ----------
    local export=folder("💾 Manager Export")
    button(export,"💾 Export Manager State",function()
        local payload={
            time=os.date("%Y-%m-%d %H:%M:%S"),
            status=M.lastStatus,
            versions=M.versions,
            plans=M.plans,
            tests=M.tests,
            dependencies=M.dependencies,
            sandbox=M.sandbox,
            autonomous=M.autonomous,
            autoMaintain=M.autoMaintain,
        }
        local ok2,data=pcall(HttpService.JSONEncode,HttpService,payload)
        if ok2 then
            print("========== SERAPH AI 2.0 STATE ==========")
            print(data)
            print("=========================================")
        end
    end)

    pcall(function()
        local e=env()
        e.SERAPH_AI_2_MANAGER=e.SERAPH_AI_2_MANAGER or {}
        e.SERAPH_AI_2_MANAGER.State=M
        e.SERAPH_AI_2_MANAGER.Run=autonomousCycle
        e.SERAPH_AI_2_MANAGER.Plan=buildPlan
        e.SERAPH_AI_2_MANAGER.Test=runTests
        e.SERAPH_AI_2_MANAGER.Version=createVersion
    end)

    runTests()
    setStatus("ready")
end)


-- ============================================================
-- SERAPH AI 3.0 SELF-HEALING LAYER
-- Root Cause + Regression Tests + Learning + Architecture Map +
-- Dead Code hints + Health Score + Changelog + Smart Alerts.
-- Sólo analiza y mantiene módulos/estado propios de SERAPH.
-- ============================================================
task.defer(function()
    local HttpService = game:GetService("HttpService")
    if not window then return end

    local ok,tab=pcall(function() return window:AddTab("🧠 AI 3.0 SELF-HEALING") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2,f=pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function switch(f,n,fn)
        if f and f.AddSwitch then pcall(f.AddSwitch,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok2,x=pcall(f.AddLabel,f,t)
            if ok2 then return x end
        end
    end

    local S={
        learning={fixes={},failures={},patterns={}},
        changelog={},
        alerts={},
        health=0,
        lastRootCause="none",
        regression={},
        architecture={},
        deadCodeHints={},
        enabled=true,
    }

    local function env() return getgenv and getgenv() or _G end
    local function mods()
        local e=env()
        return {
            ["AI Router"]=e.SERAPH_AI_ROUTER_PRO,
            ["Game Analyzer"]=e.SERAPH_GAME_ANALYZER,
            ["Ultimate Suite"]=e.SERAPH_ULTIMATE_SUITE,
            ["Autonomous AI"]=e.SERAPH_AUTONOMOUS_AI,
            ["Permissions"]=e.SERAPH_AI_PERMISSIONS,
            ["AI 2 Manager"]=e.SERAPH_AI_2_MANAGER,
            ["Module Manager"]=e.SERAPH_MODULE_MANAGER,
            ["Ultra"]=e.SERAPH_ULTRA,
        }
    end

    local function analyzer()
        local a=env().SERAPH_GAME_ANALYZER
        return a
    end

    -- ---------- Root Cause Analyzer ----------
    local root=folder("🔬 Root Cause Analyzer")
    local rootLabel=label(root,"Root cause: esperando análisis.")

    local function rootCause()
        local findings={}
        local m=mods()

        if not m["Permissions"] then
            findings[#findings+1]="Permissions layer missing: dependent autonomous operations should remain disabled."
        end
        if not m["AI Router"] then
            findings[#findings+1]="AI Router missing: AI planning/repair cannot run."
        end
        if not m["Game Analyzer"] then
            findings[#findings+1]="Game Analyzer missing: diagnostics are incomplete."
        end
        if not m["AI 2 Manager"] then
            findings[#findings+1]="AI 2 Manager missing: orchestration layer unavailable."
        end

        local manager=env().SERAPH_AI_2_MANAGER
        if manager and manager.State then
            local tests=manager.State.tests or {}
            for _,t in ipairs(tests) do
                if not t.ok then
                    findings[#findings+1]="Failed self-test '"..t.name.."': "..tostring(t.error)
                end
            end
        end

        if #findings==0 then
            findings[#findings+1]="No structural root cause detected by local checks."
        end

        S.lastRootCause=table.concat(findings,"\n")
        rootLabel.Text="Root cause: "..(#findings).." finding(s)"
        return findings
    end

    button(root,"🔎 Analyze Root Cause",function()
        local f=rootCause()
        print("========== SERAPH ROOT CAUSE ==========")
        for i,x in ipairs(f) do print(i..". "..x) end
        print("=======================================")
    end)

    -- ---------- Regression Tests ----------
    local reg=folder("🧪 Regression Testing")
    local regLabel=label(reg,"Regression: 0 tests")

    local function regression()
        local results={}
        local function test(name,fn)
            local ok2,err=pcall(fn)
            results[#results+1]={name=name,ok=ok2,error=ok2 and "" or tostring(err)}
        end

        local m=mods()
        test("GUI",function() assert(window,"GUI missing") end)
        test("Permissions API",function()
            assert(m["Permissions"] and type(m["Permissions"].Can)=="function","permissions unavailable")
        end)
        test("Analyzer API",function()
            assert(m["Game Analyzer"] and type(m["Game Analyzer"].Run)=="function","analyzer unavailable")
        end)
        test("AI Router API",function()
            assert(m["AI Router"] and type(m["AI Router"].SmartRoute)=="function","router unavailable")
        end)
        test("Manager API",function()
            assert(m["AI 2 Manager"] and type(m["AI 2 Manager"].Run)=="function","manager unavailable")
        end)

        S.regression=results
        local good=0
        for _,r in ipairs(results) do if r.ok then good+=1 end end
        regLabel.Text=string.format("Regression: %d/%d OK",good,#results)
        return results
    end

    button(reg,"▶ Run Regression Suite",function()
        local r=regression()
        for _,x in ipairs(r) do print(x.ok and "🟢" or "🔴",x.name,x.error) end
    end)

    -- ---------- Learning ----------
    local learn=folder("📚 Learning System")
    local learnLabel=label(learn,"Learning: 0 successful fixes")

    local function rememberFix(name,reason,result)
        local bucket=result and S.learning.fixes or S.learning.failures
        bucket[#bucket+1]={
            name=tostring(name),
            reason=tostring(reason),
            time=os.date("%Y-%m-%d %H:%M:%S")
        }
        learnLabel.Text="Learning: "..#S.learning.fixes.." successful / "..#S.learning.failures.." failed"
    end

    local function rememberPattern(pattern)
        S.learning.patterns[pattern]=(S.learning.patterns[pattern] or 0)+1
    end

    button(learn,"📈 Record Current Diagnostics",function()
        local causes=rootCause()
        for _,c in ipairs(causes) do rememberPattern(c) end
        print("[SERAPH LEARNING] patterns updated:",#causes)
    end)

    button(learn,"📋 Print Learned History",function()
        print("========== SERAPH LEARNING ==========")
        print("Successful fixes:",#S.learning.fixes)
        for _,x in ipairs(S.learning.fixes) do print("✓",x.name,x.reason) end
        print("Failed fixes:",#S.learning.failures)
        for _,x in ipairs(S.learning.failures) do print("✗",x.name,x.reason) end
        print("=====================================")
    end)

    -- ---------- Architecture Map ----------
    local arch=folder("🗺️ Architecture Map")
    local archLabel=label(arch,"Architecture: not built")

    local graph={
        ["Permissions"]={"AI Router","Autonomous AI","AI 2 Manager"},
        ["Game Analyzer"]={"Ultimate Suite","Autonomous AI","AI 2 Manager"},
        ["AI Router"]={"Autonomous AI","AI 2 Manager"},
        ["Autonomous AI"]={"AI 2 Manager"},
        ["AI 2 Manager"]={"AI 3 Self-Healing"},
    }

    local function buildArchitecture()
        S.architecture={}
        local m=mods()
        for from,to in pairs(graph) do
            if m[from] or from=="AI 3 Self-Healing" then
                local active={}
                for _,x in ipairs(to) do
                    if m[x] or x=="AI 3 Self-Healing" then active[#active+1]=x end
                end
                S.architecture[from]=active
            end
        end
        archLabel.Text="Architecture: "..tostring(#(function()
            local t={} for k in pairs(S.architecture) do t[#t+1]=k end return t end)()).." nodes"
        return S.architecture
    end

    button(arch,"🗺️ Build Architecture Map",function()
        local g=buildArchitecture()
        print("========== SERAPH ARCHITECTURE ==========")
        for from,to in pairs(g) do
            print(from,"->",#to>0 and table.concat(to,", ") or "none")
        end
        print("=========================================")
    end)

    -- ---------- Dead Code Hints ----------
    local dead=folder("🧹 Dead-Code Hints")
    local deadLabel=label(dead,"Dead-code scan: no report")

    button(dead,"🔎 Scan Own Module Registry",function()
        local m=mods()
        local hints={}
        for name,obj in pairs(m) do
            if obj==nil then
                hints[#hints+1]=name.." is registered as an expected module but is unavailable."
            end
        end
        S.deadCodeHints=hints
        deadLabel.Text="Dead-code hints: "..#hints
        for _,x in ipairs(hints) do print("🟡",x) end
        if #hints==0 then print("🟢 No missing expected modules.") end
    end)

    -- ---------- Security Audit ----------
    local security=folder("🛡️ Security Audit")
    local secLabel=label(security,"Security: ready")

    button(security,"🛡️ Audit Autonomous Permissions",function()
        local p=env().SERAPH_AI_PERMISSIONS
        local blocked={
            "GAME_REMOTES","ANTICHEAT","PURCHASES",
            "OTHER_PLAYER_DATA","SERVER_PRIVATE_CODE",
            "GAMEPLAY_AUTOMATION"
        }
        local safe=true
        if not p or not p.Map then
            safe=false
            print("🔴 Permission API missing")
        else
            for _,k in ipairs(blocked) do
                if p.Map[k]~=false then
                    safe=false
                    print("🔴 Must remain blocked:",k)
                end
            end
        end
        secLabel.Text="Security: "..(safe and "🟢 OK" or "🔴 WARNING")
        return safe
    end)

    -- ---------- Smart Alerts ----------
    local alerts=folder("🔔 Smart Alerts")
    local alertLabel=label(alerts,"Alerts: 0")

    local function alert(level,msg)
        S.alerts[#S.alerts+1]={
            level=level,msg=tostring(msg),
            time=os.date("%H:%M:%S")
        }
        alertLabel.Text="Alerts: "..#S.alerts
        if level=="CRITICAL" then
            warn("[SERAPH ALERT]",msg)
        else
            print("[SERAPH ALERT]",level,msg)
        end
    end

    button(alerts,"🔎 Evaluate Alerts",function()
        local causes=rootCause()
        if #causes>0 and causes[1]~="No structural root cause detected by local checks." then
            alert("WARNING",causes[1])
        end
        if not regression() then
            alert("WARNING","Regression suite could not run.")
        end
        local p=env().SERAPH_AI_PERMISSIONS
        if not p then alert("CRITICAL","Permission layer unavailable.") end
    end)

    -- ---------- Health Score ----------
    local health=folder("❤️ Health Score")
    local healthLabel=label(health,"Health: calculating...")

    local function calculateHealth()
        local score=100
        local m=mods()
        local expected={"AI Router","Game Analyzer","Permissions","AI 2 Manager","Autonomous AI"}
        for _,n in ipairs(expected) do
            if not m[n] then score-=15 end
        end

        local r=S.regression
        for _,x in ipairs(r) do
            if not x.ok then score-=10 end
        end

        local p=env().SERAPH_AI_PERMISSIONS
        if p and p.Map then
            local critical={"GAME_REMOTES","ANTICHEAT","PURCHASES",
                "OTHER_PLAYER_DATA","SERVER_PRIVATE_CODE","GAMEPLAY_AUTOMATION"}
            for _,k in ipairs(critical) do
                if p.Map[k]~=false then score-=20 end
            end
        else
            score-=20
        end

        score=math.max(0,math.min(100,score))
        S.health=score
        healthLabel.Text="Health: "..score.."/100"
        return score
    end

    button(health,"❤️ Calculate Health",function()
        regression()
        local score=calculateHealth()
        print("[SERAPH HEALTH]",score.."/100")
    end)

    -- ---------- Changelog ----------
    local change=folder("🧾 Changelog")
    local function logChange(action,result,reason)
        S.changelog[#S.changelog+1]={
            time=os.date("%Y-%m-%d %H:%M:%S"),
            action=action,result=result,reason=reason
        }
    end

    button(change,"📝 Add Current Health Entry",function()
        local score=calculateHealth()
        logChange("health-check",tostring(score).."/100","manual health audit")
        print("[SERAPH CHANGELOG] health entry added.")
    end)

    button(change,"📋 Print Changelog",function()
        print("========== SERAPH CHANGELOG ==========")
        for _,x in ipairs(S.changelog) do
            print(x.time,x.action,x.result,x.reason)
        end
        print("======================================")
    end)

    -- ---------- Autonomous Self-Healing Orchestrator ----------
    local heal=folder("🩹 Self-Healing")
    local healLabel=label(heal,"Self-Healing: ready")
    local autoHeal=false

    switch(heal,"🩹 Enable Self-Healing",function(v)
        autoHeal=v==true
        healLabel.Text="Self-Healing: "..(autoHeal and "ON" or "OFF")
    end)

    local function healingCycle()
        if not autoHeal then return end

        local before=calculateHealth()
        local causes=rootCause()
        for _,c in ipairs(causes) do rememberPattern(c) end

        -- Safe local actions only: diagnostics, regression, security and
        -- orchestration. Actual code patches remain behind the existing
        -- SERAPH autonomous permission/patch gates.
        local secure=env().SERAPH_AI_PERMISSIONS
        local safe=true
        if secure and type(secure.Require)=="function" then
            local allowed,mode=secure.Require("SERAPH_DIAGNOSTICS")
            safe=allowed or mode=="AUTO"
        end

        regression()
        local after=calculateHealth()

        if after>=before then
            rememberFix("diagnostic-cycle","health "..before.." -> "..after,true)
            logChange("self-healing-cycle","improved/stable",table.concat(causes,"\n"))
        else
            rememberFix("diagnostic-cycle","health decreased",false)
            logChange("self-healing-cycle","degraded",table.concat(causes,"\n"))
            alert("WARNING","Health score decreased during self-healing cycle.")
        end

        if not safe then
            alert("CRITICAL","Permission gate denied autonomous diagnostic scope.")
        end
    end

    button(heal,"▶ Run Self-Healing Cycle",function()
        healingCycle()
    end)

    -- ---------- Master Dashboard ----------
    local dash2=folder("🎯 Master Dashboard")
    local masterLabel=label(dash2,"SERAPH AI 3.0")

    button(dash2,"🚀 Run Full AI 3.0 Audit",function()
        buildArchitecture()
        regression()
        rootCause()
        calculateHealth()
        local p=env().SERAPH_AI_PERMISSIONS
        if p and type(p.Can)=="function" then
            pcall(p.Can,"SERAPH_DIAGNOSTICS")
        end
        masterLabel.Text="SERAPH AI 3.0 • Health "..S.health.."/100"
        print("========== SERAPH AI 3.0 AUDIT ==========")
        print("Health:",S.health.."/100")
        print("Root Cause:",S.lastRootCause)
        print("Alerts:",#S.alerts)
        print("=========================================")
    end)

    button(dash2,"📦 Export AI 3.0 State",function()
        local payload={
            time=os.date("%Y-%m-%d %H:%M:%S"),
            health=S.health,
            rootCause=S.lastRootCause,
            regression=S.regression,
            learning=S.learning,
            architecture=S.architecture,
            deadCodeHints=S.deadCodeHints,
            alerts=S.alerts,
            changelog=S.changelog
        }
        local ok2,data=pcall(HttpService.JSONEncode,HttpService,payload)
        if ok2 then print(data) end
    end)

    pcall(function()
        local e=env()
        e.SERAPH_AI_3_SELF_HEALING=e.SERAPH_AI_3_SELF_HEALING or {}
        e.SERAPH_AI_3_SELF_HEALING.State=S
        e.SERAPH_AI_3_SELF_HEALING.RunAudit=function()
            buildArchitecture()
            regression()
            rootCause()
            return calculateHealth()
        end
        e.SERAPH_AI_3_SELF_HEALING.RootCause=rootCause
        e.SERAPH_AI_3_SELF_HEALING.Regression=regression
        e.SERAPH_AI_3_SELF_HEALING.Health=calculateHealth
    end)

    regression()
    buildArchitecture()
    calculateHealth()
end)


-- ============================================================
-- SERAPH AI 4.0 ADAPTIVE PERFORMANCE
-- Static heuristics + profiling + memory observations +
-- type/syntax hints + adaptive scheduling + regression scoring.
-- El sistema analiza únicamente el propio SERAPH.
-- ============================================================
task.defer(function()
    local RunService = game:GetService("RunService")
    local HttpService = game:GetService("HttpService")
    if not window then return end

    local ok,tab=pcall(function() return window:AddTab("⚡ AI 4.0 PERFORMANCE") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2,f=pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function switch(f,n,fn)
        if f and f.AddSwitch then pcall(f.AddSwitch,f,n,fn) end
    end
    local function textBox(f,n,fn)
        if f and f.AddTextBox then pcall(f.AddTextBox,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok2,x=pcall(f.AddLabel,f,t)
            if ok2 then return x end
        end
    end

    local P={
        enabled=true,
        adaptive=true,
        profileSeconds=10,
        targetInterval=60,
        minInterval=15,
        maxInterval=600,
        samples={},
        findings={},
        typeHints={},
        performanceScore=100,
        memorySamples={},
        history={},
        profilerAvailable=type(debug)=="table"
            and type(debug.profilebegin)=="function"
            and type(debug.profileend)=="function",
    }

    local function env() return getgenv and getgenv() or _G end
    local function modules()
        local e=env()
        return {
            ["AI Router"]=e.SERAPH_AI_ROUTER_PRO,
            ["Analyzer"]=e.SERAPH_GAME_ANALYZER,
            ["Autonomous AI"]=e.SERAPH_AUTONOMOUS_AI,
            ["AI 2 Manager"]=e.SERAPH_AI_2_MANAGER,
            ["AI 3 Self-Healing"]=e.SERAPH_AI_3_SELF_HEALING,
            ["Permissions"]=e.SERAPH_AI_PERMISSIONS,
            ["Ultra"]=e.SERAPH_ULTRA,
        }
    end

    -- ---------- Performance Dashboard ----------
    local dash=folder("📊 Performance Dashboard")
    local dashLabel=label(dash,"Performance: calculating...")

    local function sampleHeartbeat(seconds)
        local frames=0
        local total=0
        local maxDt=0
        local start=os.clock()
        local conn
        conn=RunService.Heartbeat:Connect(function(dt)
            frames+=1
            total+=dt
            if dt>maxDt then maxDt=dt end
        end)
        task.wait(seconds)
        if conn then conn:Disconnect() end

        local elapsed=math.max(os.clock()-start,0.001)
        local avgDt=total/math.max(frames,1)
        local fps=frames/elapsed
        local result={
            seconds=elapsed,frames=frames,fps=fps,
            avgFrameMs=avgDt*1000,maxFrameMs=maxDt*1000,
            time=os.date("%Y-%m-%d %H:%M:%S")
        }
        P.samples[#P.samples+1]=result
        return result
    end

    button(dash,"▶ Profile SERAPH Runtime",function()
        task.spawn(function()
            if P.profilerAvailable then
                pcall(debug.profilebegin,"SERAPH_AI4_Profile")
            end
            local r=sampleHeartbeat(P.profileSeconds)
            if P.profilerAvailable then pcall(debug.profileend) end

            local score=100
            if r.avgFrameMs>16.67 then score-=15 end
            if r.avgFrameMs>25 then score-=15 end
            if r.maxFrameMs>50 then score-=15 end
            if r.maxFrameMs>100 then score-=20 end
            score=math.max(0,score)

            P.performanceScore=score
            dashLabel.Text=string.format(
                "Performance: %d/100 | %.1f FPS | avg %.2fms | max %.2fms",
                score,r.fps,r.avgFrameMs,r.maxFrameMs
            )

            print("========== SERAPH PERFORMANCE ==========")
            print("FPS:",r.fps)
            print("Average frame:",r.avgFrameMs,"ms")
            print("Max frame:",r.maxFrameMs,"ms")
            print("Score:",score.."/100")
            print("========================================")
        end)
    end)

    -- ---------- Static Heuristic Scanner ----------
    local static=folder("🔎 Static Analyzer")
    local staticLabel=label(static,"Static analysis: waiting")

    local function analyzerReport()
        local a=env().SERAPH_GAME_ANALYZER
        if a and type(a.Report)=="function" then
            local ok2,r=pcall(a.Report)
            if ok2 then return tostring(r) end
        end
        return ""
    end

    local function scanText(text)
        local findings={}
        local patterns={
            {pat="Heartbeat:Connect",msg="Heartbeat connection detected; verify work is lightweight."},
            {pat="PreRender:Connect",msg="PreRender connection detected; avoid expensive work every frame."},
            {pat="PreSimulation:Connect",msg="PreSimulation connection detected; review frequency."},
            {pat="GetDescendants",msg="GetDescendants usage detected; consider caching when repeated."},
            {pat="JSONEncode",msg="Serialization detected; avoid repeatedly encoding large tables."},
            {pat="JSONDecode",msg="Deserialization detected; avoid repeatedly decoding large payloads."},
            {pat="while true do",msg="Infinite loop detected; verify it yields."},
            {pat="while task.wait",msg="Repeated task.wait loop detected; verify interval is appropriate."},
        }
        for _,x in ipairs(patterns) do
            if string.find(text,x.pat,1,true) then findings[#findings+1]=x.msg end
        end
        return findings
    end

    button(static,"🔎 Scan SERAPH Performance Patterns",function()
        local report=analyzerReport()
        P.findings=scanText(report)
        staticLabel.Text="Static findings: "..#P.findings
        for _,x in ipairs(P.findings) do print("🟡",x) end
        if #P.findings==0 then print("🟢 No known high-frequency patterns found.") end
    end)

    -- ---------- Luau Type/Syntax Hints ----------
    local types=folder("🧩 Luau Type Hints")
    local typeLabel=label(types,"Type hints: waiting")

    local function typeHintsFromText(text)
        local hints={}
        if string.find(text,"local%s+[%w_]+%s*=") and
           not string.find(text,"local%s+[%w_]+%s*:%s*[%w_]+%s*=") then
            hints[#hints+1]="Consider explicit type annotations for important state."
        end
        if string.find(text,"function%s+[%w_]+%(") then
            hints[#hints+1]="Consider return/parameter annotations on stable public functions."
        end
        return hints
    end

    button(types,"🧩 Generate Type Safety Hints",function()
        local hints=typeHintsFromText(analyzerReport())
        P.typeHints=hints
        typeLabel.Text="Type hints: "..#hints
        for _,x in ipairs(hints) do print("🟡",x) end
    end)

    -- ---------- Memory Observation ----------
    local memory=folder("💾 Memory Monitor")
    local memoryLabel=label(memory,"Memory: unavailable until sampled")

    local function sampleMemory()
        local ok2,mb=pcall(function()
            if gcinfo then return gcinfo() end
            return nil
        end)
        local item={
            time=os.date("%Y-%m-%d %H:%M:%S"),
            value=ok2 and mb or nil
        }
        P.memorySamples[#P.memorySamples+1]=item
        return item
    end

    button(memory,"📈 Sample Memory",function()
        local x=sampleMemory()
        if x.value then
            memoryLabel.Text="Memory sample: "..tostring(x.value)
            print("[SERAPH MEMORY]",x.value)
        else
            memoryLabel.Text="Memory API not available"
        end
    end)

    button(memory,"📊 Compare Memory Samples",function()
        if #P.memorySamples<2 then
            warn("[SERAPH] Need at least two samples.")
            return
        end
        local a=P.memorySamples[#P.memorySamples-1]
        local b=P.memorySamples[#P.memorySamples]
        if a.value and b.value then
            print("[SERAPH MEMORY] Delta:",b.value-a.value)
        else
            warn("[SERAPH] Memory values unavailable.")
        end
    end)

    -- ---------- Adaptive Scheduler ----------
    local adaptive=folder("🧠 Adaptive Scheduler")
    local schedLabel=label(adaptive,"Interval: "..P.targetInterval.."s")

    textBox(adaptive,"⏱️ Initial Interval",function(v)
        local n=tonumber(v)
        if n and n>=P.minInterval and n<=P.maxInterval then
            P.targetInterval=math.floor(n)
            schedLabel.Text="Interval: "..P.targetInterval.."s"
        end
    end)

    switch(adaptive,"🧠 Adaptive Scheduling",function(v)
        P.adaptive=v==true
    end)

    local function adapt()
        if not P.adaptive then return P.targetInterval end
        if P.performanceScore<60 then
            P.targetInterval=math.min(P.targetInterval*2,P.maxInterval)
        elseif P.performanceScore>90 then
            P.targetInterval=math.max(math.floor(P.targetInterval*0.8),P.minInterval)
        end
        schedLabel.Text="Interval: "..P.targetInterval.."s"
        return P.targetInterval
    end

    button(adaptive,"⚡ Adapt Interval Now",function()
        local x=adapt()
        print("[SERAPH ADAPTIVE] New interval:",x,"seconds")
    end)

    -- ---------- Regression Performance ----------
    local regression=folder("📉 Performance Regression")
    local regLabel=label(regression,"Regression: no baseline")

    local function comparePerformance()
        if #P.samples<2 then
            regLabel.Text="Regression: need 2 profiles"
            return nil
        end
        local a=P.samples[#P.samples-1]
        local b=P.samples[#P.samples]
        local delta=b.avgFrameMs-a.avgFrameMs
        local percent=(delta/math.max(a.avgFrameMs,0.001))*100
        local improved=delta<=0
        regLabel.Text=string.format(
            "Regression: %s %.1f%%",
            improved and "improved" or "worse",
            math.abs(percent)
        )
        return improved,percent
    end

    button(regression,"🔀 Compare Last Profiles",function()
        local improved,pct=comparePerformance()
        if improved==nil then return end
        print(improved and "🟢 Performance improved" or "🔴 Performance regressed",
            string.format("%.1f%%",math.abs(pct)))
    end)

    -- ---------- AI Optimization ----------
    local ai=folder("🤖 AI Performance Advisor")
    local aiLabel=label(ai,"AI Advisor: ready")

    button(ai,"🤖 Analyze Performance With AI",function()
        local r=env().SERAPH_AI_ROUTER_PRO
        if not r or type(r.SmartRoute)~="function" then
            warn("[SERAPH] AI Router unavailable.")
            return
        end
        local latest=P.samples[#P.samples]
        local prompt="Analyze ONLY the performance of the SERAPH HUB. "
            .."Do not propose gameplay automation, remote invocation, anti-cheat changes, "
            .."or modifications outside SERAPH. Return concise recommendations with risk.\n"
            .."Static findings:\n"..table.concat(P.findings,"\n")
            .."\nType hints:\n"..table.concat(P.typeHints,"\n")
        if latest then
            prompt=prompt..string.format(
                "\nLatest profile: %.1f FPS, avg %.2fms, max %.2fms.",
                latest.fps,latest.avgFrameMs,latest.maxFrameMs
            )
        end

        task.spawn(function()
            local answer,provider=r.SmartRoute(prompt)
            if answer then
                aiLabel.Text="AI Advisor: response received"
                print("========== SERAPH AI PERFORMANCE ==========")
                print("Provider:",provider)
                print(answer)
                print("===========================================")
            else
                warn("[SERAPH AI]",tostring(provider))
            end
        end)
    end)

    -- ---------- Auto Cycle ----------
    local auto=folder("🔄 Performance Auto-Cycle")
    local autoEnabled=false
    switch(auto,"⚡ Auto Performance Monitoring",function(v)
        autoEnabled=v==true
    end)

    task.spawn(function()
        while task.wait(30) do
            if autoEnabled and P.enabled then
                local r=sampleHeartbeat(3)
                local score=100
                if r.avgFrameMs>16.67 then score-=15 end
                if r.maxFrameMs>50 then score-=15 end
                if r.maxFrameMs>100 then score-=20 end
                P.performanceScore=math.max(0,score)
                adapt()
                sampleMemory()
                comparePerformance()
            end
        end
    end)

    -- ---------- Export ----------
    local export=folder("💾 Performance Export")
    button(export,"💾 Export Performance State",function()
        local payload={
            time=os.date("%Y-%m-%d %H:%M:%S"),
            performanceScore=P.performanceScore,
            samples=P.samples,
            findings=P.findings,
            typeHints=P.typeHints,
            memory=P.memorySamples,
            interval=P.targetInterval,
            adaptive=P.adaptive
        }
        local ok2,data=pcall(HttpService.JSONEncode,HttpService,payload)
        if ok2 then print(data) end
    end)

    pcall(function()
        local e=env()
        e.SERAPH_AI_4_PERFORMANCE=e.SERAPH_AI_4_PERFORMANCE or {}
        e.SERAPH_AI_4_PERFORMANCE.State=P
        e.SERAPH_AI_4_PERFORMANCE.Profile=function(sec)
            local n=tonumber(sec) or P.profileSeconds
            return sampleHeartbeat(math.max(1,math.min(n,60)))
        end
        e.SERAPH_AI_4_PERFORMANCE.Adapt=adapt
    end)

    staticLabel.Text="Static analysis: ready"
    typeLabel.Text="Type hints: ready"
    aiLabel.Text="AI Advisor: ready"
end)


-- ============================================================
-- SERAPH AI 5.0 FREE API MANAGER
-- OpenRouter free router + optional Gemini fallback.
-- IMPORTANT: never hard-code a real API key in source.
-- The user supplies the key at runtime/configuration time.
-- ============================================================
task.defer(function()
    local HttpService = game:GetService("HttpService")
    if not window then return end

    local ok,tab=pcall(function() return window:AddTab("🌐 AI API MANAGER") end)
    if not ok or not tab then return end

    local function folder(name)
        local ok2,f=pcall(function() return tab:AddFolder(name) end)
        return ok2 and f or nil
    end
    local function button(f,n,fn)
        if f and f.AddButton then pcall(f.AddButton,f,n,fn) end
    end
    local function switch(f,n,fn)
        if f and f.AddSwitch then pcall(f.AddSwitch,f,n,fn) end
    end
    local function textBox(f,n,fn)
        if f and f.AddTextBox then pcall(f.AddTextBox,f,n,fn) end
    end
    local function label(f,t)
        if f and f.AddLabel then
            local ok2,x=pcall(f.AddLabel,f,t)
            if ok2 then return x end
        end
    end

    local A={
        provider="OpenRouter",
        endpoint="https://openrouter.ai/api/v1/chat/completions",
        model="openrouter/free",
        apiKey="",
        enabled=false,
        fallbackGemini=false,
        geminiEndpoint="https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
        timeout=30,
        maxRequests=20,
        requests=0,
        lastError="",
        lastProvider="none",
        connected=false,
    }

    local function env() return getgenv and getgenv() or _G end

    local api=folder("🔑 API Configuration")
    local status=label(api,"API: no configurada")

    textBox(api,"🔑 OpenRouter API Key",function(v)
        A.apiKey=tostring(v or "")
        status.Text=A.apiKey~="" and "API: key loaded" or "API: no configurada"
    end)

    textBox(api,"🌐 OpenRouter Endpoint",function(v)
        if tostring(v or "")~="" then A.endpoint=tostring(v) end
    end)

    textBox(api,"🤖 Model",function(v)
        if tostring(v or "")~="" then A.model=tostring(v) end
    end)

    switch(api,"🌐 Enable Internet AI",function(v)
        A.enabled=v==true
        status.Text=A.enabled and "API: enabled" or "API: disabled"
    end)

    -- Safe request wrapper with timeout, request cap and pcall.
    local function requestOpenRouter(prompt)
        if not A.enabled then return nil,"API_DISABLED" end
        if A.apiKey=="" then return nil,"API_KEY_MISSING" end
        if A.requests>=A.maxRequests then return nil,"REQUEST_LIMIT_REACHED" end

        A.requests+=1

        local body={
            model=A.model,
            messages={
                {
                    role="system",
                    content="You are the SERAPH assistant. Analyze only the user's SERAPH project. "
                        .."Do not execute code, do not invoke game remotes, do not bypass anti-cheat, "
                        .."do not automate gameplay, and do not access other players' private data."
                },
                {role="user",content=tostring(prompt)}
            },
            temperature=0.2
        }

        local encoded=HttpService:JSONEncode(body)
        local result
        local ok2,err=pcall(function()
            result=HttpService:RequestAsync({
                Url=A.endpoint,
                Method="POST",
                Headers={
                    ["Content-Type"]="application/json",
                    ["Authorization"]="Bearer "..A.apiKey,
                    ["HTTP-Referer"]="https://openrouter.ai/",
                    ["X-Title"]="SERAPH AI"
                },
                Body=encoded
            })
        end)

        if not ok2 or not result then
            A.lastError=tostring(err or "HTTP request failed")
            return nil,A.lastError
        end

        if not result.Success then
            A.lastError="HTTP "..tostring(result.StatusCode)..": "..tostring(result.StatusMessage)
            return nil,A.lastError
        end

        local decoded
        local ok3,parseErr=pcall(function()
            decoded=HttpService:JSONDecode(result.Body)
        end)
        if not ok3 or not decoded then
            return nil,"INVALID_JSON_RESPONSE"
        end

        local content=nil
        pcall(function()
            content=decoded.choices[1].message.content
        end)

        if not content then return nil,"NO_MODEL_CONTENT" end
        A.lastProvider="OpenRouter/"..A.model
        A.connected=true
        return content,A.lastProvider
    end

    -- Public router-compatible API used by the existing SERAPH modules.
    local function SmartRoute(prompt)
        local answer,provider=requestOpenRouter(prompt)
        if answer then return answer,provider end
        return nil,provider
    end

    local test=folder("🧪 Connection Test")
    button(test,"🔎 Test OpenRouter API",function()
        task.spawn(function()
            local answer,provider=SmartRoute("Respond with exactly: SERAPH API OK")
            if answer then
                status.Text="🟢 API connected"
                print("[SERAPH API]",provider,answer)
            else
                status.Text="🔴 API error"
                warn("[SERAPH API]",provider)
            end
        end)
    end)

    button(test,"📊 API Status",function()
        print("========== SERAPH API STATUS ==========")
        print("Provider:",A.provider)
        print("Model:",A.model)
        print("Enabled:",A.enabled)
        print("Connected:",A.connected)
        print("Requests:",A.requests.."/"..A.maxRequests)
        print("Last error:",A.lastError)
        print("=======================================")
    end)

    local router=folder("🔀 SERAPH AI Router")
    button(router,"🤖 Ask AI",function()
        local answer,provider=SmartRoute(
            "Give one concise maintenance recommendation for SERAPH."
        )
        if answer then print("[SERAPH AI]["..provider.."]",answer)
        else warn("[SERAPH AI]",provider) end
    end)

    -- Install/extend the existing SmartRoute interface.
    pcall(function()
        local e=env()
        e.SERAPH_AI_API_MANAGER=A
        e.SERAPH_AI_API_MANAGER.SmartRoute=SmartRoute
        e.SERAPH_AI_API_MANAGER.Test=function()
            return SmartRoute("Respond with exactly: SERAPH API OK")
        end

        -- If a router already exists, expose this provider as its fallback.
        e.SERAPH_AI_ROUTER_PRO=e.SERAPH_AI_ROUTER_PRO or {}
        e.SERAPH_AI_ROUTER_PRO.FreeAPI=SmartRoute
        e.SERAPH_AI_ROUTER_PRO.OpenRouter=SmartRoute
    end)

    -- Reset the local request counter periodically.
    task.spawn(function()
        while task.wait(86400) do
            A.requests=0
        end
    end)

    status.Text="API Manager: ready (key required)"
end)
