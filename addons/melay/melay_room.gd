class_name MelayRoom
extends RefCounted

## A snapshot of one room as the relay last described it.

var room_id: String = ""
var code: String = ""
var name: String = ""
var host_peer_id: int = 0
var self_peer_id: int = 0
var max_players: int = 0
var visibility: String = MelayProtocol.VISIBILITY_PUBLIC
var dedicated: bool = false
var tags: Dictionary = {}
var peers: Dictionary = {}


static func from_dictionary(data: Dictionary) -> MelayRoom:
	var room: MelayRoom = MelayRoom.new()
	room.room_id = data.get("room_id", "")
	room.code = data.get("code", "")
	room.name = data.get("name", "")
	room.host_peer_id = int(data.get("host_peer_id", 0))
	room.self_peer_id = int(data.get("self_peer_id", 0))
	room.max_players = int(data.get("max_players", 0))
	room.visibility = data.get("visibility", MelayProtocol.VISIBILITY_PUBLIC)
	room.dedicated = bool(data.get("dedicated", false))
	room.tags = data.get("tags", {})

	for entry: Variant in data.get("peers", []):
		if entry is Dictionary:
			var info: MelayPeerInfo = MelayPeerInfo.from_dictionary(entry)
			room.peers[info.peer_id] = info
	return room


func is_host() -> bool:
	return self_peer_id == host_peer_id


func player_count() -> int:
	return peers.size()


## Peer ids in the room other than this client's own.
func other_peer_ids() -> Array[int]:
	var out: Array[int] = []
	for peer_id: int in peers:
		if peer_id != self_peer_id:
			out.append(peer_id)
	out.sort()
	return out


func get_peer(peer_id: int) -> MelayPeerInfo:
	return peers.get(peer_id, null)


func _to_string() -> String:
	return "MelayRoom<code=%s, players=%d/%d, host=%d, self=%d>" % [
		code, player_count(), max_players, host_peer_id, self_peer_id,
	]
