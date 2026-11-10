extends Control
## Settings: controls, account (sign in by e-mail code / sign out), report a problem (FO §9, §10).

var _box: VBoxContainer
var _account: VBoxContainer
var _status: Label
var _email_edit: LineEdit
var _code_edit: LineEdit
var _resend: Button
var _resend_left := 0.0
var _busy := false


func _ready() -> void:
	theme = UiTheme.get_theme()
	Platform.entered("settings")
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
	title.text = tr("SETTINGS_TITLE")
	title.label_settings = UiTheme.heading(80)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	title.position.y = 30
	title.grow_horizontal = Control.GROW_DIRECTION_BOTH

	var panel := PanelContainer.new()
	add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	panel.custom_minimum_size = Vector2(1100, 0)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 22)
	panel.add_child(_box)

	# controls
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 30)
	_box.add_child(row)
	row.add_child(_heading(tr("SETTINGS_CONTROLS")))
	var controls := OptionButton.new()
	controls.add_item(tr("CONTROLS_KEYS"))
	controls.add_item(tr("CONTROLS_MOUSE"))
	var profile: Dictionary = Platform.load_profile()
	controls.selected = 1 if str(profile.get("settings", {}).get("controls", "keys")) == "mouse" else 0
	controls.item_selected.connect(_on_controls)
	row.add_child(controls)

	# account
	_box.add_child(_heading(tr("SETTINGS_ACCOUNT")))
	_account = VBoxContainer.new()
	_account.add_theme_constant_override("separation", 14)
	_box.add_child(_account)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(1000, 0)

	# report
	var report := Button.new()
	report.text = tr("SETTINGS_REPORT")
	report.pressed.connect(func() -> void: Platform.open_report())
	_box.add_child(report)
	var hint := Label.new()
	hint.text = tr("REPORT_HOTKEY")
	hint.add_theme_font_size_override("font_size", 24)
	_box.add_child(hint)

	_show_account()
	St33f.signed_in.connect(func(_u: String) -> void: _show_account())
	St33f.signed_out.connect(_show_account)


func _process(delta: float) -> void:
	if _resend_left > 0.0 and _resend != null:
		_resend_left -= delta
		_resend.disabled = _resend_left > 0.0
		_resend.text = tr("SIGNIN_RESEND_IN").format({"seconds": int(ceil(_resend_left))}) if _resend_left > 0.0 else tr("SIGNIN_RESEND")


func _heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.label_settings = UiTheme.heading(40, UiTheme.INK, 0)
	return l


func _on_controls(index: int) -> void:
	var p: Dictionary = Platform.load_profile()
	var s: Dictionary = p.get("settings", {})
	s["controls"] = "mouse" if index == 1 else "keys"
	p["settings"] = s
	Platform.save_profile(p)


func _clear_account() -> void:
	for c in _account.get_children():
		if c != _status:
			c.queue_free()
	if _status.get_parent() == null:
		_account.add_child(_status)
	_status.text = ""
	_resend = null


## Signed in: who and sign-out buttons. Signed out: the e-mail step.
func _show_account() -> void:
	_clear_account()
	if St33f.is_signed_in():
		_add_label(tr("ACCOUNT_SIGNED_IN").format({"email": St33f.email if St33f.email != "" else "…"}))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 20)
		_account.add_child(row)
		var out := Button.new()
		out.text = tr("ACCOUNT_SIGN_OUT")
		out.pressed.connect(func() -> void: St33f.sign_out(false))
		row.add_child(out)
		var all := Button.new()
		all.text = tr("ACCOUNT_SIGN_OUT_ALL")
		all.pressed.connect(func() -> void: St33f.sign_out(true))
		row.add_child(all)
		_account.move_child(_status, -1)
		return
	_add_label(tr("ACCOUNT_GUEST"))
	_add_label(tr("SIGNIN_EMAIL_HINT"))
	_email_edit = LineEdit.new()
	_email_edit.placeholder_text = tr("SIGNIN_EMAIL_PLACEHOLDER")
	_email_edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS
	_email_edit.text_submitted.connect(func(_t: String) -> void: _send_code())
	_account.add_child(_email_edit)
	var send := Button.new()
	send.text = tr("SIGNIN_SEND")
	send.theme_type_variation = "BlueButton"
	send.pressed.connect(_send_code)
	_account.add_child(send)
	_account.move_child(_status, -1)


func _show_code_step(email: String) -> void:
	_clear_account()
	_add_label(tr("SIGNIN_CODE_HINT").format({"email": email}))
	_code_edit = LineEdit.new()
	_code_edit.placeholder_text = tr("SIGNIN_CODE_PLACEHOLDER")
	_code_edit.max_length = 6
	_code_edit.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	_code_edit.text_submitted.connect(func(_t: String) -> void: _verify())
	_account.add_child(_code_edit)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	_account.add_child(row)
	var verify := Button.new()
	verify.text = tr("SIGNIN_VERIFY")
	verify.theme_type_variation = "BlueButton"
	verify.pressed.connect(_verify)
	row.add_child(verify)
	_resend = Button.new()
	_resend.pressed.connect(_send_code)
	row.add_child(_resend)
	_resend_left = 60.0
	var other := Button.new()
	other.text = tr("SIGNIN_OTHER_ADDRESS")
	other.pressed.connect(_show_account)
	row.add_child(other)
	_account.move_child(_status, -1)
	_code_edit.grab_focus()


func _add_label(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(1000, 0)
	_account.add_child(l)


var _pending_email := ""


func _send_code() -> void:
	if _busy:
		return
	var email := _email_edit.text.strip_edges() if _email_edit != null and is_instance_valid(_email_edit) else _pending_email
	_busy = true
	var res: Dictionary = await St33f.sign_in_start(email)
	_busy = false
	if res.ok:
		_pending_email = email
		_show_code_step(email)
	else:
		_status.text = UiErrors.text(res.error)


func _verify() -> void:
	if _busy:
		return
	_busy = true
	var res: Dictionary = await St33f.sign_in_verify(_code_edit.text)
	_busy = false
	if res.ok:
		_show_account()
		_status.text = tr("SIGNIN_DONE")
	else:
		_status.text = UiErrors.text(res.error)
