extends AnimatableBody2D

@export var pan_speed: float = 100.0
@export var pan_acceleration: float = 1500.0
@export var pan_deceleration: float = 500.0

@export var min_flip_angle: float = -8.0
@export var max_flip_angle: float = -35.0
@export var flip_duration: float = 0.4

@export var max_charge_time: float = 0.6  # hold this long (seconds) for a full-power flip

@export_group("Balance / Gravity")
@export var tilt_gravity: float = 4.0  # rad/sec^2 - how fast the tilt accelerates once past a stove edge
@export var tilt_recovery_strength: float = 8.0  # spring pull back to flat once supported again
@export var tilt_damping: float = 6.0  # bleeds off angular velocity so it doesn't oscillate forever
@export var max_recoverable_angle: float = 50.0  # degrees - past this, it's committed, no more recovery
@export var fall_gravity: float = 1400.0  # px/sec^2 - once committed, how fast it accelerates downward
@export var fall_off_screen_distance: float = 1200.0  # how far down it must fall before we call it "gone"

@export_group("Stove / Heat")
@export var max_heat_distance: float = 70.0  # how far above the floor heat still reaches
@export var heat_falloff_exponent: float = 4.0  # higher = heat drops off much faster with height
@export var flat_angle_tolerance: float = 0.05  # radians; how close to 0 rotation counts as "flat"
@export var heat_radiate_distance: float = 60.0  # how far past the fire's edge heat still weakly radiates
@export var heat_radiate_strength: float = 0.25  # radiated-heat multiplier right at the fire's edge, fading to 0 beyond heat_radiate_distance

# Read from marker nodes in _ready()
var stove_min_x: float
var stove_max_x: float
var stove_floor_y: float

# World-space fire bounds, from the two "stove_edge" group members in the
# game scene (StoveLeft/StoveRight). Heat is checked per-grain against
# these bounds - see get_heat_factor() - so only rice actually positioned
# over the fire heats up, not the pan as a whole.
var stove_edge_min_x: float = -INF
var stove_edge_max_x: float = INF
var stove_surface_y: float = 0.0  # world Y of the stove's surface - the fixed pivot height when tipping over an edge

# Local x-offset from this node's own origin (the handle-tip pivot) to the
# bowl's reference point. Needed because "is the pan balanced?" has to be
# judged from where the bowl actually is, not from the pivot far off to
# the side of it.
var bowl_offset_x: float = 0.0

# Which stove edge (world x) we're currently hinging on, locked in for the
# duration of a single tilt episode so the recovery swings back around the
# same corner it tipped over, rather than the pivot jumping around frame
# to frame.
var tilt_edge_x: float = 0.0

@onready var stove_zone_left: Marker2D = $StoveZoneLeft
@onready var stove_zone_right: Marker2D = $StoveZoneRight
@onready var rice_spawn_point: Marker2D = $RiceSpawnPoint

var flipping := false
var charging := false
var charge_time := 0.0
var current_speed_x := 0.0

var angular_velocity := 0.0
var falling := false
var fall_velocity_y := 0.0
var fall_start_y := 0.0


func _ready() -> void:
	add_to_group("pan")

	stove_min_x = min(stove_zone_left.position.x, stove_zone_right.position.x)
	stove_max_x = max(stove_zone_left.position.x, stove_zone_right.position.x)
	stove_floor_y = rice_spawn_point.position.y

	bowl_offset_x = rice_spawn_point.position.x

	var edges := get_tree().get_nodes_in_group("stove_edge")
	if edges.size() >= 2:
		var x0: float = edges[0].global_position.x
		var x1: float = edges[1].global_position.x
		stove_edge_min_x = min(x0, x1)
		stove_edge_max_x = max(x0, x1)
		stove_surface_y = edges[0].global_position.y
	else:
		push_warning("Pan: expected 2 nodes in group 'stove_edge', found %d." % edges.size())


func _physics_process(delta: float) -> void:
	if flipping:
		return

	if falling:
		_update_fall(delta)
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

	# Compute the candidate position/rotation as plain values first - do NOT
	# write to `position`/`rotation` individually mid-frame. On an
	# AnimatableBody2D with sync_to_physics on, two separate property writes
	# in the same physics frame (position, then rotation) causes the second
	# write to clobber the first, which silently prevented movement whenever
	# balance/tilt was also active. Applying both at once via `transform`
	# avoids that entirely.
	var translated_position := position
	translated_position.x += current_speed_x * delta

	var old_rotation := rotation
	var new_rotation := _compute_balance(delta, translated_position)
	var new_position := _apply_edge_pivot_rotation(translated_position, old_rotation, new_rotation)

	transform = Transform2D(new_rotation, new_position)

	if falling:
		return

	_handle_flip_input(delta)


func _apply_edge_pivot_rotation(base_position: Vector2, old_rotation: float, new_rotation: float) -> Vector2:
	# While tipping over a stove edge, the pan should hinge around that fixed
	# world point (like a book pivoting on a table's corner as it slides
	# off) - NOT around its own bowl. If there's no rotation change this
	# frame, there's nothing to compensate for.
	if is_equal_approx(old_rotation, new_rotation):
		return base_position

	var world_pivot := Vector2(tilt_edge_x, stove_surface_y)
	var delta_rot := new_rotation - old_rotation
	var offset := base_position - world_pivot
	return world_pivot + offset.rotated(delta_rot)


func _apply_bowl_pivot_rotation(base_position: Vector2, old_rotation: float, new_rotation: float) -> Vector2:
	# Once fully off the stove and in free-fall, tumble around the pan's own
	# center of mass (the bowl) instead of a table corner that no longer
	# applies - like a real object tumbling through the air.
	var local_pivot_offset := Vector2(bowl_offset_x, 0.0)
	var pivot_world := base_position + local_pivot_offset.rotated(old_rotation)
	return pivot_world - local_pivot_offset.rotated(new_rotation)


func _compute_balance(delta: float, candidate_position: Vector2) -> float:
	# Purely reactive to current position - fully recoverable by steering
	# back the other way, right up until max_recoverable_angle is crossed.
	# Forward velocity (current_speed_x) is left untouched here: sliding off
	# an edge keeps carrying you further off it, exactly like the real thing.
	#
	# NOTE: assumes this node's parent has an identity transform (no offset/
	# rotation/scale), so local position == global position. True for the
	# current scene (Pan is a direct child of the Game root). If that ever
	# changes, this needs to go through to_global() instead.
	var bowl_world_x := (candidate_position + Vector2(bowl_offset_x, 0.0).rotated(rotation)).x
	var overhang_left := stove_edge_min_x - bowl_world_x
	var overhang_right := bowl_world_x - stove_edge_max_x
	var overhang: float = max(overhang_left, overhang_right, 0.0)

	if is_equal_approx(rotation, 0.0) and overhang <= 0.0:
		angular_velocity = 0.0
		return 0.0

	if overhang > 0.0 and is_equal_approx(rotation, 0.0):
		# Just started tipping this frame - lock in which corner we hinge
		# on for the whole episode, so recovery swings back around the
		# same point instead of the pivot jumping frame to frame.
		tilt_edge_x = stove_edge_min_x if overhang_left > overhang_right else stove_edge_max_x

	if overhang > 0.0:
		var tilt_sign := -1.0 if tilt_edge_x == stove_edge_min_x else 1.0
		angular_velocity += tilt_sign * tilt_gravity * delta
		push_warning("AAAAAAAAAAAAAAAAHHHHHH IT'S FUCKING FALLING!!!")
	else:
		# Supported - actively rights itself back toward flat, and bleeds
		# off any spin so it settles instead of oscillating forever.
		angular_velocity += -tilt_recovery_strength * rotation * delta
		angular_velocity = move_toward(angular_velocity, 0.0, tilt_damping * delta)

	var new_rotation := rotation + angular_velocity * delta

	# Snap cleanly back to flat once close enough, rather than hovering with
	# a tiny persistent rotation (and pivot state) forever.
	if overhang <= 0.0 and abs(new_rotation) < 0.001 and abs(angular_velocity) < 0.01:
		new_rotation = 0.0
		angular_velocity = 0.0

	if abs(new_rotation) >= deg_to_rad(max_recoverable_angle):
		_start_falling(signf(new_rotation))

	return new_rotation


func _start_falling(direction_sign: float) -> void:
	falling = true
	fall_velocity_y = 0.0
	fall_start_y = position.y

	# Keep spinning further the way it was already tipping, for a believable
	# "completely lost it" continuation, rather than stopping dead.
	if angular_velocity == 0.0:
		angular_velocity = direction_sign * 2.0


func _update_fall(delta: float) -> void:
	var translated_position := position
	translated_position.x += current_speed_x * delta

	fall_velocity_y += fall_gravity * delta
	translated_position.y += fall_velocity_y * delta

	var new_rotation := rotation + angular_velocity * delta
	var new_position := _apply_bowl_pivot_rotation(translated_position, rotation, new_rotation)

	transform = Transform2D(new_rotation, new_position)

	if new_position.y - fall_start_y >= fall_off_screen_distance:
		_trigger_game_over()


func _trigger_game_over() -> void:
	set_physics_process(false)  # stop re-triggering every frame once it's called

	for screen in get_tree().get_nodes_in_group("game_over_screen"):
		if screen.has_method("show_screen"):
			screen.show_screen()


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
	return not flipping and not falling and abs(wrapf(rotation, -PI, PI)) < flat_angle_tolerance


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
