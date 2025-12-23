if _G.AssaultIntelHUD and _G.AssaultIntelHUD.__alive then
	return
end

local A = _G.AssaultIntelHUD or {}
_G.AssaultIntelHUD = A

A.__alive = true
A.version = "0.1.1"

A.state = A.state or {
	enabled = true,
	mode = "compact"
}

A._ui = A._ui or {
	ready = false,
	panel = nil,
	card = nil,
	shadow = nil,
	bg = nil,
	header = nil,
	accent = nil,
	border = nil,
	title = nil,
	badge = nil,
	lines = nil,
	last_sig = nil,
	last_theme_key = nil,
	last_try_t = 0,
	last_w = 0,
	last_h = 0
}

A._perf = A._perf or { acc = 0, frames = 0, fps = 0 }

A._last = A._last or {
	phase = nil,
	active = nil,
	assault_number = nil,
	last_fade_reason = nil,
	last_fade_reason_t = nil,
	last_pool = nil,
	last_allowance = nil,
	last_end_reason = nil,
	last_end_reason_t = nil,
	initialized = false
}

A._events = A._events or {
	buf = {},
	head = 1,
	size = 0,
	cap = 18,
	last_msg = nil,
	last_t = 0
}

A._hooks_installed = A._hooks_installed or {
	assault = false
}

A._probe = A._probe or {
	phase = nil,
	t = 0,
	phase_end_t = nil,
	assault_end_t = nil,
	force_spawned = nil,
	active = nil,
	force_end = nil,
	said_retreat = nil,
	enemies_left = nil,
	drama_amount = nil,
	engaged = nil,
	skirmish = nil,
	hunt = nil,
	drama_zone = nil
}

local function _alive(o)
	return o and alive and alive(o)
end

local function _now()
	local tm = _G.TimerManager and TimerManager:game()
	if tm and tm.time then
		return tm:time()
	end
	if _G.Application and Application.time then
		return Application:time()
	end
	return os.clock()
end

local function _safe_field(o, k)
	if not o then
		return nil
	end
	local ok, v = pcall(function()
		return o[k]
	end)
	if ok then
		return v
	end
	return nil
end

local function _safe_call(o, k, ...)
	if not o then
		return nil
	end
	local f = _safe_field(o, k)
	if type(f) ~= "function" then
		return nil
	end
	local ok, r = pcall(f, o, ...)
	if ok then
		return r
	end
	return nil
end

local function _clamp(x, a, b)
	if x < a then
		return a
	end
	if x > b then
		return b
	end
	return x
end

local function _fmt_time(v)
	if not v then
		return "-"
	end
	if v < 0 then
		v = 0
	end
	return string.format("%.1f", v)
end

local function _fmt_time_s(v)
	if v == nil then
		return "n/a"
	end
	if v < 0 then
		v = 0
	end
	return string.format("%.1fs", v)
end

local function _fmt_pct(v)
	if v == nil then
		return "-"
	end
	return string.format("%d%%", math.floor(_clamp(v, 0, 1) * 100 + 0.5))
end

local function _fmt_num(v)
	if v == nil then
		return "-"
	end
	if type(v) ~= "number" then
		return tostring(v)
	end
	if math.abs(v) >= 100 then
		return string.format("%.0f", v)
	end
	return string.format("%.2f", v)
end

local function _fmt_int(v)
	if v == nil then
		return "-"
	end
	if type(v) ~= "number" then
		return tostring(v)
	end
	if v < 0 then
		v = 0
	end
	return tostring(math.floor(v + 0.5))
end

function A:_push_event(s)
	local e = self._events
	local msg = tostring(s or "")
	local now = _now()
	if e.last_msg == msg and now - (e.last_t or 0) < 0.35 then
		return
	end
	e.last_msg = msg
	e.last_t = now
	e.buf[e.head] = msg
	e.head = e.head + 1
	if e.head > e.cap then
		e.head = 1
	end
	e.size = math.min(e.size + 1, e.cap)
end

function A:_events_list()
	local e = self._events
	local out = {}
	if e.size == 0 then
		return out
	end
	local idx = e.head - e.size
	if idx <= 0 then
		idx = idx + e.cap
	end
	for i = 1, e.size do
		out[#out + 1] = e.buf[idx] or ""
		idx = idx + 1
		if idx > e.cap then
			idx = 1
		end
	end
	return out
end

function A:_calc_force_pool(st)
	local td = _safe_field(st, "_tweak_data")
	local assault = td and td.assault or nil
	local fp = assault and assault.force_pool or nil
	local mul = assault and assault.force_pool_balance_mul or nil
	local pool = _safe_call(st, "_get_difficulty_dependent_value", fp)
	local bal = _safe_call(st, "_get_balancing_multiplier", mul)
	if type(pool) ~= "number" then
		return nil
	end
	if type(bal) ~= "number" then
		bal = 1
	end
	return pool * bal
end

function A:_calc_spawn_allowance(st, phase, force_spawned)
	local fp = self:_calc_force_pool(st)
	if type(fp) ~= "number" then
		return nil, nil, nil
	end
	local hunt = _safe_field(st, "_hunt_mode") and true or false
	local spawned = force_spawned
	if type(spawned) ~= "number" then
		spawned = 0
	end
	local allowance = fp - (hunt and 0 or spawned)
	if phase == "sustain" and _G.managers and managers.modifiers and managers.modifiers.modify_value then
		local ok, mod = pcall(function()
			return managers.modifiers:modify_value("GroupAIStateBesiege:SustainSpawnAllowance", allowance, fp)
		end)
		if ok and type(mod) == "number" then
			allowance = mod
		end
	end
	return fp, spawned, allowance
end

function A:_infer_fade_reason(st, prev, new_phase)
	local fp, spawned, allowance = self:_calc_spawn_allowance(st, prev and prev.phase, prev and prev.force_spawned)
	local t = prev and prev.t or _safe_field(st, "_t") or _now()
	local end_t = (prev and prev.assault_end_t) or (prev and prev.phase_end_t) or nil
	if type(allowance) == "number" and allowance <= 0.01 then
		return "spawn_pool_empty", fp, spawned, allowance
	end
	if (prev and prev.phase) == "sustain" and not (prev and prev.hunt) and type(end_t) == "number" and end_t < t then
		return "sustain_timer_end", fp, spawned, allowance
	end
	if new_phase == "fade" then
		return "unknown", fp, spawned, allowance
	end
	return nil, fp, spawned, allowance
end

function A:_infer_end_reason(prev)
	if not prev then
		return "unknown"
	end
	if prev.force_end then
		return "force_end"
	end
	if prev.skirmish and type(prev.phase_end_t) == "number" and prev.t > prev.phase_end_t then
		return "skirmish_timeout"
	end
	local drama_cfg = _G.tweak_data and tweak_data.drama
	local assault_fade_end = drama_cfg and drama_cfg.assault_fade_end or nil
	if type(assault_fade_end) == "number" and type(prev.drama_amount) == "number" and prev.drama_amount < assault_fade_end and type(prev.engaged) == "number" and prev.engaged <= 10 then
		return "low_drama_clear"
	end
	if type(prev.phase_end_t) == "number" and prev.t > prev.phase_end_t + 60 then
		return "engagement_timeout"
	end
	if type(prev.phase_end_t) == "number" and prev.t > prev.phase_end_t + 30 then
		return "retreat_timeout"
	end
	if type(prev.enemies_left) == "number" and prev.enemies_left < 50 then
		return "enemies_defeated"
	end
	return "end_assault"
end

function A:_install_hooks()
	if self._hooks_installed.assault then
		return true
	end
	if not (_G.Hooks and Hooks.PreHook and Hooks.PostHook and _G.GroupAIStateBesiege) then
		return false
	end
	if type(GroupAIStateBesiege._upd_assault_task) ~= "function" then
		return false
	end

	Hooks:PreHook(GroupAIStateBesiege, "_upd_assault_task", "AssaultIntelHUD.Assault.Pre", function(st)
		local td = _safe_field(st, "_task_data")
		local assault = td and td.assault or nil
		A._probe.phase = assault and assault.phase or nil
		A._probe.t = _safe_field(st, "_t") or _now()
		A._probe.phase_end_t = assault and assault.phase_end_t or nil
		A._probe.assault_end_t = _safe_call(st, "assault_phase_end_time") or (assault and assault.phase_end_t) or nil
		A._probe.force_spawned = assault and assault.force_spawned or nil
		A._probe.active = assault and assault.active or nil
		A._probe.force_end = assault and assault.force_end or nil
		A._probe.said_retreat = assault and assault.said_retreat or nil
		A._probe.enemies_left = _safe_call(st, "_count_police_force", "assault")
		A._probe.hunt = _safe_field(st, "_hunt_mode") and true or false
		local drama = _safe_field(st, "_drama_data")
		A._probe.drama_amount = drama and drama.amount or nil
		A._probe.drama_zone = drama and drama.zone or nil
		A._probe.engaged = _safe_call(st, "_count_criminals_engaged_force", 11)
		A._probe.skirmish = _G.managers and managers.skirmish and managers.skirmish.is_skirmish and managers.skirmish:is_skirmish() or false
	end)

	Hooks:PostHook(GroupAIStateBesiege, "_upd_assault_task", "AssaultIntelHUD.Assault.Post", function(st)
		local td = _safe_field(st, "_task_data")
		local assault = td and td.assault or nil
		local new_phase = assault and assault.phase or nil
		local prev = A._probe
		local new_active = assault and assault.active or nil
		if new_phase == "fade" and prev and prev.phase ~= "fade" then
			local reason, fp, spawned, allowance = A:_infer_fade_reason(st, prev, new_phase)
			A._last.last_fade_reason = reason or "unknown"
			A._last.last_fade_reason_t = prev.t or _now()
			A._last.last_pool = fp
			A._last.last_allowance = allowance
			A:_push_event(string.format("fade (%s) pool=%s allow=%s", tostring(A._last.last_fade_reason), _fmt_num(fp), _fmt_num(allowance)))
		end
		local regroup = td and td.regroup or nil
		local regroup_active = regroup and regroup.active or false
		local ended = prev and prev.phase == "fade" and regroup_active and (new_phase == nil)
		if ended or (prev and prev.active and not new_active and regroup_active) then
			local reason = A:_infer_end_reason(prev)
			A._last.last_end_reason = reason
			A._last.last_end_reason_t = prev.t or _now()
			A:_push_event(string.format("assault_end (%s) e=%s eng=%s drama=%s", tostring(reason), _fmt_num(prev.enemies_left), _fmt_num(prev.engaged), _fmt_num(prev.drama_amount)))
		end
	end)

	self._hooks_installed.assault = true
	return true
end

function A:_update_fps(dt)
	local p = self._perf
	p.acc = p.acc + (dt or 0)
	p.frames = p.frames + 1
	if p.acc >= 0.5 then
		p.fps = math.floor(p.frames / p.acc + 0.5)
		p.acc = 0
		p.frames = 0
	end
end

function A:_ensure_ui(t)
	if not self.state.enabled then
		if self._ui.ready and _alive(self._ui.panel) then
			self._ui.panel:set_visible(false)
		end
		return false
	end

	local ui = self._ui
	if ui.ready and _alive(ui.panel) and _alive(ui.card) then
		ui.panel:set_visible(true)
		return true
	end

	local now = t or _now()
	if now - (ui.last_try_t or 0) < 0.5 then
		return false
	end
	ui.last_try_t = now

	if not (_G.managers and managers.hud and managers.hud.script and _G.PlayerBase) then
		return false
	end

	local hud = managers.hud:script(PlayerBase.PLAYER_INFO_HUD_PD2)
	if not hud or not hud.panel then
		return false
	end

	local root = hud.panel
	local existing = root:child("assault_intel_panel")
	if _alive(existing) then
		local card = existing:child("assault_intel_card")
		if not _alive(card) then
			root:remove(existing)
		else
			ui.panel = existing
			ui.card = card
			ui.shadow = card:child("assault_intel_shadow")
			ui.bg = card:child("assault_intel_bg")
			ui.header = card:child("assault_intel_header")
			ui.accent = card:child("assault_intel_accent")
			ui.border = {
				t = card:child("assault_intel_border_t"),
				b = card:child("assault_intel_border_b"),
				l = card:child("assault_intel_border_l"),
				r = card:child("assault_intel_border_r")
			}
			ui.title = card:child("assault_intel_title")
			ui.badge = card:child("assault_intel_badge")
			ui.lines = ui.lines or {}
			ui.ready = _alive(ui.bg) and _alive(ui.header) and _alive(ui.title) and _alive(ui.badge)
			return ui.ready
		end
	end

	local panel = root:panel({
		name = "assault_intel_panel",
		layer = 9998,
		x = 0,
		y = 0,
		w = root:w(),
		h = root:h(),
		visible = true
	})

	local card = panel:panel({
		name = "assault_intel_card",
		layer = 9998,
		w = 420,
		h = 220,
		x = panel:w() - 420 - 20,
		y = 12,
		visible = true
	})

	card:rect({
		name = "assault_intel_shadow",
		layer = -2,
		x = 2,
		y = 2,
		w = card:w(),
		h = card:h(),
		color = Color(0.25, 0, 0, 0)
	})

	card:rect({
		name = "assault_intel_bg",
		layer = -1,
		x = 0,
		y = 0,
		w = card:w(),
		h = card:h(),
		color = Color(0.42, 0, 0, 0)
	})

	card:rect({ name = "assault_intel_border_t", layer = 4, x = 0, y = 0, w = card:w(), h = 1, color = Color(0.8, 0, 0, 0) })
	card:rect({ name = "assault_intel_border_b", layer = 4, x = 0, y = card:h() - 1, w = card:w(), h = 1, color = Color(0.8, 0, 0, 0) })
	card:rect({ name = "assault_intel_border_l", layer = 4, x = 0, y = 0, w = 1, h = card:h(), color = Color(0.8, 0, 0, 0) })
	card:rect({ name = "assault_intel_border_r", layer = 4, x = card:w() - 1, y = 0, w = 1, h = card:h(), color = Color(0.8, 0, 0, 0) })

	card:rect({
		name = "assault_intel_header",
		layer = 1,
		x = 0,
		y = 0,
		w = card:w(),
		h = 28,
		color = Color(0.75, 0.06, 0.06, 0.06)
	})

	card:rect({
		name = "assault_intel_accent",
		layer = 2,
		x = 0,
		y = 0,
		w = 3,
		h = 28,
		color = Color(1, 1, 0.7, 0.15)
	})

	local font_title = _G.tweak_data and tweak_data.hud and tweak_data.hud.medium_font_noshadow or "fonts/font_medium_noshadow"
	local font_body = _G.tweak_data and tweak_data.hud and (tweak_data.hud.small_font_noshadow or tweak_data.hud.medium_font_noshadow) or "fonts/font_medium_noshadow"

	card:text({
		name = "assault_intel_title",
		layer = 3,
		x = 10,
		y = 4,
		w = card:w() - 20,
		h = 22,
		font = font_title,
		font_size = 16,
		color = Color(1, 0.95, 0.95, 0.95),
		align = "left",
		vertical = "center",
		text = "ASSAULT INTEL"
	})

	card:text({
		name = "assault_intel_badge",
		layer = 3,
		x = 10,
		y = 4,
		w = card:w() - 20,
		h = 22,
		font = font_body,
		font_size = 13,
		color = Color(0.9, 0.8, 0.8, 0.8),
		align = "right",
		vertical = "center",
		text = ""
	})

	ui.lines = ui.lines or {}
	for i = 1, 18 do
		ui.lines[i] = card:text({
			name = "assault_intel_line_" .. tostring(i),
			layer = 3,
			x = 10,
			y = 32 + (i - 1) * 16,
			w = card:w() - 20,
			h = 16,
			font = font_body,
			font_size = 13,
			color = Color(1, 0.9, 0.9, 0.9),
			align = "left",
			vertical = "top",
			wrap = false,
			word_wrap = false,
			text = "",
			visible = false
		})
	end

	ui.panel = panel
	ui.card = card
	ui.shadow = card:child("assault_intel_shadow")
	ui.bg = card:child("assault_intel_bg")
	ui.header = card:child("assault_intel_header")
	ui.accent = card:child("assault_intel_accent")
	ui.border = {
		t = card:child("assault_intel_border_t"),
		b = card:child("assault_intel_border_b"),
		l = card:child("assault_intel_border_l"),
		r = card:child("assault_intel_border_r")
	}
	ui.title = card:child("assault_intel_title")
	ui.badge = card:child("assault_intel_badge")
	ui.last_sig = nil
	ui.last_theme_key = nil
	ui.last_w = 0
	ui.last_h = 0
	ui.ready = true
	return true
end

function A:_theme_key(snap)
	return tostring((snap and snap.active) and 1 or 0) .. ":" .. tostring(snap and snap.phase or "nil")
end

function A:_theme(snap)
	local phase = snap and snap.phase or nil
	local active = snap and snap.active or false
	local accent
	if active and (phase == "build" or phase == "sustain") then
		accent = Color(1, 1, 0.65, 0.12)
	elseif active and phase == "anticipation" then
		accent = Color(1, 0.9, 0.85, 0.15)
	elseif phase == "fade" then
		accent = Color(1, 1, 0.45, 0.08)
	else
		accent = Color(1, 0.35, 0.65, 1)
	end
	return {
		accent = accent,
		bg = Color(0.44, 0, 0, 0),
		header = Color(0.80, 0.06, 0.06, 0.06),
		border = Color(0.80, 0, 0, 0),
		text = Color(1, 0.92, 0.92, 0.92),
		muted = Color(0.85, 0.65, 0.65, 0.65),
		warn = Color(1, 1, 0.55, 0.15),
		bad = Color(1, 1, 0.2, 0.2)
	}
end

function A:_apply_theme(theme)
	local ui = self._ui
	if not ui.ready or not _alive(ui.card) then
		return
	end
	if _alive(ui.bg) then ui.bg:set_color(theme.bg) end
	if _alive(ui.header) then ui.header:set_color(theme.header) end
	if _alive(ui.accent) then ui.accent:set_color(theme.accent) end
	if ui.border then
		if _alive(ui.border.t) then ui.border.t:set_color(theme.border) end
		if _alive(ui.border.b) then ui.border.b:set_color(theme.border) end
		if _alive(ui.border.l) then ui.border.l:set_color(theme.border) end
		if _alive(ui.border.r) then ui.border.r:set_color(theme.border) end
	end
	if _alive(ui.badge) then ui.badge:set_color(theme.muted) end
end

function A:_set_rows(theme, theme_key, rows, badge)
	local ui = self._ui
	if not ui.ready or not _alive(ui.card) or not ui.lines then
		return
	end

	local sig = tostring(badge or "") .. "\n"
	for i = 1, #rows do
		sig = sig .. tostring(rows[i].text or "") .. "\n"
	end
	if ui.last_sig == sig and ui.last_theme_key == theme_key then
		return
	end
	ui.last_sig = sig
	ui.last_theme_key = theme_key

	if _alive(ui.badge) then
		ui.badge:set_text(tostring(badge or ""))
	end

	local max_w = 0
	local y = 32
	for i = 1, #ui.lines do
		local line = ui.lines[i]
		local row = rows[i]
		if row then
			line:set_visible(true)
			line:set_text(tostring(row.text or ""))
			if row.color then line:set_color(row.color) else line:set_color(theme.text) end
			if row.size then line:set_font_size(row.size) end
			line:set_y(y)
			local _, _, w, h = line:text_rect()
			max_w = math.max(max_w, w)
			y = y + math.ceil((row.size or 13) * 1.25)
		else
			line:set_visible(false)
		end
	end

	local card_w = _clamp(math.ceil(max_w) + 26, 340, self.state.mode == "verbose" and 680 or 520)
	local card_h = _clamp(y + 10, 120, 520)

	if ui.last_w ~= card_w or ui.last_h ~= card_h then
		ui.last_w = card_w
		ui.last_h = card_h
		ui.card:set_w(card_w)
		ui.card:set_h(card_h)
		ui.card:set_x(ui.panel:w() - card_w - 20)
		if _alive(ui.shadow) then ui.shadow:set_w(card_w); ui.shadow:set_h(card_h) end
		if _alive(ui.bg) then ui.bg:set_w(card_w); ui.bg:set_h(card_h) end
		if _alive(ui.header) then ui.header:set_w(card_w) end
		if ui.border then
			if _alive(ui.border.t) then ui.border.t:set_w(card_w) end
			if _alive(ui.border.b) then ui.border.b:set_y(card_h - 1); ui.border.b:set_w(card_w) end
			if _alive(ui.border.l) then ui.border.l:set_h(card_h) end
			if _alive(ui.border.r) then ui.border.r:set_x(card_w - 1); ui.border.r:set_h(card_h) end
		end
		if _alive(ui.title) then ui.title:set_w(card_w - 20) end
		if _alive(ui.badge) then ui.badge:set_w(card_w - 20) end
		for i = 1, #ui.lines do
			ui.lines[i]:set_w(card_w - 20)
		end
	end
end

function A:_snapshot(st, t)
	local td = _safe_field(st, "_task_data")
	local assault = td and td.assault or nil
	local regroup = td and td.regroup or nil
	local reenforce = td and td.reenforce or nil
	local recon = td and td.recon or nil

	local phase = assault and assault.phase or nil
	local active = assault and assault.active or false
	local end_t = _safe_call(st, "assault_phase_end_time") or (assault and assault.phase_end_t) or nil
	local next_dispatch = assault and assault.next_dispatch_t or nil
	local disabled = assault and assault.disabled or nil
	local fp, spawned, allowance = self:_calc_spawn_allowance(st, phase, assault and assault.force_spawned or nil)

	local assault_number = _safe_call(st, "get_assault_number") or _safe_field(st, "_assault_number") or nil
	local hunt = _safe_field(st, "_hunt_mode") and true or false
	local endless = _safe_field(st, "_assault_endless") and true or false

	local drama = _safe_field(st, "_drama_data")
	local drama_amount = drama and drama.amount or nil
	local drama_zone = drama and drama.zone or nil

	local police_force = _safe_field(st, "_police_force") or nil
	local enemies_left = _safe_call(st, "_count_police_force", "assault")
	local engaged = _safe_call(st, "_count_criminals_engaged_force", 11)
	local phalanx_center = _safe_field(st, "_phalanx_center_pos")
	local phalanx_group = _safe_call(st, "phalanx_spawn_group") or _safe_field(st, "_phalanx_spawn_group")
	local phalanx_state = nil
	if not (assault and assault.active) then
		phalanx_state = "inactive"
	elseif phalanx_center then
		if phalanx_group then
			phalanx_state = phalanx_group.has_spawned and "spawned" or "spawning"
		else
			phalanx_state = "ready"
		end
	else
		phalanx_state = "none"
	end

	local rg_active = regroup and regroup.active or false
	local rg_end = regroup and regroup.end_t or nil
	local rc_next = recon and recon.next_dispatch_t or nil
	local rf_next = reenforce and reenforce.next_dispatch_t or nil

	local server = Network and Network.is_server and Network:is_server() or false

	return {
		server = server,
		phase = phase,
		active = active and true or false,
		disabled = disabled and true or false,
		end_t = end_t,
		next_dispatch = next_dispatch,
		force_pool = fp,
		force_spawned = spawned,
		allowance = allowance,
		assault_number = assault_number,
		hunt = hunt,
		endless = endless,
		drama_amount = drama_amount,
		drama_zone = drama_zone,
		police_force = police_force,
		enemies_left = enemies_left,
		engaged = engaged,
		rg_active = rg_active and true or false,
		rg_end = rg_end,
		rc_next = rc_next,
		rf_next = rf_next,
		last_fade_reason = self._last.last_fade_reason,
		last_fade_reason_t = self._last.last_fade_reason_t,
		last_end_reason = self._last.last_end_reason,
		last_end_reason_t = self._last.last_end_reason_t,
		phalanx = phalanx_state,
		t = t
	}
end

function A:_diff_events(snap)
	local l = self._last
	if not l.initialized then
		l.phase = snap.phase
		l.active = snap.active
		l.assault_number = snap.assault_number
		l.initialized = true
		return
	end
	if l.phase ~= snap.phase then
		self:_push_event(string.format("phase %s -> %s", tostring(l.phase), tostring(snap.phase)))
	end
	if l.active ~= snap.active then
		self:_push_event(string.format("active %s -> %s", tostring(l.active), tostring(snap.active)))
	end
	if l.assault_number ~= snap.assault_number and snap.assault_number ~= nil then
		self:_push_event(string.format("assault #%s", tostring(snap.assault_number)))
	end
	l.phase = snap.phase
	l.active = snap.active
	l.assault_number = snap.assault_number
end

function A:_render(snap)
	local t = snap.t
	local end_in = snap.end_t and (snap.end_t - t) or nil
	local dispatch_in = snap.next_dispatch and (snap.next_dispatch - t) or nil
	local rg_in = snap.rg_end and (snap.rg_end - t) or nil
	local recon_in = snap.rc_next and (snap.rc_next - t) or nil
	local reenforce_in = snap.rf_next and (snap.rf_next - t) or nil
	local pool = snap.force_pool
	local allow = snap.allowance
	local spawned = snap.force_spawned

	local theme_key = self:_theme_key(snap)
	local theme = self:_theme(snap)
	self:_apply_theme(theme)

	local badge = string.format("%s | %s | %s", snap.server and "HOST" or "CLIENT", self.state.mode:upper(), tostring(self._perf.fps or 0) .. "fps")
	local rows = {}

	if self.state.mode == "compact" then
		rows[#rows + 1] = { text = string.format("ASSAULT #%s  %s  %s", tostring(snap.assault_number or "-"), snap.active and "ON" or "OFF", tostring(snap.phase or "-")), color = theme.accent, size = 15 }
		rows[#rows + 1] = { text = string.format("TIMERS  end %s  dispatch %s  regroup %s", _fmt_time_s(end_in), _fmt_time_s(dispatch_in), _fmt_time_s(rg_in)), color = theme.text, size = 13 }
		rows[#rows + 1] = { text = string.format("POOL    %s / %s  spawned %s", _fmt_num(pool), _fmt_num(allow), _fmt_num(spawned)), color = theme.text, size = 13 }
		rows[#rows + 1] = { text = string.format("DRAMA   %s (%s)  engaged %s  enemies %s", _fmt_pct(snap.drama_amount), tostring(snap.drama_zone or "-"), _fmt_int(snap.engaged), _fmt_int(snap.enemies_left)), color = theme.text, size = 13 }
		rows[#rows + 1] = { text = string.format("FLAGS   hunt %s  endless %s  phalanx %s", snap.hunt and "ON" or "OFF", snap.endless and "ON" or "OFF", tostring(snap.phalanx or "-")), color = theme.muted, size = 13 }
		local show_reason = (snap.phase == "fade") or (snap.last_fade_reason_t and (t - snap.last_fade_reason_t) < 8)
		if show_reason and snap.last_fade_reason then rows[#rows + 1] = { text = string.format("REASON  fade: %s", tostring(snap.last_fade_reason)), color = theme.warn, size = 13 } end
		local show_end = snap.last_end_reason_t and (t - snap.last_end_reason_t) < 10
		if show_end and snap.last_end_reason then rows[#rows + 1] = { text = string.format("REASON  end:  %s", tostring(snap.last_end_reason)), color = theme.warn, size = 13 } end
	else
		rows[#rows + 1] = { text = string.format("ASSAULT  #%s  active=%s  phase=%s  disabled=%s", tostring(snap.assault_number or "-"), tostring(snap.active), tostring(snap.phase or "-"), tostring(snap.disabled)), color = theme.accent, size = 15 }
		rows[#rows + 1] = { text = string.format("FLAGS    hunt=%s  endless=%s  phalanx=%s", tostring(snap.hunt), tostring(snap.endless), tostring(snap.phalanx or "-")), color = theme.muted, size = 13 }
		rows[#rows + 1] = { text = string.format("TIMERS   end=%s  dispatch=%s  regroup=%s", _fmt_time_s(end_in), _fmt_time_s(dispatch_in), _fmt_time_s(rg_in)), color = theme.text, size = 13 }
		rows[#rows + 1] = { text = string.format("TASKS    recon=%s  reenforce=%s", _fmt_time_s(recon_in), _fmt_time_s(reenforce_in)), color = theme.text, size = 13 }
		rows[#rows + 1] = { text = string.format("POOL     pool=%s  allow=%s  spawned=%s", _fmt_num(pool), _fmt_num(allow), _fmt_num(spawned)), color = theme.text, size = 13 }
		rows[#rows + 1] = { text = string.format("DRAMA    %s (%s)  engaged=%s  enemies=%s", _fmt_pct(snap.drama_amount), tostring(snap.drama_zone or "-"), _fmt_int(snap.engaged), _fmt_int(snap.enemies_left)), color = theme.text, size = 13 }
		if snap.last_fade_reason then rows[#rows + 1] = { text = string.format("REASON   fade: %s", tostring(snap.last_fade_reason)), color = theme.warn, size = 13 } end
		if snap.last_end_reason then rows[#rows + 1] = { text = string.format("REASON   end:  %s", tostring(snap.last_end_reason)), color = theme.warn, size = 13 } end
		local ev = self:_events_list()
		if #ev > 0 then
			rows[#rows + 1] = { text = "EVENTS", color = theme.muted, size = 12 }
			local from = math.max(1, #ev - 8)
			for i = from, #ev do
				rows[#rows + 1] = { text = "• " .. tostring(ev[i]), color = theme.muted, size = 12 }
			end
		end
	end

	self:_set_rows(theme, theme_key, rows, badge)
end

function A:update(t, dt)
	self:_update_fps(dt)
	local now = t or _now()
	self:_install_hooks()
	if not self:_ensure_ui(now) then
		return
	end
	if not (_G.managers and managers.groupai and managers.groupai.state) then
		local theme = self:_theme(nil)
		self:_apply_theme(theme)
		self:_set_rows(theme, "0:nil", { { text = "WAITING FOR GAME STATE", color = theme.muted, size = 13 } }, "N/A")
		return
	end
	local st = managers.groupai:state()
	if not st then
		local theme = self:_theme(nil)
		self:_apply_theme(theme)
		self:_set_rows(theme, "0:nil", { { text = "WAITING FOR AI STATE", color = theme.muted, size = 13 } }, "N/A")
		return
	end
	local snap = self:_snapshot(st, now)
	self:_diff_events(snap)
	self:_render(snap)
end

function A:toggle()
	self.state.enabled = not self.state.enabled
	if self._ui.ready and _alive(self._ui.panel) then
		self._ui.panel:set_visible(self.state.enabled)
	end
end

function A:toggle_mode()
	self.state.mode = self.state.mode == "compact" and "verbose" or "compact"
end

Hooks:Add("GameSetupUpdate", "AssaultIntelHUD.Update", function(t, dt)
	if _G.AssaultIntelHUD and _G.AssaultIntelHUD.update then
		_G.AssaultIntelHUD:update(t, dt)
	end
end)

Hooks:Add("GameSetupPausedUpdate", "AssaultIntelHUD.PausedUpdate", function(t, dt)
	if _G.AssaultIntelHUD and _G.AssaultIntelHUD.update then
		_G.AssaultIntelHUD:update(t, dt)
	end
end)