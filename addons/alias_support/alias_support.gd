class_name AliasSupport
extends Node
## The client of ALIAS, the anonymous support desk (docs/openapi.yaml): one coroutine a call, named as
## the spec's operationIds in snake_case, the same in every client. The product draws its own UI; the
## addon gives it AliasRedactor (the user paints over what shouldn't go in a screenshot) and AliasMarkdown
## (notes and answers as BBCode).
##
##   var alias := AliasSupport.new()
##   alias.url = "https://alias.help"
##   alias.key = PRODUCT_KEY
##   alias.context_provider = func() -> Dictionary: return {"level": level_name}
##   alias.telemetry_provider = func() -> Dictionary: return {"fps": Engine.get_frames_per_second()}
##   add_child(alias)
##   var r: Dictionary = await alias.report("The door won't open", get_viewport().get_texture().get_image())
##   await alias.report("It **crashed**", null, null, null, [{"name": "log.txt", "data": log_bytes}], "text/markdown")
##   alias.answered.connect(func(u: Dictionary): print("support answered ", u.ticket))
##   alias.watch()
##
## Every call returns {ok: bool, status: int (0: no answer), data: the JSON, error: the service's words}.
## The identity is the service's: the first call that needs one asks for it (POST /api/v1/identity) and
## keeps it in user:// (AliasIdentity: `kept`); calls made meanwhile wait for it. Live answers: polling
## /api/v1/updates every poll_every seconds, and natively a stream (/api/v1/events, Server-Sent Events by
## HTTPClient) besides; on the web and gasm (no streaming HTTP there) polling alone.
##
## Before a report or a reply goes, the product's redaction rules (GET /api/v1/product, asked once) are
## applied to its note, context and telemetry (AliasRedact); the service applies them again. Files go as
## multipart/form-data (each {name, data: PackedByteArray or Image}); a screenshot alone as before.

signal answered(update: Dictionary) # support answered or changed one of the user's tickets: {kind, ticket, status, at}
## A live ticket's events, from the stream: {kind: mode (it went live or back: `mode`), typing (support
## is: `name`), read (support read up to `at`), ticket, status, at}.
signal live(update: Dictionary)
signal identity_changed # made, moved in (a transfer, typed in), or forgotten (erased)

@export var url := ""
@export var key := ""
## The name the identity is kept under in user:// (several products in one game: one each).
@export var identity_name := "default"
@export var app_version := ""
## Seconds between polls while watching (also after the stream drops).
@export var poll_every := 60.0
## Stream answers where it can (natively); false: poll only.
@export var stream := true
## Apply the product's redaction rules here before sending (the service applies them anyway).
@export var redact := true

var context_provider := Callable() # () -> Dictionary: the product's context fields for a report
var telemetry_provider := Callable() # () -> Dictionary: its telemetry

var kept: AliasIdentity # (the identity as kept in user://)
var product: Dictionary = {} # (GET /api/v1/product's, once asked)
var _making := false
signal _made
var _watching := false
var _since := ""
var _seen := {}
var _sse: HTTPClient
var _sse_buf := ""
var _sse_state := 0 # 0 none, 1 connecting, 2 requested, 3 reading
var _poll_left := 0.0
var _retry_in := 0.0 # seconds before the stream connects again
var _retry_step := 1.0 # doubled per drop, to 60

func _ready() -> void:
	kept = AliasIdentity.load_for(identity_name)
	process_mode = Node.PROCESS_MODE_ALWAYS

# --- the identity ---

## The identity, asked of the service the first time: {ok, data: {id, secret}}.
func identity() -> Dictionary:
	if kept == null:
		kept = AliasIdentity.load_for(identity_name)
	if kept.has():
		return _ok({"id": kept.id, "secret": kept.secret})
	if _making:
		await _made
		return _ok({"id": kept.id, "secret": kept.secret}) if kept.has() else _fail(0, "no identity")
	_making = true
	var r: Dictionary = await new_identity()
	if r.ok:
		_keep(r.data)
	_making = false
	_made.emit()
	return r

## Forget the identity here (the next call gets a new one).
func forget() -> void:
	kept.clear()
	identity_changed.emit()

## Use an identity typed in (moved by hand): checked with the service before it's kept.
func use_identity(id: String, secret: String) -> Dictionary:
	var r: Dictionary = await _request(HTTPClient.METHOD_GET, "/api/v1/me", null, true, {"id": id.to_lower(), "secret": secret.to_lower()})
	if r.ok:
		_keep({"id": id.to_lower(), "secret": secret.to_lower()})
	return r

# --- the calls (docs/openapi.yaml's operationIds) ---

func get_product() -> Dictionary:
	var r: Dictionary = await _request(HTTPClient.METHOD_GET, "/api/v1/product", null, false)
	if r.ok and r.data is Dictionary:
		product = r.data
	return r

## A new identity from the service; if the product asks for proof of work (identity_challenge), it's
## done first: some thousands of SHA-256s, a batch a frame.
func new_identity() -> Dictionary:
	for tries in 2:
		var c: Dictionary = await identity_challenge()
		if not c.ok:
			return c
		var extra := PackedStringArray()
		var bits := int(c.data.get("bits", 0))
		if bits > 0:
			var ch := String(c.data.get("challenge", ""))
			extra.append("X-Alias-Work: " + ch + ":" + await solve_work(ch, bits))
		var r: Dictionary = await _request(HTTPClient.METHOD_POST, "/api/v1/identity", null, false, {}, extra)
		# (428: the challenge ran out of time, or the work asked for went up meanwhile: once more)
		if r.ok or r.status != 428 or tries > 0:
			return r
	return _fail(0, "no identity")

func identity_challenge() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/api/v1/identity/challenge", null, false)

## The proof of work: a nonce such that SHA-256(challenge:nonce) begins with `bits` zero bits.
func solve_work(challenge: String, bits: int) -> String:
	var n := 0
	while true:
		for i in 2048:
			var h := HashingContext.new()
			h.start(HashingContext.HASH_SHA256)
			h.update((challenge + ":" + str(n)).to_utf8_buffer())
			if _zero_bits(h.finish()) >= bits:
				return str(n)
			n += 1
		if is_inside_tree():
			await get_tree().process_frame
	return ""

static func _zero_bits(b: PackedByteArray) -> int:
	var n := 0
	for x in b:
		if x == 0:
			n += 8
			continue
		var m := 0x80
		while x & m == 0:
			n += 1
			m >>= 1
		return n
	return n

func me() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/api/v1/me")

## Erase the id and everything of it at the service, and forget it here.
func erase_me() -> Dictionary:
	var r: Dictionary = await _request(HTTPClient.METHOD_DELETE, "/api/v1/me")
	if r.ok:
		forget()
	return r

func my_data() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/api/v1/me/data")

func get_contact() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/api/v1/me/contact")

## Give a contact ("email" or "other"), only once the user agreed to `consent`: the product's
## contact_consent ({text, version}; or get_contact's consent), shown to them whole. The service records
## the consent with its text; one to an older text than the product's now is refused (409: ask again).
func set_contact(kind: String, value: String, consent: Dictionary) -> Dictionary:
	if String(consent.get("version", "")) == "":
		return _fail(0, "set_contact: the consent the user agreed to (contact_consent)")
	return await _request(HTTPClient.METHOD_PUT, "/api/v1/me/contact", {"kind": kind, "value": value,
		"consent": {"version": consent.version, "app_version": app_version}})

func withdraw_contact() -> Dictionary:
	return await _request(HTTPClient.METHOD_DELETE, "/api/v1/me/contact")

## A code (XXXX-XXXX) for the user to type on another device within 10 minutes.
func new_transfer() -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/api/v1/me/transfer")

## This device takes the identity a code names (with a secret of its own), and keeps it.
func claim_transfer(code: String) -> Dictionary:
	var r: Dictionary = await _request(HTTPClient.METHOD_POST, "/api/v1/transfer/claim", {"code": code}, false)
	if r.ok:
		_keep(r.data)
	return r

## A report: the note, a screenshot (an Image, JPEG bytes, or none), the context and telemetry from the
## providers unless given, files (each {name, data: PackedByteArray or Image}), the note's format
## ("text/plain", the default, or "text/markdown").
func report(note: String, screenshot: Variant = null, context: Variant = null, telemetry: Variant = null, attachments: Array = [], format := "") -> Dictionary:
	var b: Dictionary = await _body({"note": note, "app_version": app_version}, "note", format, screenshot, context, telemetry)
	return await _send_report("/api/v1/tickets", b, screenshot, attachments)

func tickets() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/api/v1/tickets")

func ticket(id: int) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/api/v1/tickets/%d" % id)

func reply(id: int, body: String, screenshot: Variant = null, context: Variant = null, telemetry: Variant = null, attachments: Array = [], format := "") -> Dictionary:
	var b: Dictionary = await _body({"body": body}, "body", format, screenshot, context, telemetry)
	return await _send_report("/api/v1/tickets/%d/comments" % id, b, screenshot, attachments)

## Ask to talk live: live at once if someone's at the desk (data.mode "live"), else asked for
## (data.live_requested_at). Offer it when get_product's live.user_may_ask; live.available says
## someone's there now.
func request_live(id: int) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/api/v1/tickets/%d/live" % id)

## Remote assistance requests still going, across the user's tickets ({remote: [...], offered}). Support
## asks for a shell (SSH) or the screen (VNC); nothing connects until the device accepts.
func remote_requests() -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/api/v1/remote")

## A ticket's remote assistance requests, all of them, newest first.
func ticket_remote(id: int) -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/api/v1/tickets/%d/remote" % id)

## The device's answer. Yes: data.relay is its side ({url, token}): dial url (WebSocketPeer, the token as
## ?token=) and bridge it to what the channel is on this device (StreamPeerTCP to 127.0.0.1:5900, your
## setting, never support's).
func answer_remote(ticket: int, id: String, accept: bool) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/api/v1/tickets/%d/remote/%s" % [ticket, id.uri_encode()], {"accept": accept})

## The device ends the session (or takes its yes back).
func end_remote(ticket: int, id: String) -> Dictionary:
	return await _request(HTTPClient.METHOD_DELETE, "/api/v1/tickets/%d/remote/%s" % [ticket, id.uri_encode()])

## The user is typing (a live ticket's): call it as they type; the service passes on one every 2 s.
func typing(id: int) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/api/v1/tickets/%d/typing" % id)

## The user has read the thread up to now: support sees it.
func mark_read(id: int) -> Dictionary:
	return await _request(HTTPClient.METHOD_POST, "/api/v1/tickets/%d/read" % id)

## One of the user's own attachments: {ok, data: PackedByteArray}.
func attachment(ticket_id: int, attachment_id: int) -> Dictionary:
	return await _send(HTTPClient.METHOD_GET, "/api/v1/tickets/%d/attachments/%d" % [ticket_id, attachment_id], PackedByteArray(), "", true, {}, true)

## What a report would send of the telemetry and context (the providers' unless given), the product's
## rules applied, and which of its removable paths are there for the user to take out:
## {ok, data: {telemetry, context, removable: [paths]}}. Take them out with remove_paths.
func preview_telemetry(telemetry: Variant = null, context: Variant = null) -> Dictionary:
	var p: Dictionary = await _product()
	var input := _gathered(context, telemetry)
	var out := AliasRedact.redact(p.get("redact", []), input)
	var removable := []
	for path in p.get("removable", []):
		if AliasRedact.has_path(out, String(path)):
			removable.append(path)
	return _ok({"telemetry": out.get("telemetry", {}), "context": out.get("context", {}), "removable": removable})

## The data without what's at these paths (/telemetry/… or /context/…; a path's root picks which of
## {context, telemetry} it's from: pass the telemetry, or the context, as data).
static func remove_paths(data: Dictionary, paths: Array) -> Dictionary:
	return AliasRedact.remove_paths(data, paths)

func updates(since := "") -> Dictionary:
	return await _request(HTTPClient.METHOD_GET, "/api/v1/updates" + ("?since=" + since.uri_encode() if since != "" else ""))

## The stream's state, for a product that shows it ("none", "connecting", "open"); `watch` runs it.
func events() -> String:
	return ["none", "connecting", "connecting", "open"][_sse_state]

# --- live answers ---

## Start watching: `answered` for each ticket support answers or changes from now on.
func watch() -> void:
	if _watching:
		return
	_watching = true
	_poll_left = 0.0
	_since = ""
	_retry_in = 0.0
	_retry_step = 1.0

func stop() -> void:
	_watching = false
	_close_sse()

func _process(delta: float) -> void:
	if not _watching:
		return
	_poll_left -= delta
	if _poll_left <= 0.0:
		_poll_left = poll_every
		_poll()
	if stream and _can_stream() and kept != null and kept.has():
		_pump_sse(delta)

func _poll() -> void:
	var r: Dictionary = await updates(_since)
	if not r.ok:
		return
	if _since != "": # (the first poll only says where to start)
		for u in r.data.get("updates", []):
			_emit(u)
	_since = String(r.data.get("now", ""))

func _emit(u: Dictionary) -> void:
	var k := "%s@%s" % [u.get("ticket"), u.get("at")]
	if _seen.has(k):
		return
	_seen[k] = true
	if _seen.size() > 500:
		_seen.clear()
	answered.emit(u)

static func _can_stream() -> bool:
	return not OS.has_feature("web") and not Engine.has_singleton("Gasm")

func _pump_sse(delta: float) -> void:
	if _sse_state == 0:
		_retry_in -= delta
		if _retry_in > 0.0:
			return
		var u := url.trim_suffix("/")
		var tls := u.begins_with("https://")
		var host := u.trim_prefix("https://").trim_prefix("http://")
		var port := 443 if tls else 80
		if host.contains(":"):
			port = host.get_slice(":", 1).to_int()
			host = host.get_slice(":", 0)
		_sse = HTTPClient.new()
		if _sse.connect_to_host(host, port, TLSOptions.client() if tls else null) != OK:
			_sse_drop()
			return
		_sse_state = 1
	_sse.poll()
	var st := _sse.get_status()
	match _sse_state:
		1:
			if st == HTTPClient.STATUS_CONNECTED:
				_sse.request(HTTPClient.METHOD_GET, "/api/v1/events", _headers(false, {}))
				_sse_state = 2
			elif st != HTTPClient.STATUS_CONNECTING and st != HTTPClient.STATUS_RESOLVING:
				_sse_drop()
		2:
			if st == HTTPClient.STATUS_BODY:
				if _sse.get_response_code() != 200:
					_sse_drop()
					return
				_sse_state = 3
				_retry_step = 1.0
				_poll() # (anything missed while it was down)
			elif st != HTTPClient.STATUS_REQUESTING:
				_sse_drop()
		3:
			if st != HTTPClient.STATUS_BODY:
				_sse_drop()
				return
			var chunk := _sse.read_response_body_chunk()
			if chunk.size() > 0:
				_sse_buf += chunk.get_string_from_utf8().replace("\r\n", "\n")
				var i := _sse_buf.find("\n\n")
				while i >= 0:
					var block := _sse_buf.substr(0, i)
					_sse_buf = _sse_buf.substr(i + 2)
					var ev := "message"
					var data := ""
					for line in block.split("\n"):
						if line.begins_with("event:"):
							ev = line.substr(6).strip_edges()
						elif line.begins_with("data:"):
							data += line.substr(5).strip_edges()
					if ev in ["answer", "mode", "typing", "read"] and data != "":
						var u: Variant = JSON.parse_string(data)
						if u is Dictionary:
							u["kind"] = ev
							if ev == "answer":
								_emit(u)
							else:
								live.emit(u)
					i = _sse_buf.find("\n\n")

func _sse_drop() -> void:
	_close_sse()
	_retry_in = _retry_step
	_retry_step = minf(_retry_step * 2.0, 60.0)

func _close_sse() -> void:
	if _sse != null:
		_sse.close()
	_sse = null
	_sse_state = 0
	_sse_buf = ""

# --- the wire ---

func _keep(d: Variant) -> void:
	if d is Dictionary and AliasIdentity.valid(String(d.get("id", "")), String(d.get("secret", ""))):
		kept.id = String(d.id)
		kept.secret = String(d.secret)
		kept.save()
		identity_changed.emit()

## The product's settings, asked once ({} if it can't be had: the service redacts anyway).
func _product() -> Dictionary:
	if product.is_empty():
		await get_product()
	return product

func _gathered(context: Variant, telemetry: Variant) -> Dictionary:
	var out := {}
	var c: Variant = context if context != null else (context_provider.call() if context_provider.is_valid() else null)
	var t: Variant = telemetry if telemetry != null else (telemetry_provider.call() if telemetry_provider.is_valid() else null)
	if c is Dictionary:
		out["context"] = c
	if t is Dictionary:
		out["telemetry"] = t
	return out

## A report's or a reply's JSON, the rules applied (text: "note" or "body", the field the text is in).
func _body(base: Dictionary, text: String, format: String, screenshot: Variant, context: Variant, telemetry: Variant) -> Dictionary:
	var input := _gathered(context, telemetry)
	input["note"] = base[text]
	if redact:
		var p: Dictionary = await _product()
		input = AliasRedact.redact(p.get("redact", []), input)
	base[text] = input.get("note", "")
	for k in ["context", "telemetry"]:
		if input.has(k):
			base[k] = input[k]
	if format != "":
		base["format"] = format
	return base

## JSON (a screenshot alone in it, base64, as servers before attachments take it), or multipart/form-data
## with the files.
func _send_report(path: String, base: Dictionary, screenshot: Variant, attachments: Array) -> Dictionary:
	if attachments.is_empty():
		var shot := _jpeg(screenshot)
		if shot != "":
			base["screenshot"] = shot
		return await _request(HTTPClient.METHOD_POST, path, base)
	var files := []
	if screenshot != null:
		var shot := _jpeg(screenshot)
		if shot != "":
			files.append({"name": "screenshot.jpg", "data": Marshalls.base64_to_raw(shot)})
	for a in attachments:
		if a is Dictionary:
			var d: Variant = a.get("data")
			if d is Image:
				d = Marshalls.base64_to_raw(_jpeg(d))
			files.append({"name": String(a.get("name", "attachment")), "data": d})
	var boundary := "alias-" + str(randi()) + str(Time.get_ticks_usec())
	return await _send(HTTPClient.METHOD_POST, path, multipart(base, files, boundary), "multipart/form-data; boundary=" + boundary)

## A multipart/form-data body: the part report (the JSON), then a part attachment per file.
static func multipart(report: Dictionary, files: Array, boundary: String) -> PackedByteArray:
	var out := PackedByteArray()
	out.append_array(("--%s\r\nContent-Disposition: form-data; name=\"report\"\r\nContent-Type: application/json\r\n\r\n" % boundary).to_utf8_buffer())
	out.append_array(json(report).to_utf8_buffer())
	for f in files:
		var name := String(f.name).replace("\"", "").replace("\r", "").replace("\n", "")
		out.append_array(("\r\n--%s\r\nContent-Disposition: form-data; name=\"attachment\"; filename=\"%s\"\r\nContent-Type: application/octet-stream\r\n\r\n" % [boundary, name]).to_utf8_buffer())
		out.append_array(f.data)
	out.append_array(("\r\n--%s--\r\n" % boundary).to_utf8_buffer())
	return out

static func _jpeg(s: Variant) -> String:
	if s is Image:
		var img: Image = s
		if img.is_compressed():
			img = img.duplicate()
			img.decompress()
		return Marshalls.raw_to_base64(img.save_jpg_to_buffer(0.85))
	if s is PackedByteArray and (s as PackedByteArray).size() > 0:
		return Marshalls.raw_to_base64(s)
	return ""

func _headers(ctype: Variant, who: Dictionary) -> PackedStringArray:
	var h := PackedStringArray(["X-Alias-Key: " + key, "Accept: application/json"])
	var i: String = who.get("id", kept.id if kept != null else "")
	var s: String = who.get("secret", kept.secret if kept != null else "")
	if i != "":
		h.append("X-Alias-User: " + i)
		h.append("X-Alias-Secret: " + s)
	if ctype is bool and ctype:
		h.append("Content-Type: application/json")
	elif ctype is String and ctype != "":
		h.append("Content-Type: " + ctype)
	return h

## One request: {ok, status, data, error}. With the user (as): the identity first (made if need be).
func _request(method: int, path: String, body: Variant = null, as_user := true, who := {}, extra := PackedStringArray()) -> Dictionary:
	var raw := json(body).to_utf8_buffer() if body != null else PackedByteArray()
	return await _send(method, path, raw, "application/json" if body != null else "", as_user, who, false, extra)

## One request with a body of this type ("": none); binary: data is the answer's bytes, not its JSON.
func _send(method: int, path: String, body: PackedByteArray, ctype: String, as_user := true, who := {}, binary := false, extra := PackedStringArray()) -> Dictionary:
	if as_user and who.is_empty():
		var idr: Dictionary = await identity()
		if not idr.ok:
			return idr
	var headers := _headers(ctype, who) if as_user else PackedStringArray(["X-Alias-Key: " + key, "Accept: application/json"] + (["Content-Type: " + ctype] if ctype != "" else []))
	headers.append_array(extra)
	var req := HTTPRequest.new()
	req.timeout = 30.0
	add_child(req)
	if req.request_raw(url.trim_suffix("/") + path, headers, method, body) != OK:
		req.queue_free()
		return _fail(0, "couldn't send")
	var got: Array = await req.request_completed
	req.queue_free()
	var result: int = got[0]
	var code: int = got[1]
	var raw: PackedByteArray = got[3]
	if result != HTTPRequest.RESULT_SUCCESS:
		return _fail(0, "no answer")
	if binary and code >= 200 and code < 300:
		return {"ok": true, "status": code, "data": raw, "error": ""}
	var data: Variant = JSON.parse_string(raw.get_string_from_utf8()) if raw.size() > 0 else null
	if code < 200 or code >= 300:
		var f := _fail(code, String(data.get("error", "HTTP %d" % code)) if data is Dictionary else "HTTP %d" % code)
		if data is Dictionary:
			# key_revoked: this build's key was revoked; reason: support's words for the player, to show as they are
			f["code"] = String(data.get("code", ""))
			f["reason"] = String(data.get("reason", ""))
		return f
	return {"ok": true, "status": code, "data": data, "error": ""}

## JSON as the service reads it: a whole number as one (GDScript's JSON numbers are floats, and
## JSON.stringify would write 365.0 where an integer's wanted).
static func json(v: Variant) -> String:
	return JSON.stringify(_whole(v))

static func _whole(v: Variant) -> Variant:
	if typeof(v) == TYPE_FLOAT and v == floorf(v) and absf(v) < 9.0e15:
		return int(v)
	if v is Dictionary:
		var d := {}
		for k in v:
			d[k] = _whole(v[k])
		return d
	if v is Array:
		var a := []
		for x in v:
			a.append(_whole(x))
		return a
	return v

static func _ok(d: Variant) -> Dictionary:
	return {"ok": true, "status": 200, "data": d, "error": ""}

static func _fail(code: int, why: String) -> Dictionary:
	return {"ok": false, "status": code, "data": null, "error": why}
