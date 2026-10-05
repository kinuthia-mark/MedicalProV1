extends SceneTree
## Renders the app with the example transcript and a sample note, and saves
## a PNG for the README. Needs a real renderer (not --headless), e.g. in CI:
##     xvfb-run godot --path medical-pro --rendering-driver opengl3 \
##         --resolution 1280x760 --script res://tools/capture.gd -- out.png

const Soap := preload("res://soap_logic.gd")

const SAMPLE_NOTE := (
	"SUBJECTIVE:\n"
	+ "2-week history of dry cough, worse at night. Denies fever; temperature normal.\n\n"
	+ "OBJECTIVE:\n"
	+ "Lungs clear on auscultation.\nVital signs: Not documented.\n\n"
	+ "ASSESSMENT:\n"
	+ "Acute cough, likely viral.\n\n"
	+ "PLAN:\n"
	+ "1. Rest and increased fluid intake\n"
	+ "2. Honey for symptomatic relief of cough\n"
	+ "3. Expected duration 3-4 weeks; return if fever develops or symptoms worsen"
)


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path: String = args[0] if args.size() > 0 else "screenshot.png"

	var app: Control = load("res://src/control.tscn").instantiate()
	root.add_child(app)
	await process_frame

	app.input_field.text = Soap.EXAMPLE_TRANSCRIPT
	app._set_note(SAMPLE_NOTE, true)
	app._set_status("Note ready")
	app.generate_button.disabled = false

	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw

	var image := root.get_texture().get_image()
	var err := image.save_png(out_path)
	print("Saved %s (%dx%d), error %d" % [out_path, image.get_width(), image.get_height(), err])
	quit(err)
