class_name LobbyScreen
extends Control

## Waiting room. Everyone marks themselves ready; the host starts the match once
## every player in the room has.

signal ready_toggled(is_ready: bool)
signal start_requested
signal leave_requested

@onready var _title_label: Label = %TitleLabel
@onready var _hint_label: Label = %HintLabel
@onready var _player_list: ItemList = %PlayerList
@onready var _ready_button: Button = %ReadyButton
@onready var _start_button: Button = %StartButton
@onready var _leave_button: Button = %LeaveButton

var _is_ready: bool = false
var _is_host: bool = false
var _can_start: bool = false


func _ready() -> void:
	_ready_button.pressed.connect(_on_ready_button_pressed)
	_start_button.pressed.connect(start_requested.emit)
	_leave_button.pressed.connect(leave_requested.emit)
	_update_ready_button()


func set_room(room: MelayRoom) -> void:
	if room == null:
		return
	_title_label.text = "Room %s" % room.code
	_hint_label.text = "Share that code, or find this room in the browser."


func set_players(rows: Array[Dictionary]) -> void:
	_player_list.clear()
	for row: Dictionary in rows:
		var label: String = "%s  (peer %d)" % [row["display_name"], row["peer_id"]]
		if bool(row["is_host"]):
			label += "  host"
		if bool(row["is_self"]):
			label += "  you"
		label += "        %s" % ("READY" if bool(row["is_ready"]) else "waiting")
		_player_list.add_item(label)


func set_is_host(is_host: bool) -> void:
	_is_host = is_host
	_start_button.visible = is_host
	_update_start_button()


func set_can_start(can_start: bool) -> void:
	_can_start = can_start
	_update_start_button()


func _on_ready_button_pressed() -> void:
	_is_ready = not _is_ready
	_update_ready_button()
	ready_toggled.emit(_is_ready)


func _update_ready_button() -> void:
	_ready_button.text = "Not ready" if _is_ready else "Ready up"


func _update_start_button() -> void:
	if not _is_host:
		return
	_start_button.disabled = not _can_start
	_start_button.text = "Start game" if _can_start else "Waiting for players"
