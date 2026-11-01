extends SceneTree
## Surfaces GDScript static-analysis warnings for the addon, which headless
## runs never print and which the editor hides for res://addons by default.
## Raises every warning that is set to "warn" to "error" (in memory only;
## project.godot is not changed), turns off the addons exclusion, then
## re-parses each script. Each warning then shows up as a parse error.
## Run: $GODOT --headless --path . --script res://tests/lint_warnings.gd
## Normally run via tests/check_editor.sh, which does the comparison.

const DIRS := ["res://addons/vertex_painter/", "res://tests/"]
const PREFIX := "debug/gdscript/warnings/"


func _initialize() -> void:
	var raised := 0
	for p in ProjectSettings.get_property_list():
		var key: String = p.name
		if not key.begins_with(PREFIX):
			continue
		var val = ProjectSettings.get_setting(key)
		if key == PREFIX + "exclude_addons":
			ProjectSettings.set_setting(key, false)
		elif key == PREFIX + "enable":
			ProjectSettings.set_setting(key, true)
		elif typeof(val) == TYPE_INT and val == 1:  # 1 = warn
			ProjectSettings.set_setting(key, 2)  # 2 = error
			raised += 1
	print("LINT raised %d warning kinds to error level" % raised)

	var files: Array[String] = []
	for d in DIRS:
		_collect(d, files)
	files.sort()
	for path in files:
		if path == get_script().resource_path:
			continue  # already loaded; re-parsing itself clashes with the cache
		print("LINT parse ", path)
		ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	# Per-script load status is unreliable (a dependency that fails cascades
	# into its dependents, and repeat loads may hit caches), so this script
	# only produces the log. tests/check_editor.sh extracts the
	# "(Warning treated as error.)" lines and compares them to
	# tests/lint_baseline.txt.
	print("LINT_DONE")
	quit(0)


func _collect(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_collect(dir_path.path_join(sub), out)
	for f in dir.get_files():
		if f.get_extension() == "gd":
			out.append(dir_path.path_join(f))
