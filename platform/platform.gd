extends Node
## The one door between the game and everything that may live on a server later:
## profile/cloud save, achievements, results/leaderboards, remote config, crash reports.
## Game code only calls these functions. The backend behind them is swappable:
## LocalBackend now, RemoteBackend (St33f Engine) from phase 2/4.

signal profile_changed(profile: Dictionary)

const LocalBackend := preload("res://platform/local_backend.gd")

var backend: RefCounted


func _ready() -> void:
	backend = LocalBackend.new()


func is_signed_in() -> bool:
	return backend.is_signed_in()


func load_profile() -> Dictionary:
	return backend.load_profile()


func save_profile(profile: Dictionary) -> void:
	backend.save_profile(profile)
	profile_changed.emit(profile)


func unlock_achievement(id: String, tier: int = 1) -> void:
	backend.unlock_achievement(id, tier)


func submit_result(board: String, result: Dictionary, replay: Dictionary) -> void:
	backend.submit_result(board, result, replay)


func get_config(key: String, default_value: Variant = null) -> Variant:
	return backend.get_config(key, default_value)


func report_crash(message: String, stack: Array = []) -> void:
	backend.report_crash(message, stack)
