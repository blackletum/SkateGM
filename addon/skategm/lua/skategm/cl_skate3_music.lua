local S = SkateGM

local SM = S.skate3Music or {}
S.skate3Music = SM
SM.MANIFEST = "skategm/skate3_music.json"
SM.LB, SM.RS = 0x0100, 0x0080
SM.FLICK, SM.FLICK_BACK, SM.VOLUME_DEAD = 0.7, 0.4, 0.3
SM.VOLUME_RATE, SM.VOLUME_SAVE = 0.6, 0.3
SM.DRIFT = 0.75
SM.NOTE_TIME = 4
SM.SLIDE = 0.35
SM.BAR_W, SM.BAR_H, SM.DOT = 220, 8, 9
SM.BAR_FULL, SM.BAR_EMPTY = Color(30, 110, 200), Color(150, 205, 250)

SM.cvOn = SM.cvOn or CreateClientConVar("skategm_skate3_music", "1", true, false, "1 = Skate 3's songs (from your game) play while you skate", 0, 1)
SM.cvVolume = SM.cvVolume or CreateClientConVar("skategm_skate3_music_volume", "0.5", true, false, "Skate 3 music volume, 0-1", 0, 1)

function SM.Songs()
	if SM.songs then return SM.songs end
	SM.songs, SM.byId = {}, {}
	local text = file and file.Read and file.Read(SM.MANIFEST, "DATA")
	local m = text and util.JSONToTable(text)
	for _, s in ipairs(m and m.songs or {}) do
		if type(s.id) == "string" and type(s.file) == "string" and tonumber(s.seconds) and file.Exists(s.file, "GAME") then
			local song = { id = s.id, file = s.file, artist = tostring(s.artist or ""), title = tostring(s.title or ""), seconds = tonumber(s.seconds) }
			SM.songs[#SM.songs + 1] = song
			SM.byId[song.id] = song
		end
	end
	return SM.songs
end
function SM.Have() return #SM.Songs() > 0 end
function SM.On() return SM.cvOn:GetBool() and SM.Have() end
function SM.Name(song) return song and (song.artist ~= "" and (song.artist .. " - " .. song.title) or song.title) or "" end

function SM.Shuffle()
	local order = {}
	for i, s in ipairs(SM.Songs()) do order[i] = s.id end
	for i = #order, 2, -1 do
		local j = math.random(i)
		order[i], order[j] = order[j], order[i]
	end
	SM.order, SM.at = order, 1
end

function SM.Time(st, now)
	if not st then return 0 end
	return st.paused or (now - st.start)
end

function SM.Note(text, volume)
	local real, n = RealTime(), SM.note
	if volume and n and n.volume and real - n.t < SM.NOTE_TIME then
		if real - n.t > SM.SLIDE then n.t = real - SM.SLIDE end
		return
	end
	SM.note = { text = text, volume = volume, t = real }
end

function SM.Play(id, now)
	SM.me = { id = id, start = now }
	SM.Note(SM.Name(SM.byId[id]))
end

function SM.Next(now)
	if not SM.order or #SM.order == 0 then SM.Shuffle() end
	SM.at = (SM.at or 0) % #SM.order + 1
	SM.Play(SM.order[SM.at], now)
end

function SM.Hold(st, now)
	if st and not st.paused then st.paused = math.max(0, now - st.start) end
end
function SM.Resume(st, now)
	if st and st.paused then st.start, st.paused = now - st.paused, nil end
end

function SM.TogglePause(now)
	local me = SM.me
	if not me then return end
	if me.stopped then
		me.stopped = nil
		SM.Resume(me, now)
		SM.Note(SM.Name(SM.byId[me.id]))
	else
		SM.Hold(me, now)
		me.stopped = true
		SM.Note("Music paused")
	end
end

function SM.Restart(now)
	if SM.me then SM.Play(SM.me.id, now) end
end

function SM.Volume()
	return SM.volume or math.Clamp(SM.cvVolume:GetFloat(), 0, 1)
end

function SM.TakesStick(pad)
	return SM.On() and pad ~= nil and bit.band(pad.buttons or 0, SM.LB) ~= 0
end

function SM.Input(pad, real, now, dt)
	local busy = SKATEGM_UI and SKATEGM_UI.Busy and SKATEGM_UI.Busy()
	if not (SM.me and SM.TakesStick(pad)) or busy then
		SM.clickHeld = pad ~= nil and bit.band(pad.buttons or 0, SM.RS) ~= 0
		SM.dir = nil
		return
	end
	local click = bit.band(pad.buttons or 0, SM.RS) ~= 0
	if click and SM.clickHeld == false then SM.TogglePause(now) end
	SM.clickHeld = click
	local x, y = pad.rx or 0, pad.ry or 0
	local dir = SM.dir
	if x > SM.FLICK then dir = 1 elseif x < -SM.FLICK then dir = -1 elseif math.abs(x) < SM.FLICK_BACK then dir = 0 end
	if SM.dir == 0 and dir == 1 then SM.Next(now) elseif SM.dir == 0 and dir == -1 then SM.Restart(now) end
	SM.dir = dir
	if math.abs(y) > SM.VOLUME_DEAD and math.abs(y) > math.abs(x) then
		SM.volume = math.Clamp(SM.Volume() + y * SM.VOLUME_RATE * dt, 0, 1)
		SM.Note("Music volume", true)
		if real - (SM.volumeSaved or -1) > SM.VOLUME_SAVE then
			SM.volumeSaved = real
			RunConsoleCommand("skategm_skate3_music_volume", string.format("%.2f", SM.volume))
		end
	elseif SM.volume and real - (SM.volumeSaved or -1) > SM.VOLUME_SAVE then
		RunConsoleCommand("skategm_skate3_music_volume", string.format("%.2f", SM.volume))
		SM.volume, SM.volumeSaved = nil, nil
	end
end

SM.WORDS = { up = "volume up", down = "volume down", left = "start over", right = "skip" }

function SM.PaintControls(w, h, u, on, text, keys)
	if not (SM.On() and SM.me) then return false end
	local font = "skategm_cmid"
	surface.SetFont(font)
	local leftW = surface.GetTextSize(SM.WORDS.left)
	local gap = u * 0.45
	local r = u * 1.5
	local cx, cy = math.floor(w * 0.03 + leftW + gap + r), math.floor(h * 0.82)
	draw.RoundedBox(r + 2, cx - r - 2, cy - r - 2, (r + 2) * 2, (r + 2) * 2, Color(0, 0, 0, 160))
	draw.RoundedBox(r, cx - r, cy - r, r * 2, r * 2, Color(70, 70, 70, 210))
	local k = u * 0.6
	draw.RoundedBox(k, cx - k, cy - k, k * 2, k * 2, on)
	if keys then draw.SimpleText("Ctrl", "skategm_ui_key", cx, cy, Color(10, 10, 10), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER) end
	surface.SetDrawColor(on.r, on.g, on.b, on.a)
	draw.NoTexture()
	local a, b = r * 0.92, u * 0.32
	surface.DrawPoly({ { x = cx, y = cy - a }, { x = cx + b, y = cy - a + b }, { x = cx - b, y = cy - a + b } })
	surface.DrawPoly({ { x = cx, y = cy + a }, { x = cx - b, y = cy + a - b }, { x = cx + b, y = cy + a - b } })
	surface.DrawPoly({ { x = cx - a, y = cy }, { x = cx - a + b, y = cy - b }, { x = cx - a + b, y = cy + b } })
	surface.DrawPoly({ { x = cx + a, y = cy }, { x = cx + a - b, y = cy + b }, { x = cx + a - b, y = cy - b } })
	text(SM.WORDS.up, font, cx, cy - r - gap, on, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
	text(SM.WORDS.down, font, cx, cy + r + gap, on, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	text(SM.WORDS.left, font, cx - r - gap, cy, on, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
	text(SM.WORDS.right, font, cx + r + gap, cy, on, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	local _, th = surface.GetTextSize("M")
	local click = (keys and "Ctrl: " or "click: ") .. (SM.me.stopped and "play" or "pause")
	text(click, font, cx, cy + r + gap + th * 1.15, on, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
	text("MUSIC", font, cx, cy - r - gap - th * 1.15, Color(200, 200, 200, 200), TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
	return true
end

function SM.Release(slot)
	if slot and IsValid(slot.ch) then slot.ch:Stop() end
end

function SM.Load(slot, song)
	slot.id, slot.ch = song.id, nil
	sound.PlayFile(song.file, "noplay noblock", function(ch)
		if not IsValid(ch) then return end
		if slot.id ~= song.id then ch:Stop() return end
		slot.ch = ch
	end)
end

function SM.Follow(slot, st, now, volume)
	local song = st and SM.byId[st.id]
	if not song or volume <= 0 then
		SM.Release(slot)
		slot.id, slot.ch = nil, nil
		return
	end
	if slot.id ~= song.id then
		SM.Release(slot)
		SM.Load(slot, song)
	end
	local ch = slot.ch
	if not IsValid(ch) then return end
	ch:SetVolume(volume)
	local t = SM.Time(st, now)
	if t >= song.seconds then
		if ch:GetState() ~= GMOD_CHANNEL_STOPPED then ch:Pause() end
		return
	end
	if math.abs(ch:GetTime() - t) > SM.DRIFT then ch:SetTime(math.max(0, t)) end
	if st.paused then
		if ch:GetState() == GMOD_CHANNEL_PLAYING then ch:Pause() end
	elseif ch:GetState() ~= GMOD_CHANNEL_PLAYING then
		ch:Play()
	end
end

function SM.StickFlag(on)
	if SM.stickSent == on then return end
	SM.stickSent = on
	if skategm and skategm.SetLBRightStick then skategm.SetLBRightStick(on and 1 or 0) end
end

function SM.GameMusic()
	local M = SKATEGM_MODES
	local cur = M and M.music and M.music.current
	return cur ~= nil and (cur.vol or 0) > 0
end

function SM.Think(real, now, dt)
	local on = SM.On()
	SM.StickFlag(true)
	if on and not SM.me then
		SM.Shuffle()
		SM.Play(SM.order[1], now)
	elseif not on and SM.me then
		SM.me, SM.dir = nil, nil
	end
	local me = SM.me
	if me then
		local skating = (S.phase == "on" or S.phase == "loading") and not (SKATEGM_UI and SKATEGM_UI.IsOpen and SKATEGM_UI.IsOpen("replay"))
		if skating and not me.stopped then SM.Resume(me, now) elseif not skating then SM.Hold(me, now) end
		if skating then SM.Input(S.API and S.API.Pad and S.API.Pad(), real, now, dt or 0) end
		local song = SM.byId[me.id]
		if not song or SM.Time(me, now) >= song.seconds then SM.Next(now) end
	end
	SM.mine = SM.mine or {}
	SM.Follow(SM.mine, SM.me, now, SM.GameMusic() and 0 or SM.Volume())
end

function SM.Slide(age)
	local k
	if age < SM.SLIDE then
		k = age / SM.SLIDE
	elseif age > SM.NOTE_TIME - SM.SLIDE then
		k = (SM.NOTE_TIME - age) / SM.SLIDE
	else
		return 1
	end
	k = math.Clamp(k, 0, 1)
	return 1 - (1 - k) * (1 - k)
end

function SM.Paint(w, h, real)
	local n = SM.note
	local age = n and real - n.t
	if not n or age > SM.NOTE_TIME or (S.phase ~= "on" and S.phase ~= "loading") or (S.HudShows and not S.HudShows()) then return end
	local PAD = SKATEGM_UI and SKATEGM_UI.pad
	if PAD and PAD.Fonts then PAD.Fonts() end
	local font = PAD and "skategm_ui_row" or "DermaDefaultBold"
	surface.SetFont(font)
	local tw, th = surface.GetTextSize(n.text)
	local padX, padY, margin = 16, 8, math.floor(w * 0.02)
	local bw, bh = tw + padX * 2, th + padY * 2
	local value = SM.Volume()
	if n.volume then
		tw = math.max(tw + 12 + surface.GetTextSize("100%"), SM.BAR_W)
		bw, bh = tw + padX * 2, th + padY * 3 + SM.DOT * 2
	end
	local x = w - margin - bw + (1 - SM.Slide(age)) * (bw + margin + 8)
	local y = math.floor(h * 0.06)
	draw.RoundedBox(8, x, y, bw, bh, PAD and PAD.PANEL or Color(0, 0, 0, 190))
	draw.SimpleText(n.text, font, x + padX, y + padY, Color(255, 255, 255), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
	if not n.volume then return end
	draw.SimpleText(string.format("%d%%", math.floor(value * 100 + 0.5)), font, x + bw - padX, y + padY, Color(255, 255, 255), TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
	local bx, by = x + padX, y + padY * 2 + th + SM.DOT - SM.BAR_H / 2
	local fill = math.floor(tw * value + 0.5)
	draw.RoundedBox(SM.BAR_H / 2, bx, by, tw, SM.BAR_H, SM.BAR_EMPTY)
	if fill > 0 then draw.RoundedBox(SM.BAR_H / 2, bx, by, fill, SM.BAR_H, SM.BAR_FULL) end
	local d = SM.DOT
	draw.RoundedBox(d, bx + fill - d, by + SM.BAR_H / 2 - d, d * 2, d * 2, Color(255, 255, 255))
end

hook.Add("Think", "skategm_skate3_music", function()
	local real = RealTime()
	local ok, err = pcall(SM.Think, real, real, math.Clamp(real - (SM.lastThink or real), 0, 0.1))
	SM.lastThink = real
	if not ok and not SM.warned then
		SM.warned = true
		if ErrorNoHalt then ErrorNoHalt("[SkateGM] Skate 3 music: " .. tostring(err) .. "\n") end
	end
end)
hook.Add("HUDPaint", "skategm_skate3_music", function() pcall(SM.Paint, ScrW(), ScrH(), RealTime()) end)
