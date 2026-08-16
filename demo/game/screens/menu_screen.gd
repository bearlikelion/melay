class_name MenuScreen
extends Control

## Entry screen: pick a name, then host, join by code, or browse open rooms.
## It reports intent upward and never talks to Melay itself.

signal host_requested(display_name: String)
signal join_requested(code: String, display_name: String)
signal browse_requested(display_name: String)

@onready var _status_label: Label = %StatusLabel
@onready var _name_edit: LineEdit = %NameEdit
@onready var _code_edit: LineEdit = %CodeEdit
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _refresh_button: Button = %RefreshButton
@onready var _room_list: ItemList = %RoomList

var _codes: Array[String] = []


func _ready() -> void:
	_host_button.pressed.connect(_on_host_button_pressed)
	_join_button.pressed.connect(_on_join_button_pressed)
	_refresh_button.pressed.connect(_on_refresh_button_pressed)
	_room_list.item_activated.connect(_on_room_list_item_activated)

	_name_edit.text = "Player %d" % (randi() % 900 + 100)


func set_status(message: String) -> void:
	_status_label.text = message


func set_busy(busy: bool) -> void:
	_host_button.disabled = busy
	_join_button.disabled = busy
	_refresh_button.disabled = busy


func show_rooms(rooms: Array) -> void:
	_room_list.clear()
	_codes.clear()

	for summary: Variant in rooms:
		if not summary is Dictionary:
			continue
		_codes.append(summary.get("code", ""))
		_room_list.add_item("%s   %s   %d/%d" % [
			summary.get("code", "?"),
			summary.get("name", "unnamed"),
			int(summary.get("player_count", 0)),
			int(summary.get("max_players", 0)),
		])

	if _codes.is_empty():
		set_status("No open rooms. Host one instead.")
	else:
		set_status("%d room(s) open. Double-click to join." % _codes.size())


func _on_host_button_pressed() -> void:
	host_requested.emit(_display_name())


func _on_join_button_pressed() -> void:
	join_requested.emit(_code_edit.text, _display_name())


func _on_refresh_button_pressed() -> void:
	browse_requested.emit(_display_name())


func _on_room_list_item_activated(index: int) -> void:
	if index < 0 or index >= _codes.size():
		return
	join_requested.emit(_codes[index], _display_name())


func _display_name() -> String:
	var chosen: String = _name_edit.text.strip_edges()
	if chosen.is_empty():
		chosen = "Player"
	return chosen
