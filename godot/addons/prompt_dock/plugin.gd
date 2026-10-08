@tool
extends EditorPlugin
## Prompt Dock — an OpenCode-style LLM prompt window inside the Godot editor.
## Works as a global editor plugin (editor_data/addons/) or a project addon.
## Talks to any OpenAI-compatible endpoint (e.g. a local Strata server).

const PromptDock := preload("dock.gd")

var _dock: Control = null


func _enter_tree() -> void:
	_dock = PromptDock.new()
	_dock.name = "PromptDock"
	_dock.setup_editor(get_editor_interface())
	add_control_to_bottom_panel(_dock, "Prompt Dock")
	# Do NOT auto-show: a global plugin must stay quiet until the user opens it.


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
		_dock = null
