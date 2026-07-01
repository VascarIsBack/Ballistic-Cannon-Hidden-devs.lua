-- Discord lossvscar| Roblox: LoopKwik (not vascar)
--[[
	Ballistic cannon demo. Turret picks a target, works out the angle to hit it
	under gravity, fires a projectile that arcs, raycasts for collisions and
	explodes on impact. Uses metatables, CFrame math, a manual physics step and
	raycasting, all driven by one Heartbeat loop.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local CONFIG = {
	GravityMagnitude = 60,
	MuzzleSpeed = 130,
	FireInterval = 1.4,
	ProjectileLifetime = 8, -- safety despawn if a bullet never hits
	ExplosionRadius = 10,
	TargetRespawnDelay = 1.5,
	TargetCount = 6,
	ArenaRadius = 90,
}

local GRAVITY = Vector3.new(0, -CONFIG.GravityMagnitude, 0)

-- parenting last so the engine doesn't re-simulate the part mid-setup
local function makePart(props)
	local part = Instance.new("Part")
	for property, value in props do
		if property ~= "Parent" then
			part[property] = value
		end
	end
	part.Parent = props.Parent or Workspace
	return part
end

local function buildGround()
	return makePart({
		Name = "Ground",
		Anchored = true,
		Size = Vector3.new(400, 4, 400),
		Position = Vector3.new(0, -2, 0),
		Color = Color3.fromRGB(60, 65, 75),
		Material = Enum.Material.SmoothPlastic,
	})
end

-- returns the barrel since that's what I aim and fire from
local function buildCannon()
	local base = makePart({
		Name = "CannonBase",
		Anchored = true,
		Size = Vector3.new(6, 3, 6),
		Position = Vector3.new(0, 1.5, 0),
		Color = Color3.fromRGB(35, 35, 45),
		Material = Enum.Material.Metal,
	})

	local barrel = makePart({
		Name = "Barrel",
		Anchored = true,
		Size = Vector3.new(1.6, 1.6, 8),
		Color = Color3.fromRGB(20, 20, 28),
		Material = Enum.Material.Metal,
		CFrame = CFrame.new(0, 4, 0),
	})

	return base, barrel
end

local function spawnTarget(position)
	local target = makePart({
		Name = "Target",
		Anchored = true,
		Size = Vector3.new(5, 5, 5),
		Position = position,
		Color = Color3.fromRGB(230, 80, 90),
		Material = Enum.Material.Neon,
	})
	target:SetAttribute("IsTarget", true) -- tag so the blast only affects targets
	return target
end

--[[
	Split the shot into flat distance (d) and height (y). Projectile motion turns
	into a quadratic in tan(angle), solving it gives the pitch to fire at:
		tan(theta) = ( v^2 +- sqrt( v^4 - g*(g*d^2 + 2*y*v^2) ) ) / (g * d)
	Negative under the sqrt = too far for this speed, so return nil.
]]
local function solveLaunchDirection(origin, target, speed)
	local toTarget = target - origin
	local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
	local d = flat.Magnitude
	local y = toTarget.Y

	if d < 0.001 then
		return nil
	end

	local g = CONFIG.GravityMagnitude
	local v2 = speed * speed
	local discriminant = v2 * v2 - g * (g * d * d + 2 * y * v2)
	if discriminant < 0 then
		return nil
	end

	-- two valid angles exist, take the low one (flatter, gets there faster)
	local root = math.sqrt(discriminant)
	local angle = math.atan((v2 - root) / (g * d))

	local direction = flat.Unit * math.cos(angle) + Vector3.new(0, 1, 0) * math.sin(angle)
	return direction.Unit
end

local ActiveProjectiles = {}
local destroyTarget -- filled in below, but onHit needs it
local effectsFolder

local Projectile = {}
Projectile.__index = Projectile

function Projectile.new(origin, direction, ignoreList)
	local self = setmetatable({}, Projectile)

	self.position = origin
	self.velocity = direction * CONFIG.MuzzleSpeed
	self.age = 0
	self.alive = true

	self.part = makePart({
		Name = "Projectile",
		Anchored = true,
		CanCollide = false,
		Size = Vector3.new(0.6, 0.6, 2.4),
		Color = Color3.fromRGB(255, 220, 120),
		Material = Enum.Material.Neon,
		CFrame = CFrame.new(origin),
		Parent = effectsFolder,
	})

	-- one params reused for the bullet's whole life, skips the cannon
	self.rayParams = RaycastParams.new()
	self.rayParams.FilterType = Enum.RaycastFilterType.Exclude
	self.rayParams.FilterDescendantsInstances = ignoreList

	return self
end

function Projectile:update(dt)
	if not self.alive then
		return
	end

	self.age += dt
	if self.age >= CONFIG.ProjectileLifetime then
		self:destroy()
		return
	end

	-- semi-implicit euler: gravity onto velocity first, then move with it
	self.velocity += GRAVITY * dt
	local step = self.velocity * dt

	-- ray the whole segment, not just the end, so a fast bullet can't skip a target
	local result = Workspace:Raycast(self.position, step, self.rayParams)
	if result then
		self.position = result.Position
		self:onHit(result)
		return
	end

	self.position += step
	self.part.CFrame = CFrame.lookAt(self.position, self.position + self.velocity)
end

function Projectile:onHit(result)
	self:spawnExplosion(result.Position)

	for _, instance in Workspace:GetChildren() do
		if instance:GetAttribute("IsTarget") then
			if (instance.Position - result.Position).Magnitude <= CONFIG.ExplosionRadius then
				destroyTarget(instance)
			end
		end
	end

	self:destroy()
end

function Projectile:spawnExplosion(position)
	local blast = makePart({
		Name = "Explosion",
		Anchored = true,
		CanCollide = false,
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1, 1, 1),
		Position = position,
		Color = Color3.fromRGB(255, 170, 70),
		Material = Enum.Material.Neon,
		Transparency = 0.1,
		Parent = effectsFolder,
	})

	local goal = { Size = Vector3.new(CONFIG.ExplosionRadius * 2, CONFIG.ExplosionRadius * 2, CONFIG.ExplosionRadius * 2), Transparency = 1 }
	local tween = TweenService:Create(blast, TweenInfo.new(0.4, Enum.EasingStyle.Quad), goal)
	tween:Play()
	tween.Completed:Connect(function()
		blast:Destroy()
	end)
end

function Projectile:destroy()
	if not self.alive then
		return
	end
	self.alive = false
	self.part:Destroy()
end

buildGround()
local cannonBase, barrel = buildCannon()

effectsFolder = Instance.new("Folder")
effectsFolder.Name = "CannonEffects"
effectsFolder.Parent = Workspace

-- spread targets on a circle, each at its slice of the full turn
local targets = {}
for i = 1, CONFIG.TargetCount do
	local angle = (i / CONFIG.TargetCount) * math.pi * 2
	local x = math.cos(angle) * CONFIG.ArenaRadius
	local z = math.sin(angle) * CONFIG.ArenaRadius
	table.insert(targets, spawnTarget(Vector3.new(x, 4, z)))
end

local cannonParts = { cannonBase, barrel, effectsFolder }

function destroyTarget(target)
	if target:GetAttribute("Down") then
		return
	end
	target:SetAttribute("Down", true)

	local homePosition = target.Position
	local shrink = TweenService:Create(target, TweenInfo.new(0.2), { Size = Vector3.new(0, 0, 0) })
	shrink:Play()
	shrink.Completed:Connect(function()
		target.Transparency = 1
		task.delay(CONFIG.TargetRespawnDelay, function()
			target.Size = Vector3.new(5, 5, 5)
			target.Position = homePosition
			target.Transparency = 0
			target:SetAttribute("Down", false)
		end)
	end)
end

local function pickTarget(fromPosition)
	local best, bestDistance = nil, math.huge
	for _, target in targets do
		if not target:GetAttribute("Down") then
			local distance = (target.Position - fromPosition).Magnitude
			if distance < bestDistance then
				best, bestDistance = target, distance
			end
		end
	end
	return best
end

local function fireAt(target)
	local muzzle = Vector3.new(0, 6, 0)
	local direction = solveLaunchDirection(muzzle, target.Position, CONFIG.MuzzleSpeed)
	if not direction then
		return
	end

	barrel.CFrame = CFrame.lookAt(Vector3.new(0, 4, 0), Vector3.new(0, 4, 0) + direction)

	table.insert(ActiveProjectiles, Projectile.new(muzzle, direction, cannonParts))
end

-- loop backwards so removing a dead bullet doesn't skip the next one
RunService.Heartbeat:Connect(function(dt)
	for index = #ActiveProjectiles, 1, -1 do
		local projectile = ActiveProjectiles[index]
		projectile:update(dt)
		if not projectile.alive then
			table.remove(ActiveProjectiles, index)
		end
	end
end)

local timeSinceShot = 0
RunService.Heartbeat:Connect(function(dt)
	timeSinceShot += dt
	if timeSinceShot >= CONFIG.FireInterval then
		timeSinceShot = 0
		local target = pickTarget(Vector3.new(0, 6, 0))
		if target then
			fireAt(target)
		end
	end
end)
