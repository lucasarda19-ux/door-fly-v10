repeat task.wait() until game:IsLoaded()

----------------------------------------------------
-- CONFIG
----------------------------------------------------
local targetName = "Ghostly_x01"

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
-- LIMPIEZA TOTAL DE REINYECCION
----------------------------------------------------
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
		if type(old) == "table" and old.Destroy then
			pcall(function()
				old:Destroy("reinjected")
			end)
		elseif type(old) == "table" and old.Stop then
			pcall(function()
				old:Stop("reinjected")
			end)
		end

		ENV[key] = nil
	end
end

if ENV.__SUPER_DOOR_FLY_STOP then
	pcall(ENV.__SUPER_DOOR_FLY_STOP)
	ENV.__SUPER_DOOR_FLY_STOP = nil
end

if ENV.__doorFlyConnection then
	pcall(function()
		ENV.__doorFlyConnection:Disconnect()
	end)
	ENV.__doorFlyConnection = nil
end

----------------------------------------------------
-- SERVICES
----------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local VirtualInputManager = game:GetService("VirtualInputManager")

repeat task.wait() until Players.LocalPlayer
local LocalPlayer = Players.LocalPlayer

local function getWorkspace()
	return game:GetService("Workspace")
end

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

local ZERO = Vector3.new(0, 0, 0)
local UP = Vector3.new(0, 1, 0)

local function log(...)
	if DEBUG then
		print("[DOOR_FLY_V10]", ...)
	end
end

local function statusLog(...)
	local now = os.clock()

	if DEBUG and now - runtime.LastStatus > 2 then
		runtime.LastStatus = now
		print("[DOOR_FLY_V10]", ...)
	end
end

function runtime:AddConnection(connection)
	table.insert(self.Connections, connection)
	return connection
end

----------------------------------------------------
-- UTILS
----------------------------------------------------
local function isValidInstance(inst)
	local ok, result = pcall(function()
		return typeof(inst) == "Instance" and inst.Parent ~= nil and inst:IsDescendantOf(game)
	end)

	return ok and result
end

local function clamp(n, a, b)
	if n < a then return a end
	if n > b then return b end
	return n
end

local function safeUnit(v)
	local mag = v.Magnitude

	if mag < 0.05 then
		return ZERO, 0
	end

	return v / mag, mag
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function flatUnit(v)
	local f = flat(v)

	if f.Magnitude < 0.05 then
		return Vector3.new(1, 0, 0)
	end

	return f.Unit
end

local function getRoot(char)
	if not char then return nil end

	return char:FindFirstChild("HumanoidRootPart")
		or char:FindFirstChild("UpperTorso")
		or char:FindFirstChild("Torso")
		or char.PrimaryPart
end

local cleanupNames = {
	FlightGyro = true,
	FlightAttachment = true,
	FlightLinearVelocity = true,
	FlightAlignOrientation = true,
	ExecutorFlyVelocity = true,
	ExecutorFlyGyro = true,
	ExecutorMoveGyro = true,
	__PrivateDoorFlyGyro = true,
	__PrivateDoorFlyGyroV9 = true,
	__DoorFlyGyroV10 = true
}

local function cleanupRootObjects(root)
	if not root then return end

	for _, child in ipairs(root:GetChildren()) do
		if cleanupNames[child.Name] or child.Name:find("DoorFly") or child.Name:find("FlightGyro") then
			pcall(function()
				child:Destroy()
			end)
		end
	end

	pcall(function()
		root.AssemblyLinearVelocity = ZERO
		root.AssemblyAngularVelocity = ZERO
	end)
end

local function getCharacterParts()
	local char = LocalPlayer.Character

	if not isValidInstance(char) then
		return nil, nil, nil
	end

	local humanoid = char:FindFirstChildOfClass("Humanoid")
	local root = getRoot(char)

	if not humanoid or not root then
		return nil, nil, nil
	end

	if humanoid.Health <= 0 then
		return nil, nil, nil
	end

	return char, humanoid, root
end

local function getTargetPlayer()
	local exact = Players:FindFirstChild(targetName)

	if exact then
		return exact
	end

	local wanted = targetName:lower()

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			if player.Name:lower() == wanted or player.DisplayName:lower() == wanted then
				return player
			end
		end
	end

	return nil
end

local function getTargetRoot()
	local targetPlayer = getTargetPlayer()

	if targetPlayer and targetPlayer.Character then
		local root = getRoot(targetPlayer.Character)

		if root then
			return root, targetPlayer.Character
		end
	end

	return nil, nil
end

----------------------------------------------------
-- RAYCAST
----------------------------------------------------
local function makeRayParams(myChar, targetChar)
	local params = RaycastParams.new()
	params.IgnoreWater = true

	local ok = pcall(function()
		params.FilterType = Enum.RaycastFilterType.Exclude
	end)

	if not ok then
		pcall(function()
			params.FilterType = Enum.RaycastFilterType.Blacklist
		end)
	end

	local ignore = {}

	if myChar then
		table.insert(ignore, myChar)
	end

	if targetChar then
		table.insert(ignore, targetChar)
	end

	params.FilterDescendantsInstances = ignore

	return params
end

local function cast(origin, direction, params)
	if direction.Magnitude < 0.05 then
		return nil
	end

	return getWorkspace():Raycast(origin, direction, params)
end

----------------------------------------------------
-- PUERTAS
----------------------------------------------------
local doorWords = {
	"door",
	"gate",
	"exit",
	"entrance",
	"doorway",
	"puerta",
	"salida",
	"entrada",
	"portal"
}

local function nameLooksLikeDoor(inst)
	local current = inst
	local ws = getWorkspace()

	while current and current ~= ws do
		local lowerName = current.Name:lower()

		for _, word in ipairs(doorWords) do
			if lowerName:find(word) then
				return true
			end
		end

		current = current.Parent
	end

	return false
end

local function isUsableDoorPart(obj)
	if not obj:IsA("BasePart") then
		return false
	end

	if not nameLooksLikeDoor(obj) then
		return false
	end

	if obj.Size.Y < 2.5 then
		return false
	end

	if math.max(obj.Size.X, obj.Size.Z) < 1.2 then
		return false
	end

	return true
end

local function cacheDoors(force)
	local now = os.clock()

	if not force and now - runtime.LastDoorCache < doorRecacheInterval then
		return
	end

	runtime.LastDoorCache = now
	runtime.Doors = {}

	for _, obj in ipairs(getWorkspace():GetDescendants()) do
		if isUsableDoorPart(obj) then
			table.insert(runtime.Doors, obj)
		end
	end

	log("Puertas cacheadas:", #runtime.Doors)
end

local function isDoorRelated(instance, door)
	if not instance or not door then
		return false
	end

	if instance == door then
		return true
	end

	local parent = door.Parent

	if parent and parent ~= getWorkspace() and nameLooksLikeDoor(parent) then
		return instance:IsDescendantOf(parent)
	end

	return false
end

----------------------------------------------------
-- INTERIOR
----------------------------------------------------
local function isUnderRoof(pos, params)
	local hit = cast(pos + Vector3.new(0, 2, 0), Vector3.new(0, alturaRayTecho, 0), params)
	return hit ~= nil
end

local function countNearbyWalls(pos, params)
	local dirs = {
		Vector3.new(1, 0, 0),
		Vector3.new(-1, 0, 0),
		Vector3.new(0, 0, 1),
		Vector3.new(0, 0, -1),
		Vector3.new(1, 0, 1).Unit,
		Vector3.new(-1, 0, 1).Unit,
		Vector3.new(1, 0, -1).Unit,
		Vector3.new(-1, 0, -1).Unit
	}

	local count = 0

	for _, dir in ipairs(dirs) do
		local hit = cast(pos, dir * wallCheckDistance, params)

		if hit and hit.Instance and hit.Instance.CanCollide then
			count = count + 1
		end
	end

	return count
end

local function shouldSearchDoor(pos, targetPosition, now, params)
	if runtime.ExitedThisSpawn then
		return false
	end

	if now < runtime.IgnoreDoorsUntil then
		return false
	end

	if now - runtime.SpawnedAt < spawnGraceTime then
		return false
	end

	if not isUnderRoof(pos, params) then
		return false
	end

	local walls = countNearbyWalls(pos, params)

	if walls >= 3 then
		return true
	end

	local dir, dist = safeUnit(targetPosition - pos)

	if dist > 1 and walls >= 2 then
		local hit = cast(pos, dir * math.min(dist, 80), params)

		if hit and hit.Instance and hit.Instance.CanCollide then
			return true
		end
	end

	return false
end

----------------------------------------------------
-- RUTAS DE SALIDA
----------------------------------------------------
local function getDoorCenter(door, fromPosition)
	local lowY = door.Position.Y - door.Size.Y * 0.35
	local highY = door.Position.Y + door.Size.Y * 0.35
	local y = clamp(fromPosition.Y, lowY, highY)

	return Vector3.new(door.Position.X, y, door.Position.Z)
end

local function directionClearDistance(origin, dir, maxDistance, params)
	local unit = flatUnit(dir)
	local hit = cast(origin, unit * maxDistance, params)

	if hit and hit.Instance and hit.Instance.CanCollide then
		return (hit.Position - origin).Magnitude, hit
	end

	return maxDistance, nil
end

local function buildDoorRoute(door, fromPosition, targetPosition, params)
	if not door or not door.Parent then
		return nil
	end

	if runtime.BadDoors[door] and runtime.BadDoors[door] > os.clock() then
		return nil
	end

	local distanceToDoor = (door.Position - fromPosition).Magnitude

	if distanceToDoor > maxDoorDistance then
		return nil
	end

	local center = getDoorCenter(door, fromPosition)
	local axes = {
		flatUnit(door.CFrame.LookVector),
		flatUnit(door.CFrame.RightVector)
	}

	local bestRoute = nil
	local bestScore = -math.huge

	for _, baseAxis in ipairs(axes) do
		for _, sign in ipairs({ 1, -1 }) do
			local outsideDir = baseAxis * sign

			local insidePoint = center - outsideDir * distanciaAntesPuerta
			local middlePoint = center
			local outsidePoint = center + outsideDir * distanciaSalidaPuerta
			local clearPoint = center + outsideDir * (distanciaSalidaPuerta + 22)

			local score = -distanceToDoor

			if not isUnderRoof(outsidePoint, params) then
				score = score + 900
			else
				score = score - 250
			end

			if not isUnderRoof(clearPoint, params) then
				score = score + 450
			end

			score = score + (8 - countNearbyWalls(outsidePoint, params)) * 35

			local directHit = cast(fromPosition, insidePoint - fromPosition, params)

			if not directHit or isDoorRelated(directHit.Instance, door) then
				score = score + 180
			else
				score = score - 160
			end

			local forwardHit = cast(center + Vector3.new(0, 2, 0), outsideDir * (distanciaSalidaPuerta + 20), params)

			if not forwardHit then
				score = score + 180
			elseif isDoorRelated(forwardHit.Instance, door) then
				score = score + 80
			else
				score = score - 220
			end

			score = score + outsideDir:Dot(flatUnit(targetPosition - fromPosition)) * 40

			if score > bestScore then
				bestScore = score
				bestRoute = {
					kind = "door",
					door = door,
					score = score,
					points = {
						insidePoint,
						middlePoint,
						outsidePoint,
						clearPoint
					}
				}
			end
		end
	end

	return bestRoute
end

local function findBestOpenDirection(origin, biasPosition, params)
	local bestDir = nil
	local bestScore = -math.huge
	local biasDir = flatUnit(biasPosition - origin)

	for i = 1, 32 do
		local angle = (math.pi * 2) * (i / 32)
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local clearDistance = directionClearDistance(origin, dir, 46, params)
		local farPoint = origin + dir * math.min(clearDistance, 34)

		local score = clearDistance * 8

		if not isUnderRoof(farPoint, params) then
			score = score + 150
		end

		score = score + dir:Dot(biasDir) * 30

		if score > bestScore then
			bestScore = score
			bestDir = dir
		end
	end

	return bestDir or biasDir
end

local function buildScanRoute(fromPosition, targetPosition, params)
	local dir = findBestOpenDirection(fromPosition, targetPosition, params)

	return {
		kind = "scan",
		door = nil,
		score = 0,
		points = {
			fromPosition + dir * 24 + Vector3.new(0, 4, 0),
			fromPosition + dir * 56 + Vector3.new(0, alturaVuelo, 0)
		}
	}
end

local function chooseExitRoute(fromPosition, targetPosition, params)
	cacheDoors(false)

	local bestRoute = nil
	local bestScore = -math.huge
	local cleaned = {}

	for _, door in ipairs(runtime.Doors) do
		if door and door.Parent then
			table.insert(cleaned, door)

			local route = buildDoorRoute(door, fromPosition, targetPosition, params)

			if route and route.score > bestScore then
				bestScore = route.score
				bestRoute = route
			end
		end
	end

	runtime.Doors = cleaned

	if bestRoute then
		log("Ruta por puerta:", bestRoute.door:GetFullName(), "score:", math.floor(bestScore))
		return bestRoute
	end

	log("Sin puerta valida; escaneando hueco.")
	return buildScanRoute(fromPosition, targetPosition, params)
end

----------------------------------------------------
-- ORIENTACION / MOVIMIENTO
----------------------------------------------------
local function createGyro(root)
	if runtime.ActiveGyro and runtime.ActiveGyro.Parent == root then
		return runtime.ActiveGyro
	end

	if runtime.ActiveGyro then
		pcall(function()
			runtime.ActiveGyro:Destroy()
		end)
	end

	local gyro = Instance.new("BodyGyro")
	gyro.Name = "__DoorFlyGyroV10"
	gyro.P = 9000
	gyro.D = 350
	gyro.MaxTorque = Vector3.new(0, math.huge, 0)
	gyro.Parent = root

	runtime.ActiveGyro = gyro

	return gyro
end

local function facePosition(gyro, root, goal)
	local look = Vector3.new(goal.X, root.Position.Y, goal.Z)
	local offset = look - root.Position

	if offset.Magnitude < 0.5 then
		return
	end

	gyro.CFrame = gyro.CFrame:Lerp(
		CFrame.lookAt(root.Position, look),
		0.3
	)
end

local function avoidDirection(root, desiredDir, hit, params)
	local normal = hit.Normal
	local slideDir = desiredDir - normal * desiredDir:Dot(normal)

	if slideDir.Magnitude < 0.08 then
		local right = desiredDir:Cross(UP)

		if right.Magnitude < 0.08 then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end

		local rightClear = directionClearDistance(root.Position, right, 16, params)
		local leftClear = directionClearDistance(root.Position, -right, 16, params)

		if rightClear >= leftClear then
			slideDir = right
		else
			slideDir = -right
		end
	end

	local dodge = slideDir + normal * 0.75 + Vector3.new(0, 0.42, 0)
	local unit, mag = safeUnit(dodge)

	if mag < 0.05 then
		return desiredDir
	end

	return unit
end

local function applyVelocity(root, velocity, dt, allowFallback)
	runtime.CurrentVelocity = runtime.CurrentVelocity:Lerp(velocity, suavizado)
	root.AssemblyLinearVelocity = runtime.CurrentVelocity

	if useCFrameFallback and allowFallback and runtime.StuckTime > 0.45 then
		local unit, mag = safeUnit(runtime.CurrentVelocity)

		if mag > 8 then
			root.CFrame = root.CFrame + unit * math.min(3.5, mag * dt)
		end
	end
end

local function moveToGoal(root, gyro, goal, speed, shouldBrake, shouldAvoid, currentDoor, lockVertical, params, dt)
	local offset = goal - root.Position

	if lockVertical then
		offset = Vector3.new(offset.X, 0, offset.Z)
	end

	local desiredDir, distance = safeUnit(offset)

	if distance < 0.2 then
		return true
	end

	local moveDir = desiredDir

	if shouldAvoid then
		local hit = cast(root.Position, desiredDir * obstacleDistance, params)

		if hit and hit.Instance and hit.Instance.CanCollide and not isDoorRelated(hit.Instance, currentDoor) then
			moveDir = avoidDirection(root, desiredDir, hit, params)
		end
	end

	local desiredVelocity

	if shouldBrake and distance < distanciaFreno then
		desiredVelocity = ZERO
	else
		desiredVelocity = moveDir * speed
	end

	if lockVertical then
		desiredVelocity = Vector3.new(desiredVelocity.X, 0, desiredVelocity.Z)
	end

	applyVelocity(root, desiredVelocity, dt, not lockVertical)
	facePosition(gyro, root, goal)

	return distance < 5
end

----------------------------------------------------
-- ESTADOS
----------------------------------------------------
local function setState(newState, reason)
	if runtime.State == newState then
		return
	end

	runtime.State = newState
	log("Estado =>", newState, reason or "")
end

local function resetSession(reason)
	log("Reset:", reason or "unknown")

	runtime.State = "CHECK"
	runtime.ExitedThisSpawn = false
	runtime.SpawnedAt = os.clock()

	runtime.Route = nil
	runtime.RouteIndex = 1
	runtime.ExitStartedAt = 0
	runtime.ExitAttempts = 0

	runtime.IgnoreDoorsUntil = 0
	runtime.DoorNoUnstuckUntil = 0

	runtime.UnstuckUntil = 0
	runtime.UnstuckDir = Vector3.new(1, 0, 0)

	runtime.LastPosition = nil
	runtime.StuckTime = 0
	runtime.CurrentVelocity = ZERO
	runtime.BadDoors = {}

	local _, _, root = getCharacterParts()

	if root then
		cleanupRootObjects(root)
	end

	cacheDoors(true)
end

local function finishExit(reason)
	runtime.Route = nil
	runtime.RouteIndex = 1
	runtime.ExitedThisSpawn = true
	runtime.IgnoreDoorsUntil = os.clock() + doorIgnoreAfterExit
	setState("CHASE", reason or "salida completa")
end

local function startUnstuck(root, targetPosition, params, reason)
	runtime.UnstuckDir = findBestOpenDirection(root.Position, targetPosition, params)
	runtime.UnstuckUntil = os.clock() + unstuckSeconds
	setState("UNSTUCK", reason or "atascado")
end

local function clearBadHumanoidStates(humanoid, root)
	if root.Anchored then
		root.Anchored = false
	end

	if humanoid.Sit then
		humanoid.Sit = false
	end
end

----------------------------------------------------
-- AUTO INTERACT (Pulsar E + Soporte Custom UI)
----------------------------------------------------
local function fireProximityPrompts(door, myRoot)
	if not door then return end
	local now = os.clock()
	
	if now - runtime.LastPromptFire < 0.5 then return end 

	pcall(function()
		VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
		task.delay(0.1, function()
			VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
		end)
	end)

	local parent = door.Parent
	if parent and parent ~= getWorkspace() then
		for _, obj in ipairs(parent:GetDescendants()) do
			if obj:IsA("ProximityPrompt") and obj.Enabled then
				local promptPart = obj.Parent
				if promptPart and promptPart:IsA("BasePart") then
					local distance = (promptPart.Position - myRoot.Position).Magnitude
					
					if distance <= obj.MaxActivationDistance + 5 then
						if fireproximityprompt then
							fireproximityprompt(obj, 1) 
						else
							obj:InputHoldBegin()
							task.delay(obj.HoldDuration + 0.1, function()
								pcall(function() obj:InputHoldEnd() end)
							end)
						end
					end
				end
			end
		end
	end

	runtime.LastPromptFire = now
	log("Auto-Interact: Intento de abrir puerta.")
end

----------------------------------------------------
-- RESPAWN
----------------------------------------------------
runtime:AddConnection(LocalPlayer.CharacterRemoving:Connect(function()
	resetSession("character_removing")
end))

runtime:AddConnection(LocalPlayer.CharacterAdded:Connect(function(newChar)
	resetSession("character_added")

	task.defer(function()
		local root = newChar:WaitForChild("HumanoidRootPart", 12)

		if runtime.Alive and root then
			task.wait(0.35)
			cleanupRootObjects(root)
		end
	end)
end))

runtime:AddConnection(getWorkspace().DescendantAdded:Connect(function(obj)
	if runtime.Alive and isUsableDoorPart(obj) then
		table.insert(runtime.Doors, obj)
	end
end))

----------------------------------------------------
-- STOP
----------------------------------------------------
function runtime:Destroy(reason)
	if not self.Alive then
		return
	end

	self.Alive = false

	for _, connection in ipairs(self.Connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end

	table.clear(self.Connections)

	local _, _, root = getCharacterParts()

	if root then
		cleanupRootObjects(root)
	end

	if self.ActiveGyro then
		pcall(function()
			self.ActiveGyro:Destroy()
		end)

		self.ActiveGyro = nil
	end

	if ENV[RUN_KEY] == self then
		ENV[RUN_KEY] = nil
	end

	log("Detenido:", reason or "manual")
end

ENV.__SUPER_DOOR_FLY_STOP = function()
	if ENV[RUN_KEY] and ENV[RUN_KEY].Destroy then
		ENV[RUN_KEY]:Destroy("manual_stop")
	end

	ENV.__SUPER_DOOR_FLY_STOP = nil
end

----------------------------------------------------
-- MAIN LOOP
----------------------------------------------------
runtime:AddConnection(RunService.Heartbeat:Connect(function(dt)
	if not runtime.Alive then
		return
	end

	local myChar, humanoid, myRoot = getCharacterParts()

	if not myChar or not humanoid or not myRoot then
		statusLog("Esperando personaje/root...")
		return
	end

	local targetRoot, targetChar = getTargetRoot()

	if not targetRoot then
		statusLog("Esperando objetivo:", targetName)
		applyVelocity(myRoot, ZERO, dt, false)
		return
	end

	local params = makeRayParams(myChar, targetChar)
	local gyro = createGyro(myRoot)

	clearBadHumanoidStates(humanoid, myRoot)
	cacheDoors(false)

	local now = os.clock()

	local targetPosition = targetRoot.Position
		+ Vector3.new(0, alturaVuelo, 0)
		+ targetRoot.AssemblyLinearVelocity * 0.14

	if runtime.State == "CHECK" then
		local shouldExit = shouldSearchDoor(myRoot.Position, targetPosition, now, params)

		statusLog(
			"Estado:", runtime.State,
			"Target OK",
			"Puertas:", #runtime.Doors,
			"Buscar puerta:", shouldExit
		)

		if shouldExit then
			runtime.Route = chooseExitRoute(myRoot.Position, targetPosition, params)
			runtime.RouteIndex = 1
			runtime.ExitStartedAt = now
			runtime.ExitAttempts = 1
			runtime.DoorNoUnstuckUntil = now + doorOpenGrace
			setState("EXIT", "spawn dentro")
		elseif now - runtime.SpawnedAt >= spawnGraceTime then
			runtime.ExitedThisSpawn = true
			setState("CHASE", "spawn libre")
		end
	end

	if runtime.State == "EXIT" then
		if not runtime.Route then
			runtime.Route = chooseExitRoute(myRoot.Position, targetPosition, params)
			runtime.RouteIndex = 1
			runtime.ExitStartedAt = now
			runtime.ExitAttempts = runtime.ExitAttempts + 1
			runtime.DoorNoUnstuckUntil = now + doorOpenGrace
		end

		if now - runtime.ExitStartedAt > exitTimeout then
			if runtime.Route and runtime.Route.door then
				runtime.BadDoors[runtime.Route.door] = now + badDoorCooldown
			end

			if runtime.ExitAttempts >= maxExitAttempts then
				finishExit("timeout salida")
				return
			end

			runtime.Route = chooseExitRoute(myRoot.Position, targetPosition, params)
			runtime.RouteIndex = 1
			runtime.ExitStartedAt = now
			runtime.ExitAttempts = runtime.ExitAttempts + 1
			runtime.DoorNoUnstuckUntil = now + doorOpenGrace
		end

		local goal = runtime.Route.points[runtime.RouteIndex]

		if not goal then
			finishExit("ruta terminada")
			return
		end

		local doorPushMode = runtime.Route.kind == "door" and runtime.RouteIndex <= 3

		if doorPushMode then
			runtime.DoorNoUnstuckUntil = now + 0.9
			fireProximityPrompts(runtime.Route.door, myRoot)
		end

		-- NUEVO: Caminar hacia la puerta usando físicas normales
		gyro.MaxTorque = Vector3.new(0, 0, 0) -- Apagamos el Gyro para no flotar
		humanoid.WalkSpeed = 24 -- Caminata rápida (no activa anti-cheat)
		humanoid:MoveTo(goal)
		
		-- Sincronizamos para el sistema Anti-Atascos
		runtime.CurrentVelocity = myRoot.AssemblyLinearVelocity 

		-- Calculamos distancia 2D (solo piso, sin tomar en cuenta la altura)
		local flatPos = Vector3.new(myRoot.Position.X, 0, myRoot.Position.Z)
		local flatGoal = Vector3.new(goal.X, 0, goal.Z)
		
		if (flatGoal - flatPos).Magnitude < 3.5 then
			runtime.RouteIndex = runtime.RouteIndex + 1
		end

		if runtime.RouteIndex > #runtime.Route.points then
			finishExit("salio por ruta")
		end

	elseif runtime.State == "UNSTUCK" then
		gyro.MaxTorque = Vector3.new(0, math.huge, 0) -- Restauramos el Gyro
		
		local moveDir = runtime.UnstuckDir + Vector3.new(0, 0.7, 0)
		local unit, mag = safeUnit(moveDir)

		if mag > 0.05 then
			applyVelocity(myRoot, unit * velocidadSalida, dt, true)
			facePosition(gyro, myRoot, myRoot.Position + unit * 20)
		end

		if now >= runtime.UnstuckUntil then
			setState("CHASE", "destrabado")
		end
		
	elseif runtime.State == "CHASE" then
		statusLog("Estado:", runtime.State, "persiguiendo:", targetName)
		
		gyro.MaxTorque = Vector3.new(0, math.huge, 0) -- Encendemos Gyro para volar

		local reached = moveToGoal(
			myRoot,
			gyro,
			targetPosition,
			velocidad,
			true,
			true,
			nil,
			false,
			params,
			dt
		)

		if reached then
			applyVelocity(myRoot, ZERO, dt, false)
		end
	end

	-- LÓGICA ANTI-ATASCOS ACTUALIZADA PARA CAMINATA Y VUELO
	if runtime.LastPosition then
		local moved = (myRoot.Position - runtime.LastPosition).Magnitude
		local expected = 0
		
		if runtime.State == "EXIT" then
			expected = humanoid.WalkSpeed * dt
		else
			expected = runtime.CurrentVelocity.Magnitude * dt
		end

		if runtime.State == "EXIT" and now < runtime.DoorNoUnstuckUntil then
			runtime.StuckTime = 0
			runtime.LastPosition = myRoot.Position
			return
		end

		if expected > 0.5 and moved < expected * 0.12 then
			runtime.StuckTime = runtime.StuckTime + dt
		else
			runtime.StuckTime = 0
		end

		if runtime.StuckTime >= stuckSeconds then
			runtime.StuckTime = 0

			if runtime.State == "EXIT" then
				if runtime.Route and runtime.Route.door then
					runtime.BadDoors[runtime.Route.door] = now + badDoorCooldown
				end

				if runtime.RouteIndex >= 3 then
					finishExit("atasco despues de puerta")
				else
					runtime.Route = chooseExitRoute(myRoot.Position, targetPosition, params)
					runtime.RouteIndex = 1
					runtime.ExitStartedAt = now
					runtime.ExitAttempts = runtime.ExitAttempts + 1
					runtime.DoorNoUnstuckUntil = now + doorOpenGrace
				end
			else
				startUnstuck(myRoot, targetPosition, params, "atascado")
			end
		end
	end

	runtime.LastPosition = myRoot.Position
end))

task.defer(function()
	local started = os.clock()

	while runtime.Alive and os.clock() - started < 15 do
		local _, _, root = getCharacterParts()

		if root then
			cleanupRootObjects(root)
			break
		end

		task.wait(0.25)
	end
end)

resetSession("initial_start")
log("Script activo. Objetivo:", targetName)
