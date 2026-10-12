extends CanvasLayer

@onready var replay_button: Button = $Panel/CenterContainer/VBoxContainer/ReplayButton


func _ready() -> void:
	add_to_group("game_over_screen")
	visible = false
	replay_button.pressed.connect(_on_replay_pressed)


func show_screen() -> void:
	visible = true


func _on_replay_pressed() -> void:
	get_tree().reload_current_scene()
