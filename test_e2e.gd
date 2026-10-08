extends SceneTree
## Headless end-to-end test for Prompt Dock: tool layer + live LLM round-trip.
## Run: godot --headless -s test_e2e.gd

const Dock := preload("res://addons/prompt_dock/dock.gd")
const Tools := preload("res://addons/prompt_dock/tools.gd")
const Llm := preload("res://addons/prompt_dock/llm_client.gd")

var _failures := 0


func _init() -> void:
	print("== tool layer ==")
	var tools = Tools.new()
	root.add_child(tools)
	tools.setup(null)  # no EditorInterface headless: scene context unavailable

	var listing: String = tools.execute("list_files", {"path": "res://addons/prompt_dock"}, true)
	_check("list_files finds dock.gd", listing.contains("dock.gd"))

	var read: String = tools.execute("read_file", {"path": "res://addons/prompt_dock/plugin.cfg"}, true)
	_check("read_file returns plugin.cfg", read.contains("Prompt Dock"))

	var bad: String = tools.execute("read_file", {"path": "/etc/passwd"}, true)
	_check("read_file rejects non-res paths", bad.contains("must start with"))

	var decl: String = tools.execute("write_file", {"path": "res://tmp_test.txt", "content": "x"}, false)
	_check("write_file declined when not confirmed", decl.contains("declined"))

	var trav: String = tools.execute("write_file", {"path": "res://../escape.txt", "content": "x"}, true)
	_check("write_file blocks traversal", trav.contains("traversal"))

	var w: String = tools.execute("write_file", {"path": "res://tmp_test.txt", "content": "hello from test"}, true)
	_check("write_file writes when confirmed", w.contains("\"ok\":true"))
	var rw: String = tools.execute("read_file", {"path": "res://tmp_test.txt"}, true)
	_check("written file reads back", rw.contains("hello from test"))

	print("== live LLM round-trip (Strata) ==")
	_llm_phase.call_deferred()


func _llm_phase() -> void:
	var client = Llm.new()
	client.base_url = "http://strata:8000/v1"
	client.model = "Qwen3.8-Flash-Next"
	root.add_child(client)
	client.responded.connect(_on_llm)
	client.chat([{"role": "user", "content": "Reply with exactly: PONG"}])


func _on_llm(ok: bool, raw: String) -> void:
	_check("LLM call succeeds", ok)
	if ok:
		var msg = JSON.parse_string(raw)
		var content := str(msg.get("content", ""))
		print("   model said: ", content.left(120))
		_check("model replied PONG", content.contains("PONG"))

	print("== tool-calling round-trip ==")
	var client2 = Llm.new()
	client2.base_url = "http://strata:8000/v1"
	client2.model = "Qwen3.8-Flash-Next"
	root.add_child(client2)
	client2.responded.connect(_on_tools_llm)
	var tools = Tools.new()
	root.add_child(tools)
	tools.setup(null)
	client2.chat(
		[{"role": "user", "content": "Use the list_files tool on res://addons/prompt_dock and then tell me how many .gd files it found."}],
		tools.tool_defs())


func _on_tools_llm(ok: bool, raw: String) -> void:
	_check("tool-calling call succeeds", ok)
	if ok:
		var msg = JSON.parse_string(raw)
		var tcs = msg.get("tool_calls", [])
		print("   tool_calls: ", tcs.size())
		_check("model requested a tool", typeof(tcs) == TYPE_ARRAY and not (tcs as Array).is_empty())
		if typeof(tcs) == TYPE_ARRAY and not (tcs as Array).is_empty():
			var fn: Dictionary = tcs[0].get("function", {})
			print("   requested: ", fn.get("name"), " args=", fn.get("arguments"))
			_check("requested list_files", str(fn.get("name")) == "list_files")
	print("RESULT: ", "FAILURES=%d" % _failures)
	quit(1 if _failures > 0 else 0)


func _check(name: String, cond: bool) -> void:
	if cond:
		print("  ok: ", name)
	else:
		_failures += 1
		print("  FAIL: ", name)
