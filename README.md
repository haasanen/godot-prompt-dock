# Prompt Dock — an LLM prompt window inside the Godot editor

An OpenCode-style assistant that lives in a Godot bottom panel. It talks to any
OpenAI-compatible endpoint (tested against a local [Strata](https://github.com/Niko1221/Strata)
server — no cloud, no API key needed) and can act on the live editor:

- **read / write project files** (writes always ask for confirmation)
- **run GDScript inside the running editor process** (with confirmation) —
  structured scene edits, resource inspection, anything `EditorScript` can do
- **see what you're looking at**: current scene tree, selected nodes, live state

No leaving the editor to prompt.

## Install (pick one)

### A. Global — available in every project (recommended)

1. Download `prompt-dock.zip` from the [latest release](../../releases).
2. Unzip into Godot's editor data dir:
   - Linux: `~/.local/share/godot/editor_data/addons/`
   - Windows: `%APPDATA%\Godot\editor_data\addons\`
   - macOS: `~/Library/Application Support/Godot/editor_data/addons/`
3. Open Godot → **Editor → Manage Editor Extensions → Global Plugins → Add**
   → pick `prompt_dock/plugin.cfg` → Enable.
4. Restart the editor. The **Prompt Dock** tab appears in the bottom panel.

### B. Per project

Copy `addons/prompt_dock/` into your project and enable it in
**Project → Project Settings → Plugin**.

## Configure

Open the dock → **Settings**:

- **Endpoint**: any OpenAI-compatible `/v1` URL, e.g. `http://192.168.1.10:8000/v1`
- **Model**: the model name your server reports (e.g. `Qwen3.8-Flash-Next`)
- **API key**: optional

Settings are saved per user (`user://prompt_dock.cfg`), not per project.

## How it works

The dock runs a tool loop: your message goes to the model with five tools;
the model calls tools; results are fed back until it answers.

| Tool | Mutates? | Notes |
|---|---|---|
| `list_files` | no | project file listing |
| `read_file` | no | res:// / user:// text files |
| `write_file` | **yes** | confirmation dialog first |
| `run_editor_script` | **yes** | code runs in the editor process; confirmation shows the code |
| `get_scene_context` | no | edited scene tree + selection |

Everything is plain GDScript (no `.tscn`), so the whole addon is reviewable text.

## Requirements

Godot **4.7+** (developed and compile-checked on 4.7.2 stable). No network
permissions to worry about — it only talks to the endpoint you configure.

## Status

v0.1.0 — working core. Known gaps / next steps:

- No streaming (replies arrive whole).
- No undo integration for `run_editor_script` mutations yet — confirm dialogs
  are the safety net; use project backups for big scene surgery.
- No image input.
- Context is manual: the model sees the scene tree when it asks, not a full
  project index.

## License

MIT
