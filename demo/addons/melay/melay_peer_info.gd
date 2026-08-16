class_name MelayPeerInfo
extends RefCounted

## One member of a room. [member session_id] is stable for the whole connection and
## survives host migration; [member peer_id] is the Godot-facing integer and may be
## reassigned, so anything the player sees should key off the session id.

var peer_id: int = 0
var session_id: String = ""
var display_name: String = ""
var platform: String = ""
var is_host: bool = false


static func from_dictionary(data: Dictionary) -> MelayPeerInfo:
	var info: MelayPeerInfo = MelayPeerInfo.new()
	info.peer_id = int(data.get("peer_id", 0))
	info.session_id = data.get("session_id", "")
	info.display_name = data.get("display_name", "")
	info.platform = data.get("platform", "")
	info.is_host = bool(data.get("is_host", false))
	return info


func _to_string() -> String:
	return "MelayPeerInfo<peer_id=%d, name=%s, platform=%s, host=%s>" % [
		peer_id, display_name, platform, is_host,
	]
