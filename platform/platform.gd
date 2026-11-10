extends Node
## The one door between the game and everything that may live on a server later:
## profile/cloud save, achievements, results/leaderboards, remote config, crash reports.
## Game code only calls these functions. The backend behind them is swappable:
## RemoteBackend: local-first, synced to the St33f Engine when signed in (St33f autoload, loaded before us).

signal profile_changed(profile: Dictionary)

const RemoteBackend := preload("res://platform/remote_backend.gd")

var backend: RefCounted


func _ready() -> void:
	backend = RemoteBackend.new(St33f)


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
