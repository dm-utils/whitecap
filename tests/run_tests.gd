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
