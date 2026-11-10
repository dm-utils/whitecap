extends Node
## Headless test runner, run as a scene so autoloads (Platform, Boot) exist like in the real game.
## Exit code 1 on any failure, so CI fails.
##   godot --headless --path . res://tests/run_tests.tscn

const LocalBackend := preload("res://platform/local_backend.gd")
const BootScript := preload("res://boot/boot.gd")
const ContentScript := preload("res://sim/content.gd")

var _passed := 0
var _failed := 0


func _ready() -> void:
	test_every_script_compiles()
	test_data_loads()
	test_every_text_key_exists()
	test_profile_roundtrip()
	test_debug_args()
	test_profile_merge()
	await test_remote_backend()
	test_fx_and_rng()
	test_sim_rules()
	test_determinism()
	test_golden_traces()
	test_result_bookkeeping()
	test_every_asset_has_credits()
	test_setting_declarations()
	test_every_language_complete()
	test_cutouts_build()
	test_island_view()
	test_fx_draw()
	test_sfx()
	print("tests: %d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		printerr("FAIL: " + what)


## A parse error anywhere must fail CI, not only show up in the editor.
func test_every_script_compiles() -> void:
	for path in files_under("res://", [".gd"]):
		if path == "res://tests/run_tests.gd":
			continue
		var s: Script = load(path)
		check(s != null and s.can_instantiate(), "script compiles: " + path)


func test_data_loads() -> void:
	var list: Array = ContentScript.animals()
	check(list.size() >= 3, "animals.json has at least 3 animals")
	for a in list:
		for k in ["id", "name_key", "type", "hp", "attack", "special"]:
			check(a.has(k), "animal %s has %s" % [a.get("id", "?"), k])
		check(a.get("type") in ["land", "water", "flyer"], "animal %s has a known type" % a.get("id"))


## No player-facing string inline: every tr("KEY") in code and every *_key in data must exist in strings.csv
## with a non-empty English text.
func test_every_text_key_exists() -> void:
	var table := read_strings("res://i18n/strings.csv")
	check(table.size() > 0, "strings.csv is readable")
	var used := {}
	var rx := RegEx.create_from_string("tr\\(\"([A-Z0-9_]+)\"\\)")
	for path in files_under("res://", [".gd", ".tscn"]):
		if path.begins_with("res://tests/"):
			continue
		for m in rx.search_all(FileAccess.get_file_as_string(path)):
			used[m.get_string(1)] = path
	var key_rx := RegEx.create_from_string("\"[a-z_]*key\"\\s*:\\s*\"([A-Z0-9_]+)\"")
	for path in files_under("res://data/", [".json"]):
		for m in key_rx.search_all(FileAccess.get_file_as_string(path)):
			used[m.get_string(1)] = path
	check(used.size() > 0, "found text keys in code")
	for key in used:
		check(table.has(key) and str(table[key]).strip_edges() != "", "text key %s (used in %s) exists in strings.csv" % [key, used[key]])


func test_profile_roundtrip() -> void:
	var b = LocalBackend.new()
	b.profile_path = "user://test_profile.json"
	if FileAccess.file_exists(b.profile_path):
		DirAccess.remove_absolute(b.profile_path)
	var p: Dictionary = b.load_profile()
	check(int(p["version"]) == 0, "fresh profile has version 0")
	p["pearls_total"] = 12
	b.save_profile(p)
	var q: Dictionary = b.load_profile()
	check(int(q["pearls_total"]) == 12, "pearls survive save/load")
	check(int(q["version"]) == 1, "save bumps version")
	check(str(q["updated_at"]).ends_with("Z"), "updated_at is UTC")
	DirAccess.remove_absolute(b.profile_path)


func test_debug_args() -> void:
	var a: Dictionary = BootScript.parse(PackedStringArray(["--scene=match", "--seed=42", "ignored"]))
	check(a.get("scene") == "match" and a.get("seed") == "42", "desktop debug args parse")
	var q: Dictionary = BootScript.parse_query("?scene=match&seed=7")
	check(q.get("scene") == "match" and q.get("seed") == "7", "web query parses")


func test_profile_merge() -> void:
	var a := {"pearls_total": 120, "unlocked_animals": ["crab", "octopus"], "selected_animal": "octopus",
		"stats": {"matches": 10, "wins": 2}, "achievements": {"first_win": 1}, "updated_at": "2026-11-10T10:00:00Z",
		"settings": {"music": 0.5}, "version": 4}
	var b := {"pearls_total": 90, "unlocked_animals": ["gull", "crab"], "selected_animal": "gull",
		"stats": {"matches": 12, "wins": 1, "knockouts": 7}, "achievements": {"first_win": 2, "survivor": 1},
		"updated_at": "2026-11-10T11:00:00Z", "settings": {"music": 0.9}, "version": 2}
	var m: Dictionary = ProfileMerge.merge(a, b)
	check(int(m.pearls_total) == 120, "merge: counters take the max")
	check(m.unlocked_animals == ["crab", "gull", "octopus"], "merge: unlocks are the sorted union")
	check(m.stats == {"knockouts": 7, "matches": 12, "wins": 2}, "merge: stats max per key")
	check(m.achievements == {"first_win": 2, "survivor": 1}, "merge: achievements max tier")
	check(m.selected_animal == "gull" and float(m.settings.music) == 0.9, "merge: choices from the newer profile")
	check(int(m.version) == 4, "merge: write counter max")
	var m2: Dictionary = ProfileMerge.merge(b, a)
	check(m2.unlocked_animals == m.unlocked_animals and m2.stats == m.stats and int(m2.pearls_total) == 120,
		"merge: order of arguments does not change counters and unlocks")
	check(ProfileMerge.merge(a, {}) == a, "merge: empty server keeps local")


func test_remote_backend() -> void:
	var server := {"profile": {"pearls_total": 50, "unlocked_animals": ["crab", "puffer"], "updated_at": "2026-01-01T00:00:00Z"}, "version": 3}
	var puts := []
	var handler := func(method, path, _h, body):
		if path == "/auth/start":
			return [200, {"ok": true, "challenge": "c1"}]
		if path == "/auth/verify":
			return [200, {"ok": true, "token": "cs1_" + "a".repeat(43), "userId": "u1"}]
		if path.ends_with("/profile") and method == HTTPClient.METHOD_GET:
			return [200, {"ok": true, "profile": server.profile, "version": server.version}]
		if path.ends_with("/profile") and method == HTTPClient.METHOD_PUT:
			puts.append(body)
			server.version += 1
			server.profile = body.profile
			return [200, {"ok": true, "version": server.version}]
		return [404, {"error": "not_found"}]
	var node = preload("res://addons/st33f/st33f.gd").new()
	node.configure("getij", St33fScriptedTransport.new(handler), St33fTokenStore.new(), "http://test.local", Callable(), "user://st33f/test_queue.json")
	add_child(node)
	var b = preload("res://platform/remote_backend.gd").new(node)
	b.profile_path = "user://test_remote_profile.json"
	if FileAccess.file_exists(b.profile_path):
		DirAccess.remove_absolute(b.profile_path)
	var local: Dictionary = b.load_profile()
	local["pearls_total"] = 80
	b.save_profile(local)
	check(not node.profile_sync.dirty, "signed out: saves stay local")

	await node.sign_in_start("p@example.com")
	await node.sign_in_verify("123456")
	await get_tree().process_frame
	var merged: Dictionary = b.load_profile()
	check(int(merged.pearls_total) == 80 and (merged.unlocked_animals as Array).has("puffer") and (merged.unlocked_animals as Array).has("gull"),
		"after sign-in the cloud copy is merged into the local profile")
	check(node.profile_sync.dirty and node.profile_sync.version == 3, "merged profile is queued for upload on top of server version 3")
	var r: Dictionary = await node.profile_sync.push_now()
	check(r.ok and puts.size() == 1 and int(server.profile.pearls_total) == 80, "upload sends the merged profile")
	DirAccess.remove_absolute(b.profile_path)
	node.queue_free()


func test_fx_and_rng() -> void:
	check(Fx.sin_a(0) == 0 and Fx.sin_a(1024) == 1024 and Fx.cos_a(0) == 1024 and Fx.sin_a(3072) == -1024, "sin table cardinal points")
	var worst := 0
	for a in range(0, 4096, 37):
		worst = maxi(worst, absi(Fx.angle_diff(Fx.atan2_a(Fx.sin_a(a) * 100, Fx.cos_a(a) * 100), a)))
	check(worst <= 2, "atan2 inverts sin/cos within 2 units (worst %d)" % worst)
	check(Fx.isqrt(0) == 0 and Fx.isqrt(15) == 3 and Fx.isqrt(16) == 4 and Fx.isqrt(1_000_000) == 1000, "integer sqrt")
	var r := SimRng.new(1)
	# pinned values: the C++ port must produce exactly these
	check(r.next_u32() == 270369 and r.next_u32() == 67634689, "xorshift32 reference values")


## A two-player sim with both entrants placed by hand.
func _duel(a: String, b: String) -> MatchSim:
	var s := MatchSim.new(42, [a, b])
	s.projs.clear()
	s.snacks.clear()
	s.ents[0].x = 14 * 1000 + 500
	s.ents[0].y = 12 * 1000 + 500
	s.ents[1].x = 14 * 1000 + 500
	s.ents[1].y = 12 * 1000 + 500 + 6000 # 6 tiles south
	return s


func test_sim_rules() -> void:
	var s := _duel("crab", "gull")
	var e0: MatchSim.Ent = s.ents[0]
	var x0 := e0.x
	for i in 5:
		s.step([{"m": 0}, {}])
	check(e0.x - x0 == 5 * (120 * 108 / 100), "land animal on dry sand moves 129 milli-tiles per tick (got %d)" % (e0.x - x0))

	s = _duel("crab", "gull")
	s.ents[0].x = 4 * 1000 + 500
	s.ents[0].y = 4 * 1000 + 500
	var hp := int(s.ents[0].hp)
	for i in 30:
		s.step([{}, {}])
	check(hp - int(s.ents[0].hp) == 30 * 30, "deep water costs a land animal 30 hp-units per tick")

	s = _duel("gull", "crab")
	var shots := 0
	for i in 40:
		var before := s.projs.size()
		s.step([{"a": 1024}, {}])
		if s.projs.size() > before or s.events.any(func(ev): return ev.type == "attack"):
			shots += 1
	check(shots == 3 + 1, "3 charges, then one more after a 29-tick reload within 40 ticks (got %d)" % shots)

	s = _duel("gull", "crab")
	var target_hp := int(s.ents[1].hp)
	for i in 15:
		s.step([{"a": 1024} if i == 0 else {}, {}])
	check(target_hp - int(s.ents[1].hp) == 2100 and int(s.ents[0].special) == 1, "a hit deals the attack damage and charges the special")

	s = _duel("gull", "crab")
	s.ents[1].hp = 1
	for i in 15:
		s.step([{"a": 1024} if i == 0 else {}, {}])
	check(not s.ents[1].alive and s.ents[1].place == 2 and s.ents[0].place == 1 and s.ents[0].kos == 1 and s.finished == 1,
		"knockout: places 1 and 2, KO credited, match finished")

	s = _duel("crab", "gull")
	var lvl := s.level
	var rose := false
	for i in int(s.rules.tide.phase_ticks):
		s.step([{}, {}])
		rose = rose or s.events.any(func(ev): return ev.type == "tide_rise")
	check(s.level == lvl + 1 and rose, "the tide rises one level per phase")

	s = _duel("crab", "gull")
	s.ents[0].hp = 5000
	s.snacks.append([s.ents[0].x + 300, s.ents[0].y])
	s.step([{}, {}])
	check(int(s.ents[0].hp) == 5000 + 3000 and s.snacks.is_empty(), "a snack heals 30 and disappears")

	s = _duel("octopus", "crab")
	s.ents[0].special = 4
	s.step([{"s": 1024}, {}])
	check(s.clouds.size() == 1, "octopus special drops an ink cloud")


func test_determinism() -> void:
	var a := Match.create(777, "", 6, "easy")
	var b := Match.create(777, "", 6, "easy")
	var c := Match.create(778, "", 6, "easy")
	for i in 900:
		a.step()
		b.step()
		c.step()
	check(a.sim.state_hash() == b.sim.state_hash(), "same seed -> same state after 900 ticks")
	check(a.sim.state_hash() != c.sim.state_hash(), "different seed -> different state")

	var snap := a.sim.snapshot()
	for i in 600:
		a.step()
	var d := Match.create(777, "", 6, "easy")
	d.sim.restore(snap)
	for i in 600:
		d.step()
	check(a.sim.state_hash() == d.sim.state_hash(), "snapshot + restore continues identically")


## Golden traces: fixed seeds, all bots, fixed number of ticks -> fixed state hash.
## An unintended change to rules, data or bots fails here. After an intended change, record new values:
##   godot --headless --path . res://tests/run_tests.tscn -- --update-golden
func test_golden_traces() -> void:
	var path := "res://tests/golden/traces.json"
	var update := OS.get_cmdline_user_args().has("--update-golden")
	var cases := [{"seed": 1, "ticks": 1800}, {"seed": 2026, "ticks": 3600}, {"seed": 31337, "ticks": 6000}]
	var recorded: Variant = Content.load_json(path) if FileAccess.file_exists(path) else null
	var out: Array = []
	for i in cases.size():
		var cs: Dictionary = cases[i]
		var m := Match.create(int(cs.seed), "", 6, "easy")
		for t in int(cs.ticks):
			m.step()
		var row := {"seed": cs.seed, "ticks": cs.ticks, "hash": m.sim.state_hash(), "alive": m.sim.alive_count(), "level": m.sim.level}
		out.append(row)
		if not update:
			var ok: bool = recorded is Array and i < recorded.size() and int(recorded[i].hash) == int(row.hash)
			check(ok, "golden trace seed %d after %d ticks (hash %d, recorded %s)" % [cs.seed, cs.ticks, row.hash,
				str(recorded[i].hash) if recorded is Array and i < recorded.size() else "none"])
	if update:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tests/golden"))
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(out, "  ", false, true) + "\n")
		print("golden traces updated: ", out)


func test_result_bookkeeping() -> void:
	var backend = Platform.backend
	var saved_path: String = backend.profile_path
	backend.profile_path = "user://test_result_profile.json"
	if FileAccess.file_exists(backend.profile_path):
		DirAccess.remove_absolute(backend.profile_path)
	var RS := preload("res://ui/result_screen.gd")
	var o: Dictionary = RS.apply_result({"place": 1, "kos": 3, "animal": "gull"})
	check(int(o.earned) == 60 + 30 and int(o.after) == 90, "win with 3 KOs earns 60 + 3 x 10 pearls")
	o = RS.apply_result({"place": 2, "kos": 1, "animal": "gull"})
	check(int(o.after) == 145 and o.unlocked.size() == 1 and str(o.unlocked[0].id) == "shell", "crossing 100 unlocks the first reward")
	for i in 3:
		o = RS.apply_result({"place": 1, "kos": 0, "animal": "crab"})
	var p: Dictionary = Platform.load_profile()
	check((p.unlocked_animals as Array).has("puffer") and int(p.pearls_total) == 325, "crossing 250 adds the pufferfish to the unlocked animals")
	check(int(p.stats.matches) == 5 and int(p.stats.wins) == 4 and int(p.mastery.gull.matches) == 2, "stats and mastery counted")
	DirAccess.remove_absolute(backend.profile_path)
	backend.profile_path = saved_path


## Every slice animal builds from its rig; part names the code binds to exist; looks build too.
func test_cutouts_build() -> void:
	for id in Match.SLICE_ANIMALS:
		var c := Cutout.new()
		c.build(id)
		check(c.joints.has("body") and c.joints.size() >= 7, "%s builds from its rig (%d parts)" % [id, c.joints.size()])
		for j in c.joints.values():
			var sprite: Sprite2D = j.get_child(0)
			check(sprite.texture != null, "%s/%s has a texture" % [id, j.name])
		c.trigger("attack")
		c._process(0.1)
		c.free()
	for look in [["crab", "crab_sunset"], ["octopus", "octopus_midnight"]]:
		var c := Cutout.new()
		c.build(look[0], look[1])
		check((c.joints.body.get_child(0) as Sprite2D).texture != null, "look %s builds" % look[1])
		c.free()


## The island shader gets the sim's heights exactly (one texel per tile), and the shown tide eases to the sim's.
func test_island_view() -> void:
	var img := IslandView.height_image(3, 2, [0, 1, 2, 3, 9, 10])
	var ok := true
	for i in 6:
		var v := roundi(img.get_pixel(i % 3, i / 3).r * 255.0 / IslandView.HEIGHT_SCALE)
		ok = ok and v == [0, 1, 2, 3, 9, 10][i]
	check(ok and img.get_format() == Image.FORMAT_R8, "island heights survive the round trip through the texture")
	var m := Match.create(123, "crab", 6, "easy")
	var view := IslandView.new().setup(m.sim, 80.0)
	check(view.material is ShaderMaterial and (view.material as ShaderMaterial).get_shader_parameter("atlas") != null, "island has its shader and atlas")
	m.sim.level += 1
	view._process(IslandView.RISE_S / 2.0)
	check(view.shown_level > m.sim.level - 1 and view.shown_level < m.sim.level, "water rises gradually on screen")
	view._process(IslandView.RISE_S)
	check(is_equal_approx(view.shown_level, float(m.sim.level)), "and then matches the sim")
	view.free()
	var world: Dictionary = Content.load_json("res://data/palette.json").world
	# styleguide: shallow and deep water must also differ in brightness (colour-blind players)
	check(Color(str(world.shallow)).get_luminance() - Color(str(world.deep)).get_luminance() > 0.25, "shallow is clearly lighter than deep")


## Effects are view-only and finish by themselves.
func test_fx_draw() -> void:
	var fx := FxDraw.new()
	fx.splash(Vector2(100, 100), 1.5)
	fx.ripple(Vector2(50, 50))
	check(fx.drops.size() > 5 and fx.rings.size() == 3, "a splash makes droplets and rings")
	for i in 60:
		fx.update(1.0 / 30.0)
	check(fx.is_idle(), "splashes are gone after two seconds")


## Every sound the game asks for is defined in data/sfx.json; in CI (after sfx.py --ffmpeg) every sound exists.
func test_sfx() -> void:
	var spec: Dictionary = Content.load_json("res://data/sfx.json")
	var sounds: Dictionary = spec.sounds
	var wanted := ["tap", "hit", "ko", "snack", "boom", "tide", "win", "splash", "dash", "ink", "dive"]
	wanted.append_array(preload("res://view/match_view.gd").ATTACK_SOUNDS.values())
	var missing := wanted.filter(func(n): return not sounds.has(n))
	check(missing.is_empty(), "every sound the game plays is in sfx.json (missing: %s)" % ", ".join(missing))
	check(float(spec.peak_dbfs) <= -3.0, "effects are normalised to a peak <= -3 dBFS")
	check(AudioServer.get_bus_index("Sfx") != -1 and AudioServer.get_bus_effect_count(0) > 0, "Sfx bus and a limiter on the master")
	check(Sfx.attenuation_db(0.0, 1920.0) == 0.0 and Sfx.attenuation_db(1920.0, 1920.0) < -10.0 and Sfx.attenuation_db(4000.0, 1920.0) <= -60.0, "sounds fade with distance")
	if OS.has_environment("CI"):
		var absent := sounds.keys().filter(func(n): return not Sfx.has_sound(n))
		check(absent.is_empty(), "every sound was built and imported (missing: %s)" % ", ".join(absent))


## A new key goes into every language in the same change, with the same placeholders ({count} etc.).
func test_every_language_complete() -> void:
	var f := FileAccess.open("res://i18n/strings.csv", FileAccess.READ)
	var header := f.get_csv_line()
	var langs := []
	for i in range(1, header.size()):
		if not header[i].begins_with("_"):
			langs.append(i)
	check(langs.size() >= 2, "strings.csv has at least two languages (%s)" % ", ".join(header))
	var rx := RegEx.create_from_string("\\{[a-z_]+\\}")
	var problems := []
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() < 2 or row[0] == "":
			continue
		var en_ph := _placeholders(rx, row[1])
		for i in langs:
			var text: String = row[i] if i < row.size() else ""
			if text.strip_edges() == "":
				problems.append("%s has no %s text" % [row[0], header[i]])
			elif _placeholders(rx, text) != en_ph:
				problems.append("%s: placeholders differ in %s" % [row[0], header[i]])
	check(problems.is_empty(), "every key translated with matching placeholders: " + "; ".join(problems))
	TranslationServer.set_locale("nl")
	check(tr("MENU_PLAY") == "SPELEN", "the Dutch translation is loaded")
	TranslationServer.set_locale("en")
	check(tr("MENU_PLAY") == "PLAY", "English is back")


func _placeholders(rx: RegEx, text: String) -> Array:
	var out := []
	for m in rx.search_all(text):
		out.append(m.get_string())
	out.sort()
	return out


## The same checks the server applies when CI pushes the declarations, so a bad one fails here first.
func test_setting_declarations() -> void:
	var d: Dictionary = Content.load_json("res://data/settings_defs.json")
	var key_rx := RegEx.create_from_string("^[a-z][a-z0-9_]{0,47}$")
	for def in d.defs:
		var ok_type := false
		match str(def.type):
			"bool": ok_type = typeof(def.default) == TYPE_BOOL
			"int": ok_type = typeof(def.default) == TYPE_FLOAT and float(def.default) == floor(float(def.default))
			"float": ok_type = typeof(def.default) == TYPE_FLOAT
			"string": ok_type = typeof(def.default) == TYPE_STRING
		check(key_rx.search(str(def.key)) != null and ok_type and str(def.get("description", "")) != "",
			"setting %s: valid key, default matches type, has a description" % def.key)
	check(Platform.get_config("show_daily", false) == true and Platform.get_config("event_banner", "x") == "",
		"get_config falls back to the declared defaults")


## Asset policy: no file under assets/ without a credits row (source, author, licence, date).
func test_every_asset_has_credits() -> void:
	var credits := FileAccess.get_file_as_string("res://assets/credits.csv")
	# a row may name a file, or a folder ending in "/" for generated sets (e.g. cutout parts)
	var folders: Array = []
	for line in credits.split("\n"):
		var first := line.split(",")[0]
		if first.ends_with("/"):
			folders.append(first)
	for path in files_under("res://assets/", [".svg", ".png", ".jpg", ".webp", ".ttf", ".otf", ".ogg", ".wav", ".glb", ".gltf"]):
		var rel: String = str(path).trim_prefix("res://")
		var covered := credits.contains("\n" + rel + ",") or folders.any(func(f): return rel.begins_with(f))
		check(covered, "credits row for " + rel)
	# cutout parts are imported at 2x so the big menu animal stays sharp
	for path in files_under("res://assets/animals/", [".svg.import"]) + files_under("res://assets/looks/", [".svg.import"]):
		check(FileAccess.get_file_as_string(path).contains("svg/scale=2.0"), "imported at 2x: " + str(path))


# --- helpers ---

func read_strings(path: String) -> Dictionary:
	var out := {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var header := f.get_csv_line()
	var en := header.find("en")
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() > en and row[0] != "":
			out[row[0]] = row[en]
	return out


func files_under(dir: String, exts: Array) -> Array:
	var out := []
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for sub in d.get_directories():
		if sub.begins_with("."):
			continue
		out.append_array(files_under(dir.path_join(sub), exts))
	for file in d.get_files():
		for e in exts:
			if file.ends_with(e):
				out.append(dir.path_join(file))
	return out
