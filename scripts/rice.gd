extends RigidBody2D

@export var time_to_burnt: float = 10.0  # seconds of continuous full heat to go raw -> fully burnt

var cook_level: float = 0.0  # 0 = raw, 1 = fully burnt - read directly by the MultiMesh renderer in RiceManager
var pan: Node2D


func _ready() -> void:
	add_to_group("rice")
	pan = get_tree().get_first_node_in_group("pan")


func _physics_process(delta: float) -> void:
	if pan == null or not pan.has_method("get_heat_factor"):
		return

	var heat: float = pan.get_heat_factor(global_position)

	if heat <= 0.0:
		return

	cook_level = clamp(cook_level + heat * delta / time_to_burnt, 0.0, 1.0)
