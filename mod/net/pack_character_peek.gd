extends Node
# Counts the dub characters in a GameBanana ZIP without downloading it.
#
# The characters are not in GameBanana's catalog. Each clip carries them in a
# small sibling config (.ini, .cfg or .txt) as dub_characters=[...], somewhere in
# an archive that is usually a few hundred megabytes. GameBanana's file servers
# answer HTTP range requests, including several ranges at once, so this reads
# the ZIP's own index off the end of the file and then fetches just those config
# files in a handful of requests -- tens of kilobytes rather than the whole pack.
#
# Nothing fetched here is executed or parsed as a Godot resource. Configs are
# read with a small string scanner rather than ConfigFile, because ConfigFile's
# value parser can construct objects and this runs before anyone has agreed to
# install the pack.

signal finished(file_id: int, result: Dictionary)

const EOCD_SIGNATURE: int = 0x06054b50
const CENTRAL_SIGNATURE: int = 0x02014b50
const LOCAL_SIGNATURE: int = 0x04034b50
const TAIL_BYTES: int = 65557
const MAX_DIRECTORY_BYTES: int = 4 * 1024 * 1024
const MAX_ENTRIES: int = 4096
const MAX_CONFIG_BYTES: int = 64 * 1024
# the local header's extra field is not in the central directory and is usually
# a little longer. fetching this much past the name covers it without a retry.
const LOCAL_HEADER_SLACK: int = 512
# neighbouring configs closer than this are fetched as one range. a few kilobytes
# of someone's jpg is cheaper than another part in the response.
const MERGE_GAP: int = 4096
const RANGES_PER_REQUEST: int = 48
const RESPONSE_LIMIT: int = 8 * 1024 * 1024
const MAX_REDIRECTS: int = 5
const AUDIO_EXTENSIONS: PackedStringArray = ["wav", "mp3", "ogg"]
# the order the base game's VD.get_config_agnostic tries them in.
const CONFIG_EXTENSIONS: PackedStringArray = ["ini", "cfg", "txt", "INI", "CFG", "TXT"]
const INSTALLER_SCRIPT: Script = preload("res://net/community_pack_installer.gd")

static var _cache: Dictionary = {}

var _http: HTTPRequest
var _file_id: int = 0
var _url: String = ""
var _stage: String = ""
var _total_bytes: int = 0
var _entry_count: int = 0
var _configs: Array[Dictionary] = []
var _clip_count: int = 0
var _batches: Array = []
var _texts: Dictionary = {}
var _range_header: String = ""
var _redirects: int = 0


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.timeout = 20.0
	_http.body_size_limit = RESPONSE_LIMIT
	# a server that gzips a multipart range response would hand back something
	# none of the offsets below point into.
	_http.accept_gzip = false
	# followed by hand: /dl/ bounces through two redirects to a file cache, and
	# pointing the later requests straight at that cache saves a second or more.
	_http.max_redirects = 0
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)


static func cached(file_id: int) -> Dictionary:
	return _cache.get(file_id, {})


func is_busy() -> bool:
	return not _stage.is_empty()


func cancel() -> void:
	if is_busy(): _http.cancel_request()
	_stage = ""


func peek(file: Dictionary) -> void:
	cancel()
	_file_id = int(file.get("id", 0))
	if _cache.has(_file_id):
		finished.emit.call_deferred(_file_id, _cache[_file_id])
		return
	if str(file.get("name", "")).get_extension().to_lower() != "zip":
		_finish({"error": "Only ZIP files can be counted before downloading."}, false)
		return
	_url = str(file.get("url", ""))
	if not _url.begins_with("https://gamebanana.com/dl/"):
		_finish({"error": "This file has no GameBanana download link."}, false)
		return
	_total_bytes = 0
	_configs = []
	_clip_count = 0
	_batches = []
	_texts = {}
	_redirects = 0
	_request("tail", "bytes=-%d" % TAIL_BYTES)


func _request(stage: String, range_header: String) -> void:
	_stage = stage
	_range_header = range_header
	var headers: PackedStringArray = [
		"Range: " + range_header,
		"User-Agent: TCV-Multiplayer/%s" % str(Net.MOD_VERSION),
	]
	var error: Error = _http.request(_url, headers)
	if error != OK:
		_finish({"error": "Could not start the request (%s)." % error_string(error)}, false)


func _finish(result: Dictionary, remember: bool = true) -> void:
	_stage = ""
	if remember: _cache[_file_id] = result
	# deferred even when nothing was fetched, so a caller that awaits the signal
	# right after peek() hears about an instant refusal too.
	finished.emit.call_deferred(_file_id, result)


func _on_request_completed(
	result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray
) -> void:
	var stage: String = _stage
	if stage.is_empty(): return
	# with max_redirects at 0 Godot reports every redirect as the limit being hit,
	# but still hands over the status and Location header to follow ourselves.
	var redirected: bool = (result == HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED
		and response_code in [301, 302, 303, 307, 308])
	if result != HTTPRequest.RESULT_SUCCESS and not redirected:
		_finish({"error": "The download server did not answer (%d)." % result}, false)
		return
	if redirected:
		var location: String = _header(headers, "location")
		_redirects += 1
		if _redirects > MAX_REDIRECTS or not _trusted_download_url(location):
			_finish({"error": "The download link redirected somewhere unexpected."}, false)
			return
		_url = location
		_request(stage, _range_header)
		return
	if response_code != 206:
		# 200 means the whole file is coming. the body limit will have cut it off,
		# but either way this server cannot be peeked into.
		_finish({"error": "The download server does not allow partial reads (HTTP %d)." % response_code}, false)
		return
	var parts: Array[Dictionary] = parse_range_response(headers, body)
	if parts.is_empty():
		_finish({"error": "The download server sent an unreadable partial response."}, false)
		return
	match stage:
		"tail": _on_tail(parts[0])
		"directory": _on_directory(parts[0])
		"configs": _on_configs(parts)


func _on_tail(part: Dictionary) -> void:
	_total_bytes = int(part.get("total", 0))
	var tail: PackedByteArray = part["data"]
	var eocd: Dictionary = parse_end_of_directory(tail)
	if eocd.has("error"):
		_finish(eocd)
		return
	var directory_offset: int = int(eocd["offset"])
	var directory_size: int = int(eocd["size"])
	if directory_offset + directory_size > _total_bytes:
		_finish({"error": "The ZIP directory points past the end of the file."})
		return
	var tail_start: int = int(part["start"])
	if directory_offset >= tail_start:
		var local: int = directory_offset - tail_start
		_use_directory(tail.slice(local, local + directory_size), int(eocd["entries"]))
		return
	_entry_count = int(eocd["entries"])
	_request("directory", "bytes=%d-%d" % [directory_offset, directory_offset + directory_size - 1])


func _on_directory(part: Dictionary) -> void:
	_use_directory(part["data"], _entry_count)


func _use_directory(directory: PackedByteArray, entry_count: int) -> void:
	var parsed: Dictionary = parse_central_directory(directory, entry_count)
	if parsed.has("error"):
		_finish(parsed)
		return
	var entries: Array[Dictionary] = []
	for value: Variant in Array(parsed["entries"]):
		if value is Dictionary: entries.append(value)
	var selection: Dictionary = select_clip_configs(entries)
	if selection.has("error"):
		_finish(selection)
		return
	_clip_count = int(selection["clips"])
	for value: Variant in Array(selection["configs"]):
		if value is Dictionary: _configs.append(value)
	if _configs.is_empty():
		_finish(summarize(_clip_count, []))
		return
	_batches = plan_ranges(_configs, _total_bytes)
	_next_batch()


func _next_batch() -> void:
	if _batches.is_empty():
		var texts: Array[String] = []
		for config: Dictionary in _configs:
			texts.append(str(_texts.get(str(config["path"]), "")))
		var summary: Dictionary = summarize(_clip_count, texts)
		summary["unread"] = _configs.size() - _texts.size()
		_finish(summary)
		return
	var batch: Array = _batches.pop_front()
	var specs: PackedStringArray = []
	for span: Vector2i in batch: specs.append("%d-%d" % [span.x, span.y])
	_request("configs", "bytes=" + ",".join(specs))


func _on_configs(parts: Array[Dictionary]) -> void:
	for config: Dictionary in _configs:
		var path: String = str(config["path"])
		if _texts.has(path): continue
		for part: Dictionary in parts:
			var data: PackedByteArray = extract_entry(int(part["start"]), part["data"], config)
			if data.is_empty(): continue
			_texts[path] = data.get_string_from_utf8()
			break
	_next_batch()


# --- pure helpers, tested offline by _selftest.gd ------------------------------


static func parse_end_of_directory(tail: PackedByteArray) -> Dictionary:
	for i: int in range(tail.size() - 22, -1, -1):
		if tail.decode_u32(i) != EOCD_SIGNATURE: continue
		var entries: int = tail.decode_u16(i + 10)
		var size: int = tail.decode_u32(i + 12)
		var offset: int = tail.decode_u32(i + 16)
		if entries == 0xffff or size == 0xffffffff or offset == 0xffffffff:
			return {"error": "ZIP64 archives cannot be counted before downloading."}
		if entries <= 0 or entries > MAX_ENTRIES or size <= 0 or size > MAX_DIRECTORY_BYTES:
			return {"error": "The ZIP directory is empty or too large to read."}
		return {"entries": entries, "size": size, "offset": offset}
	return {"error": "The file has no readable ZIP directory."}


static func parse_central_directory(directory: PackedByteArray, entry_count: int) -> Dictionary:
	var entries: Array[Dictionary] = []
	var pos: int = 0
	for _index: int in entry_count:
		if pos + 46 > directory.size() or directory.decode_u32(pos) != CENTRAL_SIGNATURE:
			return {"error": "The ZIP directory is corrupt."}
		var name_length: int = directory.decode_u16(pos + 28)
		var extra_length: int = directory.decode_u16(pos + 30)
		var comment_length: int = directory.decode_u16(pos + 32)
		if name_length <= 0 or pos + 46 + name_length > directory.size():
			return {"error": "A ZIP filename is truncated."}
		var zip_path: String = directory.slice(pos + 46, pos + 46 + name_length).get_string_from_utf8()
		var normalized: String = zip_path.replace("\\", "/").trim_prefix("./")
		entries.append({
			"path": normalized.trim_suffix("/"),
			"directory": normalized.ends_with("/"),
			"flags": directory.decode_u16(pos + 8),
			"method": directory.decode_u16(pos + 10),
			"crc": directory.decode_u32(pos + 16),
			"compressed": directory.decode_u32(pos + 20),
			"size": directory.decode_u32(pos + 24),
			"offset": directory.decode_u32(pos + 42),
		})
		pos += 46 + name_length + extra_length + comment_length
	return {"entries": entries}


# the clips the base game would load from the folder the installer would
# install, and the config each one would read, found the way the game finds
# them: same folder, same base name, first of its config extensions that exists.
static func select_clip_configs(entries: Array[Dictionary]) -> Dictionary:
	var root: String = INSTALLER_SCRIPT._find_dub_root(entries)
	if root == INSTALLER_SCRIPT.NO_DUB_ROOT:
		return {"error": "This ZIP has no dub video, so it is not a Dub Mode pack."}
	var prefix: String = "" if root.is_empty() else root + "/"
	var by_path: Dictionary = {}
	for entry: Dictionary in entries:
		if not bool(entry["directory"]): by_path[str(entry["path"])] = entry
	var configs: Array[Dictionary] = []
	var clips: int = 0
	for entry: Dictionary in entries:
		if bool(entry["directory"]): continue
		var path: String = str(entry["path"])
		if not prefix.is_empty() and not path.begins_with(prefix): continue
		var file_name: String = path.get_file()
		# underscore audio is the backing track or the game's own recordings.
		if file_name.begins_with("_") or not AUDIO_EXTENSIONS.has(file_name.get_extension().to_lower()):
			continue
		clips += 1
		var base: String = path.get_basename()
		for extension: String in CONFIG_EXTENSIONS:
			var config: Dictionary = by_path.get(base + "." + extension, {})
			if config.is_empty(): continue
			if ((int(config["flags"]) & 1) == 0 and int(config["method"]) in [0, 8]
				and int(config["compressed"]) <= MAX_CONFIG_BYTES
				and int(config["size"]) <= MAX_CONFIG_BYTES):
				configs.append(config)
			break
	return {"clips": clips, "configs": configs}


# byte spans to ask for, merged where configs sit close together and split into
# requests small enough for any server's header limit.
static func plan_ranges(configs: Array[Dictionary], total_bytes: int) -> Array:
	var spans: Array[Vector2i] = []
	for config: Dictionary in configs:
		var start: int = int(config["offset"])
		var end: int = start + 30 + str(config["path"]).to_utf8_buffer().size() \
			+ LOCAL_HEADER_SLACK + int(config["compressed"]) - 1
		if total_bytes > 0: end = mini(end, total_bytes - 1)
		spans.append(Vector2i(start, end))
	spans.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x < b.x)
	var merged: Array[Vector2i] = []
	for span: Vector2i in spans:
		if not merged.is_empty() and span.x <= merged[-1].y + MERGE_GAP:
			merged[-1] = Vector2i(merged[-1].x, maxi(merged[-1].y, span.y))
		else:
			merged.append(span)
	var batches: Array = []
	for i: int in range(0, merged.size(), RANGES_PER_REQUEST):
		batches.append(merged.slice(i, i + RANGES_PER_REQUEST))
	return batches


# one 206 part, or every part of a multipart/byteranges one, as
# {start, total, data}. servers may coalesce ranges, so callers look entries up
# by offset rather than assuming one part per range asked for.
static func parse_range_response(headers: PackedStringArray, body: PackedByteArray) -> Array[Dictionary]:
	var content_type: String = _header(headers, "content-type")
	var parts: Array[Dictionary] = []
	if not content_type.to_lower().begins_with("multipart/byteranges"):
		var single: Dictionary = _content_range(_header(headers, "content-range"))
		if single.is_empty() or int(single["length"]) != body.size(): return parts
		single["data"] = body
		parts.append(single)
		return parts
	var boundary: String = ""
	for piece: String in content_type.split(";"):
		var clean: String = piece.strip_edges()
		if clean.to_lower().begins_with("boundary="):
			boundary = clean.substr(9).trim_prefix("\"").trim_suffix("\"")
	if boundary.is_empty(): return parts
	var delimiter: PackedByteArray = ("--" + boundary).to_ascii_buffer()
	var pos: int = _find_bytes(body, delimiter, 0)
	while pos >= 0:
		pos += delimiter.size()
		if pos + 2 <= body.size() and body[pos] == 45 and body[pos + 1] == 45: break
		var header_end: int = _find_bytes(body, "\r\n\r\n".to_ascii_buffer(), pos)
		if header_end < 0 or header_end - pos > 4096: break
		var part_headers: PackedStringArray = body.slice(pos, header_end).get_string_from_ascii().split("\r\n", false)
		var info: Dictionary = _content_range(_header(part_headers, "content-range"))
		var data_start: int = header_end + 4
		if info.is_empty() or data_start + int(info["length"]) > body.size(): break
		info["data"] = body.slice(data_start, data_start + int(info["length"]))
		parts.append(info)
		pos = _find_bytes(body, delimiter, data_start + int(info["length"]))
	return parts


# the file's bytes, decompressed, if this part holds all of its local header and
# data. empty if it does not, or if anything about it fails to check out.
static func extract_entry(part_start: int, data: PackedByteArray, entry: Dictionary) -> PackedByteArray:
	var local: int = int(entry["offset"]) - part_start
	if local < 0 or local + 30 > data.size() or data.decode_u32(local) != LOCAL_SIGNATURE:
		return PackedByteArray()
	var data_start: int = local + 30 + data.decode_u16(local + 26) + data.decode_u16(local + 28)
	var compressed: int = int(entry["compressed"])
	if data_start + compressed > data.size(): return PackedByteArray()
	var raw: PackedByteArray = data.slice(data_start, data_start + compressed)
	var size: int = int(entry["size"])
	if int(entry["method"]) == 0: return raw if raw.size() == size else PackedByteArray()
	if int(entry["method"]) != 8: return PackedByteArray()
	# Godot only inflates zlib or gzip streams, and ZIP stores raw deflate. A gzip
	# wrapper needs the CRC-32 and size in its trailer, both of which the ZIP
	# directory already has, so wrap it rather than carry an inflater in here.
	var gzip: = PackedByteArray([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff])
	gzip.append_array(raw)
	var trailer: = PackedByteArray()
	trailer.resize(8)
	trailer.encode_u32(0, int(entry["crc"]))
	trailer.encode_u32(4, size)
	gzip.append_array(trailer)
	var out: PackedByteArray = gzip.decompress(size, FileAccess.COMPRESSION_GZIP)
	return out if out.size() == size else PackedByteArray()


# dub_characters from a clip config's [data] section, the one key the base game
# reads it from. a value the scanner cannot read counts as no characters, the
# same as the game treating the clip as untagged.
static func characters_from_config(text: String) -> PackedStringArray:
	var found: PackedStringArray = []
	var section: String = ""
	var lines: PackedStringArray = text.replace("\r", "").split("\n")
	var i: int = 0
	while i < lines.size():
		var line: String = lines[i].strip_edges()
		i += 1
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2).strip_edges()
			continue
		if section != "data" or not line.begins_with("dub_characters"): continue
		var equals: int = line.find("=")
		if equals < 0 or line.substr(0, equals).strip_edges() != "dub_characters": continue
		var value: String = line.substr(equals + 1)
		while not (value.contains("]") or value.contains(")")) and i < lines.size() and i < 400:
			value += "\n" + lines[i]
			i += 1
		var strings: = RegEx.new()
		strings.compile("\"((?:[^\"\\\\]|\\\\.)*)\"")
		for m: RegExMatch in strings.search_all(value):
			var name: String = m.get_string(1).c_unescape().strip_edges()
			if not name.is_empty() and not found.has(name): found.append(name)
		return found
	return found


static func summarize(clips: int, config_texts: Array[String]) -> Dictionary:
	var characters: PackedStringArray = []
	var tagged: int = 0
	for text: String in config_texts:
		var names: PackedStringArray = characters_from_config(text)
		if not names.is_empty(): tagged += 1
		for name: String in names:
			if not characters.has(name): characters.append(name)
	return {"characters": characters, "clips": clips, "tagged_clips": tagged}


static func describe(result: Dictionary) -> String:
	if result.has("error"): return "Characters: could not count (%s)" % str(result["error"]).trim_suffix(".")
	var characters: PackedStringArray = result.get("characters", PackedStringArray())
	var clips: int = int(result.get("clips", 0))
	if characters.is_empty():
		return "Characters: none tagged. The %d clips will be split evenly between players." % clips
	var shown: PackedStringArray = characters.slice(0, 12)
	var names: String = ", ".join(shown)
	if characters.size() > shown.size(): names += ", and %d more" % (characters.size() - shown.size())
	var text: String = "%d character%s: %s" % [
		characters.size(), "" if characters.size() == 1 else "s", names]
	var tagged: int = int(result.get("tagged_clips", 0))
	if tagged < clips: text += "\n%d of %d clips are tagged; the rest are shared out evenly." % [tagged, clips]
	return text


static func _trusted_download_url(url: String) -> bool:
	if not url.begins_with("https://"): return false
	var host: String = url.substr(8).get_slice("/", 0).get_slice(":", 0).to_lower()
	return host == "gamebanana.com" or host.ends_with(".gamebanana.com")


static func _header(headers: PackedStringArray, name: String) -> String:
	var wanted: String = name.to_lower() + ":"
	for header: String in headers:
		if header.to_lower().begins_with(wanted): return header.substr(wanted.length()).strip_edges()
	return ""


static func _content_range(value: String) -> Dictionary:
	var parsed: = RegEx.new()
	parsed.compile("^bytes\\s+(\\d+)-(\\d+)/(\\d+|\\*)$")
	var m: RegExMatch = parsed.search(value.strip_edges())
	if m == null: return {}
	var start: int = m.get_string(1).to_int()
	var end: int = m.get_string(2).to_int()
	if end < start: return {}
	var total: int = m.get_string(3).to_int() if m.get_string(3) != "*" else 0
	return {"start": start, "length": end - start + 1, "total": total}


static func _find_bytes(haystack: PackedByteArray, needle: PackedByteArray, from: int) -> int:
	if needle.is_empty(): return -1
	var first: int = needle[0]
	var last_start: int = haystack.size() - needle.size()
	var pos: int = haystack.find(first, from)
	while pos >= 0 and pos <= last_start:
		if haystack.slice(pos, pos + needle.size()) == needle: return pos
		pos = haystack.find(first, pos + 1)
	return -1
