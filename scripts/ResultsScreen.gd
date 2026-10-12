extends CanvasLayer

@onready var title_label: Label = $Title
@onready var score_label: Label = $ScoreLabel
@onready var stats_label: Label = $StatsLabel
@onready var food_container: Node2D = $FoodContainer
@onready var dish: Node2D = $Dish


func show_results(
	final_score: int,
	max_score: int,
	food_ratio: float,
	cookedness_quality: float,
	elapsed_seconds: float,
	rice_remaining: Array,
	pea_remaining: Array,
	carrot_remaining: Array
) -> void:
	visible = true

	var score_ratio: float = float(final_score) / float(max_score)
	title_label.text = "You cooked... %s!" % _rating_text(score_ratio)
	score_label.text = "Score: %d / %d" % [final_score, max_score]
	stats_label.text = (
		"Food remaining: %d%%    Cookedness: %d%%    Time: %.1fs"
		% [round(food_ratio * 100), round(cookedness_quality * 100), elapsed_seconds]
	)

	_scatter_food(rice_remaining, Color.WHITE, 20.0, rice_remaining.size())
	_scatter_food(pea_remaining, Color(0.3, 0.8, 0.3), 25.0, pea_remaining.size())
	_scatter_food(carrot_remaining, Color(1.0, 0.55, 0.05), 25.0, carrot_remaining.size())


func _rating_text(score_ratio: float) -> String:
	if score_ratio >= 0.8:
		return "a MASTERPIECE!!!"
	elif score_ratio >= 0.6:
		return "a meal!"
	elif score_ratio >= 0.4:
		return "barely edible slop."
	elif score_ratio >= 0.2:
		return "...something."
	else:
		return "an insult to God's Earth."


func _scatter_food(cook_levels: Array, base_color: Color, dot_radius: float, visual_count: int) -> void:
	# Decorative only - colored per-item from its actual cook_level,
	# scattered within an ellipse roughly matching the dish's visible bowl
	# area, with a staggered drop-in tween for a bit of "being plated" polish.
	if cook_levels.is_empty():
		return

	var count: int = min(visual_count, cook_levels.size()) if visual_count > 0 else cook_levels.size()
	var dish_center: Vector2 = dish.position

	for i in range(count):
		var cook_level: float = cook_levels[i % cook_levels.size()]

		var dot := ColorRect.new()
		var tint := base_color.lerp(Color(0.05, 0.05, 0.05), clamp((cook_level - 0.3) / 0.3, 0.0, 1.0))
		dot.color = tint
		dot.size = Vector2(dot_radius, dot_radius)

		var angle := randf_range(0.0, TAU)
		var radius_x := randf_range(0.0, 340.0)
		var radius_y := radius_x * 0.35
		var target := dish_center + Vector2(cos(angle) * radius_x, sin(angle) * radius_y - 10.0)

		dot.position = target - Vector2(dot_radius, dot_radius) / 2.0 - Vector2(0, 200)
		food_container.add_child(dot)

		var tween := create_tween()
		tween.tween_interval(randf_range(0.0, 0.3))
		tween.tween_property(
			dot,
			"position",
			target - Vector2(dot_radius, dot_radius) / 2.0,
			0.25
		).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)


func clear_food() -> void:
	for child in food_container.get_children():
		child.queue_free()
