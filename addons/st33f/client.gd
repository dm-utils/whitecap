class_name St33fClient
extends RefCounted
## Thin client for the St33f Engine API. Every call returns
##   {"ok": bool, "status": int, "data": Dictionary, "error": St33fError or null}
## and never throws. Calls are coroutines: `var r := await client.me()`.

const URLS := {
	"dev": "https://st33f-accounts-dev.st33fd3v.workers.dev",
	"acc": "",
	"prod": "https://api.steefbeest.nl",
}

var base_url: String
var game: String
var transport: St33fTransport
var token := ""
var user_agent := ""


func _init(p_game: String, p_base_url: String, p_transport: St33fTransport) -> void:
	game = p_game
	base_url = p_base_url.trim_suffix("/")
	transport = p_transport
	# Browsers forbid setting User-Agent; native builds identify game, version and OS.
	if not OS.has_feature("web"):
		user_agent = "%s/%s (%s)" % [game.capitalize(), str(ProjectSettings.get_setting("application/config/version", "0")), OS.get_name()]


func call_api(method: int, path: String, body: Variant = null, auth := false) -> Dictionary:
	var headers := PackedStringArray()
	if user_agent != "":
		headers.append("User-Agent: " + user_agent)
	var text := ""
	if body != null:
		headers.append("Content-Type: application/json")
		# full precision: never round numbers the server or a sim will read
		text = JSON.stringify(body, "", false, true)
	if auth:
		if token == "":
			return _result(401, {"error": "signed_out", "message": "sign in first"})
		headers.append("Authorization: Bearer " + token)
	var r: Dictionary = await transport.request(method, base_url + path, headers, text)
	var data: Variant = JSON.parse_string(str(r.get("body", ""))) if str(r.get("body", "")) != "" else {}
	return _result(int(r.get("status", 0)), data if typeof(data) == TYPE_DICTIONARY else {})


func _result(status: int, data: Dictionary) -> Dictionary:
	if status >= 200 and status < 300:
		return {"ok": true, "status": status, "data": data, "error": null}
	var code := "network" if status == 0 else str(data.get("error", "http_%d" % status))
	var err := St33fError.new(status, code, str(data.get("message", "")), data)
	return {"ok": false, "status": status, "data": data, "error": err}


# --- endpoints ---

func health() -> Dictionary:
	return await call_api(HTTPClient.METHOD_GET, "/health")


func auth_start(email: String) -> Dictionary:
	return await call_api(HTTPClient.METHOD_POST, "/auth/start", {"email": email, "game": game})


func auth_verify(email: String, challenges: PackedStringArray, code: String) -> Dictionary:
	return await call_api(HTTPClient.METHOD_POST, "/auth/verify", {"email": email, "challenges": Array(challenges), "code": code})


func logout(everywhere := false) -> Dictionary:
	return await call_api(HTTPClient.METHOD_POST, "/auth/logout", {"everywhere": everywhere}, true)


func me() -> Dictionary:
	return await call_api(HTTPClient.METHOD_GET, "/me", null, true)


func get_profile() -> Dictionary:
	return await call_api(HTTPClient.METHOD_GET, "/v1/games/%s/profile" % game, null, true)


func put_profile(profile: Dictionary, version: int) -> Dictionary:
	return await call_api(HTTPClient.METHOD_PUT, "/v1/games/%s/profile" % game, {"profile": profile, "version": version}, true)
