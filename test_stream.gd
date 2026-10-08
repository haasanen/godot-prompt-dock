extends SceneTree
## Headless test for the streaming client: plain stream + tool-call stream.

const Llm := preload("res://addons/prompt_dock/llm_client.gd")

var _client
var _phase := 0
var _deltas := 0
var _thinks := 0
var _failures := 0


func _init() -> void:
	_client = Llm.new()
	_client.base_url = "http://strata:8000/v1"
	_client.model = "Qwen3.8-Flash-Next"
	root.add_child(_client)
	_client.delta.connect(func(t: String) -> void: _deltas += 1)
	_client.thinking.connect(func(t: String) -> void: _thinks += 1)
	_client.responded.connect(_on_resp)
	print("== streaming plain ==")
	_client.chat([{"role": "user", "content": "Count 1 to 5, digits only."}])


func _process(_dt: float) -> bool:
	_client.poll()
	return false


func _on_resp(ok: bool, raw: String) -> void:
	if _phase == 0:
		_check("stream call ok", ok)
		if not ok:
			print("   ERR: ", raw.left(300))
		print("   deltas=%d thinking=%d" % [_deltas, _thinks])
		_check("multiple deltas streamed", _deltas > 1)
		var msg = JSON.parse_string(raw) if ok else {}
		var content := str(msg.get("content", ""))
		print("   merged content: ", content.left(100))
		_check("merged content has 5", content.contains("5"))
		# phase 1: streaming tool call
		_phase = 1
		_deltas = 0
		var tools = preload("res://addons/prompt_dock/tools.gd").new()
		root.add_child(tools)
		tools.setup(null)
		_client.chat(
			[{"role": "user", "content": "Use list_files on res://addons/prompt_dock, then say DONE."}],
			tools.tool_defs())
	elif _phase == 1:
		_check("tool stream ok", ok)
		var msg = JSON.parse_string(raw) if ok else {}
		var tcs = msg.get("tool_calls", [])
		print("   tool_calls merged: ", tcs.size())
		if typeof(tcs) == TYPE_ARRAY and not (tcs as Array).is_empty():
			var fn: Dictionary = tcs[0].get("function", {})
			print("   name=", fn.get("name"), " args=", str(fn.get("arguments")).left(80))
			_check("streamed tool name", str(fn.get("name")) == "list_files")
			var args = JSON.parse_string(str(fn.get("arguments")))
			_check("streamed tool args parse as JSON", typeof(args) == TYPE_DICTIONARY)
		else:
			_check("model requested a tool", false)
		print("RESULT: FAILURES=%d" % _failures)
		quit(1 if _failures > 0 else 0)


func _check(name: String, cond: bool) -> void:
	if cond:
		print("  ok: ", name)
	else:
		_failures += 1
		print("  FAIL: ", name)
