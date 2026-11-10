extends Control
## Main menu skeleton: two taps to play (FO §2). Real screens arrive in phase 3+.

var _toast: Label
var _toast_t := 0.0


func _ready() -> void:
	theme = UiTheme.get_theme()
	var bg := TextureRect.new()
	bg.texture = UiTheme.sky_gradient()
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var profile: Dictionary = Platform.load_profile()
	var animal := Content.animal(str(profile.get("selected_animal", "octopus")))

	# left menu
	var menu := VBoxContainer.new()
	menu.add_theme_constant_override("separation", 22)
	add_child(menu)
	menu.position = Vector2(60, 200)
	menu.custom_minimum_size = Vector2(420, 0)
	for key in ["MENU_COLLECTION", "MENU_PATH", "MENU_LEADERBOARD", "MENU_PROFILE", "MENU_SETTINGS"]:
		var b := Button.new()
		b.text = tr(key)
		b.pressed.connect(_soon)
		menu.add_child(b)

	# centre: selected animal (art arrives in phase 6)
	var name_label := Label.new()
	name_label.text = tr(str(animal.get("name_key", "")))
	name_label.label_settings = UiTheme.heading(64, UiTheme.INK, 0)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(name_label)
	name_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	name_label.grow_horizontal = Control.GROW_DIRECTION_BOTH

	var count := Label.new()
	count.text = tr("MENU_ANIMALS_LOADED").format({"count": Content.animals().size()})
	add_child(count)
	count.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	count.position.y += 70
	count.grow_horizontal = Control.GROW_DIRECTION_BOTH

	# right: daily + play
	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 26)
	add_child(right)
	right.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	right.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	right.grow_vertical = Control.GROW_DIRECTION_BEGIN
	right.offset_left = -620
	right.offset_right = -60
	right.offset_bottom = -60
	var daily := Button.new()
	daily.theme_type_variation = "BlueButton"
	daily.text = tr("MENU_DAILY")
	daily.pressed.connect(_soon)
	right.add_child(daily)
	var play := Button.new()
	play.theme_type_variation = "PlayButton"
	play.text = tr("MENU_PLAY")
	play.pressed.connect(_play)
	right.add_child(play)

	var version := Label.new()
	version.text = tr("MENU_VERSION").format({"version": ProjectSettings.get_setting("application/config/version")})
	version.add_theme_font_size_override("font_size", 24)
	add_child(version)
	version.position = Vector2(60, 40)

	var pearls := Label.new()
	pearls.text = tr("MENU_PEARLS").format({"count": int(profile.get("pearls_total", 0))})
	pearls.label_settings = UiTheme.heading(40, UiTheme.INK, 0)
	add_child(pearls)
	pearls.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	pearls.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	pearls.offset_left = -400
	pearls.offset_right = -60
	pearls.offset_top = 40
	pearls.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	_toast = Label.new()
	_toast.label_settings = UiTheme.heading(44, Color.WHITE, 10)
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.modulate.a = 0.0
	add_child(_toast)
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast.position.y = 60
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH


func _process(delta: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= delta
		_toast.modulate.a = clampf(_toast_t * 2.0, 0.0, 1.0)


func _soon() -> void:
	_toast.text = tr("MENU_COMING_SOON")
	_toast_t = 1.6


func _play() -> void:
	Boot.args["seed"] = str(randi())
	get_tree().change_scene_to_file(Boot.SCENES["match"])
