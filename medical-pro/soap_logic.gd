extends RefCounted
## Pure logic for talking to the Gemini API, with no UI and no network calls.
##
## Kept separate from medical_pro.gd so every function can be unit tested
## headless (see tests/run_tests.gd).

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

# The first %s is the template's extra guidance, the second the transcript.
const PROMPT := (
	"TASK: Convert the transcript below into a SOAP note.\n"
	+ "FORMAT: Use the headings SUBJECTIVE, OBJECTIVE, ASSESSMENT and PLAN.\n"
	+ "RULES: Only use information that is in the transcript. "
	+ "If something was not discussed, write 'Not documented'. "
	+ "Do not ask questions and do not introduce yourself.\n"
	+ "%s\n"
	+ "TRANSCRIPT:\n%s"
)

# Note templates. Each adds guidance for what that kind of visit needs.
const TEMPLATES := {
	"General": "",
	"Paediatrics":
	(
		"FOCUS: The patient is a child. Record age, weight and who gave the history "
		+ "(parent or carer). Note feeding, growth and immunisation status if discussed. "
		+ "Express any doses per kg if the clinician stated them."
	),
	"Mental health":
	(
		"FOCUS: Record mood, sleep, appetite and any risk to self or others in SUBJECTIVE. "
		+ "Put a brief mental state examination in OBJECTIVE. "
		+ "If risk was discussed, state the risk level and the safety plan in PLAN."
	),
	"Follow-up visit":
	(
		"FOCUS: This is a follow-up. Start SUBJECTIVE with the change since the last "
		+ "visit, record adherence to the previous plan, and say in ASSESSMENT whether "
		+ "the condition is improving, stable or worse."
	),
}

const SECTIONS := ["SUBJECTIVE", "OBJECTIVE", "ASSESSMENT", "PLAN"]

const EXAMPLE_TRANSCRIPT := (
	"Doctor: What brings you in today?\n"
	+ "Patient: I've had this cough for two weeks. It's dry, keeps me up at night.\n"
	+ "Doctor: Any fever?\n"
	+ "Patient: No, nothing like that. Temperature's been normal.\n"
	+ "Doctor: Let me listen to your chest. Lungs are clear.\n"
	+ "Doctor: I think this is viral. Rest, fluids, honey for the cough.\n"
	+ "Patient: How long should it last?\n"
	+ "Doctor: Usually 3 to 4 weeks. Call if it gets worse or you develop a fever."
)


## Returns the API key from the environment or the key file, or "".
static func load_api_key(env_value: String, key_file: String = KEY_FILE) -> String:
	var from_env := env_value.strip_edges()
	if not from_env.is_empty():
		return from_env
	if FileAccess.file_exists(key_file):
		return FileAccess.get_file_as_string(key_file).strip_edges()
	return ""


static func request_url() -> String:
	return API_URL % MODEL


## The request headers. The key goes in a header rather than the URL, so it
## never shows up in logs or error messages that print the address.
static func request_headers(api_key: String) -> PackedStringArray:
	return PackedStringArray(["Content-Type: application/json", "x-goog-api-key: " + api_key])


static func build_prompt(transcript: String, template: String = "General") -> String:
	var guidance: String = TEMPLATES.get(template, "")
	return PROMPT % [guidance, transcript]


static func request_body(transcript: String, template: String = "General") -> String:
	var payload := {
		"contents": [{"parts": [{"text": build_prompt(transcript, template)}]}],
		"generationConfig": {"temperature": TEMPERATURE, "maxOutputTokens": MAX_OUTPUT_TOKENS},
	}
	return JSON.stringify(payload)


## Pulls candidates[0].content.parts[0].text out of a Gemini response.
## Returns "" if any part of that path is missing.
static func extract_text(data) -> String:
	if not data is Dictionary:
		return ""
	var candidates = data.get("candidates", [])
	if not candidates is Array or candidates.is_empty() or not candidates[0] is Dictionary:
		return ""
	var content = candidates[0].get("content", {})
	if not content is Dictionary:
		return ""
	var parts = content.get("parts", [])
	if not parts is Array or parts.is_empty() or not parts[0] is Dictionary:
		return ""
	return str(parts[0].get("text", "")).strip_edges()


static func api_error_message(code: int, data) -> String:
	var detail := ""
	if data is Dictionary and data.get("error") is Dictionary:
		detail = str(data["error"].get("message", ""))
	match code:
		400:
			return "Error 400: the request was rejected. %s" % detail
		401, 403:
			return "Error %d: the API key was refused. Check it in Google AI Studio." % code
		404:
			return "Error 404: model '%s' was not found. Check MODEL in soap_logic.gd." % MODEL
		429:
			return "Error 429: rate limit reached. Wait a minute and try again."
		_:
			return ("API error %d. %s" % [code, detail]).strip_edges()


static func network_error_message(result: int) -> String:
	match result:
		HTTPRequest.RESULT_TIMEOUT:
			return "Error: the request timed out after %d seconds." % int(REQUEST_TIMEOUT_SECONDS)
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE:
			return "Error: could not reach the Gemini API. Check your internet connection."
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "Error: secure connection failed (TLS handshake)."
		_:
			return "Error: the request failed (result code %d)." % result


## Makes sure a saved note ends in .txt or .md.
static func with_note_extension(path: String) -> String:
	var ext := path.get_extension().to_lower()
	return path if ext in ["txt", "md"] else path + ".txt"


## SOAP headings that are missing from a note. A heading counts if it starts
## a line, ignoring Markdown marks such as "**" or "#", and in any letter case.
static func missing_sections(note: String) -> PackedStringArray:
	var missing := PackedStringArray()
	for section in SECTIONS:
		var pattern := RegEx.create_from_string("(?im)^[\\s#*_>-]*%s\\b" % section)
		if pattern.search(note) == null:
			missing.append(section)
	return missing
