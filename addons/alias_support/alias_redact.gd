class_name AliasRedact
extends RefCounted
## A product's redaction rules (GET /api/v1/product: `redact`), applied before anything leaves the device,
## as the service applies them again as it comes in (internal/desk/redact.go; docs/redact-vectors.json
## holds every client to the same results). Each strategy is idempotent: twice is once.
##
##   var out := AliasRedact.redact(product.redact, {"note": note, "context": ctx, "telemetry": tel})
##
## A rule's path: /telemetry/… (a JSON pointer, ~1 for /, ~0 for ~; * every key or element),
## /context/<field>, or /note. Skipped here: `server_only` rules (hash: its secret is the service's) and
## strategies this client doesn't know. `client:<name>` is the app's own: AliasRedact.register_redactor.

## What a custom redactor returns to drop the value.
const DROP := &"__alias_drop__"
const MASK := "•"

static var _custom := {}

## The app's own strategy, for rules saying client:<name>: f(value: Variant, rule: Dictionary) -> Variant
## (the value redacted, or AliasRedact.DROP). An empty Callable takes it away again: do that before the
## object f is bound to goes (a static's Callable outliving its object crashes Godot at exit).
static func register_redactor(name: String, f: Callable) -> void:
	if f.is_valid():
		_custom[name] = f
	else:
		_custom.erase(name)

## The input ({note, context, telemetry}; any may be missing) with the rules applied, in order, to a copy.
## A context or telemetry left empty is left out.
static func redact(rules: Array, input: Dictionary) -> Dictionary:
	var out := input.duplicate(true)
	for r in rules:
		if not (r is Dictionary):
			continue
		var rule: Dictionary = r
		var strategy := String(rule.get("strategy", ""))
		if bool(rule.get("server_only", false)) or strategy == "hash":
			continue
		var f := _strategy(strategy, rule)
		if not f.is_valid():
			continue
		var segs := _path(String(rule.get("path", "")))
		if segs.is_empty():
			continue
		match segs[0]:
			"note":
				if out.has("note"):
					var v: Variant = f.call(out.note)
					if not (v is StringName and v == DROP):
						out.note = String(v) if v is String else ""
			"context", "telemetry":
				var root: String = segs[0]
				if out.get(root) is Dictionary:
					var m: Variant = _root(out[root], segs.slice(1), f)
					if m == null:
						out.erase(root)
					else:
						out[root] = m
	return out

## The value at each of these paths taken out of a copy of the telemetry (or context), as `drop` would:
## what the user chose not to send of the product's removable fields.
static func remove_paths(data: Dictionary, paths: Array) -> Dictionary:
	var out: Dictionary = data.duplicate(true)
	var drop := func(_v: Variant) -> Variant: return DROP
	for p in paths:
		var segs := _path(String(p))
		if segs.size() < 2:
			continue
		var m: Variant = _root(out, segs.slice(1), drop)
		out = m if m is Dictionary else {}
	return out

## Whether anything is at this path (/telemetry/… or /context/…) of {context, telemetry}.
static func has_path(input: Dictionary, path: String) -> bool:
	var segs := _path(path)
	if segs.size() < 2 or not (input.get(segs[0]) is Dictionary):
		return false
	return _has(input[segs[0]], segs.slice(1))

# --- paths ---

## A path's segments, its root first; [] if it isn't one.
static func _path(p: String) -> Array:
	if not p.begins_with("/"):
		return []
	var segs := []
	for s in p.substr(1).split("/"):
		segs.append(s.replace("~1", "/").replace("~0", "~"))
	var root: String = segs[0]
	if (root == "note" and segs.size() == 1) or root == "telemetry" or (root == "context" and segs.size() >= 2):
		return segs
	return []

static func _root(m: Dictionary, segs: Array, f: Callable) -> Variant:
	if segs.is_empty() or (segs.size() == 1 and segs[0] == ""):
		var v: Variant = f.call(m)
		if v is StringName and v == DROP:
			return null
		return v if v is Dictionary else m
	var out: Variant = _at(m, segs, f)
	if not (out is Dictionary) or (out as Dictionary).is_empty():
		return null
	return out

## v with f applied where segs lead; DROP: v itself dropped.
static func _at(v: Variant, segs: Array, f: Callable) -> Variant:
	if segs.is_empty():
		return f.call(v)
	var s: String = segs[0]
	var rest := segs.slice(1)
	if v is Dictionary:
		var d: Dictionary = v
		for k in d.keys():
			if s != "*" and s != str(k):
				continue
			var nv: Variant = _at(d[k], rest, f)
			if nv is StringName and nv == DROP:
				d.erase(k)
			else:
				d[k] = nv
		return d
	if v is Array:
		# dropped: gone under *, null at an index (so a second pass drops nothing more)
		var out := []
		for i in (v as Array).size():
			var x: Variant = v[i]
			if s == "*":
				var nv: Variant = _at(x, rest, f)
				if not (nv is StringName and nv == DROP):
					out.append(nv)
			elif s == str(i):
				var nv: Variant = _at(x, rest, f)
				out.append(null if (nv is StringName and nv == DROP) else nv)
			else:
				out.append(x)
		return out
	return v

static func _has(v: Variant, segs: Array) -> bool:
	if segs.is_empty():
		return true
	var s: String = segs[0]
	if v is Dictionary:
		for k in (v as Dictionary).keys():
			if (s == "*" or s == str(k)) and _has(v[k], segs.slice(1)):
				return true
	elif v is Array:
		for i in (v as Array).size():
			if (s == "*" or s == str(i)) and _has(v[i], segs.slice(1)):
				return true
	return false

# --- the strategies ---

static func _strategy(name: String, rule: Dictionary) -> Callable:
	match name:
		"drop":
			return func(_v: Variant) -> Variant: return DROP
		"mask":
			return _mask.bind(int(rule.get("keep", 0)))
		"truncate":
			return _truncate.bind(int(rule.get("max", 0)))
		"round":
			return _round.bind(float(rule.get("step", 0.0)))
		"coarsen":
			return _coarsen.bind(int(rule.get("digits", 0)))
		"regex":
			var re := RegEx.create_from_string(String(rule.get("pattern", "")))
			if re == null or not re.is_valid():
				return Callable()
			var with := String(rule.get("replace", ""))
			return _regex.bind(re, with if with != "" else "[redacted]")
	if name.begins_with("client:") and _custom.has(name.substr(7)):
		var f: Callable = _custom[name.substr(7)]
		return func(v: Variant) -> Variant: return f.call(v, rule)
	return Callable()

static func _is_number(v: Variant) -> bool:
	return typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT

## A text, or a number or bool as text (a number as Go writes it: 98765, 1.5).
static func _leaf(v: Variant) -> Variant:
	match typeof(v):
		TYPE_STRING, TYPE_STRING_NAME:
			return String(v)
		TYPE_INT:
			return str(v)
		TYPE_FLOAT:
			var f: float = v
			if f == floorf(f) and absf(f) < 1e15:
				return "%d" % int(f)
			return String.num(f)
		TYPE_BOOL:
			return "true" if v else "false"
	return null

## ••••, then the last `keep` characters (leading • not counted: so twice is once).
static func _mask(v: Variant, keep: int) -> Variant:
	var s: Variant = _leaf(v)
	if s == null:
		return v
	var t: String = s
	while t.begins_with(MASK):
		t = t.substr(1)
	var k := mini(keep, t.length())
	return MASK.repeat(4) + t.substr(t.length() - k)

static func _truncate(v: Variant, n: int) -> Variant:
	if v is String and (v as String).length() > n:
		return (v as String).substr(0, n)
	return v

static func _decimals(step: float) -> int:
	var s := String.num(step)
	return s.length() - s.find(".") - 1 if s.contains(".") else 0

static func _round(v: Variant, step: float) -> Variant:
	if not _is_number(v) or step <= 0.0:
		return v
	var r: float = round(float(v) / step) * step
	return String.num(r, _decimals(step)).to_float()

static func _coarsen(v: Variant, digits: int) -> Variant:
	var p := pow(10.0, digits)
	if _is_number(v):
		return round(float(v) * p) / p
	if v is Dictionary:
		for k in ["lat", "lon"]:
			if _is_number(v.get(k)):
				v[k] = round(float(v[k]) * p) / p
	return v

## Every match in every text under the value replaced, literally.
static func _regex(v: Variant, re: RegEx, with: String) -> Variant:
	if v is String:
		var out := ""
		var at := 0
		for m in re.search_all(v):
			out += (v as String).substr(at, m.get_start() - at) + with
			at = m.get_end()
		return out + (v as String).substr(at)
	if v is Dictionary:
		for k in (v as Dictionary).keys():
			v[k] = _regex(v[k], re, with)
	elif v is Array:
		for i in (v as Array).size():
			v[i] = _regex(v[i], re, with)
	return v
