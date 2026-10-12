extends Node2D

@export var par_time_seconds: float = 60.0  # completion around this time or faster gets full time credit
@export var score_weight_food: float = 0.5
@export var score_weight_cook: float = 1.0
@export var score_weight_time: float = 0.2
@export var max_score: int = 1000

var start_time_ms: int = 0
var finished := false

@onready var pan := $Pan
@onready var rice_manager := $RiceManager
@onready var results_screen := $ResultsScreen


func _ready() -> void:
	start_time_ms = Time.get_ticks_msec()


func _unhandled_input(event: InputEvent) -> void:
	if finished:
		if event is InputEventKey and event.pressed and event.keycode == KEY_R:
			get_tree().reload_current_scene()
		return

	if pan.falling:
		return  # already mid-disaster - finishing cooking doesn't make sense here

	if event.is_action_pressed("ui_accept"):  # Space (and Enter) by default
		_finish_cooking()


func _finish_cooking() -> void:
	finished = true
	pan.set_physics_process(false)

	var elapsed_seconds: float = (Time.get_ticks_msec() - start_time_ms) / 1000.0

	var remaining: Array = get_tree().get_nodes_in_group("rice") + get_tree().get_nodes_in_group("ingredient")
	var total_food: int = rice_manager.get_total_food_count()
	var remaining_count: int = remaining.size()

	var cook_sum := 0.0
	var rice_remaining: Array = []
	var pea_remaining: Array = []
	var carrot_remaining: Array = []

	for body in remaining:
		cook_sum += body.cook_level

		if body.is_in_group("rice"):
			rice_remaining.append(body.cook_level)
		elif "ingredient_name" in body:
			if body.ingredient_name == "pea":
				pea_remaining.append(body.cook_level)
			elif body.ingredient_name == "carrot":
				carrot_remaining.append(body.cook_level)

	var avg_cook_level: float = cook_sum / remaining_count if remaining_count > 0 else 0.0

	var food_ratio: float = float(remaining_count) / float(total_food) if total_food > 0 else 0.0
	var cookedness_quality: float = clamp(1.0 - abs(avg_cook_level - 0.5) * 2.0, 0.0, 1.0)
	var time_score: float = clamp(par_time_seconds / max(elapsed_seconds, 1.0), 0.0, 1.0)

	var total_weight := score_weight_food + score_weight_cook + score_weight_time
	var combined: float = (
		food_ratio * score_weight_food +
		cookedness_quality * score_weight_cook +
		time_score * score_weight_time
	) / total_weight
	var final_score: int = int(round(combined * max_score))

	rice_manager.stop_rendering()

	results_screen.show_results(
		final_score,
		max_score,
		food_ratio,
		cookedness_quality,
		elapsed_seconds,
		rice_remaining,
		pea_remaining,
		carrot_remaining
	)

	for body in remaining:
		body.queue_free()
