extends Control
## Medical-Pro: turns a doctor-patient transcript into a SOAP note.
##
## The transcript is sent to the Google Gemini API with a fixed instruction,
## and the note that comes back is shown in the output box.

# Model and endpoint. Change MODEL to try a different Gemini model.
const MODEL := "gemini-3.1-flash-lite"
const API_URL := "https://generativelanguage.googleapis.com/v1/models/%s:generateContent"

# The API key is never stored in the project. It is read, in this order, from:
#   1. the GEMINI_API_KEY environment variable
#   2. a local file at user://gemini_api_key.txt (outside the project folder)
const KEY_ENV_VAR := "GEMINI_API_KEY"
const KEY_FILE := "user://gemini_api_key.txt"

# Generation settings. Low temperature keeps the note factual and consistent.
const TEMPERATURE := 0.1
const MAX_OUTPUT_TOKENS := 1000
const REQUEST_TIMEOUT_SECONDS := 60.0

const PROMPT := (
	"TASK: Convert the transcript below into a SOAP note.\n"
	+ "FORMAT: Use the headings SUBJECTIVE, OBJECTIVE, ASSESSMENT and PLAN.\n"
	+ "RULES: Only use information that is in the transcript. "
	+ "If something was not discussed, write 'Not documented'. "
	+ "Do not ask questions and do not introduce yourself.\n\n"
	+ "TRANSCRIPT:\n%s"
)

var _api_key := ""

@onready var input_field: TextEdit = $VBoxContainer/TranscriptInput
@onready var output_field: TextEdit = $VBoxContainer/OutputDisplay
@onready var generate_button: Button = $VBoxContainer/GenerateButton
@onready var http_request: HTTPRequest = $HTTPRequest


func _ready() -> void:
	generate_button.pressed.connect(_on_generate_pressed)
	http_request.request_completed.connect(_on_request_completed)
	http_request.timeout = REQUEST_TIMEOUT_SECONDS

	_api_key = _load_api_key()
	if _api_key.is_empty():
		var key_path := ProjectSettings.globalize_path(KEY_FILE)
		output_field.text = (
			"No API key found.\n\nSet the %s environment variable, or save your key in:\n%s"
			% [KEY_ENV_VAR, key_path]
		)
		generate_button.disabled = true
	else:
		output_field.text = "Ready. Paste a transcript above and press Generate SOAP Note."


## Returns the API key from the environment or the local key file, or "".
func _load_api_key() -> String:
	var from_env := OS.get_environment(KEY_ENV_VAR).strip_edges()
	if not from_env.is_empty():
		return from_env
	if FileAccess.file_exists(KEY_FILE):
		return FileAccess.get_file_as_string(KEY_FILE).strip_edges()
	return ""


func _on_generate_pressed() -> void:
	var transcript := input_field.text.strip_edges()
	if transcript.is_empty():
		output_field.text = "Error: paste a transcript first."
		return

	var payload := {
		"contents": [{"parts": [{"text": PROMPT % transcript}]}],
		"generationConfig": {"temperature": TEMPERATURE, "maxOutputTokens": MAX_OUTPUT_TOKENS},
	}
	var body := JSON.stringify(payload)
	# The key goes in a header rather than the URL, so it does not end up in
	# logs or error messages that print the request address.
	var headers := ["Content-Type: application/json", "x-goog-api-key: " + _api_key]

	var err := http_request.request(API_URL % MODEL, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		output_field.text = "Error: could not send the request (code %d)." % err
		return

	# Stop double submissions while a request is in flight.
	generate_button.disabled = true
	output_field.text = "Generating SOAP note..."


func _on_request_completed(
	result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray
) -> void:
	generate_button.disabled = false

	if result != HTTPRequest.RESULT_SUCCESS:
		output_field.text = _network_error_message(result)
		return

	var data = JSON.parse_string(body.get_string_from_utf8())
	if response_code != 200:
		output_field.text = _api_error_message(response_code, data)
		return

	var note := _extract_text(data)
	if note.is_empty():
		output_field.text = "Error: Gemini returned an empty response. Try a longer transcript."
	else:
		output_field.text = note


## Pulls candidates[0].content.parts[0].text out of a Gemini response.
## Returns "" if any part of that path is missing.
func _extract_text(data) -> String:
	if not data is Dictionary:
		return ""
	var candidates = data.get("candidates", [])
	if not candidates is Array or candidates.is_empty():
		return ""
	var parts = candidates[0].get("content", {}).get("parts", [])
	if not parts is Array or parts.is_empty():
		return ""
	return str(parts[0].get("text", "")).strip_edges()


func _api_error_message(code: int, data) -> String:
	var detail := ""
	if data is Dictionary and data.get("error") is Dictionary:
		detail = str(data["error"].get("message", ""))
	match code:
		400:
			return "Error 400: the request was rejected. %s" % detail
		401, 403:
			return "Error %d: the API key was refused. Check it in Google AI Studio." % code
		404:
			return "Error 404: model '%s' was not found. Check MODEL in medical_pro.gd." % MODEL
		429:
			return "Error 429: rate limit reached. Wait a minute and try again."
		_:
			return "API error %d. %s" % [code, detail]


func _network_error_message(result: int) -> String:
	match result:
		HTTPRequest.RESULT_TIMEOUT:
			return "Error: the request timed out after %d seconds." % int(REQUEST_TIMEOUT_SECONDS)
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE:
			return "Error: could not reach the Gemini API. Check your internet connection."
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "Error: secure connection failed (TLS handshake)."
		_:
			return "Error: the request failed (result code %d)." % result
