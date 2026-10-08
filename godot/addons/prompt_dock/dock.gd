@tool
extends VBoxContainer
## The Prompt Dock UI + agent loop. Pure code (no .tscn) so the addon is
## plain text files — easy to review, diff, and package.

const LlmClient := preload("llm_client.gd")
const Tools := preload("tools.gd")

const SYSTEM_PROMPT := """You are a coding assistant embedded inside the Godot editor, with live tools.
Rules:
- You can read and write project files, run GDScript inside the EDITOR process, and inspect the live scene tree and selection.
- Call get_project_index FIRST when you need to understand the project — it maps every script (class + functions) and scene (node skeleton) in one call.
- Prefer get_scene_context to see what the user is editing right now.
- For scene edits use scene_op (add_node / remove_node / set_property) — it is structured and undoable. Use run_editor_script only when scene_op cannot do it.
- Scripts (.gd) may be edited as text with write_file.
- Keep answers short. The user is in a small dock, not a terminal.
- When you change something, say what changed and how to verify it."""

var _history: RichTextLabel
var _input: LineEdit
var _status: Label
var _send_btn: Button
var _settings_btn: Button
var _client: Node
var _tools: Node
var _busy := false
var _messages: Array = []  # chat history: {role, content} (+ tool fields)
var _stream_open := false   # an assistant paragraph is being streamed
var _settings := {
	"base_url": "http://localhost:8000/v1",
	"model": "Qwen3.8-Flash-Next",
	"api_key": "",
}


func setup_editor(editor_interface: EditorInterface) -> void:
	_load_settings()
	_client = LlmClient.new()
	_client.base_url = _settings.base_url
	_client.model = _settings.model
	_client.api_key = _settings.api_key
	add_child(_client)
	_client.responded.connect(_on_llm_response)
	_client.delta.connect(_on_delta)
	_client.thinking.connect(_on_thinking)

	_tools = Tools.new()
	add_child(_tools)
	_tools.setup(editor_interface)

	_build_ui()
	_load_chat()
	_append("Prompt Dock ready. Model: %s" % _settings.model, "dim")


func _process(_dt: float) -> void:
	_client.poll()


func _build_ui() -> void:
	var top := HBoxContainer.new()
	add_child(top)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_status)
	_settings_btn = Button.new()
	_settings_btn.text = "Settings"
	_settings_btn.pressed.connect(_show_settings)
	top.add_child(_settings_btn)
	var clear_btn := Button.new()
	clear_btn.text = "New chat"
	clear_btn.pressed.connect(_clear_chat)
	top.add_child(clear_btn)

	_history = RichTextLabel.new()
	_history.bbcode_enabled = true
	_history.scroll_following = true
	_history.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_history)

	var row := HBoxContainer.new()
	add_child(row)
	_input = LineEdit.new()
	_input.placeholder_text = "Ask about this project... (Enter to send)"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.text_submitted.connect(func(_t: String) -> void: _send())
	row.add_child(_input)
	_send_btn = Button.new()
	_send_btn.text = "Send"
	_send_btn.pressed.connect(_send)
	row.add_child(_send_btn)


func _send() -> void:
	var text := _input.text.strip_edges()
	if text == "" or _busy:
		return
	_input.text = ""
	_messages.append({"role": "user", "content": text})
	_append("You: " + text, "user")
	_run_turn()


func _run_turn() -> void:
	_busy = true
	_send_btn.disabled = true
	_status.text = "thinking..."
	var msgs := [{"role": "system", "content": SYSTEM_PROMPT}]
	msgs.append_array(_messages)
	_client.chat(msgs, _tools.tool_defs(), true)


# --- streaming display ------------------------------------------------------

func _on_thinking(_t: String) -> void:
	if _busy:
		_status.text = "reasoning..."


func _on_delta(piece: String) -> void:
	if not _stream_open:
		_stream_open = true
		_history.append_text("\n")
	_history.append_text(piece.replace("[", "\\["))
	_status.text = "answering..."


# --- agent loop --------------------------------------------------------------

func _on_llm_response(ok: bool, raw: String) -> void:
	_stream_open = false
	if not ok:
		_finish_turn()
		_append("Error: " + raw, "err")
		return
	var msg = JSON.parse_string(raw)
	if typeof(msg) != TYPE_DICTIONARY:
		_finish_turn()
		_append("Error: unparsable model reply", "err")
		return
	var m: Dictionary = msg
	# strip reasoning before storing (keeps context small)
	m.erase("reasoning_content")
	_messages.append(m)
	var tool_calls = m.get("tool_calls", [])
	if typeof(tool_calls) == TYPE_ARRAY and not (tool_calls as Array).is_empty():
		var content := str(m.get("content", ""))
		if content.strip_edges() != "" and not _streamed_already(m):
			_append(content, "assistant")
		_run_tools(tool_calls as Array, 0)
		return
	_finish_turn()
	# content already streamed live; only add a label line if anything was said
	var reply := str(m.get("content", ""))
	if reply.strip_edges() == "":
		_append("(no reply)", "dim")
	_save_chat()


## True when the deltas for this message were already printed live.
func _streamed_already(_m: Dictionary) -> bool:
	return true


func _run_tools(calls: Array, i: int) -> void:
	if i >= calls.size():
		_save_chat()
		_run_turn()  # all tool results in: ask the model to continue
		return
	var tc: Dictionary = calls[i]
	var fn: Dictionary = tc.get("function", {})
	var name := str(fn.get("name", ""))
	var args = JSON.parse_string(str(fn.get("arguments", "{}")))
	if typeof(args) != TYPE_DICTIONARY:
		args = {}
	_status.text = "tool: " + name
	var mutating := name == "write_file" or name == "run_editor_script" or name == "scene_op"
	if not mutating:
		_after_tool(calls, i, tc, name, args, true)
		return
	var preview := str(args.get("content", "")) if name == "write_file" else str(args.get("code", ""))
	var target := str(args.get("path", "")) if name == "write_file" else ""
	var dlg := ConfirmationDialog.new()
	dlg.title = "Prompt Dock: confirm " + name
	match name:
		"write_file":
			dlg.dialog_text = "Write file?\n" + target
		"scene_op":
			dlg.dialog_text = "Edit the scene (undoable with Ctrl+Z)?\n" + JSON.stringify(args)
		_:
			dlg.dialog_text = "Run this code in the editor?\n\n" + preview.left(1200)
	add_child(dlg)
	dlg.confirmed.connect(func() -> void: dlg.queue_free(); _after_tool(calls, i, tc, name, args, true))
	dlg.cancelled.connect(func() -> void: dlg.queue_free(); _after_tool(calls, i, tc, name, args, false))
	dlg.popup_centered(Vector2i(640, 420))


func _after_tool(calls: Array, i: int, tc: Dictionary, name: String, args: Dictionary, confirmed: bool) -> void:
	var result: String = _tools.execute(name, args, confirmed)
	_append("tool %s -> %s" % [name, result.left(300)], "tool")
	_messages.append({
		"role": "tool",
		"tool_call_id": str(tc.get("id", "")),
		"content": result,
	})
	_run_tools(calls, i + 1)


func _finish_turn() -> void:
	_busy = false
	_send_btn.disabled = false
	_status.text = ""
	_history.append_text("\n")


# --- settings ----------------------------------------------------------------

func _show_settings() -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Prompt Dock settings"
	var box := VBoxContainer.new()
	var url := LineEdit.new(); url.text = _settings.base_url; url.placeholder_text = "http://host:8000/v1"
	var model := LineEdit.new(); model.text = _settings.model
	var key := LineEdit.new(); key.text = _settings.api_key; key.secret = true
	box.add_child(_labeled("Endpoint (OpenAI-compatible):", url))
	box.add_child(_labeled("Model:", model))
	box.add_child(_labeled("API key (optional):", key))
	dlg.add_child(box)
	dlg.confirmed.connect(func() -> void:
		_settings.base_url = url.text.strip_edges()
		_settings.model = model.text.strip_edges()
		_settings.api_key = key.text.strip_edges()
		_client.base_url = _settings.base_url
		_client.model = _settings.model
		_client.api_key = _settings.api_key
		_save_settings()
		_append("Settings saved.", "dim"))
	add_child(dlg)
	dlg.popup_centered(Vector2i(520, 240))


func _labeled(label: String, field: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	var l := Label.new(); l.text = label; l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l); h.add_child(field)
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return h


func _clear_chat() -> void:
	_messages.clear()
	_history.clear()
	_save_chat()
	_append("New chat.", "dim")


func _append(text: String, kind: String) -> void:
	var colors := {"user": "cyan", "assistant": "", "err": "red", "tool": "gray", "dim": "gray"}
	var c: String = colors.get(kind, "")
	var line := text
	if c != "":
		line = "[color=%s]%s[/color]" % [c, text.replace("[", "\\[")]
	else:
		line = text.replace("[", "\\[")
	_history.append_text(line + "\n\n")


# --- persistence ---------------------------------------------------------------

const SETTINGS_PATH := "user://prompt_dock.cfg"
const CHAT_PATH := "user://prompt_dock_chat.json"


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		for k in _settings:
			_settings[k] = cfg.get_value("net", k, _settings[k])


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	for k in _settings:
		cfg.set_value("net", k, _settings[k])
	cfg.save(SETTINGS_PATH)


func _save_chat() -> void:
	var fa := FileAccess.open(CHAT_PATH, FileAccess.WRITE)
	if fa != null:
		fa.store_string(JSON.stringify(_messages))
		fa.close()


func _load_chat() -> void:
	if not FileAccess.file_exists(CHAT_PATH):
		return
	var fa := FileAccess.open(CHAT_PATH, FileAccess.READ)
	if fa == null:
		return
	var data = JSON.parse_string(fa.get_as_text())
	fa.close()
	if typeof(data) == TYPE_ARRAY:
		_messages = data
		for m in _messages:
			if typeof(m) != TYPE_DICTIONARY:
				continue
			match str(m.get("role", "")):
				"user":
					_append("You: " + str(m.get("content", "")), "user")
				"assistant":
					var c := str(m.get("content", "")).strip_edges()
					if c != "":
						_append(c, "assistant")
		if not _messages.is_empty():
			_append("(chat restored — 'New chat' to start fresh)", "dim")
