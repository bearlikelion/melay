extends Node

## Screenshot helper for eyeballing the demo screens. Not part of run_tests.sh.
##
##   godot --path . res://tests/shot.tscn -- --out=/tmp/shots --url=ws://127.0.0.1:8890

const DEMO_SCENE: PackedScene = preload("res://game/melay_demo.tscn")

var _out_dir: String = "/tmp"
var _url: String = "ws://127.0.0.1:8890"
var _demo: MelayDemo = null


func _ready() -> void:
	for argument: String in OS.get_cmdline_user_args():
		var parts: PackedStringArray = argument.split("=", true, 1)
		if parts.size() != 2:
			continue
		match parts[0]:
			"--out":
				_out_dir = parts[1]
			"--url":
				_url = parts[1]

	_run()


func _run() -> void:
	Melay.configure(_url, "melay-demo-shot", "1.0.0")

	_demo = DEMO_SCENE.instantiate()
	add_child(_demo)
	await _wait(0.6)
	await _shot("menu")

	_demo._current.host_requested.emit("Screenshot")
	await _wait(1.5)
	await _shot("lobby")

	_demo._current.ready_toggled.emit(true)
	await _wait(0.6)
	await _shot("lobby_ready")

	_demo._current.start_requested.emit()
	await _wait(1.2)
	await _shot("countdown")

	await _wait(3.0)
	await _shot("game")

	get_tree().quit(0)


func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	image.save_png("%s/%s.png" % [_out_dir, label])
	print("wrote %s/%s.png" % [_out_dir, label])


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
