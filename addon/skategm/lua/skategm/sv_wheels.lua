local C = SKATEGM_CELLS
local W = C.wheels or {}
C.wheels = W
W.pads = W.pads or {}
W.MODEL = "models/hunter/plates/plate8x8.mdl"
W.RECENTRE = 100
W.STEP = 2
W.TILT = 3
W.LEAD = 3
W.PARK = 2000

function W.Wanted(ent)
	return C.On() and IsValid(ent) and ent:IsVehicle()
end

function W.Wheels(ent)
	if not (ent.GetWheelCount and IsValid(ent:GetPhysicsObject())) then return 0 end
	local ok, n = pcall(ent.GetWheelCount, ent)
	return ok and n or 0
end

local function Pad(car)
	local p = ents.Create("prop_physics")
	if not IsValid(p) then return nil end
	p:SetModel(W.MODEL)
	p.SkateGMPad = car
	C.SetCell(p, C.CellOf(car))
	p:SetPos(car:GetPos() - Vector(0, 0, W.PARK))
	p:Spawn()
	p:SetNoDraw(true)
	p:DrawShadow(false)
	p.PhysgunDisabled = true
	p.m_tblToolsAllowed = {}
	p.DoNotDuplicate = true
	local phys = p:GetPhysicsObject()
	if IsValid(phys) then phys:EnableMotion(false) end
	return p
end

function W.Add(car)
	if W.pads[car] or not W.Wanted(car) or W.Wheels(car) == 0 then return end
	local a, b = Pad(car), Pad(car)
	if not (a and b) then
		if IsValid(a) then a:Remove() end
		if IsValid(b) then b:Remove() end
		return
	end
	W.pads[car] = { a, b, active = 1 }
end

function W.Remove(car)
	local w2 = W.pads[car]
	if not w2 then return end
	for i = 1, 2 do if IsValid(w2[i]) then w2[i]:Remove() end end
	W.pads[car] = nil
end

local function NoEntities() return false end

function W.Ground(car)
	local cell = C.CellOf(car)
	local sum, normals, hits = Vector(0, 0, 0), Vector(0, 0, 0), 0
	for i = 0, W.Wheels(car) - 1 do
		local w = car:GetWheel(i)
		if IsValid(w) then
			local wp = w:GetPos() + w:GetVelocity() * FrameTime() * W.LEAD
			local tr = SkateGMTraceWorld({ start = wp + Vector(0, 0, 40), endpos = wp - Vector(0, 0, 120), filter = NoEntities }, cell)
			if tr.Hit and tr.HitWorld then
				sum = sum + tr.HitPos
				normals = normals + tr.HitNormal
				hits = hits + 1
			end
		end
	end
	if hits == 0 then return nil end
	return sum / hits, normals:GetNormalized()
end

function W.Follow(car, w2)
	local cell = C.CellOf(car)
	for i = 1, 2 do
		local p = w2[i]
		if IsValid(p) and p.SkateGMCell ~= car.SkateGMCell then
			C.SetCell(p, cell)
			p.padCentre = nil
			if i == w2.active then w2.active = i == 1 and 2 or 1 end
		end
	end
	local centre, normal = W.Ground(car)
	if not centre then return end
	local cur = w2[w2.active]
	local off = cur.padCentre and (centre - cur.padCentre) or nil
	local plane = off and math.abs(off:Dot(cur.padNormal)) or math.huge
	local along = off and (off - cur.padNormal * off:Dot(cur.padNormal)):Length() or math.huge
	local tilt = cur.padNormal and math.deg(math.acos(math.Clamp(normal:Dot(cur.padNormal), -1, 1))) or 180
	if along <= W.RECENTRE and plane <= W.STEP and tilt <= W.TILT then return end
	local nxt = w2.active == 1 and 2 or 1
	local p = w2[nxt]
	local ang = normal:Angle()
	ang:RotateAroundAxis(ang:Right(), -90)
	p:SetPos(centre - normal * 1.6)
	p:SetAngles(ang)
	p.padCentre, p.padNormal = centre, normal
	w2.active = nxt
	if IsValid(cur) then cur:SetPos(cur:GetPos() - normal * 4) end
end

function W.Think()
	if not C.On() then return end
	for car, w2 in pairs(W.pads) do
		if not IsValid(car) or not IsValid(w2[1]) or not IsValid(w2[2]) then
			W.Remove(car)
		else
			W.Follow(car, w2)
		end
	end
end

hook.Add("Think", "skategm_wheels", W.Think)
hook.Add("EntityRemoved", "skategm_wheels", function(ent) if W.pads[ent] then W.Remove(ent) end end)
