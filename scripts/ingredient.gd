extends RigidBody2D

@export var ingredient_name: String = "ingredient"  # "pea" or "carrot"
@export var time_to_burnt: float = 15.0  # same cook time as rice
@export var cook_gradient: Gradient  # pale -> colorful -> blackened

var cook_level: float = 0.0
var pan: Node2D

@onready var sprite: Sprite2D = $Sprite2D


func _ready() -> void:
	add_to_group("ingredient")
	pan = get_tree().get_first_node_in_group("pan")


func _physics_process(delta: float) -> void:
	if pan == null or not pan.has_method("get_heat_factor"):
		return

	var heat: float = pan.get_heat_factor(global_position)

	if heat <= 0.0:
		return

	cook_level = clamp(cook_level + heat * delta / time_to_burnt, 0.0, 1.0)

	if cook_gradient:
		sprite.self_modulate = cook_gradient.sample(cook_level)
