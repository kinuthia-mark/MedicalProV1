extends SceneTree
## Unit tests for soap_logic.gd. No window and no network needed.
##
## Run from the repository root:
##     godot --headless --path medical-pro --script res://tests/run_tests.gd
## The process exits with code 1 if any check fails.

const Soap := preload("res://soap_logic.gd")

var _failures := 0
var _checks := 0


func _init() -> void:
	_test_request()
	_test_extract_text()
	_test_error_messages()
	_test_api_key_loading()
	_test_note_extension()
	print("\n%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok    ", label)
	else:
		_failures += 1
		print("  FAIL  ", label)


func _test_request() -> void:
	print("request")
	var body: Dictionary = JSON.parse_string(Soap.request_body("Doctor: Hello"))
	var prompt: String = body["contents"][0]["parts"][0]["text"]
	check(prompt.ends_with("TRANSCRIPT:\nDoctor: Hello"), "transcript is appended to the prompt")
	check(
		prompt.contains("SUBJECTIVE, OBJECTIVE, ASSESSMENT and PLAN"),
		"prompt asks for SOAP headings"
	)
	check(prompt.contains("Not documented"), "prompt forbids guessing")
	check(body["generationConfig"]["temperature"] == Soap.TEMPERATURE, "temperature is set")
	check(
		Soap.request_body('He said "100%" sure').contains("100%"),
		"percent signs and quotes in the transcript survive"
	)
	var headers := Soap.request_headers("secret-key")
	check(headers.has("x-goog-api-key: secret-key"), "API key is sent as a header")
	check(not Soap.request_url().contains("key="), "API key is never in the URL")
	check(Soap.request_url().contains(Soap.MODEL), "URL uses the configured model")


func _test_extract_text() -> void:
	print("extract_text")
	var good := {"candidates": [{"content": {"parts": [{"text": "  SUBJECTIVE: cough  "}]}}]}
	check(Soap.extract_text(good) == "SUBJECTIVE: cough", "reads and trims the note")
	check(Soap.extract_text({}) == "", "missing candidates")
	check(Soap.extract_text({"candidates": []}) == "", "empty candidates")
	check(Soap.extract_text({"candidates": [{}]}) == "", "candidate without content")
	check(Soap.extract_text({"candidates": [{"content": {"parts": []}}]}) == "", "empty parts")
	check(Soap.extract_text({"candidates": ["oops"]}) == "", "malformed candidate")
	check(Soap.extract_text(null) == "", "null body")
	check(Soap.extract_text("not json") == "", "string body")


func _test_error_messages() -> void:
	print("error messages")
	check(Soap.api_error_message(401, null).contains("API key was refused"), "401")
	check(Soap.api_error_message(403, {}).contains("API key was refused"), "403")
	check(Soap.api_error_message(404, null).contains(Soap.MODEL), "404 names the model")
	check(Soap.api_error_message(429, null).contains("rate limit"), "429")
	var detail := {"error": {"message": "Bad field"}}
	check(Soap.api_error_message(400, detail).contains("Bad field"), "400 shows the API's reason")
	check(Soap.api_error_message(500, null) == "API error 500.", "other codes")
	check(Soap.network_error_message(HTTPRequest.RESULT_TIMEOUT).contains("timed out"), "timeout")
	check(
		Soap.network_error_message(HTTPRequest.RESULT_CANT_RESOLVE).contains("internet"),
		"no internet"
	)


func _test_api_key_loading() -> void:
	print("api key")
	var path := "user://test_key.txt"
	check(Soap.load_api_key("  env-key \n", path) == "env-key", "environment variable wins")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	check(Soap.load_api_key("", path) == "", "nothing set gives an empty key")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("file-key\n")
	f.close()
	check(Soap.load_api_key("", path) == "file-key", "key file is used when env is empty")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _test_note_extension() -> void:
	print("save path")
	check(Soap.with_note_extension("/tmp/note") == "/tmp/note.txt", "adds .txt")
	check(Soap.with_note_extension("/tmp/note.md") == "/tmp/note.md", "keeps .md")
	check(Soap.with_note_extension("/tmp/note.TXT") == "/tmp/note.TXT", "keeps .TXT")
