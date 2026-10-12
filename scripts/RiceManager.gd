extends Node2D

@export var pile_rows: int = 10   # keep rows * spacing comfortably under the bowl's depth (~122px)
@export var pile_columns: int = 50  # keep columns * spacing comfortably under the bowl's width (~593px)
@export var rice_visual_size: Vector2 = Vector2(8, 8)
@export var cook_gradient: Gradient

@export_group("Extra Ingredients")
@export var pea_count: int = 10
@export var carrot_count: int = 8
@export var pea_scene: PackedScene = preload("res://scenes/pea.tscn")
@export var carrot_scene: PackedScene = preload("res://scenes/carrot.tscn")
@export var drop_height: float = 80.0  # how far above the pile they start, so they fall in and scatter rice

@onready var pan = $"../Pan"
@onready var spawn_point: Node2D = pan.get_node("RiceSpawnPoint")
@export var rice_scene: PackedScene = preload("res://scenes/rice.tscn")

# The actual RigidBody2D for each grain (not the "Rice" wrapper instantiate()
# returns - that wrapper never moves; its RigidBody2D child does, via
# physics). This is what the renderer below reads position/rotation from.
var rice_bodies: Array[RigidBody2D] = []

var multimesh_instance: MultiMeshInstance2D

var total_food_count: int = 0


func _ready() -> void:
	spawn_rice()
	_setup_multimesh()
	spawn_extra_ingredients()
	total_food_count = rice_bodies.size() + pea_count + carrot_count


func get_total_food_count() -> int:
	return total_food_count


func stop_rendering() -> void:
	# Called once cooking is finished and the remaining food is about to be
	# freed/replaced by the results-screen visual - stops the multimesh sync
	# loop from touching bodies that are about to be gone.
	set_process(false)
	rice_bodies.clear()
	if multimesh_instance:
		multimesh_instance.visible = false


func spawn_rice() -> void:
	var spacing := 8.0

	for y in range(pile_rows):
		for x in range(pile_columns):
			if x < y or x >= pile_columns - y:
				continue

			var rice_wrapper := rice_scene.instantiate()

			var offset_x = (x - pile_columns / 2.0) * spacing
			var offset_y = -y * spacing

			rice_wrapper.global_position = spawn_point.global_position + Vector2(
				offset_x + randf_range(-1.5, 1.5),
				offset_y + randf_range(-1.0, 1.0)
			)

			add_child(rice_wrapper)
			rice_bodies.append(rice_wrapper.get_node("rice"))


func spawn_extra_ingredients() -> void:
	# Bigger and much heavier than rice (see pea.tscn/carrot.tscn masses),
	# and dropped in from above the pile's top rather than placed within
	# it, so they physically fall through and shove rice aside on landing
	# instead of just spawning already-settled.
	var pile_half_width: float = (pile_columns / 2.0) * 8.0
	var pile_top_y: float = -pile_rows * 8.0

	for i in range(pea_count):
		_drop_ingredient(pea_scene, pile_half_width, pile_top_y)

	for i in range(carrot_count):
		_drop_ingredient(carrot_scene, pile_half_width, pile_top_y)


func _drop_ingredient(scene: PackedScene, pile_half_width: float, pile_top_y: float) -> void:
	var instance := scene.instantiate()

	instance.global_position = spawn_point.global_position + Vector2(
		randf_range(-pile_half_width * 0.7, pile_half_width * 0.7),
		pile_top_y - drop_height - randf_range(0.0, 40.0)
	)

	add_child(instance)


func _setup_multimesh() -> void:
	var mesh := QuadMesh.new()
	mesh.size = rice_visual_size

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = rice_bodies.size()

	multimesh_instance = MultiMeshInstance2D.new()
	multimesh_instance.multimesh = mm
	add_child(multimesh_instance)

	# One-time initial sync so grains don't flash at the origin for a frame
	# before the first _process() call fills in real transforms.
	_sync_multimesh()


func _process(_delta: float) -> void:
	_sync_multimesh()


func _sync_multimesh() -> void:
	if multimesh_instance == null:
		return

	var mm := multimesh_instance.multimesh

	for i in range(rice_bodies.size()):
		var body := rice_bodies[i]

		mm.set_instance_transform_2d(i, Transform2D(body.rotation, body.global_position))

		var color := Color.WHITE
		if cook_gradient:
			color = cook_gradient.sample(body.cook_level)
		mm.set_instance_color(i, color)
