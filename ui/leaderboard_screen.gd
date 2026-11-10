extends Control
## Leaderboard (FO §8): tabs Day (the daily challenge) / Week; each player's best; your own place always visible.
## Scores that wait for the replay check are marked. Names come from word lists (PlayerName); tap a row for the
## player's public profile (name, favourite animal, mastery, collection).
## Debug entry: --scene=leaderboard [--board=week]

const BOARDS := ["day", "week"]

var _board := "day"
var _list: VBoxContainer
var _status: Label
var _tabs: Array[Button] = []
var _loading := 0 # request counter: a late answer for an old tab is ignored


func _ready() -> void:
	theme = UiTheme.get_theme()
	Platform.entered("leaderboard")
	var bg := TextureRect.new()
	bg.texture = UiTheme.sky_gradient()
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var back := Button.new()
	back.text = tr("COMMON_BACK")
	back.pressed.connect(func() -> void: get_tree().change_scene_to_file(Boot.SCENES["menu"]))
	add_child(back)
	back.position = Vector2(60, 40)

	var title := Label.new()
	title.text = tr("MENU_LEADERBOARD")
	title.label_settings = UiTheme.heading(80)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	title.position.y = 30
	title.grow_horizontal = Control.GROW_DIRECTION_BOTH

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 20)
	tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(tabs)
	tabs.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	tabs.position.y = 150
	tabs.grow_horizontal = Control.GROW_DIRECTION_BOTH
	for b in BOARDS:
		var t := Button.new()
		t.text = tr("BOARD_TAB_DAY") if b == "day" else tr("BOARD_TAB_WEEK")
		t.toggle_mode = true
		t.custom_minimum_size = Vector2(260, 0)
		t.pressed.connect(func() -> void: _show(b))
		tabs.add_child(t)
		_tabs.append(t)

	var panel := PanelContainer.new()
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	panel.custom_minimum_size = Vector2(1100, 760)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.position.y = 260
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 10)
	scroll.add_child(inner)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	inner.add_child(_status)
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	inner.add_child(_list)

	_show(str(Boot.args.get("board", "day")) if BOARDS.has(str(Boot.args.get("board", ""))) else "day")


func _show(board: String) -> void:
	_board = board
	for i in BOARDS.size():
		_tabs[i].button_pressed = BOARDS[i] == board
	for c in _list.get_children():
		c.queue_free()
	_status.text = tr("BOARD_LOADING")
	_loading += 1
	var ticket := _loading
	var res: Dictionary = await St33f.client.get_board(board) if St33f.client != null else {"ok": false, "error": null}
	if ticket != _loading or not is_inside_tree():
		return
	if not res.ok:
		_status.text = tr("BOARD_OFFLINE")
		return
	fill(res.data)


## Builds the rows from a board answer (also used by tests).
func fill(data: Dictionary) -> void:
	for c in _list.get_children():
		c.queue_free()
	var entries: Array = data.get("entries", [])
	var me: Variant = data.get("me")
	var my_player := str(me.player) if me is Dictionary else ""
	_status.text = tr("BOARD_EMPTY") if entries.is_empty() else tr("BOARD_PLAYERS").format({"count": int(data.get("players", entries.size()))})
	if not St33f.is_signed_in():
		_status.text += "\n" + tr("BOARD_SIGN_IN")
	var shown_me := false
	for e in entries:
		var mine := str(e.player) == my_player
		shown_me = shown_me or mine
		_list.add_child(_row(e, mine))
	if me is Dictionary and not shown_me:
		_list.add_child(_label("…", UiTheme.INK))
		_list.add_child(_row(me, true))


func _row(e: Dictionary, mine: bool) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var player_id := str(e.get("player", ""))
	row.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT or ev is InputEventScreenTouch and ev.pressed:
			open_profile(player_id))
	var shown := PlayerName.text(e.get("name")) if e.get("name") is Dictionary else tr("BOARD_PLAYER").format({"id": str(e.player).left(6)})
	var name := "%s (%s)" % [shown, tr("BOARD_YOU")] if mine else shown
	var colour := UiTheme.GOLD.darkened(0.35) if mine else UiTheme.INK
	var rank := _label("#%d" % int(e.rank), colour)
	rank.custom_minimum_size = Vector2(120, 0)
	row.add_child(rank)
	var who := _label(name, colour)
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	who.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	row.add_child(who)
	if bool(e.get("pending", false)):
		row.add_child(_label(tr("BOARD_PENDING"), Color(UiTheme.INK, 0.6)))
	var pts := _label(str(int(e.score)), colour)
	pts.custom_minimum_size = Vector2(160, 0)
	pts.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(pts)
	return row


## The player's public profile in the standard dialog frame: fits the screen, closes with a tap outside or Close.
func open_profile(player_id: String) -> Control:
	var shade := ColorRect.new()
	shade.color = Color(0, 0, 0, 0.45)
	add_child(shade)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed or ev is InputEventScreenTouch and ev.pressed:
			shade.queue_free())
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(900, 0)
	shade.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	box.add_child(body)
	body.add_child(_label(tr("PROFILE_LOADING"), UiTheme.INK))
	var close := Button.new()
	close.text = tr("COMMON_CLOSE")
	close.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close.pressed.connect(shade.queue_free)
	box.add_child(close)
	if player_id != "" and St33f.client != null:
		var res: Dictionary = await St33f.client.get_player(player_id)
		if is_instance_valid(body):
			fill_profile(body, res.data if res.ok else {})
	return shade


## Rows of a profile dialog from the service's answer ({} = no public profile). Also used by tests.
func fill_profile(body: VBoxContainer, p: Dictionary) -> void:
	for c in body.get_children():
		c.queue_free()
	if p.is_empty():
		body.add_child(_label(tr("PROFILE_UNAVAILABLE"), UiTheme.INK))
		return
	var title := _label(PlayerName.text(p.get("name")), UiTheme.INK)
	title.label_settings = UiTheme.heading(56, UiTheme.INK, 0)
	body.add_child(title)
	var fav := Content.animal(str(p.get("animal", "")))
	body.add_child(_label(tr("PROFILE_FAVOURITE").format({"animal": tr(str(fav.get("name_key", "?")))}), UiTheme.INK))
	body.add_child(_label(tr("PROFILE_BADGES"), UiTheme.GOLD.darkened(0.35)))
	var badges: Array = p.get("badges", [])
	if badges.is_empty():
		body.add_child(_label(tr("PROFILE_NO_BADGES"), UiTheme.INK))
	for b in badges:
		var parts := str(b).split(":")
		if parts.size() == 2:
			var a := Content.animal(parts[0])
			body.add_child(_label("%s · %s" % [tr(str(a.get("name_key", parts[0]))), Mastery.tier_name(int(parts[1]))], UiTheme.INK))
	body.add_child(_label(tr("PROFILE_COLLECTION").format({"count": (p.get("collection", []) as Array).size()}), UiTheme.INK))


func _label(text: String, colour: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", colour)
	l.add_theme_font_size_override("font_size", 36)
	return l
