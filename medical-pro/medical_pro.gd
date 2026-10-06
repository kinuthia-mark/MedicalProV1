extends Control
## Medical-Pro: turns a doctor-patient transcript into a SOAP note.
##
## This script wires the UI together. Building the request and reading the
## response live in soap_logic.gd so they can be tested without a window.

const Soap := preload("res://soap_logic.gd")

var _api_key := ""

@onready var input_field: TextEdit = %TranscriptInput
@onready var output_field: TextEdit = %OutputDisplay
@onready var generate_button: Button = %GenerateButton
@onready var example_button: Button = %ExampleButton
@onready var clear_button: Button = %ClearButton
@onready var copy_button: Button = %CopyButton
@onready var save_button: Button = %SaveButton
@onready var status_label: Label = %StatusLabel
@onready var save_dialog: FileDialog = %SaveDialog
@onready var http_request: HTTPRequest = %HTTPRequest


func _ready() -> void:
	generate_button.pressed.connect(_on_generate_pressed)
	example_button.pressed.connect(func(): input_field.text = Soap.EXAMPLE_TRANSCRIPT)
	clear_button.pressed.connect(_on_clear_pressed)
	copy_button.pressed.connect(_on_copy_pressed)
	save_button.pressed.connect(func(): save_dialog.popup_centered())
	save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	save_dialog.current_file = "soap-note.txt"
	save_dialog.file_selected.connect(_on_save_path_chosen)
	http_request.request_completed.connect(_on_request_completed)
	http_request.timeout = Soap.REQUEST_TIMEOUT_SECONDS

	_api_key = Soap.load_api_key(OS.get_environment(Soap.KEY_ENV_VAR))
	if _api_key.is_empty():
		output_field.text = (
			"No API key found.\n\nSet the %s environment variable, or save your key in:\n%s"
			% [Soap.KEY_ENV_VAR, ProjectSettings.globalize_path(Soap.KEY_FILE)]
		)
		generate_button.disabled = true
		_set_status("No API key")
	else:
		output_field.placeholder_text = "The SOAP note will appear here."
		_set_status("Ready")


func _set_status(text: String) -> void:
	status_label.text = text


## Copy and Save only make sense once there is a real note.
func _set_note(text: String, is_note: bool) -> void:
	output_field.text = text
	copy_button.disabled = not is_note
	save_button.disabled = not is_note


func _on_clear_pressed() -> void:
	input_field.text = ""
	_set_note("", false)
	_set_status("Ready" if not _api_key.is_empty() else "No API key")


func _on_generate_pressed() -> void:
	var transcript := input_field.text.strip_edges()
	if transcript.is_empty():
		_set_note("Paste a transcript first, or press Load example.", false)
		return

	var err := http_request.request(
		Soap.request_url(),
		Soap.request_headers(_api_key),
		HTTPClient.METHOD_POST,
		Soap.request_body(transcript)
	)
	if err != OK:
		_set_note("Error: could not send the request (code %d)." % err, false)
		return

	# Stop double submissions while a request is in flight.
	generate_button.disabled = true
	_set_note("", false)
	_set_status("Generating...")


func _on_request_completed(
	result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	generate_button.disabled = false

	if result != HTTPRequest.RESULT_SUCCESS:
		_set_note(Soap.network_error_message(result), false)
		_set_status("Failed")
		return

	var data = JSON.parse_string(body.get_string_from_utf8())
	if response_code != 200:
		_set_note(Soap.api_error_message(response_code, data), false)
		_set_status("Failed")
		return

	var note := Soap.extract_text(data)
	if note.is_empty():
		_set_note("Gemini returned an empty response. Try a longer transcript.", false)
		_set_status("Empty response")
	else:
		_set_note(note, true)
		_set_status("Note ready")


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(output_field.text)
	_set_status("Copied to clipboard")


func _on_save_path_chosen(path: String) -> void:
	path = Soap.with_note_extension(path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_set_status("Could not save (error %d)" % FileAccess.get_open_error())
		return
	file.store_string(output_field.text + "\n")
	file.close()
	_set_status("Saved to " + path.get_file())
