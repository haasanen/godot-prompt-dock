@tool
extends Node
## Executes the agent's tool calls against the project and the editor.
## Every mutating tool goes through the dock's confirmation dialog first.
## Scene mutations route through the editor's undo/redo manager (Ctrl+Z).

const MAX_FILE_BYTES := 262144

var _editor_interface: EditorInterface
var _index_cache := {"key": "", "text": ""}


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
			"description": "Run GDScript inside the running editor process. The code runs with access to the live editor: use __r (a Dictionary) to return data, e.g. __r['count'] = .... Available: get_editor_interface(). Returns __r as JSON. NOTE: scene changes made here are NOT undoable — prefer scene_op for scene edits.",
			"parameters": {"type": "object", "properties": {
				"code": {"type": "string", "description": "Statements, run inside a function body."}},
				"required": ["code"]}}},
		{"type": "function", "function": {
			"name": "get_scene_context",
			"description": "The live editor state: currently edited scene name, the edited scene tree (node paths, types), and the current selection. Use this to know what the user is looking at.",
			"parameters": {"type": "object", "properties": {}}}},
		{"type": "function", "function": {
			"name": "scene_op",
			"description": "Structured edits on the CURRENTLY EDITED scene, fully undoable (Ctrl+Z). op='add_node' {parent, name, type}; op='remove_node' {node}; op='set_property' {node, property, value} (value as string, parsed by the engine); op='get_node_info' {node} (read-only: class, properties, children). Nodes are paths from the scene root, e.g. 'Player/Sprite2D'.",
			"parameters": {"type": "object", "properties": {
				"op": {"type": "string", "enum": ["add_node", "remove_node", "set_property", "get_node_info"]},
				"node": {"type": "string"}, "parent": {"type": "string"},
				"name": {"type": "string"}, "type": {"type": "string"},
				"property": {"type": "string"}, "value": {"type": "string"}},
				"required": ["op"]}}},
		{"type": "function", "function": {
			"name": "get_project_index",
			"description": "A compact map of the whole project: every script with its class_name and function signatures, every scene with its node skeleton, plus project settings. Read this FIRST to understand the project instead of listing and reading files one by one.",
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
		"scene_op":
			return _scene_op(args, confirmed)
		"get_project_index":
			return _project_index()
		_:
			return JSON.stringify({"error": "unknown tool: " + name})


func _list_files(path: String) -> String:
	var dir := DirAccess.open(path)
	if dir == null:
		return JSON.stringify({"error": "cannot open dir: " + path})
	var out := []
	_list_into(dir, path, out)
	return JSON.stringify({"files": out.slice(0, 800)})


func _list_into(dir: DirAccess, path: String, out: Array) -> void:
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if not f.begins_with(".") and f != ".godot":
			var full := path.path_join(f)
			if dir.current_is_dir():
				out.append({"path": full + "/", "dir": true})
				var sub := DirAccess.open(full)
				if sub != null:
					_list_into(sub, full, out)
			else:
				var size := -1
				var fa := FileAccess.open(full, FileAccess.READ)
				if fa != null:
					size = fa.get_length()
					fa.close()
				out.append({"path": full, "size": size})
		f = dir.get_next()
	dir.list_dir_end()


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
	# undo support: keep the previous content so Ctrl+Z restores it
	var old: String = ""
	var had_old := false
	if FileAccess.file_exists(path):
		var r := FileAccess.open(path, FileAccess.READ)
		if r != null:
			old = r.get_as_text()
			had_old = true
			r.close()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa == null:
		return JSON.stringify({"error": "cannot open for write: " + path + " (" + error_string(FileAccess.get_open_error()) + ")"})
	fa.store_string(content)
	fa.close()
	if _editor_interface != null:
		_editor_interface.get_resource_filesystem().scan()
		var eur := _editor_interface.get_editor_undo_redo()
		if eur != null:
			eur.create_action("Prompt Dock: write " + path)
			eur.add_do_method(self, "_apply_file", path, content)
			if had_old:
				eur.add_undo_method(self, "_apply_file", path, old)
			else:
				eur.add_undo_method(self, "_delete_file", path)
			eur.commit_action()
	return JSON.stringify({"ok": true, "path": path, "bytes": content.length(), "undoable": true})


## Undo/redo target: write file content (bound via Callable.bind).
func _apply_file(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var fa := FileAccess.open(path, FileAccess.WRITE)
	if fa != null:
		fa.store_string(content)
		fa.close()
	if _editor_interface != null:
		_editor_interface.get_resource_filesystem().scan()


func _delete_file(path: String) -> void:
	DirAccess.remove_absolute(path)
	if _editor_interface != null:
		_editor_interface.get_resource_filesystem().scan()


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


# ---------------------------------------------------------------------------
# scene_op: structured, undoable scene edits via EditorUndoRedoManager
# ---------------------------------------------------------------------------

func _scene_op(args: Dictionary, confirmed: bool) -> String:
	var op := str(args.get("op", ""))
	if op == "get_node_info":
		return _node_info(str(args.get("node", "")))
	if _editor_interface == null:
		return JSON.stringify({"error": "no editor interface"})
	if not confirmed:
		return JSON.stringify({"error": "user declined the scene edit"})
	var root := _editor_interface.get_edited_scene_root()
	if root == null:
		return JSON.stringify({"error": "no scene is being edited"})
	var eur := _editor_interface.get_editor_undo_redo()
	if eur == null:
		return JSON.stringify({"error": "no undo manager"})
	match op:
		"add_node":
			var parent := _find_node(root, str(args.get("parent", "")))
			if parent == null:
				return JSON.stringify({"error": "parent not found: " + str(args.get("parent", ""))})
			var nname := str(args.get("name", ""))
			var ntype := str(args.get("type", ""))
			if nname == "" or ntype == "":
				return JSON.stringify({"error": "add_node needs name and type"})
			if not ClassDB.class_exists(ntype) or not ClassDB.is_parent_class(ntype, "Node"):
				return JSON.stringify({"error": "unknown node type: " + ntype})
			if parent.get_node_or_null(nname) != null:
				return JSON.stringify({"error": "name already used under parent: " + nname})
			eur.create_action("Prompt Dock: add " + nname)
			eur.add_do_method(self, "_do_add_node", root, str(parent.get_path()), nname, ntype)
			eur.add_undo_method(self, "_do_remove_node", root, str(parent.get_path()), nname)
			eur.commit_action()
			return JSON.stringify({"ok": true, "op": op, "node": _rel(root, parent) + "/" + nname, "undoable": true})
		"remove_node":
			var n := _find_node(root, str(args.get("node", "")))
			if n == null:
				return JSON.stringify({"error": "node not found: " + str(args.get("node", ""))})
			if n == root:
				return JSON.stringify({"error": "cannot remove the scene root"})
			var p := n.get_parent()
			var snap := _node_snapshot(n)
			eur.create_action("Prompt Dock: remove " + str(n.name))
			eur.add_do_method(self, "_do_remove_node", root, str(p.get_path()), str(n.name))
			eur.add_undo_method(self, "_do_restore_node", root, str(p.get_path()), snap)
			eur.commit_action()
			return JSON.stringify({"ok": true, "op": op, "removed": str(args.get("node")), "undoable": true})
		"set_property":
			var n2 := _find_node(root, str(args.get("node", "")))
			if n2 == null:
				return JSON.stringify({"error": "node not found: " + str(args.get("node", ""))})
			var prop := str(args.get("property", ""))
			var found := false
			for p in n2.get_property_list():
				if str(p["name"]) == prop:
					found = true
					break
			if not found:
				return JSON.stringify({"error": "no such property: " + prop})
			var old_val = n2.get(prop)
			var new_val = _parse_value(str(args.get("value", "")), typeof(old_val))
			eur.create_action("Prompt Dock: set " + prop)
			eur.add_do_method(self, "_do_set_prop", root, str(args.get("node", "")), prop, new_val)
			eur.add_undo_method(self, "_do_set_prop", root, str(args.get("node", "")), prop, old_val)
			eur.commit_action()
			return JSON.stringify({"ok": true, "op": op, "old": str(old_val), "new": str(new_val), "undoable": true})
		_:
			return JSON.stringify({"error": "unknown scene_op: " + op})


func _find_node(root: Node, rel: String) -> Node:
	if rel == "" or rel == "." or rel == "/":
		return root
	var clean := rel.trim_prefix(str(root.name) + "/").trim_prefix("/")
	var n := root.get_node_or_null(clean)
	if n == null:
		# maybe given as an absolute editor path
		n = root.get_node_or_null(clean.trim_prefix(str(root.name)))
	return n


func _rel(root: Node, n: Node) -> String:
	if n == root:
		return str(root.name)
	return str(root.get_path_to(n))


func _do_add_node(root: Node, parent_path: String, nname: String, ntype: String) -> void:
	var parent := root.get_node_or_null(parent_path)
	if parent == null:
		return
	var n: Node = ClassDB.instantiate(ntype)
	n.name = nname
	parent.add_child(n)
	if _editor_interface != null:
		_editor_interface.mark_scene_as_unsaved()


func _do_remove_node(root: Node, parent_path: String, nname: String) -> void:
	var parent := root.get_node_or_null(parent_path)
	if parent == null:
		return
	var n := parent.get_node_or_null(nname)
	if n != null:
		parent.remove_child(n)
		n.free()
	if _editor_interface != null:
		_editor_interface.mark_scene_as_unsaved()


func _do_restore_node(root: Node, parent_path: String, snap: Dictionary) -> void:
	var parent := root.get_node_or_null(parent_path)
	if parent == null:
		return
	var n: Node = ClassDB.instantiate(str(snap["type"]))
	n.name = str(snap["name"])
	for k in snap["props"]:
		n.set(str(k), snap["props"][k])
	parent.add_child(n)
	for child_snap in snap["children"]:
		_do_restore_node(root, str(parent.get_path()), child_snap)
	if _editor_interface != null:
		_editor_interface.mark_scene_as_unsaved()


## Snapshot a node (props + children recursively) so remove can be undone.
func _node_snapshot(n: Node) -> Dictionary:
	var props := {}
	for p in n.get_property_list():
		var pname := str(p["name"])
		if int(p["usage"]) & PROPERTY_USAGE_STORAGE:
			var v = n.get(pname)
			if v is String or v is float or v is int or v is bool or v is Vector2 or v is Vector3 or v is Color:
				props[pname] = v
	var children := []
	for c in n.get_children():
		children.append(_node_snapshot(c))
	return {"name": str(n.name), "type": n.get_class(), "props": props, "children": children}


func _do_set_prop(root: Node, rel: String, prop: String, value) -> void:
	var n := _find_node(root, rel)
	if n == null:
		return
	n.set(prop, value)
	if _editor_interface != null:
		_editor_interface.mark_scene_as_unsaved()


func _parse_value(s: String, hint: int) -> Variant:
	match hint:
		TYPE_INT: return s.to_int()
		TYPE_FLOAT: return s.to_float()
		TYPE_BOOL: return s.to_lower() in ["true", "1", "yes"]
		TYPE_VECTOR2:
			var xs := s.trim_prefix("(").trim_suffix(")").split(",")
			return Vector2(xs[0].to_float(), xs[1].to_float()) if xs.size() >= 2 else Vector2.ZERO
		TYPE_VECTOR3:
			var xs3 := s.trim_prefix("(").trim_suffix(")").split(",")
			return Vector3(xs3[0].to_float(), xs3[1].to_float(), xs3[2].to_float()) if xs3.size() >= 3 else Vector3.ZERO
		TYPE_COLOR:
			var cs := s.trim_prefix("(").trim_suffix(")").split(",")
			if cs.size() >= 3:
				return Color(cs[0].to_float(), cs[1].to_float(), cs[2].to_float(), cs[3].to_float() if cs.size() >= 4 else 1.0)
			return Color.WHITE
		_: return s


func _node_info(rel: String) -> String:
	if _editor_interface == null:
		return JSON.stringify({"error": "no editor interface"})
	var root := _editor_interface.get_edited_scene_root()
	if root == null:
		return JSON.stringify({"error": "no scene is being edited"})
	var n := _find_node(root, rel)
	if n == null:
		return JSON.stringify({"error": "node not found: " + rel})
	var props := {}
	for p in n.get_property_list():
		var pname := str(p["name"])
		if int(p["usage"]) & PROPERTY_USAGE_STORAGE:
			props[pname] = str(n.get(pname))
	var kids := n.get_children().map(func(c: Node) -> String: return str(c.name) + " : " + c.get_class())
	return JSON.stringify({"node": rel, "class": n.get_class(), "properties": props, "children": kids})


# ---------------------------------------------------------------------------
# get_project_index: whole-project map, cached until files change
# ---------------------------------------------------------------------------

func _project_index() -> String:
	var key := _index_key()
	if key != "" and _index_cache.key == key:
		return _index_cache.text
	var lines: Array = []
	# project settings
	if FileAccess.file_exists("res://project.godot"):
		var fa := FileAccess.open("res://project.godot", FileAccess.READ)
		if fa != null:
			var in_app := false
			for line in fa.get_as_text().split("\n"):
				var t := line.strip_edges()
				if t == "[application]":
					in_app = true
				elif t.begins_with("["):
					in_app = false
				elif in_app and (t.begins_with("config/name") or t.begins_with("run/main_scene") or t.begins_with("config/features")):
					lines.append(t)
			fa.close()
	var files := []
	var dir := DirAccess.open("res://")
	if dir != null:
		_list_into(dir, "res://", files)
	var scripts := []
	var scenes := []
	for f in files:
		var p := str(f["path"])
		if p.ends_with(".gd"):
			scripts.append(_script_summary(p))
		elif p.ends_with(".tscn"):
			scenes.append(_scene_summary(p))
	lines.append("")
	lines.append("SCRIPTS (%d):" % scripts.size())
	lines.append_array(scripts)
	lines.append("")
	lines.append("SCENES (%d):" % scenes.size())
	lines.append_array(scenes)
	var text := "\n".join(lines)
	if text.length() > 60000:
		text = text.left(60000) + "\n[index truncated]"
	_index_cache = {"key": key, "text": text}
	return text


func _index_key() -> String:
	# cheap change key: count + total bytes of .gd/.tscn files
	var count := 0
	var total := 0
	var files := []
	var dir := DirAccess.open("res://")
	if dir == null:
		return ""
	_list_into(dir, "res://", files)
	for f in files:
		var p := str(f["path"])
		if p.ends_with(".gd") or p.ends_with(".tscn"):
			count += 1
			total += int(f.get("size", 0))
	return "%d:%d" % [count, total]


func _script_summary(path: String) -> String:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return path
	var text := fa.get_as_text()
	fa.close()
	var cls := ""
	var ext := ""
	var funcs: Array = []
	for line in text.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("class_name ") and cls == "":
			cls = t.substr(11).split("#")[0].strip_edges()
		elif t.begins_with("extends ") and ext == "":
			ext = t.substr(8).split("#")[0].strip_edges()
		elif t.begins_with("func "):
			funcs.append(t.substr(5).split("(")[0].strip_edges())
	var head := path
	if ext != "":
		head += " extends " + ext
	if cls != "":
		head += " (class_name " + cls + ")"
	return head + " — funcs: " + (", ".join(funcs) if not funcs.is_empty() else "(none)")


func _scene_summary(path: String) -> String:
	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		return path
	var text := fa.get_as_text()
	fa.close()
	var root_type := ""
	var nodes: Array = []
	for line in text.split("\n"):
		var t := line.strip_edges()
		if not t.begins_with("[node"):
			continue
		var nm := _attr(t, "name")
		var ty := _attr(t, "type")
		var parent := _attr(t, "parent")
		if parent == "":  # root node line (no parent attribute)
			root_type = ty if ty != "" else root_type
			nodes.append(nm)
		else:
			var p := "(root)" if parent == "." else parent
			nodes.append(p + "/" + nm)
	var out := path + " root: " + (root_type if root_type != "" else "?")
	if not nodes.is_empty():
		out += " nodes: " + ", ".join(nodes.slice(0, 40))
	return out


## Extract attr="value" from a .tscn header line ("" when absent).
func _attr(line: String, attr: String) -> String:
	var key := attr + "=\""
	var i := line.find(key)
	if i == -1:
		return ""
	var rest := line.substr(i + key.length())
	var j := rest.find("\"")
	return rest.substr(0, j) if j != -1 else ""
