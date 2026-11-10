class_name St33fClient
extends RefCounted
## Thin client for the St33f Engine API. Every call returns
##   {"ok": bool, "status": int, "data": Dictionary, "error": St33fError or null}
## and never throws. Calls are coroutines: `var r := await client.me()`.
## Each service (accounts, feedback, ...) has its own host; tests can point all services at one base URL.

const URLS := {
	"dev": {
		"accounts": "https://st33f-accounts-dev.st33fd3v.workers.dev",
		"feedback": "https://st33f-feedback-dev.st33fd3v.workers.dev",
	},
	"acc": {},
	"prod": {
		"accounts": "https://api.steefbeest.nl",
		"feedback": "https://feedback-api.steefbeest.nl",
	},
}

var bases: Dictionary = {}
var game: String
var transport: St33fTransport
var token := ""
var user_agent := ""


## base: a URL used for every service, or a {service: url} dictionary.
func _init(p_game: String, base: Variant, p_transport: St33fTransport) -> void:
	game = p_game
	transport = p_transport
	if base is Dictionary:
		for k in base:
			bases[k] = str(base[k]).trim_suffix("/")
	else:
		bases["*"] = str(base).trim_suffix("/")
	# Browsers forbid setting User-Agent; native builds identify game, version and OS.
	if not OS.has_feature("web"):
		user_agent = "%s/%s (%s)" % [game.capitalize(), str(ProjectSettings.get_setting("application/config/version", "0")), OS.get_name()]


func base_for(service: String) -> String:
	return str(bases.get(service, bases.get("*", "")))


func call_api(method: int, path: String, body: Variant = null, auth := false, service := "accounts", extra_headers := PackedStringArray()) -> Dictionary:
	var headers := _headers(extra_headers)
	var text := ""
	if body != null:
		headers.append("Content-Type: application/json")
		# full precision: never round numbers the server or a sim will read
		text = JSON.stringify(body, "", false, true)
	if auth:
		if token == "":
			return _result(401, {"error": "signed_out", "message": "sign in first"})
		headers.append("Authorization: Bearer " + token)
	var base := base_for(service)
	if base == "":
		return _result(0, {"error": "network", "message": "no address for " + service})
	var r: Dictionary = await transport.request(method, base + path, headers, text)
	return _parse(r)


func call_raw(method: int, path: String, body: PackedByteArray, content_type: String, service: String, extra_headers := PackedStringArray()) -> Dictionary:
	var headers := _headers(extra_headers)
	headers.append("Content-Type: " + content_type)
	var r: Dictionary = await transport.request_raw(method, base_for(service) + path, headers, body)
	return _parse(r)


func _headers(extra: PackedStringArray) -> PackedStringArray:
	var headers := PackedStringArray()
	if user_agent != "":
		headers.append("User-Agent: " + user_agent)
	headers.append_array(extra)
	return headers


func _parse(r: Dictionary) -> Dictionary:
	var data: Variant = JSON.parse_string(str(r.get("body", ""))) if str(r.get("body", "")) != "" else {}
	return _result(int(r.get("status", 0)), data if typeof(data) == TYPE_DICTIONARY else {})


func _result(status: int, data: Dictionary) -> Dictionary:
	if status >= 200 and status < 300:
		return {"ok": true, "status": status, "data": data, "error": null}
	var code := "network" if status == 0 else str(data.get("error", "http_%d" % status))
	var err := St33fError.new(status, code, str(data.get("message", "")), data)
	return {"ok": false, "status": status, "data": data, "error": err}


# --- accounts ---

func health(service := "accounts") -> Dictionary:
	return await call_api(HTTPClient.METHOD_GET, "/health", null, false, service)


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


# --- feedback ---

## A player report. Signed in when a token exists (so the player can see it later), anonymous otherwise.
func submit_feedback(category: String, text: String, build: String, device: String, attachments: Array) -> Dictionary:
	var body := {"game": game, "category": category, "text": text, "build": build, "device": device, "attachments": attachments}
	return await call_api(HTTPClient.METHOD_POST, "/v1/feedback", body, token != "", "feedback")


func upload_attachment(report_id: String, kind: String, upload_token: String, bytes: PackedByteArray, content_type: String) -> Dictionary:
	return await call_raw(HTTPClient.METHOD_PUT, "/v1/feedback/%s/attachments/%s" % [report_id, kind], bytes, content_type, "feedback",
		PackedStringArray(["X-Upload-Token: " + upload_token]))


func my_feedback() -> Dictionary:
	return await call_api(HTTPClient.METHOD_GET, "/v1/feedback/mine", null, true, "feedback")
