repeat task.wait() until game:IsLoaded()

----------------------------------------------------
-- CONFIG
----------------------------------------------------
local targetName = "MercuRBX"
local velocidad = 200
local velocidadSalida = 95
local suavizado = 0.18
local alturaVuelo = 12
local distanciaFreno = 5
local obstacleDistance = 9
local alturaRayTecho = 90
local wallCheckDistance = 18
local maxDoorDistance = 350
local distanciaSalidaPuerta = 28
local distanciaAntesPuerta = 7
local spawnGraceTime = 1.2
local doorIgnoreAfterExit = 12
local doorOpenGrace = 3.5
local exitTimeout = 12
local maxExitAttempts = 3
local stuckSeconds = 1.15
local unstuckSeconds = 0.55
local badDoorCooldown = 10
local doorRecacheInterval = 3
local useCFrameFallback = true
local DEBUG = true

----------------------------------------------------
-- LIMPIEZA
----------------------------------------------------
print("🚀 DOOR FLY V10 - Iniciando...")

local ENV = getgenv and getgenv() or _G

local oldKeys = {
    "__PRIVATE_SUPER_DOOR_FLY_V7",
    "__PRIVATE_SUPER_DOOR_FLY_V8",
    "__PRIVATE_SUPER_DOOR_FLY_V9",
    "__PRIVATE_DOOR_FLY_STABLE_V10"
}

for _, key in ipairs(oldKeys) do
    local old = ENV[key]
    if old then
        pcall(function()
            if old.Destroy then old:Destroy() end
            if old.Stop then old:Stop() end
        end)
        ENV[key] = nil
    end
end

----------------------------------------------------
-- SERVICES
----------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Workspace = game:GetService("Workspace")

repeat task.wait() until Players.LocalPlayer
local LocalPlayer = Players.LocalPlayer

print("✅ Script cargado | Target:", targetName)

----------------------------------------------------
-- RUNTIME
----------------------------------------------------
local RUN_KEY = "__PRIVATE_DOOR_FLY_STABLE_V10"
local runtime = {
    Alive = true,
    Connections = {},
    State = "CHECK",
    ExitedThisSpawn = false,
    SpawnedAt = os.clock(),
    Route = nil,
    RouteIndex = 1,
    ExitStartedAt = 0,
    ExitAttempts = 0,
    IgnoreDoorsUntil = 0,
    DoorNoUnstuckUntil = 0,
    UnstuckUntil = 0,
    UnstuckDir = Vector3.new(1, 0, 0),
    LastPosition = nil,
    StuckTime = 0,
    CurrentVelocity = Vector3.zero,
    ActiveGyro = nil,
    Doors = {},
    BadDoors = {},
    LastDoorCache = 0,
    LastStatus = 0,
    LastPromptFire = 0
}

ENV[RUN_KEY] = runtime

----------------------------------------------------
-- UTILS
----------------------------------------------------
local function log(...)
    if DEBUG then print("[DOOR_FLY_V10]", ...) end
end

local function statusLog(...)
    if DEBUG and os.clock() - runtime.LastStatus > 2 then
        runtime.LastStatus = os.clock()
        print("[DOOR_FLY_V10]", ...)
    end
end

local function getRoot(char)
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart") or char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or char.PrimaryPart
end

local function getCharacterParts()
    local char = LocalPlayer.Character
    if not char then return nil, nil, nil end
    local humanoid = char:FindFirstChildOfClass("Humanoid")
    local root = getRoot(char)
    if not humanoid or not root or humanoid.Health <= 0 then
        return nil, nil, nil
    end
    return char, humanoid, root
end

local function getTargetRoot()
    local target = Players:FindFirstChild(targetName)
    if not target then
        local lower = targetName:lower()
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and (plr.Name:lower() == lower or plr.DisplayName:lower() == lower) then
                target = plr
                break
            end
        end
    end
    if target and target.Character then
        local root = getRoot(target.Character)
        if root then return root, target.Character end
    end
    return nil, nil
end

----------------------------------------------------
-- RAYCAST
----------------------------------------------------
local function makeRayParams(myChar, targetChar)
    local params = RaycastParams.new()
    params.IgnoreWater = true
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    if myChar then table.insert(ignore, myChar) end
    if targetChar then table.insert(ignore, targetChar) end
    params.FilterDescendantsInstances = ignore
    return params
end

local function cast(origin, direction, params)
    if direction.Magnitude < 0.05 then return nil end
    return Workspace:Raycast(origin, direction, params)
end

----------------------------------------------------
-- PUERTAS (simplificado por ahora)
----------------------------------------------------
local doorWords = {"door","gate","exit","entrance","doorway","puerta","salida","entrada","portal"}

local function nameLooksLikeDoor(inst)
    local current = inst
    while current and current ~= Workspace do
        local lowerName = current.Name:lower()
        for _, word in ipairs(doorWords) do
            if lowerName:find(word) then return true end
        end
        current = current.Parent
    end
    return false
end

local function isUsableDoorPart(obj)
    if not obj:IsA("BasePart") then return false end
    if not nameLooksLikeDoor(obj) then return false end
    if obj.Size.Y < 2.5 then return false end
    if math.max(obj.Size.X, obj.Size.Z) < 1.2 then return false end
    return true
end

local function cacheDoors(force)
    local now = os.clock()
    if not force and now - runtime.LastDoorCache < doorRecacheInterval then return end
    runtime.LastDoorCache = now
    runtime.Doors = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if isUsableDoorPart(obj) then
            table.insert(runtime.Doors, obj)
        end
    end
    log("Puertas cacheadas:", #runtime.Doors)
end

----------------------------------------------------
-- MAIN LOOP
----------------------------------------------------
runtime.AddConnection = function(connection)
    table.insert(runtime.Connections, connection)
    return connection
end

runtime.AddConnection(RunService.Heartbeat:Connect(function(dt)
    if not runtime.Alive then return end

    local myChar, humanoid, myRoot = getCharacterParts()
    if not myRoot then
        statusLog("Esperando personaje...")
        return
    end

    local targetRoot, targetChar = getTargetRoot()
    if not targetRoot then
        statusLog("Esperando objetivo:", targetName)
        return
    end

    local params = makeRayParams(myChar, targetChar)
    local now = os.clock()
    local targetPosition = targetRoot.Position + Vector3.new(0, alturaVuelo, 0)

    statusLog("✅ Script funcionando | Estado:", runtime.State)
end))

print("✅ DOOR FLY V10 CARGADO CORRECTAMENTE")
