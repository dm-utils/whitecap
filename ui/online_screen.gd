extends Control
## Looking for an online match (phase 12c): joins the lobby with the chosen animal, shows how many players were
## found and when it starts (bots fill empty seats), then hands the seat over to the match scene.
## Debug entry: --scene=online

var _client: OnlineClient
var _status: Label
var _done := false


func _ready() -> void:
	theme = UiTheme.get_theme()
	Platform.entered("online")
	var bg := TextureRect.new()
	bg.texture = UiTheme.sky_gradient()
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 30)
	add_child(box)
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var title := Label.new()
	title.text = tr("ONLINE_TITLE")
	title.label_settings = UiTheme.heading(90)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_status = Label.new()
	_status.text = tr("ONLINE_CONNECTING")
	_status.label_settings = UiTheme.heading(44, UiTheme.INK, 0)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_status)
	var cancel := Button.new()
	cancel.text = tr("ONLINE_CANCEL")
	cancel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	cancel.pressed.connect(_back)
	box.add_child(cancel)

	if St33f.client == null:
		_status.text = tr("ONLINE_OFFLINE")
		return
	var animal := str(Platform.load_profile().get("selected_animal", "octopus"))
	_client = OnlineClient.new()
	add_child(_client)
	_client.message.connect(_on_message)
	_client.closed.connect(func(_c: int) -> void:
		if not _done:
			_status.text = tr("ONLINE_OFFLINE"))
	_client.open(St33f.client.pvp_lobby_url(animal))


func _on_message(msg: Dictionary) -> void:
	match str(msg.get("type", "")):
		"waiting":
			_status.text = tr("ONLINE_WAITING").format({"players": int(msg.players), "seconds": int(ceil(float(msg.get("startsInMs", 0)) / 1000.0))})
		"match":
			_done = true
			Boot.next_match = {"online": msg}
			get_tree().change_scene_to_file(Boot.SCENES["match"])


func _back() -> void:
	_done = true
	if _client != null:
		_client.close()
	get_tree().change_scene_to_file(Boot.SCENES["menu"])
