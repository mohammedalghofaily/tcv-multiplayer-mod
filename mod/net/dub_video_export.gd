extends Node
# "Save as Video" on the dub results screen. Rebuilds exactly what Watch plays --
# the pack's video, muted, with the backing track and every take laid in at its
# dub timestamps -- and hands the mix to ffmpeg, which writes an mp4. Nothing is
# screen-recorded: the video frames are the pack's own, so the file comes out at
# full quality however slow the machine is.
#
# Godot cannot encode video from a running game, so this needs an ffmpeg
# executable. It looks on PATH, in user://tools, and next to the game.
#
# Attached at runtime by Net when dub_mode.gd enters the tree, so no versioned
# patch has to carry it.

const DUB_MODE_SCRIPT: String = "res://scenes/gameplay/dub_mode/main/dub_mode.gd"
const WORK_ROOT: String = "user://dub_video_export"
const OUTPUT_FOLDER: String = "Choicer Voicer Dubs"
const POLL_SECONDS: float = 0.5
# Windows caps a command line at 32767 characters. every take is one input, so a
# pack with a few hundred clips could get near it.
const MAX_AUDIO_INPUTS: int = 300
const AUDIO_EXTENSIONS: PackedStringArray = ["wav", "mp3", "ogg", "WAV", "MP3", "OGG"]
const VIDEO_ENCODERS: PackedStringArray = ["libx264", "libopenh264", "mpeg4"]

var dub: Node
var _button: Control
var _label: Label
var _status: Label
var _pid: int = -1
var _work: String = ""
var _output: String = ""
var _progress_file: String = ""
var _log_file: String = ""
var _duration: float = 0.0
var _poll: Timer
var _last_output: String = ""


static func attach_if_dub_mode(node: Node) -> void:
	var script: Script = node.get_script()
	if script == null or script.resource_path != DUB_MODE_SCRIPT: return
	var exporter: Node = load("res://net/dub_video_export.gd").new()
	exporter.dub = node
	exporter.name = "DubVideoExport"
	node.add_child.call_deferred(exporter)


func _ready() -> void:
	var save: Control = dub.get("btn_save_dub")
	if save == null or save.get_parent() == null:
		Net.log_net("dub video export: no Save Dub button to sit next to, not adding one")
		return
	# the game's own button, minus its signal wiring, so it looks and sounds like
	# every other button on this screen.
	_button = save.duplicate(Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS | Node.DUPLICATE_USE_INSTANTIATION)
	_button.name = "BtnSaveVideo"
	if save.material: _button.material = save.material.duplicate()
	save.get_parent().add_child(_button)
	save.get_parent().move_child(_button, save.get_index() + 1)
	_label = _button.get_child(0) as Label
	# the copy keeps whatever state Save Dub was in when it was taken, which before
	# the dub starts is disabled.
	if _button.has_method("enable"): _button.call("enable", true)
	_set_button_text("Save as Video")
	_button.set("hover_info", "Save the finished dub as an MP4 video.")
	_button.connect("button_clicked", _on_pressed)
	_button.visible = save.visible
	save.visibility_changed.connect(func() -> void: _button.visible = save.visible)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 12)
	_status.visible = false
	save.get_parent().add_child(_status)
	save.get_parent().move_child(_status, _button.get_index() + 1)

	_poll = Timer.new()
	_poll.wait_time = POLL_SECONDS
	_poll.timeout.connect(_check_progress)
	add_child(_poll)


func _exit_tree() -> void:
	# leaving the results screen mid-export. ffmpeg is reading the takes out of
	# the work folder, so stop it before that folder goes.
	if _pid > 0:
		OS.kill(_pid)
		_pid = -1
		_remove_file(_output)
	_cleanup()


func _set_button_text(text: String) -> void:
	if _label: _label.text = text


func _say(text: String, problem: bool = false) -> void:
	_status.visible = not text.is_empty()
	_status.text = text
	_status.add_theme_color_override("font_color", Color("ff7b83") if problem else Color("f3f5fb"))


func _on_pressed() -> void:
	if _pid > 0:
		OS.kill(_pid)
		_pid = -1
		_poll.stop()
		_remove_file(_output)
		_cleanup()
		_set_button_text("Save as Video")
		_say("Export canceled.")
		return
	if not _last_output.is_empty() and FileAccess.file_exists(_last_output):
		OS.shell_show_in_file_manager(ProjectSettings.globalize_path(_last_output))
		return
	_start()


func _start() -> void:
	var ffmpeg: String = find_ffmpeg()
	if ffmpeg.is_empty():
		_say(ffmpeg_missing_text(), true)
		return
	var encoder: String = pick_encoder(ffmpeg)
	if encoder.is_empty():
		_say("Your ffmpeg has no video encoder this can use (tried %s)." % ", ".join(VIDEO_ENCODERS), true)
		return

	var resource: Resource = dub.get("resource")
	var folder: String = str(resource.pack_info.global_folder_path)
	if not folder.ends_with("/"): folder += "/"
	var video: String = folder + "dub_video.ogv"
	if not FileAccess.file_exists(video):
		_say("This pack has no dub_video.ogv to put the voices on.", true)
		return
	var backing: String = ""
	for extension: String in AUDIO_EXTENSIONS:
		if FileAccess.file_exists(folder + "_backing_track." + extension):
			backing = folder + "_backing_track." + extension
			break

	_work = "%s/%d" % [WORK_ROOT, Time.get_ticks_msec()]
	DirAccess.make_dir_recursive_absolute(_work)
	var takes: Array[Dictionary] = []
	var clips: Array = []
	clips.append_array(dub.get("performance_array"))
	clips.append_array(dub.get("unperformance_array"))
	var written: int = 0
	for clip: Variant in clips:
		var source: String = _audio_file_for(clip, written)
		if source.is_empty(): continue
		written += 1
		for timestamp: float in clip.shared_omniclip.dub_timestamps:
			takes.append({"path": ProjectSettings.globalize_path(source), "delay_ms": maxi(0, roundi(timestamp * 1000.0))})
	if takes.size() + 1 > MAX_AUDIO_INPUTS:
		_cleanup()
		_say("This dub has %d takes, more than one export can mix (%d)." % [takes.size(), MAX_AUDIO_INPUTS], true)
		return

	var out_dir: String = output_folder()
	DirAccess.make_dir_recursive_absolute(out_dir)
	var pack_name: String = str(resource.pack_info.get("display_name")) if resource.pack_info.get("display_name") else "dub"
	var stamp: String = Time.get_datetime_string_from_system().replace("T", " ").replace(":", "-")
	_output = out_dir.path_join(output_file_name(pack_name, stamp))
	_progress_file = _work + "/progress.txt"
	_log_file = _work + "/ffmpeg.log"
	_duration = media_duration(ffmpeg, ProjectSettings.globalize_path(video))

	var args: PackedStringArray = build_ffmpeg_args(
		ProjectSettings.globalize_path(video),
		ProjectSettings.globalize_path(backing) if not backing.is_empty() else "",
		takes,
		ProjectSettings.globalize_path(_output),
		ProjectSettings.globalize_path(_progress_file),
		encoder)
	# ffmpeg's own log, for when it fails. FFREPORT is the only way to point it at
	# a file without a shell, and child processes inherit our environment.
	OS.set_environment("FFREPORT", "file=%s:level=24" % _ffreport_escape(ProjectSettings.globalize_path(_log_file)))
	_pid = OS.create_process(ffmpeg, args)
	OS.unset_environment("FFREPORT")
	if _pid <= 0:
		_cleanup()
		_say("Could not start ffmpeg at %s." % ffmpeg, true)
		return
	Net.log_net("dub video export: %s, %d take(s), encoder %s -> %s" % [
		resource.pack_info.folder_name, takes.size(), encoder, _output])
	_set_button_text("Cancel Export")
	_say("Exporting... keep this screen open.")
	_poll.start()


# the recording for a clip that was performed, or the pack's own line for one
# the pack says to use as is. nothing for a clip that never got a take.
func _audio_file_for(clip: Variant, index: int) -> String:
	var audio: AudioStream = clip.member_audio
	if audio is AudioStreamWAV:
		var path: String = "%s/%03d.wav" % [_work, index]
		if (audio as AudioStreamWAV).save_to_wav(path) == OK: return path
		return ""
	if audio != null and bool(clip.shared_omniclip.dub_use_as_is):
		var original: String = str(clip.shared_omniclip.self_global_path)
		if FileAccess.file_exists(original): return original
	return ""


func _check_progress() -> void:
	if _pid <= 0: return
	var progress: String = FileAccess.get_file_as_string(_progress_file)
	var running: bool = OS.is_process_running(_pid)
	if running:
		var seconds: float = progress_seconds(progress)
		if _duration > 0.0:
			_say("Exporting... %d%%  (keep this screen open)" % clampi(roundi(seconds / _duration * 100.0), 0, 99))
		else:
			_say("Exporting... %d:%02d done  (keep this screen open)" % [int(seconds) / 60, int(seconds) % 60])
		return
	_pid = -1
	_poll.stop()
	_set_button_text("Save as Video")
	if progress.contains("progress=end") and FileAccess.file_exists(_output) and _file_size(_output) > 0:
		_last_output = _output
		_set_button_text("Show Video")
		# the full path is far wider than this panel. the folder is enough to find
		# it, and Show Video opens it anyway.
		_say("Saved in %s" % _output.get_base_dir().get_file())
		_status.tooltip_text = ProjectSettings.globalize_path(_output)
		Net.log_net("dub video export finished: %s" % _output)
	else:
		var reason: String = _log_tail(FileAccess.get_file_as_string(_log_file))
		Net.log_net("dub video export failed: %s" % reason)
		_remove_file(_output)
		_say("ffmpeg could not make the video.%s" % ("\n" + reason if not reason.is_empty() else ""), true)
	_cleanup()


func _cleanup() -> void:
	if _work.is_empty() or not _work.begins_with(WORK_ROOT + "/"): return
	for file: String in DirAccess.get_files_at(_work): DirAccess.remove_absolute(_work.path_join(file))
	DirAccess.remove_absolute(_work)
	_work = ""


func _remove_file(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path): DirAccess.remove_absolute(path)


static func _file_size(path: String) -> int:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	return file.get_length() if file else 0


# --- pure helpers, tested offline by _selftest.gd ------------------------------


static func find_ffmpeg() -> String:
	var name: String = "ffmpeg.exe" if OS.get_name() == "Windows" else "ffmpeg"
	var candidates: PackedStringArray = []
	var configured: String = OS.get_environment("TCV_FFMPEG")
	if not configured.is_empty(): candidates.append(configured)
	candidates.append(ProjectSettings.globalize_path("user://tools/" + name))
	candidates.append(OS.get_executable_path().get_base_dir().path_join(name))
	candidates.append("ffmpeg")
	for candidate: String in candidates:
		if candidate != "ffmpeg" and not FileAccess.file_exists(candidate): continue
		var output: Array = []
		if OS.execute(candidate, ["-hide_banner", "-version"], output) == 0: return candidate
	return ""


static func pick_encoder(ffmpeg: String) -> String:
	var output: Array = []
	if OS.execute(ffmpeg, ["-hide_banner", "-encoders"], output) != 0: return ""
	var listing: String = "\n".join(output)
	for encoder: String in VIDEO_ENCODERS:
		if listing.contains(" %s " % encoder): return encoder
	return ""


static func ffmpeg_missing_text() -> String:
	if OS.get_name() == "Windows":
		return ("Saving as video needs ffmpeg. Install it with\n  winget install Gyan.FFmpeg\n"
			+ "then restart the game. Or put ffmpeg.exe next to the game's exe.")
	return ("Saving as video needs ffmpeg. Install it with your package manager "
		+ "(the package is called ffmpeg), then try again.")


static func output_folder() -> String:
	var videos: String = OS.get_system_dir(OS.SYSTEM_DIR_MOVIES)
	if videos.is_empty() or not DirAccess.dir_exists_absolute(videos):
		return "user://" + OUTPUT_FOLDER.to_snake_case()
	return videos.path_join(OUTPUT_FOLDER)


# the whole of the export: the pack's video with its own sound dropped, the
# backing track from zero, each take delayed to its timestamp, summed at unity
# gain and limited the way the game's master bus limits it. apad plus -shortest
# lets the video decide how long the file is, whichever stream would run out first.
static func build_ffmpeg_args(
	video: String, backing: String, takes: Array[Dictionary], output: String,
	progress: String, encoder: String
) -> PackedStringArray:
	var args: PackedStringArray = ["-y", "-hide_banner", "-nostdin", "-loglevel", "error",
		"-report", "-progress", progress, "-i", video]
	var chains: PackedStringArray = []
	var labels: PackedStringArray = []
	var input: int = 1
	if not backing.is_empty():
		args.append_array(["-i", backing])
		labels.append("[%d:a]" % input)
		input += 1
	for take: Dictionary in takes:
		args.append_array(["-i", str(take["path"])])
		chains.append("[%d:a]adelay=%d:all=1[t%d]" % [input, int(take["delay_ms"]), input])
		labels.append("[t%d]" % input)
		input += 1
	args.append_array(["-map", "0:v:0"])
	if labels.is_empty():
		args.append("-an")
	else:
		chains.append("%samix=inputs=%d:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95,apad[mix]" % [
			"".join(labels), labels.size()])
		args.append_array(["-filter_complex", ";".join(chains), "-map", "[mix]",
			"-c:a", "aac", "-b:a", "192k", "-shortest"])
	match encoder:
		"libx264": args.append_array(["-c:v", "libx264", "-preset", "veryfast", "-crf", "20"])
		"libopenh264": args.append_array(["-c:v", "libopenh264", "-b:v", "6M"])
		_: args.append_array(["-c:v", encoder, "-q:v", "3"])
	args.append_array(["-pix_fmt", "yuv420p", "-movflags", "+faststart", output])
	return args


# Godot reports 0 for a Theora file's length, so ask ffmpeg, which prints it on
# the way to complaining that no output was given.
static func media_duration(ffmpeg: String, path: String) -> float:
	var output: Array = []
	OS.execute(ffmpeg, ["-hide_banner", "-i", path], output, true)
	return parse_duration("\n".join(output))


static func parse_duration(text: String) -> float:
	var found: = RegEx.new()
	found.compile("Duration:\\s*(\\d+):(\\d+):(\\d+(?:\\.\\d+)?)")
	var m: RegExMatch = found.search(text)
	if m == null: return 0.0
	return m.get_string(1).to_int() * 3600.0 + m.get_string(2).to_int() * 60.0 + m.get_string(3).to_float()


# pack names are whatever the author typed. drop what Windows will not store
# rather than leaving underscores where the question marks were.
static func output_file_name(pack_name: String, stamp: String) -> String:
	var unsafe: = RegEx.new()
	unsafe.compile("[<>:\"/\\\\|?*\\x00-\\x1f]")
	var clean: String = unsafe.sub(pack_name, "", true).strip_edges().trim_suffix(".")
	if clean.is_empty(): clean = "Dub"
	return ("%s %s.mp4" % [clean, stamp]).validate_filename()


static func progress_seconds(progress: String) -> float:
	var latest: float = 0.0
	for line: String in progress.split("\n"):
		if line.begins_with("out_time_us=") or line.begins_with("out_time_ms="):
			var value: String = line.get_slice("=", 1).strip_edges()
			if value.is_valid_int(): latest = value.to_int() / 1000000.0
	return latest


static func _ffreport_escape(path: String) -> String:
	# FFREPORT's own syntax: ':' separates options and '\' escapes.
	return path.replace("\\", "\\\\").replace(":", "\\:")


static func _log_tail(log: String) -> String:
	var lines: PackedStringArray = []
	for line: String in log.split("\n"):
		var clean: String = line.strip_edges()
		if clean.is_empty() or clean.begins_with("ffmpeg started") or clean.begins_with("Report written"): continue
		if clean.to_lower().contains("error") or clean.to_lower().contains("invalid") or clean.to_lower().contains("not found"):
			lines.append(clean)
	return "\n".join(lines.slice(maxi(0, lines.size() - 3)))
