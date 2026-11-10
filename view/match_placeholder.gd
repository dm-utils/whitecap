extends Control
## Placeholder for the match (phase 3). Proves the debug entry: --scene=match --seed=123


func _ready() -> void:
	theme = UiTheme.get_theme()
	var bg := ColorRect.new()
	bg.color = UiTheme.DEEP
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var l := Label.new()
	l.text = tr("MATCH_PLACEHOLDER").format({"seed": Boot.seed_value()})
	l.label_settings = UiTheme.heading(56)
	add_child(l)
	l.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	l.grow_horizontal = Control.GROW_DIRECTION_BOTH
	l.grow_vertical = Control.GROW_DIRECTION_BOTH

	var back := Button.new()
	back.text = tr("COMMON_BACK")
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file(Boot.SCENES["menu"]))
	add_child(back)
	back.position = Vector2(60, 50)
