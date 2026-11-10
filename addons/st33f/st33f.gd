extends Node
## The St33f autoload: wires client, token store, profile sync and offline queue together and keeps their
## state under user://st33f/. Register it as autoload "St33f" and set the project setting `st33f/game`.
##
## Environment: a build with feature tag "prod_hosts" talks to production; everything else to dev.

signal signed_in(user_id: String)
signal signed_out

const STATE_PATH := "user://st33f/state.json"

var game := ""
var environment := "dev"
var client: St33fClient
var tokens: St33fTokenStore
var profile_sync: St33fProfileSync
var queue: St33fOfflineQueue
var user_id := ""

var _email := ""
var _challenges := PackedStringArray()
var _queue_timer := 0.0


func _ready() -> void:
	if client == null:
		configure(str(ProjectSettings.get_setting("st33f/game", "")))


## Tests pass their own transport, token store, base URL and state folder.
func configure(p_game: String, transport: St33fTransport = null, token_store: St33fTokenStore = null,
		base_url := "", merge := Callable(), queue_path := "") -> void:
	game = p_game
	environment = "prod" if OS.has_feature("prod_hosts") else "dev"
	var url := base_url if base_url != "" else str(St33fClient.URLS.get(environment, ""))
	client = St33fClient.new(game, url, transport if transport != null else St33fHttpTransport.new(self))
	tokens = token_store if token_store != null else St33fEncryptedFileTokenStore.new()
	client.token = tokens.load_token()
	profile_sync = St33fProfileSync.new(client, merge if merge.is_valid() else _server_wins)
	queue = St33fOfflineQueue.new(client, queue_path)
	_load_state()
	profile_sync.synced.connect(func(_p: Dictionary, _v: int) -> void: _save_state())


func is_signed_in() -> bool:
	return client != null and client.token != ""


## Step 1: ask for a code. Up to 3 recent challenges are kept, so an older mail still works after a resend.
func sign_in_start(email: String) -> Dictionary:
	var res: Dictionary = await client.auth_start(email)
	if res.ok:
		var normalised := email.strip_edges().to_lower()
		if normalised != _email:
			_challenges.clear()
			_email = normalised
		_challenges.append(str(res.data.get("challenge", "")))
		while _challenges.size() > 3:
			_challenges.remove_at(0)
	return res


## Step 2: the 6-digit code from the mail.
func sign_in_verify(code: String) -> Dictionary:
	var res: Dictionary = await client.auth_verify(_email, _challenges, code.strip_edges())
	if res.ok:
		client.token = str(res.data.get("token", ""))
		user_id = str(res.data.get("userId", ""))
		tokens.save_token(client.token)
		_challenges.clear()
		_save_state()
		signed_in.emit(user_id)
	return res


func sign_out(everywhere := false) -> void:
	if is_signed_in():
		await client.logout(everywhere)
	_forget_session()


## Any call that comes back signed_out ends the local session too.
func handle_result(res: Dictionary) -> Dictionary:
	if not res.ok and res.error != null and (res.error as St33fError).is_signed_out() and is_signed_in():
		_forget_session()
	return res


func _forget_session() -> void:
	var was := is_signed_in()
	client.token = ""
	user_id = ""
	tokens.clear()
	profile_sync.version = 0
	_save_state()
	if was:
		signed_out.emit()


func _process(delta: float) -> void:
	if not is_signed_in():
		return
	profile_sync.tick(delta)
	_queue_timer -= delta
	if _queue_timer <= 0.0 and not queue.items.is_empty():
		_queue_timer = 5.0
		queue.flush(Time.get_unix_time_from_system())


static func _server_wins(_local: Dictionary, server: Dictionary) -> Dictionary:
	return server


func _load_state() -> void:
	if not FileAccess.file_exists(STATE_PATH):
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(STATE_PATH))
	if typeof(d) == TYPE_DICTIONARY:
		user_id = str(d.get("user_id", ""))
		profile_sync.version = int(d.get("profile_version", 0))


func _save_state() -> void:
	DirAccess.make_dir_recursive_absolute(STATE_PATH.get_base_dir())
	var f := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"user_id": user_id, "profile_version": profile_sync.version}))
