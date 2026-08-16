@tool
extends EditorPlugin

## Registers the Melay autoload and its project settings, so installing the addon is
## one checkbox rather than a page of manual setup.

const AUTOLOAD_NAME: String = "Melay"
const AUTOLOAD_SCENE: String = "res://addons/melay/melay.tscn"


func _enter_tree() -> void:
	_register_settings()
	add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_SCENE)
	# Saved after the autoload is registered, otherwise it never reaches project.godot.
	ProjectSettings.save()


# No save: this also runs on editor shutdown, which would wipe the autoload from disk.
func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)


func _register_settings() -> void:
	_add_setting(
		"melay/connection/mode",
		TYPE_INT,
		0,
		PROPERTY_HINT_ENUM,
		"Remote,Local"
	)
	_add_setting(
		"melay/connection/url",
		TYPE_STRING,
		"wss://relay.example.com",
		PROPERTY_HINT_PLACEHOLDER_TEXT,
		"wss://your-relay-host"
	)
	_add_setting(
		"melay/connection/local_url",
		TYPE_STRING,
		"ws://127.0.0.1:8890",
		PROPERTY_HINT_PLACEHOLDER_TEXT,
		"ws://127.0.0.1:8890"
	)
	_add_setting(
		"melay/connection/game_id",
		TYPE_STRING,
		"",
		PROPERTY_HINT_PLACEHOLDER_TEXT,
		"my-game"
	)
	_add_setting("melay/connection/game_version", TYPE_STRING, "1.0.0")
	_add_setting(
		"melay/connection/api_key",
		TYPE_STRING,
		"",
		PROPERTY_HINT_PLACEHOLDER_TEXT,
		"only if the relay requires one for this game"
	)
	_add_setting("melay/general/auto_assign_peer", TYPE_BOOL, true)


func _add_setting(
	name: String,
	type: Variant.Type,
	default: Variant,
	hint: PropertyHint = PROPERTY_HINT_NONE,
	hint_string: String = ""
) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default)

	ProjectSettings.set_initial_value(name, default)
	ProjectSettings.add_property_info({
		"name": name,
		"type": type,
		"hint": hint,
		"hint_string": hint_string,
	})
