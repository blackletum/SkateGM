local S = SkateGM
local C = SKATEGM_CELLS
S.cells = C
C.foreign = C.foreign or {}
C.REFRESH = 0.2

local zero = Vector(0, 0, 0)

function C.Mine()
	local me = LocalPlayer()
	if not IsValid(me) then return zero end
	return me:GetNW2Vector("SkateGMFrame", zero)
end

function C.Shift(e)
	return C.foreign[e]
end

local function Shifted(self, flags)
	local off = C.foreign[self]
	if off then
		local m = Matrix()
		m:SetTranslation(off)
		cam.PushModelMatrix(m, true)
	end
	local ro = self.SkateGMRO
	if ro then
		ro(self, flags)
	elseif self.Draw then
		self:Draw(flags)
	else
		self:DrawModel(flags)
	end
	if off then cam.PopModelMatrix() end
end
C.Shifted = Shifted

local function Foreign(e, d)
	if e.RenderOverride ~= Shifted then
		e.SkateGMRO = e.RenderOverride
		e.RenderOverride = Shifted
	end
	if not e.SkateGMRB then
		local mins, maxs = e:GetRenderBounds()
		e.SkateGMRB = { mins, maxs }
	end
	local r = d:Length()
	local rb = e.SkateGMRB
	e:SetRenderBounds(rb[1] - Vector(r, r, r), rb[2] + Vector(r, r, r))
	C.foreign[e] = d
end

local function Native(e)
	C.foreign[e] = nil
	if e.RenderOverride == Shifted then
		e.RenderOverride = e.SkateGMRO
		e.SkateGMRO = nil
	end
	if e.SkateGMRB then
		e:SetRenderBounds(e.SkateGMRB[1], e.SkateGMRB[2])
		e.SkateGMRB = nil
	end
end

function C.Refresh()
	if not C.On() then return end
	local me = LocalPlayer()
	local mine = C.Mine()
	C.lastMine = mine
	local alive = {}
	for _, e in ipairs(ents.GetAll()) do
		if IsValid(e) and e:EntIndex() > 0 and not e:IsWorld() and e:GetClass() ~= C.GROUND then
			local cell = C.CellOf(e)
			local k = C.Key(cell)
			if e.SkateGMCell ~= k then
				e.SkateGMCell = k
				e:SetCustomCollisionCheck(true)
				e:CollisionRulesChanged()
			end
			if e ~= me then
				local d = Vector(cell.x - mine.x, cell.y - mine.y, 0)
				if d.x ~= 0 or d.y ~= 0 then
					Foreign(e, d)
					alive[e] = true
				end
			end
		end
	end
	for e in pairs(C.foreign) do
		if not alive[e] then
			if IsValid(e) then Native(e) else C.foreign[e] = nil end
		end
	end
end

function C.Think()
	if not C.On() then return end
	local now = RealTime()
	local mine = C.Mine()
	if now >= (C.nextRefresh or 0) or mine ~= C.lastMine then
		C.nextRefresh = now + C.REFRESH
		C.Refresh()
	end
end

function C.Nearby(centre, r, cands)
	if not C.On() then return cands end
	local out = {}
	for _, e in ipairs(cands) do
		if not C.foreign[e] then out[#out + 1] = e end
	end
	local r2 = r * r
	for e, d in pairs(C.foreign) do
		if IsValid(e) and not e:IsPlayer() and (e:GetPos() + d):DistToSqr(centre) < r2 then out[#out + 1] = e end
	end
	return out
end

function C.Pos(e) return SKATEGM_SPACE.View(e) end

hook.Add("Think", "skategm_cells", C.Think)
hook.Add("NetworkEntityCreated", "skategm_cells", function()
	C.nextRefresh = 0
end)
