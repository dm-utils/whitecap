extends Node2D
## The match on screen. Reads the sim, never changes it: input becomes a command per tick, the sim steps at a
## fixed 30 Hz, and the view interpolates between ticks. Events (hits, KOs, tide) drive effects and messages.
## Debug entry: --scene=match --seed=N [--animal=gull] [--bots=easy|normal|hard];
## debug builds also take [--tide=<seconds per phase>] [--god=1] (smoke test).

const PX := 0.08 # screen pixels per milli-tile: 80 px per tile, ~24 x 13 tiles visible at 1920 x 1080
const DT := 1.0 / 30.0
const MAX_STEPS_PER_FRAME := 3
const TEX := {
	"crab": preload("res://assets/animals/crab.svg"),
	"octopus": preload("res://assets/animals/octopus.svg"),
	"gull": preload("res://assets/animals/gull.svg"),
}
const RESULT_SCENE := "res://ui/result_screen.tscn"

var m: Match
var board: Node2D
var cam: Camera2D
var hud: Control
var controls := "keys"

var _acc := 0.0
var _prev := {} # id -> Vector2 (milli-tiles) at the previous tick
var _intro := 1.6
var _ending := -1.0
var _pending_special := false
var _last_move := 0
var _target := -1
var _flash := {} # id -> seconds
var _fx: Array = [] # {kind, pos (px), t}
var _msg := ""
var _msg_t := 0.0
var _fps_t := 0.0
var _t := 0.0


func _ready() -> void:
	Platform.entered("match")
	var profile: Dictionary = Platform.load_profile()
	var seed_value := Boot.seed_value() if Boot.seed_value() != 0 else randi() % 2000000000 + 1
	var animal := str(Boot.args.get("animal", profile.get("selected_animal", "octopus")))
	if not Match.SLICE_ANIMALS.has(animal):
		animal = "octopus"
	m = Match.create(seed_value, animal, 6, str(Boot.args.get("bots", "easy")))
	if Boot.args.has("tide") and OS.is_debug_build():
		m.sim.rules = m.sim.rules.duplicate(true)
		m.sim.rules.tide.phase_ticks = maxi(60, int(Boot.args.tide) * 30)
		m.sim.phase_left = int(m.sim.rules.tide.phase_ticks)
	if Boot.args.get("god", "") == "1" and OS.is_debug_build():
		# debug builds only: the smoke test needs the player alive to photograph later tide phases
		m.sim.ents[m.human].hp = 100000000
		m.sim.ents[m.human].max_hp = 100000000
	controls = str(profile.get("settings", {}).get("controls", "keys"))
	_remember_positions()

	board = Node2D.new()
	board.draw.connect(_draw_board)
	add_child(board)
	cam = Camera2D.new()
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = int(m.sim.width * 1000 * PX)
	cam.limit_bottom = int(m.sim.height * 1000 * PX)
	cam.position = Vector2(cam.limit_right / 2.0, cam.limit_bottom / 2.0)
	cam.zoom = Vector2(0.55, 0.55)
	add_child(cam)
	cam.make_current()
	_build_hud()
	_say(tr("DROP_TITLE"), _intro)


# --- loop ---

func _process(delta: float) -> void:
	_t += delta
	if _intro > 0.0:
		_intro -= delta
		cam.zoom = cam.zoom.lerp(Vector2.ONE if _intro < 0.6 else Vector2(0.55, 0.55), minf(1.0, delta * 4.0))
	elif _ending < 0.0:
		_acc += delta
		var steps := 0
		while _acc >= DT and steps < MAX_STEPS_PER_FRAME:
			_remember_positions()
			m.step(_command())
			_handle_events()
			_acc -= DT
			steps += 1
		if steps == MAX_STEPS_PER_FRAME:
			_acc = 0.0 # a slow frame must not spiral
		if m.finished() or m.human_out():
			_ending = 1.4
	else:
		_ending -= delta
		if _ending <= 0.0:
			_finish()
			return
	for id in _flash.keys():
		_flash[id] = float(_flash[id]) - delta
	for f in _fx:
		f.t += delta
	_fx = _fx.filter(func(f): return f.t < 0.7)
	_msg_t -= delta
	_update_camera(delta)
	_update_hud()
	board.queue_redraw()
	hud.queue_redraw()
	if OS.is_debug_build():
		_fps_t += delta
		if _fps_t >= 5.0:
			_fps_t = 0.0
			print("fps %d tick %d t %.2f wall %d" % [Engine.get_frames_per_second(), m.sim.tick, _t, Time.get_ticks_msec()])


func _alpha() -> float:
	return clampf(_acc / DT, 0.0, 1.0) if _intro <= 0.0 else 0.0


func _remember_positions() -> void:
	for e in m.sim.ents:
		_prev[e.id] = Vector2(e.x, e.y)


func _pos_px(e: MatchSim.Ent) -> Vector2:
	var cur := Vector2(e.x, e.y)
	return Vector2(_prev.get(e.id, cur)).lerp(cur, _alpha()) * PX


func _update_camera(delta: float) -> void:
	if _intro > 0.6:
		return
	var me: MatchSim.Ent = m.sim.ents[m.human]
	var focus := me
	if not me.alive:
		for e in m.sim.ents:
			if e.alive:
				focus = e
				break
	var look := Vector2(Fx.cos_a(me.aim), Fx.sin_a(me.aim)) / 1024.0 * 120.0 if me.alive else Vector2.ZERO
	cam.position = cam.position.lerp(_pos_px(focus) + look, minf(1.0, delta * 6.0))


# --- input -> command ---

func _command() -> Dictionary:
	var e: MatchSim.Ent = m.sim.ents[m.human]
	var cmd := {"m": -1, "a": -1, "s": -1}
	var mx := int(_key(KEY_D) or _key(KEY_RIGHT)) - int(_key(KEY_A) or _key(KEY_LEFT))
	var my := int(_key(KEY_S) or _key(KEY_DOWN)) - int(_key(KEY_W) or _key(KEY_UP))
	if mx != 0 or my != 0:
		cmd.m = Fx.atan2_a(my * 1000, mx * 1000)
		_last_move = cmd.m
	var target := _auto_target(e)
	_target = target.id if target != null else -1
	var aim := _last_move
	var dist := -1
	if controls == "mouse":
		var world := get_global_mouse_position() / PX
		aim = Fx.atan2_a(int(world.y) - e.y, int(world.x) - e.x)
		dist = Fx.dist(int(world.x) - e.x, int(world.y) - e.y)
	elif target != null:
		aim = Fx.atan2_a(target.y - e.y, target.x - e.x)
		dist = Fx.dist(target.x - e.x, target.y - e.y)
	var attacking := _key(KEY_SPACE) if controls == "keys" else Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if attacking:
		cmd.a = aim
	if _pending_special:
		_pending_special = false
		cmd.s = aim
		cmd["sd"] = dist
	return cmd


func _key(k: Key) -> bool:
	return Input.is_physical_key_pressed(k)


## Nearest enemy within attack range (+15 %): the keyboard "auto-aim".
func _auto_target(e: MatchSim.Ent) -> MatchSim.Ent:
	var reach := m.sim.attack_range(e) * 115 / 100
	var best: MatchSim.Ent = null
	var best_d2 := reach * reach
	for o in m.sim.ents:
		if o.alive and o.id != e.id:
			var d2 := MatchSim._d2(o.x - e.x, o.y - e.y)
			if d2 < best_d2:
				best = o
				best_d2 = d2
	return best


func _unhandled_input(event: InputEvent) -> void:
	if UiTheme.is_emulated(event):
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if controls == "keys" and event.physical_keycode == KEY_SHIFT:
			_pending_special = true
		elif event.physical_keycode == KEY_ESCAPE and OS.is_debug_build():
			_ending = 0.01
	elif event is InputEventMouseButton and event.pressed and controls == "mouse" and event.button_index == MOUSE_BUTTON_RIGHT:
		_pending_special = true


func _on_special_pressed() -> void:
	_pending_special = true


# --- events ---

func _handle_events() -> void:
	for ev in m.sim.events:
		match str(ev.type):
			"hit":
				_flash[int(ev.id)] = 0.12
				_fx.append({"kind": "spark", "pos": Vector2(ev.x, ev.y) * PX, "t": 0.0})
			"ko":
				_fx.append({"kind": "splash", "pos": Vector2(ev.x, ev.y) * PX, "t": 0.0})
				if int(ev.id) == m.human:
					_say(tr("HUD_WASHED_AWAY"), 1.5)
			"snack":
				_fx.append({"kind": "heal", "pos": Vector2(ev.x, ev.y) * PX, "t": 0.0})
			"dive":
				_fx.append({"kind": "boom", "pos": Vector2(ev.x, ev.y) * PX, "t": 0.0})
			"tide_warning":
				_say(tr("HUD_TIDE_WARNING"), 2.0)
			"tide_rise":
				_say(tr("HUD_TIDE_RISES"), 1.5)
			"sudden_death":
				_say(tr("HUD_SUDDEN_DEATH"), 1.5)
			"finished":
				if m.sim.ents[m.human].place == 1:
					_say(tr("HUD_LAST_DRY"), 1.5)


func _say(text: String, seconds: float) -> void:
	_msg = text
	_msg_t = seconds


func _finish() -> void:
	var me: MatchSim.Ent = m.sim.ents[m.human]
	var place := me.place if me.place > 0 else 1
	Boot.last_result = {
		"place": place, "kos": me.kos, "animal": str(m.sim.animals[me.id].id), "seed": m.sim.seed_value,
		"survived_s": (me.died_tick if me.died_tick >= 0 else m.sim.tick) / 30, "players": m.sim.ents.size(),
	}
	get_tree().change_scene_to_file(RESULT_SCENE)


# --- drawing: island, water, snacks, effects, animals ---

const SAND := [Color("C9A26B"), Color("E5C384"), Color("F2D49B"), Color("F5DCA9")]
const SHALLOW := Color("5FD3C9")
const DEEP := Color("1F6F9F")
const ABYSS := Color("134A6E")
const FOAM := Color(0.97, 0.98, 0.97, 0.85)
const INK := Color("2B3A4A")
const ME := Color("3FE0FF")
const FOE := Color("FF5A4E")


func _tile_color(depth: int) -> Color:
	if depth >= 3:
		return ABYSS
	if depth == 2:
		return DEEP
	if depth == 1:
		return SHALLOW
	return SAND[clampi(-depth, 0, 3)]


func _draw_board() -> void:
	var sim := m.sim
	var ts := 1000.0 * PX
	var warn := sim.phase_left <= int(sim.rules.tide.warn_ticks) and sim.level < int(sim.rules.tide.max_level)
	board.draw_rect(Rect2(-2000, -2000, sim.width * ts + 4000, sim.height * ts + 4000), ABYSS)
	for ty in sim.height:
		for tx in sim.width:
			var d := sim.level - sim.heights[ty * sim.width + tx]
			var r := Rect2(tx * ts, ty * ts, ts + 1, ts + 1)
			board.draw_rect(r, _tile_color(d))
			if d == 1:
				var w := sin(_t * 2.0 + tx + ty) * 4.0
				board.draw_line(r.position + Vector2(10, 40 + w), r.position + Vector2(70, 40 + w), Color(1, 1, 1, 0.25), 3.0)
			if d >= 1:
				_draw_foam(tx, ty, r, d)
			if warn and d == 0:
				board.draw_rect(r, Color(1, 1, 1, 0.18 + 0.18 * sin(_t * 14.0)))
	for s in sim.snacks:
		var p := Vector2(s[0], s[1]) * PX
		board.draw_circle(p, 13.0, INK)
		board.draw_circle(p, 10.0, Color("5BD66B"))
	for c in sim.clouds:
		var p := Vector2(c.x, c.y) * PX
		for i in 5:
			var a := i * 1.26 + _t * 0.5
			board.draw_circle(p + Vector2(cos(a) * 40, sin(a) * 32), c.radius * PX * 0.6, Color(0.17, 0.12, 0.24, minf(0.7, c.life / 30.0)))
	for v in sim.dives:
		var col := ME if v.owner == m.human else FOE
		board.draw_arc(Vector2(v.x, v.y) * PX, v.radius * PX, 0, TAU, 40, col, 4.0)
	for e in _sorted_alive():
		_draw_animal(e)
	for p in sim.projs:
		var pos := Vector2(p.x, p.y) * PX
		board.draw_circle(pos, p.radius * PX * 0.55 + 4.0, INK)
		board.draw_circle(pos, p.radius * PX * 0.55 + 1.0, ME if p.owner == m.human else FOE)
	for f in _fx:
		var k: float = f.t / 0.7
		match str(f.kind):
			"splash":
				for i in 3:
					board.draw_arc(f.pos, 12.0 + k * 60.0 + i * 12.0, 0, TAU, 32, Color(1, 1, 1, 1.0 - k), 4.0)
			"boom":
				board.draw_circle(f.pos, 156.0 * (0.6 + k * 0.5), Color(1.0, 0.77, 0.19, 0.5 * (1.0 - k)))
			"heal":
				board.draw_circle(f.pos + Vector2(0, -k * 30.0), 8.0, Color(0.36, 0.84, 0.42, 1.0 - k))
			_:
				board.draw_arc(f.pos, 4.0 + k * 16.0, 0, TAU, 16, Color(1, 1, 1, 1.0 - k), 2.0)
	if _target >= 0 and controls == "keys" and m.sim.ents[_target].alive:
		board.draw_arc(_pos_px(m.sim.ents[_target]), 46.0, _t * 2.0, _t * 2.0 + TAU * 0.85, 32, Color("FFC530"), 4.0)


func _draw_foam(tx: int, ty: int, r: Rect2, _d: int) -> void:
	var sim := m.sim
	var f := 4.0 + sin(_t * 3.0 + tx * 0.7 + ty) * 1.5
	var dry := func(x: int, y: int) -> bool:
		return x >= 0 and y >= 0 and x < sim.width and y < sim.height and sim.level - sim.heights[y * sim.width + x] <= 0
	if dry.call(tx, ty - 1):
		board.draw_rect(Rect2(r.position, Vector2(r.size.x, f)), FOAM)
	if dry.call(tx, ty + 1):
		board.draw_rect(Rect2(r.position + Vector2(0, r.size.y - f), Vector2(r.size.x, f)), FOAM)
	if dry.call(tx - 1, ty):
		board.draw_rect(Rect2(r.position, Vector2(f, r.size.y)), FOAM)
	if dry.call(tx + 1, ty):
		board.draw_rect(Rect2(r.position + Vector2(r.size.x - f, 0), Vector2(f, r.size.y)), FOAM)


func _sorted_alive() -> Array:
	var list: Array = []
	for e in m.sim.ents:
		if e.alive:
			list.append(e)
	list.sort_custom(func(a, b): return a.y < b.y)
	return list


func _draw_animal(e: MatchSim.Ent) -> void:
	var p := _pos_px(e)
	var id := str(m.sim.animals[e.id].id)
	var flyer := str(m.sim.animals[e.id].type) == "flyer"
	var depth := m.sim.depth_at(e.x, e.y)
	var mine := e.id == m.human
	var bob := sin(_t * 6.0 + e.id) * 2.0 - (12.0 if flyer else 0.0)
	# shadow and team ring (styleguide: cyan = you, coral = others)
	board.draw_set_transform(p + Vector2(0, 20), 0.0, Vector2(1.0, 0.38))
	board.draw_circle(Vector2.ZERO, 26.0, Color(0, 0, 0, 0.18))
	board.draw_arc(Vector2.ZERO, 32.0, 0, TAU, 40, ME if mine else FOE, 9.0)
	board.draw_set_transform(Vector2.ZERO)
	# the animal (placeholder art at the real scale), flipped toward where it aims
	var tex: Texture2D = TEX.get(id)
	var size := 84.0
	var flip := -1.0 if Fx.cos_a(e.aim) < 0 else 1.0
	var tint := Color(1, 1, 1, 0.55) if float(_flash.get(e.id, 0.0)) > 0.0 else Color.WHITE
	board.draw_set_transform(p + Vector2(0, -14 + bob), 0.0, Vector2(flip, 1.0))
	board.draw_texture_rect(tex, Rect2(-size / 2, -size / 2, size, size), false, tint)
	board.draw_set_transform(Vector2.ZERO)
	if depth >= 1 and not flyer:
		board.draw_set_transform(p + Vector2(0, 12), 0.0, Vector2(1.0, 0.4))
		board.draw_circle(Vector2.ZERO, 36.0, Color(SHALLOW if depth == 1 else DEEP, 0.85))
		board.draw_arc(Vector2.ZERO, 36.0, 0, TAU, 32, FOAM, 4.0)
		board.draw_set_transform(Vector2.ZERO)
	# health bar
	var w := 56.0
	var top := p + Vector2(-w / 2, -70 + bob)
	board.draw_rect(Rect2(top - Vector2(2, 2), Vector2(w + 4, 11)), INK)
	var f := clampf(float(e.hp) / float(e.max_hp), 0.0, 1.0)
	var col := FOE
	if mine:
		col = Color("5BD66B") if f > 0.5 else (Color("FFD23F") if f > 0.25 else FOE)
	board.draw_rect(Rect2(top, Vector2(w * f, 7)), col)
	if mine:
		var font := UiTheme.title_font()
		board.draw_string_outline(font, top + Vector2(0, -6), tr("HUD_YOU"), HORIZONTAL_ALIGNMENT_CENTER, w, 20, 6, INK)
		board.draw_string(font, top + Vector2(0, -6), tr("HUD_YOU"), HORIZONTAL_ALIGNMENT_CENTER, w, 20, Color.WHITE)
		for i in int(m.sim.rules.attack.charges):
			var c := p + Vector2(-16 + i * 16, 42)
			board.draw_circle(c, 7.0, INK)
			board.draw_circle(c, 5.0, Color("FFC530") if i < e.charges else Color(1, 1, 1, 0.4))


# --- HUD ---

var _left: Label
var _tide: Label
var _tide_bar: ProgressBar
var _msg_label: Label
var _special: Button


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Control.new()
	hud.theme = UiTheme.get_theme()
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud)
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 20)
	top.position = Vector2(40, 30)
	hud.add_child(top)
	_left = _chip_label(top)
	_tide = _chip_label(top)
	_tide_bar = ProgressBar.new()
	_tide_bar.custom_minimum_size = Vector2(220, 24)
	_tide_bar.show_percentage = false
	_tide_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var fill := StyleBoxFlat.new()
	fill.bg_color = DEEP
	fill.set_corner_radius_all(12)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color.WHITE
	bg.border_color = INK
	bg.set_border_width_all(4)
	bg.set_corner_radius_all(12)
	_tide_bar.add_theme_stylebox_override("fill", fill)
	_tide_bar.add_theme_stylebox_override("background", bg)
	top.add_child(_tide_bar)

	_msg_label = Label.new()
	_msg_label.label_settings = UiTheme.heading(68)
	_msg_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud.add_child(_msg_label)
	_msg_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_msg_label.position.y = 140
	_msg_label.grow_horizontal = Control.GROW_DIRECTION_BOTH

	_special = Button.new()
	_special.text = tr("HUD_SPECIAL")
	_special.focus_mode = Control.FOCUS_NONE
	_special.custom_minimum_size = Vector2(220, 110)
	_special.pressed.connect(_on_special_pressed)
	hud.add_child(_special)
	_special.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_special.offset_left = -280
	_special.offset_top = -170
	_special.offset_right = -60
	_special.offset_bottom = -60

	var hint := Label.new()
	hint.text = tr("HUD_CONTROLS_KEYS") if controls == "keys" else tr("HUD_CONTROLS_MOUSE")
	hint.label_settings = UiTheme.heading(26, Color.WHITE, 6)
	hud.add_child(hint)
	hint.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	hint.offset_left = 40
	hint.offset_top = -70


func _chip_label(parent: Control) -> Label:
	var panel := PanelContainer.new()
	parent.add_child(panel)
	var l := Label.new()
	l.add_theme_font_override("font", UiTheme.title_font())
	l.add_theme_font_size_override("font_size", 34)
	panel.add_child(l)
	return l


func _update_hud() -> void:
	var sim := m.sim
	_left.text = tr("HUD_LEFT").format({"count": sim.alive_count()})
	var start := int(sim.rules.tide.start_level)
	_tide.text = tr("HUD_TIDE").format({"level": sim.level - start + 1, "max": int(sim.rules.tide.max_level) - start + 1})
	var phase := float(sim.rules.tide.phase_ticks)
	_tide_bar.value = 100.0 if sim.level >= int(sim.rules.tide.max_level) else (1.0 - sim.phase_left / phase) * 100.0
	_msg_label.text = _msg
	_msg_label.modulate.a = clampf(_msg_t * 2.0, 0.0, 1.0)
	var me: MatchSim.Ent = sim.ents[m.human]
	var ready := me.alive and me.special >= int(sim.rules.attack.special_hits)
	_special.theme_type_variation = "PlayButton" if ready else ""
	_special.add_theme_font_size_override("font_size", 40)
	_special.modulate.a = 1.0 if me.alive else 0.4
