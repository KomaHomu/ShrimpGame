extends AnimatableBody2D

@export var pan_speed: float = 300.0
@export var pan_acceleration: float = 2000.0
@export var pan_deceleration: float = 500.0

@export var min_flip_angle: float = -10.0
@export var max_flip_angle: float = -45.0
@export var flip_duration: float = 0.5

@export var max_charge_time: float = 0.5  # hold this long (seconds) for a full-power flip

@export_group("Stove / Heat")
@export var max_heat_distance: float = 50.0  # how far above the floor heat still reaches
@export var heat_falloff_exponent: float = 5.0  # higher = heat drops off much faster with height
@export var flat_angle_tolerance: float = 0.05  # radians; how close to 0 rotation counts as "flat"
@export var heat_radiate_distance: float = 20.0  # how far past the fire's edge heat still weakly radiates
@export var heat_radiate_strength: float = 0.5  # radiated-heat multiplier right at the fire's edge, fading to 0 beyond heat_radiate_distance

# Read from marker nodes in _ready() rather than hardcoded, so moving
# StoveZoneLeft/Right/RiceSpawnPoint in the editor is all that's needed
# if the pan's layout ever changes - no script edits required.
var stove_min_x: float
var stove_max_x: float
var stove_floor_y: float

# World-space fire bounds, from the two "stove_edge" group members in the
# game scene (StoveLeft/StoveRight). Heat is checked per-grain against
# these bounds - see get_heat_factor() - so only rice actually positioned
# over the fire heats up, not the pan as a whole.
var stove_edge_min_x: float = -INF
var stove_edge_max_x: float = INF

@onready var stove_zone_left: Marker2D = $StoveZoneLeft
@onready var stove_zone_right: Marker2D = $StoveZoneRight
@onready var rice_spawn_point: Marker2D = $RiceSpawnPoint

var flipping := false
var charging := false
var charge_time := 0.0
var current_speed_x := 0.0


func _ready() -> void:
	add_to_group("pan")

	stove_min_x = min(stove_zone_left.position.x, stove_zone_right.position.x)
	stove_max_x = max(stove_zone_left.position.x, stove_zone_right.position.x)
	stove_floor_y = rice_spawn_point.position.y

	var edges := get_tree().get_nodes_in_group("stove_edge")
	if edges.size() >= 2:
		var x0: float = edges[0].global_position.x
		var x1: float = edges[1].global_position.x
		stove_edge_min_x = min(x0, x1)
		stove_edge_max_x = max(x0, x1)
	else:
		push_warning("Pan: expected 2 nodes in group 'stove_edge', found %d." % edges.size())


func _physics_process(delta: float) -> void:
	if flipping:
		return

	var input_direction := (
		Input.get_action_strength("right") -
		Input.get_action_strength("left")
	)

	# Accelerate/decelerate smoothly rather than snapping to full speed -
	# avoids a one-frame velocity jump that jerks the rice via friction -
	# but keep the two rates close together so the pan still feels responsive.
	var target_speed_x := input_direction * pan_speed
	var speeding_up := bool(
		target_speed_x != 0.0
		and (current_speed_x == 0.0 or sign(target_speed_x) == sign(current_speed_x))
	)
	var rate := pan_acceleration if speeding_up else pan_deceleration
	current_speed_x = move_toward(
		current_speed_x,
		target_speed_x,
		rate * delta
	)

	position.x += current_speed_x * delta

	_handle_flip_input(delta)


func _handle_flip_input(delta: float) -> void:
	if Input.is_action_just_pressed("flip"):
		charging = true
		charge_time = 0.0

	if charging:
		charge_time += delta

		if Input.is_action_just_released("flip"):
			charging = false
			var strength: float = clamp(charge_time / max_charge_time, 0.0, 1.0)
			flip_pan(strength)


func flip_pan(strength: float) -> void:
	flipping = true
	current_speed_x = 0.0

	var angle: float = deg_to_rad(lerp(min_flip_angle, max_flip_angle, strength))
	var original_rotation := rotation
	var settled := false

	var tween := create_tween()
	tween.set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)  # stay synced with sync_to_physics

	tween.tween_property(
		self,
		"rotation",
		original_rotation + angle,
		flip_duration / 2.0
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	tween.tween_property(
		self,
		"rotation",
		original_rotation,
		flip_duration / 2.0
	).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

	var finish_flip := func() -> void:
		if settled:
			return
		settled = true
		rotation = original_rotation
		flipping = false

	tween.finished.connect(finish_flip)

	# Safety net: a violent collision (e.g. rice trapped under the pan as it
	# slams back down) can occasionally stall the tween mid-animation. Rather
	# than risk the pan getting stuck at whatever angle it stalled at, force
	# it back to flat if it hasn't finished naturally in time.
	get_tree().create_timer(flip_duration + 0.3).timeout.connect(finish_flip)


func is_flat() -> bool:
	return not flipping and abs(wrapf(rotation, -PI, PI)) < flat_angle_tolerance


func get_heat_factor(world_pos: Vector2) -> float:
	if not is_flat():
		return 0.0

	var local_pos := to_local(world_pos)

	if local_pos.x < stove_min_x or local_pos.x > stove_max_x:
		return 0.0

	# Localized: heat depends on THIS grain's own world position relative to
	# the fire, not the pan's overall position. Full heat directly above the
	# flame, a weak "radiating" heat for a short distance past its edges,
	# nothing beyond that.
	var horizontal_heat := _horizontal_heat_factor(world_pos.x)
	if horizontal_heat <= 0.0:
		return 0.0

	var distance_from_floor := stove_floor_y - local_pos.y
	var proximity: float = clamp(1.0 - distance_from_floor / max_heat_distance, 0.0, 1.0)

	# Raising to a power concentrates heat near the floor - grains right on
	# the metal cook fast, grains a couple layers up barely cook at all,
	# which is what forces the player to actively mix/flip the pile.
	var vertical_heat: float = pow(proximity, heat_falloff_exponent)

	return vertical_heat * horizontal_heat


func _horizontal_heat_factor(world_x: float) -> float:
	if world_x >= stove_edge_min_x and world_x <= stove_edge_max_x:
		return 1.0

	var distance_outside: float = (
		stove_edge_min_x - world_x if world_x < stove_edge_min_x
		else world_x - stove_edge_max_x
	)

	if distance_outside >= heat_radiate_distance:
		return 0.0

	var t: float = 1.0 - (distance_outside / heat_radiate_distance)
	return t * heat_radiate_strength
