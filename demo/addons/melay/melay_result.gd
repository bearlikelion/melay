class_name MelayResult
extends RefCounted

## The value of every awaited Melay call: either a payload or an error, never both.
## Callers check [method is_error] rather than catching anything.

var code: String = ""
var message: String = ""
var value: Variant = null


func _init(p_value: Variant = null, p_code: String = "", p_message: String = "") -> void:
	value = p_value
	code = p_code
	message = p_message


static func ok(p_value: Variant = null) -> MelayResult:
	return MelayResult.new(p_value)


static func fail(p_code: String, p_message: String = "") -> MelayResult:
	return MelayResult.new(null, p_code, p_message)


func is_error() -> bool:
	return code != ""


func _to_string() -> String:
	if is_error():
		return "MelayResult<error=%s, message=%s>" % [code, message]
	return "MelayResult<value=%s>" % [value]
