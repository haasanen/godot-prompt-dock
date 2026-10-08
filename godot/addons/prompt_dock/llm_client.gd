@tool
extends Node
## Minimal OpenAI-compatible chat client over HTTPRequest.
## Non-streaming v1: one request per turn, async completion.

signal responded(ok: bool, text: String)

var base_url: String = "http://localhost:8000/v1"
var model: String = "Qwen3.8-Flash-Next"
var api_key: String = ""
var timeout_sec: float = 300.0


func chat(messages: Array, tools: Array = []) -> void:
	var body := {
		"model": model,
		"messages": messages,
		"max_tokens": 4096,
	}
	if not tools.is_empty():
		body["tools"] = tools
	var headers := ["Content-Type: application/json"]
	if api_key != "":
		headers.append("Authorization: Bearer " + api_key)
	var req := HTTPRequest.new()
	req.timeout = timeout_sec
	add_child(req)
	req.request_completed.connect(_on_done.bind(req))
	var err := req.request(base_url.trim_suffix("/") + "/chat/completions", headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		_respond(false, "request failed to start: " + error_string(err))


func _on_done(result: int, code: int, _headers: PackedStringArray, bytes: PackedByteArray, req: HTTPRequest) -> void:
	req.queue_free()
	var text := bytes.get_string_from_utf8()
	if result != HTTPRequest.RESULT_SUCCESS:
		_respond(false, "HTTP transport error: " + error_string(result))
		return
	if code != 200:
		_respond(false, "HTTP %d: %s" % [code, text.left(400)])
		return
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("choices"):
		_respond(false, "bad response JSON: " + text.left(300))
		return
	var msg: Dictionary = parsed["choices"][0].get("message", {})
	_respond(true, JSON.stringify(msg))


func _respond(ok: bool, text: String) -> void:
	responded.emit(ok, text)
