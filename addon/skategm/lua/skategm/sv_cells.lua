local C = SKATEGM_CELLS
C.tracked = C.tracked or {}
C.pieces = C.pieces or {}
C.MARGIN = 320
C.REACH_FOOT = 1400
C.REACH_SKATE = 700
C.SLOW = 160
C.SLOW_FOR = 0.5
C.FOOT_GRACE = 0.5
C.ADOPT = 2500
C.KEEP = 10
C.BUDGET = 0.006
C.MAX_PIECES = 25
C.AHEAD = 0.6

local function PieceKey(ck, ix, iy, sub) return ck .. "|" .. ix .. " " .. iy .. " " .. sub end

function C.SetCell(ent, cell)
	cell = Vector(cell.x, cell.y, 0)
	ent:SetNW2Vector("SkateGMFrame", cell)
	local k = C.Key(cell)
	if ent.SkateGMCell ~= k then
		ent.SkateGMCell = k
		ent:SetCustomCollisionCheck(true)
		ent:CollisionRulesChanged()
	end
end

function C.CellFor(abs)
	local best, bestD
	for _, p in ipairs(player.GetAll()) do
		local cell = C.CellOf(p)
		local l = abs - cell
		if math.abs(l.x) < C.CELL * 0.75 and math.abs(l.y) < C.CELL * 0.75 then
			local d = (p:GetPos() + cell):DistToSqr(abs)
			if not bestD or d < bestD then best, bestD = cell, d end
		end
	end
	return best or C.Snap(abs)
end

function C.Place(ent, abs)
	if not C.On() then ent:SetPos(abs) return vector_origin end
	local cell = C.CellFor(abs)
	C.SetCell(ent, cell)
	ent:SetPos(abs - cell)
	C.Track(ent)
	return cell
end

function C.PlacePlayer(ply, abs) return SKATEGM_SPACE.Place(ply, abs) end

function C.Local(ent, abs) return SKATEGM_SPACE.ToLocal(ent, abs) end

local function Trackable(ent)
	if not IsValid(ent) or ent:IsPlayer() or ent:IsWorld() or ent:EntIndex() <= 0 then return false end
	if ent:GetClass() == C.GROUND or IsValid(ent:GetParent()) or ent.SkateGMPad then return false end
	if ent:CreatedByMap() then return false end
	local mdl = ent:GetModel()
	return IsValid(ent:GetPhysicsObject()) or (mdl ~= nil and mdl ~= "")
end

function C.Track(ent)
	if C.tracked[ent] or not Trackable(ent) then return end
	C.tracked[ent] = true
	if C.wheels and C.wheels.Wanted(ent) then timer.Simple(0.1, function() if IsValid(ent) then C.wheels.Add(ent) end end) end
	if not ent.SkateGMCell then
		local from = ent.SkateGMCellFrom
		if not IsValid(from) then from = ent.GetCreator and ent:GetCreator() end
		if not IsValid(from) then from = ent:GetOwner() end
		if not IsValid(from) then from = ent:GetPhysicsAttacker() end
		C.SetCell(ent, IsValid(from) and C.CellOf(from) or vector_origin)
	end
end

local function FromPlayer(ply, ent)
	if not (C.On() and IsValid(ply) and IsValid(ent)) then return end
	ent.SkateGMCellFrom = ply
	C.SetCell(ent, C.CellOf(ply))
	C.Track(ent)
end

hook.Add("PlayerSpawnedProp", "skategm_cells", function(ply, _, ent) FromPlayer(ply, ent) end)
hook.Add("PlayerSpawnedRagdoll", "skategm_cells", function(ply, _, ent) FromPlayer(ply, ent) end)
hook.Add("PlayerSpawnedEffect", "skategm_cells", function(ply, _, ent) FromPlayer(ply, ent) end)
hook.Add("PlayerSpawnedSENT", "skategm_cells", FromPlayer)
hook.Add("PlayerSpawnedVehicle", "skategm_cells", FromPlayer)
hook.Add("PlayerSpawnedNPC", "skategm_cells", FromPlayer)
hook.Add("PlayerSpawnedSWEP", "skategm_cells", FromPlayer)

hook.Add("OnEntityCreated", "skategm_cells", function(ent)
	if not C.On() then return end
	timer.Simple(0, function() if IsValid(ent) then C.Track(ent) end end)
end)

hook.Add("PlayerSpawn", "skategm_cells", function(ply)
	if not C.On() then return end
	timer.Simple(0, function()
		if IsValid(ply) and not ply.SkateGM then
			C.HoldPlayer(ply, false, CurTime())
			C.nextThink = 0
		end
	end)
end)

hook.Add("OnPhysgunPickup", "skategm_cells", function(ply, ent) ply.SkateGMHolding = ent end)
hook.Add("PhysgunDrop", "skategm_cells", function(ply) ply.SkateGMHolding = nil end)
hook.Add("GravGunOnPickedUp", "skategm_cells", function(ply, ent) ply.SkateGMHolding = ent end)
hook.Add("GravGunOnDropped", "skategm_cells", function(ply) ply.SkateGMHolding = nil end)

local function Group(ent)
	if constraint and constraint.HasConstraints(ent) then
		local out = {}
		for _, e in pairs(constraint.GetAllConstrainedEntities(ent)) do
			if IsValid(e) and not e:IsWorld() and not e:IsPlayer() then out[#out + 1] = e end
		end
		if #out > 0 then return out end
	end
	return { ent }
end

function C.MoveGroup(ent, cell)
	for _, e in ipairs(Group(ent)) do
		local old = C.CellOf(e)
		if old ~= cell then
			local d = Vector(cell.x - old.x, cell.y - old.y, 0)
			local phys = e:GetPhysicsObject()
			local vel = IsValid(phys) and phys:GetVelocity()
			local angvel = IsValid(phys) and phys:GetAngleVelocity()
			C.SetCell(e, cell)
			e:SetPos(e:GetPos() - d)
			if vel then phys:SetVelocityInstantaneous(vel) phys:AddAngleVelocity(angvel - phys:GetAngleVelocity()) end
		end
	end
end

function C.Transmit(p, ply)
	if not p.ents then return end
	local list = ply and { ply } or player.GetAll()
	if p.sent == nil then p.sent = {} end
	for _, pl in ipairs(list) do
		local see = pl.SkateGMCell == p.ck and not pl.SkateGM
		if p.sent[pl] ~= see then
			p.sent[pl] = see
			for _, e in ipairs(p.ents) do
				if IsValid(e) then e:SetPreventTransmit(pl, not see) end
			end
		end
	end
end

function C.PlayerShifted(ply)
	local held = ply.SkateGMHolding
	if IsValid(held) then C.MoveGroup(held, C.CellOf(ply)) end
	for _, p in pairs(C.pieces) do C.Transmit(p, ply) end
end

local function Ground(w, sub)
	local e = ents.Create(C.GROUND)
	if not IsValid(e) then return nil end
	e:SetPieceX(w.ix)
	e:SetPieceY(w.iy)
	e:SetPieceSub(sub)
	e:SetCellKey(w.ck)
	e.SkateGMCell = w.ck
	e:SetNW2Vector("SkateGMFrame", w.cell)
	local x, y = C.PieceCorner(w.ix, w.iy, sub)
	e:SetPos(Vector(x - w.cell.x, y - w.cell.y, 0))
	e:SetAngles(angle_zero)
	e:Spawn()
	return e
end

function C.MakePiece(w, now)
	local p = { ents = {}, used = now, ck = w.ck }
	local e = Ground(w, w.sub)
	if e then p.ents[1] = e end
	C.Transmit(p)
	return p
end

local function Mover(ent)
	local phys = ent:GetPhysicsObject()
	if not IsValid(phys) then return nil end
	if phys:IsMotionEnabled() or ent.SkateGMHeld then return phys end
	return nil
end

function C.HoldPlayer(ply, ready, now)
	if not ready then
		ply.SkateGMFootReady = nil
		if not ply.SkateGMFootHeld and ply:GetMoveType() == MOVETYPE_WALK then
			ply.SkateGMFootHeld = true
			ply:SetMoveType(MOVETYPE_NONE)
			ply:SetLocalVelocity(vector_origin)
		end
		return
	end
	ply.SkateGMFootReady = ply.SkateGMFootReady or now
	if ply.SkateGMFootHeld and now - ply.SkateGMFootReady > C.FOOT_GRACE then
		ply.SkateGMFootHeld = nil
		if ply:GetMoveType() == MOVETYPE_NONE then ply:SetMoveType(MOVETYPE_WALK) end
	end
end

function C.Think()
	if not C.On() then return end
	local now = CurTime()
	if now < (C.nextThink or 0) then return end
	C.nextThink = now + 0.1
	local want = {}
	local function Want(cell, lo, hi, pri)
		local ck = C.Key(cell)
		local x0, y0, x1, y1 = C.PieceRange(lo, hi)
		if (x1 - x0 + 1) * (y1 - y0 + 1) > C.MAX_PIECES then
			local mid = (lo + hi) / 2
			x0, y0, x1, y1 = C.PieceRange(mid - Vector(C.PIECE, C.PIECE, 0), mid + Vector(C.PIECE, C.PIECE, 0))
		end
		local ready = true
		for ix = x0, x1 do
			for iy = y0, y1 do
				for _, sub in ipairs(C.PieceParts(ix, iy)) do
					local k = PieceKey(ck, ix, iy, sub)
					local w = want[k]
					if not w then
						want[k] = { cell = cell, ck = ck, ix = ix, iy = iy, sub = sub, pri = pri }
					elseif pri < w.pri then
						w.pri = pri
					end
					if not C.pieces[k] then ready = false end
				end
			end
		end
		return ready
	end
	local players = {}
	for _, ply in ipairs(player.GetAll()) do
		if not ply.SkateGMCell then C.SetCell(ply, C.CellOf(ply)) end
		local cell = C.CellOf(ply)
		local abs = ply:GetPos() + cell
		players[#players + 1] = { ply = ply, cell = cell, abs = abs, ck = C.Key(cell) }
		local last = ply.SkateGMCellLast
		local speed = last and (abs - last):Length() / 0.1 or 0
		ply.SkateGMCellLast = abs
		if ply.SkateGM then
			if speed < C.SLOW then ply.SkateGMSlowFor = (ply.SkateGMSlowFor or 0) + 0.1 else ply.SkateGMSlowFor = 0 end
		end
		if ply:Alive() and (not ply.SkateGM or ply.SkateGMSlowFor >= C.SLOW_FOR) then
			local r = ply.SkateGM and C.REACH_SKATE or C.REACH_FOOT
			Want(cell, abs - Vector(r, r, 0), abs + Vector(r, r, 0), ply.SkateGM and 2 or 0)
			local under = Want(cell, abs - Vector(64, 64, 0), abs + Vector(64, 64, 0), 0)
			if not ply.SkateGM then C.HoldPlayer(ply, under, now) end
			local l = ply:GetPos()
			if not ply.SkateGM and (math.abs(l.x) > C.CELL * 0.75 or math.abs(l.y) > C.CELL * 0.75) then
				local target = C.Snap(abs)
				if Want(target, abs - Vector(r, r, 0), abs + Vector(r, r, 0), 1) then
					C.SetCell(ply, target)
					ply:SetPos(abs - target)
					C.PlayerShifted(ply)
				end
			end
		end
		if ply:Alive() then
			if ply.SkateGMSentFoot ~= (not ply.SkateGM) then
				ply.SkateGMSentFoot = not ply.SkateGM
				for _, p in pairs(C.pieces) do C.Transmit(p, ply) end
			end
		end
	end
	for ent in pairs(C.tracked) do
		if not IsValid(ent) then
			C.tracked[ent] = nil
		else
			local cell = C.CellOf(ent)
			local ck = ent.SkateGMCell or C.Key(cell)
			local abs = ent:GetPos() + cell
			local phys = Mover(ent)
			local target
			local near, nearD, mine = nil, nil, false
			for _, pl in ipairs(players) do
				local d = pl.abs:DistToSqr(abs)
				if d < C.ADOPT * C.ADOPT then
					if pl.ck == ck then mine = true end
					if not nearD or d < nearD then near, nearD = pl, d end
				end
			end
			if near and not mine and near.ck ~= ck then target = near.cell end
			if not target and phys then
				local l = ent:GetPos()
				if math.abs(l.x) > C.CELL * 0.75 or math.abs(l.y) > C.CELL * 0.75 then target = C.Snap(abs) end
			end
			if phys then
				local mins, maxs = ent:WorldSpaceAABB()
				local m = Vector(C.MARGIN, C.MARGIN, 0)
				local lo, hi = mins + cell - m, maxs + cell + m
				local ahead = phys:GetVelocity() * C.AHEAD
				ahead.z = 0
				lo = Vector(math.min(lo.x, lo.x + ahead.x), math.min(lo.y, lo.y + ahead.y), lo.z)
				hi = Vector(math.max(hi.x, hi.x + ahead.x), math.max(hi.y, hi.y + ahead.y), hi.z)
				local ready = Want(cell, lo, hi, 1)
				local readyT = target and Want(target, lo, hi, 1)
				if target and readyT then
					C.MoveGroup(ent, target)
					ready = true
				end
				if not ready and phys:IsMotionEnabled() and not ent:IsVehicle() then
					phys:EnableMotion(false)
					ent.SkateGMHeld = true
				elseif ready and ent.SkateGMHeld then
					ent.SkateGMHeld = nil
					phys:EnableMotion(true)
					phys:Wake()
				end
			elseif target then
				C.MoveGroup(ent, target)
			end
		end
	end
	for k, w in pairs(want) do
		local p = C.pieces[k]
		if p then
			p.used = now
		end
	end
	local missing = {}
	for k, w in pairs(want) do
		if not C.pieces[k] then
			w.key = k
			missing[#missing + 1] = w
		end
	end
	table.sort(missing, function(a, b) return a.pri < b.pri end)
	local t0 = SysTime()
	for _, w in ipairs(missing) do
		if SysTime() - t0 > C.BUDGET then break end
		C.pieces[w.key] = C.MakePiece(w, now)
	end
	for k, p in pairs(C.pieces) do
		if not want[k] and now - p.used > C.KEEP then
			for _, e in ipairs(p.ents or {}) do
				if IsValid(e) then e:Remove() end
			end
			C.pieces[k] = nil
		end
	end
end

hook.Add("Think", "skategm_cells", C.Think)

function C.Stats()
	local n, built, tris = 0, 0, 0
	for _, p in pairs(C.pieces) do
		n = n + 1
		built = built + #(p.ents or {})
	end
	local t = 0
	for _ in pairs(C.tracked) do t = t + 1 end
	return n, built, t
end

concommand.Add("skategm_cells_stats", function(ply)
	if IsValid(ply) and not ply:IsAdmin() then return end
	local n, built, t = C.Stats()
	print(string.format("[SkateGM] cells: %d pieces wanted, %d with ground, %d entities tracked", n, built, t))
end)
