@tool
extends Node
## Executes the agent's tool calls against the project and the editor.
## Every mutating tool goes through the dock's confirmation dialog first.

const MAX_FILE_BYTES := 262144

var _editor_interface: EditorInterface


func setup(editor_interface: EditorInterface) -> void:
	_editor_interface = editor_interface


func tool_defs() -> Array:
	return [
		{"type": "function", "function": {
			"name": "list_files",
			"description": "List files under a res:// path (default project root). Returns paths with sizes.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string", "description": "res:// dir, default res://"}}}}},
		{"type": "function", "function": {
			"name": "read_file",
			"description": "Read a text file from the project (res:// or user://).",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string"}}, "required": ["path"]}}},
		{"type": "function", "function": {
			"name": "write_file",
			"description": "Create or overwrite a text file in the project. Requires the user's confirmation in the editor.",
			"parameters": {"type": "object", "properties": {
				"path": {"type": "string"}, "content": {"type": "string"}},
				"required": ["path", "content"]}}},
		{"type": "function", "function": {
			"name": "run_editor_script",
			"description": "Run GDScript inside the running editor process. The code runs with access to the live editor: use __r (a Dictionary) to return data, e.g. __r['count'] = .... Available: get_editor_interface(). Returns __r as JSON.",
			"parameters": {"type": "object", "properties": {
				"code": {"type": "string", "description": "Statements, run inside a function body."}},
				"required": ["code"]}}},
		{"type": "function", "function": {
			"name": "get_scene_context",
			"description": "The live editor state: currently edited scene name, the edited scene tree (node paths, types), and the current selection. Use this to know what the user is looking at.",
			"parameters": {"type": "object", "properties": {}}}},
	]


func execute(name: String, args: Dictionary, confirmed: bool) -> String:
	match name:
		"list_files":
			return _list_files(args.get("path", "res://"))
		"read_file":
			return _read_file(str(args.get("path", "")))
		"write_file":
			return _write_file(str(args.get("path", "")), str(args.get("content", "")), confirmed)
		"run_editor_script":
			return _run_editor_script(str(args.get("code", "")), confirmed)
		"get_scene_context":
			return _scene_context()
		_:
			return JSON.stringify({"error": "unknown tool: " + name})


func _list_files(path: String) -> String:
	var dir := DirAccess.open(path)
	if dir == null:
		return JSON.stringify({"error": "cannot open dir: " + path})
	var out := []
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not f.begins_with(".") and f != "addons":
			var full := path.path_join(f)
			if dir.current_is_dir():
				out.append({"path": full + "/", "dir": true})
			else:
				out.append({"path": full, "size": dir.get_size(f)})
		f = dir.get_next()
	dir.list_dir_end()
	return JSON.stringify({"files": out.slice(0, 500)})


func _read_file(path: String) -> String:
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return JSON.stringify({"error": "path must start with res:// or user://"})
	if not FileAccess.file_exists(path):
		return JSON.stringify({"error": "not found: " + path})
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return JSON.stringify({"error": "cannot open: " + path})
	var text := fa.get_as_text()
	fa.close()
	if text.length() > MAX_FILE_BYTES:
		return JSON.stringify({"truncated": true, "content": text.left(MAX_FILE_BYTES)})
	return JSON.stringify({"content": text})


func _write_file(path: String, content: String, confirmed: bool) -> String:
	if not path.begins_with("res://"):
		return JSON.stringify({"error": "write path must start with res://"})
	if path.contains(".."):
		return JSON.stringify({"error": "path traversal not allowed"})
	if not confirmed:
		return JSON.stringify({"error": "user declined the write"})
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		return JSON.stringify({"error": "cannot open for write: " + path + " (" + error_string(FileAccess.get_open_error()) + ")"})
	fa.store_string(content)
	fa.close()
	# Refresh the editor's view of the file.
	if _editor_interface != null:
		_editor_interface.get_resource_filesystem().scan()
	return JSON.stringify({"ok": true, "path": path, "bytes": content.length()})


func _run_editor_script(code: String, confirmed: bool) -> String:
	if not confirmed:
		return JSON.stringify({"error": "user declined running editor code"})
	Engine.remove_meta("prompt_dock_result")
	var indented := ""
	for line in code.split("\n"):
		indented += ("\t" + line if line.strip_edges() != "" else "") + "\n"
	var src := """extends EditorScript
func _run() -> void:
	var __r := {}
	var ei := get_editor_interface()
%s	Engine.set_meta("prompt_dock_result", __r)
""" % indented
	var script := GDScript.new()
	script.source_code = src
	if script.reload() != OK:
		return JSON.stringify({"error": "script failed to compile (check syntax)"})
	var es = script.new()
	es.run()
	var result = Engine.get_meta("prompt_dock_result", null)
	Engine.remove_meta("prompt_dock_result")
	if result == null:
		return JSON.stringify({"error": "script ran but set no __r result (runtime error? check editor console)"})
	return JSON.stringify({"result": result})


func _scene_context() -> String:
	if _editor_interface == null:
		return JSON.stringify({"error": "no editor interface"})
	var ctx := {}
	var edited := _editor_interface.get_edited_scene_root()
	if edited != null:
		ctx["scene"] = edited.scene_file_path
		ctx["tree"] = _tree_lines(edited, "", 0).slice(0, 300)
	var sel := _editor_interface.get_selection()
	if sel != null:
		ctx["selection"] = sel.get_selected_nodes().map(
			func(n: Node) -> String: return str(n.get_path()) + " (" + n.get_class() + ")")
	return JSON.stringify(ctx)


func _tree_lines(n: Node, prefix: String, depth: int) -> Array:
	var out := [prefix + str(n.name) + " : " + n.get_class()]
	if depth >= 6:
		return out
	for c in n.get_children():
		out.append_array(_tree_lines(c, prefix + str(n.name) + "/", depth + 1))
	return out
