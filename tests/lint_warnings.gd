extends SceneTree
## Surfaces GDScript static-analysis warnings for the addon and tests. Headless
## runs never print them, and the editor hides them for res://addons by default.
##
## Two modes, both driven by tests/check_editor.sh:
##   --emit-override  Print an override.cfg (between OVR_BEGIN/OVR_END) that
##                    raises every default-on warning to error level and stops
##                    excluding the addon. Must be a file because from 4.6 the
##                    warning settings are read at startup (runtime changes are
##                    ignored). Handles exclude_addons (<=4.5) and
##                    directory_rules (4.6+).
##   (default)        With that override.cfg in place, re-parse every script.
##                    Each warning prints as "Parse Error: ... (Warning treated
##                    as error.)". check_editor.sh extracts those lines and
##                    compares them to tests/lint_baseline.txt.
## Run: $GODOT --headless --path . --script res://tests/lint_warnings.gd [-- --emit-override]

const DIRS := ["res://addons/vertex_painter/", "res://tests/"]
const PREFIX := "debug/gdscript/warnings/"


func _initialize() -> void:
	if "--emit-override" in OS.get_cmdline_user_args():
		_emit_override()
	else:
		_lint()
	quit(0)


func _emit_override() -> void:
	var out := "[debug]\n\n"
	if ProjectSettings.has_setting(PREFIX + "exclude_addons"):
		out += "gdscript/warnings/exclude_addons=false\n"
	if ProjectSettings.has_setting(PREFIX + "directory_rules"):
		out += "gdscript/warnings/directory_rules={\n\"res://addons\": 0,\n\"res://addons/vertex_painter\": 1\n}\n"
	for p in ProjectSettings.get_property_list():
		var key: String = p.name
		if key.begins_with(PREFIX) and p.type == TYPE_INT and ProjectSettings.get_setting(key) == 1:
			out += key.trim_prefix("debug/") + "=2\n"  # 1 = warn, 2 = error
	print("OVR_BEGIN\n" + out + "OVR_END")


func _lint() -> void:
	var files: Array[String] = []
	for d in DIRS:
		_collect(d, files)
	files.sort()
	for path in files:
		if path == get_script().resource_path:
			continue  # already loaded; re-parsing itself clashes with the cache
		print("LINT parse ", path)
		ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	# Per-script load status is unreliable (a failing dependency cascades into
	# its dependents), so this only produces the log; the shell does the diff.
	print("LINT_DONE")


func _collect(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	for sub in dir.get_directories():
		_collect(dir_path.path_join(sub), out)
	for f in dir.get_files():
		if f.get_extension() == "gd":
			out.append(dir_path.path_join(f))
