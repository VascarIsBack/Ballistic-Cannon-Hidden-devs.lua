-- Discord: lossvscar | Roblox: LoopKwik
--============================================================================--
--  BALLISTIC CANNON SYSTEM
--  A self-running demo: a turret picks a target, solves the launch angle needed
--  to hit it under gravity, then fires a physics-driven projectile that arcs,
--  raycasts for collisions and explodes on impact.
--
--  Concepts shown here:
--   * OOP with metatables (Projectile "class")
--   * CFrame math (orienting parts along their velocity, aiming the barrel)
--   * Manual physics integration (semi-implicit Euler: velocity + gravity)
--   * Ballistic trajectory math (solving the firing angle to hit a point)
--   * Raycasting with RaycastParams (fast collision, no tunneling)
--   * A single Heartbeat loop that updates every projectile efficiently
--============================================================================--

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

--============================================================================--
--  CONFIG
--  All the tunable numbers live in one table so the behaviour is easy to tweak
--  without hunting through the code.
--============================================================================--
local CONFIG = {
	GravityMagnitude = 60, -- how strong gravity pulls the projectile down (studs/s^2)
	MuzzleSpeed = 130, -- how fast a projectile leaves the barrel (studs/s)
	FireInterval = 1.4, -- seconds between two shots
	ProjectileLifetime = 8, -- safety despawn if a projectile never hits anything
	ExplosionRadius = 10, -- how far an impact knocks nearby targets
	TargetRespawnDelay = 1.5, -- seconds before a destroyed target comes back
	TargetCount = 6, -- how many targets circle around the cannon
	ArenaRadius = 90, -- radius of the ring the targets sit on
}

-- Gravity is a downward vector. Keeping it as a Vector3 lets us just add it to
-- the velocity each frame instead of writing the axis out every time.
local GRAVITY = Vector3.new(0, -CONFIG.GravityMagnitude, 0)

--============================================================================--
--  SMALL BUILDING HELPERS
--  These just create the world so the demo is fully self-contained (no models
--  dragged in by hand). Everything is spawned from code.
--============================================================================--

-- Creates a Part, applies a table of properties, then parents it last.
-- Parenting last is a small performance habit: the engine doesn't re-simulate
-- the part on every property we set while it's still outside the world.
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

-- Flat baseplate the whole demo stands on.
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

-- The cannon is just a base + a barrel we can rotate to aim. We return the
-- barrel because that's the part we point at targets and fire from.
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

-- A target is a floating neon block. We tag it with an Attribute so we can tell
-- targets apart from the ground/walls when the explosion checks what's nearby.
local function spawnTarget(position)
	local target = makePart({
		Name = "Target",
		Anchored = true,
		Size = Vector3.new(5, 5, 5),
		Position = position,
		Color = Color3.fromRGB(230, 80, 90),
		Material = Enum.Material.Neon,
	})
	target:SetAttribute("IsTarget", true)
	return target
end

--============================================================================--
--  BALLISTIC MATH
--  Given where we are, where the target is, our launch speed and gravity, this
--  returns the exact launch angle so the projectile lands on the target.
--
--  Physics behind it: split the shot into horizontal distance (d) and vertical
--  offset (y). The projectile motion equations reduce to a quadratic in
--  tan(angle). Solving it gives the pitch we must fire at.
--
--    tan(theta) = ( v^2 +- sqrt( v^4 - g*(g*d^2 + 2*y*v^2) ) ) / (g * d)
--
--  If what's under the square root is negative, the target is simply out of
--  range for our muzzle speed, so we return nil and skip the shot.
--============================================================================--
local function solveLaunchDirection(origin, target, speed)
	local toTarget = target - origin

	-- Flatten the vector onto the ground plane to get the horizontal distance.
	local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
	local d = flat.Magnitude
	local y = toTarget.Y

	-- Straight up / zero distance would divide by zero, so bail out safely.
	if d < 0.001 then
		return nil
	end

	local g = CONFIG.GravityMagnitude
	local v2 = speed * speed
	local discriminant = v2 * v2 - g * (g * d * d + 2 * y * v2)
	if discriminant < 0 then
		return nil -- target unreachable with this speed
	end

	-- Take the lower angle (the flatter, faster-arriving arc of the two).
	local root = math.sqrt(discriminant)
	local tanTheta = (v2 - root) / (g * d)
	local angle = math.atan(tanTheta)

	-- Rebuild a 3D unit direction: horizontal part scaled by cos, up part by sin.
	local horizontalDir = flat.Unit
	local direction = horizontalDir * math.cos(angle) + Vector3.new(0, 1, 0) * math.sin(angle)
	return direction.Unit
end

--============================================================================--
--  PROJECTILE CLASS (metatables / OOP)
--  Each fired shot is its own object with its own position, velocity and part.
--  Using a metatable lets every projectile share the same methods (:update,
--  :onHit, :destroy) without copying those functions onto each instance.
--============================================================================--
-- Forward declarations so functions that reference each other can see them.
-- `ActiveProjectiles` holds every live shot; `destroyTarget` is defined further
-- down but is needed inside Projectile:onHit, so we reserve the local name now.
local ActiveProjectiles = {}
local destroyTarget
-- All projectiles + explosion parts live in this folder. Rays exclude the whole
-- folder so a shot never detonates on another shot or on a fading explosion.
local effectsFolder

local Projectile = {}
Projectile.__index = Projectile -- lookups that miss on the instance fall back here

-- Constructor. `ignoreList` are parts the ray should skip (the cannon itself).
function Projectile.new(origin, direction, ignoreList)
	local self = setmetatable({}, Projectile)

	self.position = origin
	self.velocity = direction * CONFIG.MuzzleSpeed
	self.age = 0
	self.alive = true

	-- The visible bullet. It gets re-oriented every frame to face its velocity.
	self.part = makePart({
		Name = "Projectile",
		Anchored = true, -- we move it ourselves via CFrame, so no engine physics
		CanCollide = false,
		Size = Vector3.new(0.6, 0.6, 2.4),
		Color = Color3.fromRGB(255, 220, 120),
		Material = Enum.Material.Neon,
		CFrame = CFrame.new(origin),
		Parent = effectsFolder,
	})

	-- One RaycastParams reused for this projectile's whole life (no per-frame
	-- allocation). We exclude the cannon so the shot doesn't hit its own barrel.
	self.rayParams = RaycastParams.new()
	self.rayParams.FilterType = Enum.RaycastFilterType.Exclude
	self.rayParams.FilterDescendantsInstances = ignoreList

	return self
end

-- Advances the projectile by one frame of `dt` seconds.
function Projectile:update(dt)
	if not self.alive then
		return
	end

	-- Safety despawn so a stray shot can't live forever and leak memory.
	self.age += dt
	if self.age >= CONFIG.ProjectileLifetime then
		self:destroy()
		return
	end

	-- Semi-implicit Euler integration: update velocity with gravity first, then
	-- use that new velocity to move. It's stable and standard for game physics.
	self.velocity += GRAVITY * dt
	local step = self.velocity * dt

	-- Raycast across the exact segment we're about to travel this frame. Doing
	-- it this way means a fast projectile can't "tunnel" through a thin target
	-- between frames, because we test the whole path, not just the end point.
	local result = Workspace:Raycast(self.position, step, self.rayParams)
	if result then
		self.position = result.Position
		self:onHit(result)
		return
	end

	-- No hit: commit the movement and rotate the bullet to look where it's going.
	-- CFrame.lookAt builds a CFrame facing from A toward B, which is exactly how
	-- we align the long axis of the bullet with its travel direction.
	self.position += step
	self.part.CFrame = CFrame.lookAt(self.position, self.position + self.velocity)
end

-- Called once when the ray reports a collision.
function Projectile:onHit(result)
	self:spawnExplosion(result.Position)

	-- Area-of-effect: any target inside the blast radius gets "destroyed".
	-- We look through the workspace once and use the attribute tag we set
	-- earlier to only affect real targets.
	for _, instance in Workspace:GetChildren() do
		if instance:GetAttribute("IsTarget") then
			local distance = (instance.Position - result.Position).Magnitude
			if distance <= CONFIG.ExplosionRadius then
				destroyTarget(instance) -- forward-declared above
			end
		end
	end

	self:destroy()
end

-- A quick expanding light sphere that fades out, purely visual feedback.
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

	-- Tween it big + transparent, then clean it up so no debris piles up.
	local goal = { Size = Vector3.new(CONFIG.ExplosionRadius * 2, CONFIG.ExplosionRadius * 2, CONFIG.ExplosionRadius * 2), Transparency = 1 }
	local tween = TweenService:Create(blast, TweenInfo.new(0.4, Enum.EasingStyle.Quad), goal)
	tween:Play()
	tween.Completed:Connect(function()
		blast:Destroy()
	end)
end

-- Marks the projectile dead and removes its part. Guarded so double-calls are safe.
function Projectile:destroy()
	if not self.alive then
		return
	end
	self.alive = false
	self.part:Destroy()
end

--============================================================================--
--  WORLD SETUP
--============================================================================--
buildGround()
local cannonBase, barrel = buildCannon()

-- Container for every projectile/explosion so the collision rays can skip them.
effectsFolder = Instance.new("Folder")
effectsFolder.Name = "CannonEffects"
effectsFolder.Parent = Workspace

-- Spread the targets evenly on a circle around the cannon using basic trig:
-- each one sits at angle (i / count) * 2*pi around the centre.
local targets = {}
for i = 1, CONFIG.TargetCount do
	local angle = (i / CONFIG.TargetCount) * math.pi * 2
	local x = math.cos(angle) * CONFIG.ArenaRadius
	local z = math.sin(angle) * CONFIG.ArenaRadius
	local target = spawnTarget(Vector3.new(x, 4, z))
	table.insert(targets, target)
end

-- Things the projectile ray must ignore: its own cannon + all effect parts.
local cannonParts = { cannonBase, barrel, effectsFolder }

--============================================================================--
--  TARGET MANAGEMENT
--  Destroying a target hides it, plays a shrink tween, then respawns it after a
--  delay so the demo keeps running forever without us re-clicking anything.
--============================================================================--
-- Assigns to the local `destroyTarget` we reserved above, so Projectile:onHit
-- can reach it even though it's written here, after the class.
function destroyTarget(target)
	-- Ignore a target that's already been knocked out (avoids double respawns).
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
			-- Respawn: restore size, position and make it hittable again.
			target.Size = Vector3.new(5, 5, 5)
			target.Position = homePosition
			target.Transparency = 0
			target:SetAttribute("Down", false)
		end)
	end)
end

-- Picks the closest target that is currently standing (not knocked down).
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

--============================================================================--
--  FIRING
--  Points the barrel at the target and spawns a projectile in that direction.
--============================================================================--
local function fireAt(target)
	-- Fire from the tip of the barrel, slightly above the base.
	local muzzle = Vector3.new(0, 6, 0)

	local direction = solveLaunchDirection(muzzle, target.Position, CONFIG.MuzzleSpeed)
	if not direction then
		return -- unreachable this shot, wait for the next target
	end

	-- Aim the barrel visually along the launch direction.
	barrel.CFrame = CFrame.lookAt(Vector3.new(0, 4, 0), Vector3.new(0, 4, 0) + direction)

	-- Create the actual projectile object; the update loop takes over from here.
	local projectile = Projectile.new(muzzle, direction, cannonParts)
	table.insert(ActiveProjectiles, projectile)
end

--============================================================================--
--  MAIN LOOPS
--============================================================================--

-- A single Heartbeat connection updates every live projectile. Iterating
-- backwards lets us remove dead ones with table.remove without skipping items.
RunService.Heartbeat:Connect(function(dt)
	for index = #ActiveProjectiles, 1, -1 do
		local projectile = ActiveProjectiles[index]
		projectile:update(dt)
		if not projectile.alive then
			table.remove(ActiveProjectiles, index)
		end
	end
end)

-- Firing timer. We accumulate delta time instead of using wait() so the cadence
-- stays accurate and stays in sync with the same clock the projectiles use.
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
