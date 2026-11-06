class_name AliasMarkdown
extends RefCounted
## A note or comment as BBCode for a RichTextLabel (bbcode_enabled), by its format (docs/openapi.yaml,
## Format): text/markdown is CommonMark's common part with GFM's tables, strikethrough and autolinks;
## text/plain is the text as it is. Whatever the user wrote stays text: every [ is escaped, so a note
## can't bring tags of its own. Links only to http, https and mailto; images only the report's own
## attachments (![](attachment:name)), never a remote one (it'd tell a server the user's address).
##
##   label.text = AliasMarkdown.to_bbcode(entry.body, entry.format, func(name): return "user://alias/" + name)
##   AliasMarkdown.render(label, entry.body, entry.format, func(name): return textures.get(name)) # Texture2D

const PLAIN := "text/plain"
const MARKDOWN := "text/markdown"

## BBCode. image_path(name) -> String: a res:// or user:// path for an attachment's image ("" or no
## callback: its alt text instead).
static func to_bbcode(text: String, format := MARKDOWN, image_path := Callable()) -> String:
	var out := ""
	for seg in segments(text, format):
		if seg is String:
			out += seg
		else:
			var p := String(image_path.call(seg.image)) if image_path.is_valid() else ""
			if p != "" and _safe_path.search(p) != null:
				out += "[img]" + p + "[/img]"
			else:
				out += escape(seg.alt)
	return out

## Into the label (cleared first). texture(name) -> Texture2D or null: an attachment's image.
static func render(label: RichTextLabel, text: String, format := MARKDOWN, texture := Callable()) -> void:
	label.clear()
	for seg in segments(text, format):
		if seg is String:
			label.append_text(seg)
		else:
			var t: Variant = texture.call(seg.image) if texture.is_valid() else null
			if t is Texture2D:
				label.add_image(t, mini((t as Texture2D).get_width(), 480))
			else:
				label.append_text(escape(seg.alt))

## The BBCode in pieces: Strings, and {image: name, alt} where an attachment's image goes.
static func segments(text: String, format := MARKDOWN) -> Array:
	var out := []
	if format != MARKDOWN:
		out.append(escape(text))
		return out
	_blocks(text.replace("\r\n", "\n").split("\n"), out)
	return _merge(out)

## Text as BBCode shows it: [ and ] escaped.
static func escape(s: String) -> String:
	return s.replace("[", "\u0001").replace("]", "[rb]").replace("\u0001", "[lb]")

static var _safe_path := RegEx.create_from_string("^(res|user)://[A-Za-z0-9._/-]+$")
static var _heading := RegEx.create_from_string("^(#{1,6})\\s+(.*?)\\s*#*\\s*$")
static var _bullet := RegEx.create_from_string("^\\s{0,3}[-*+]\\s+(.*)$")
static var _ordered := RegEx.create_from_string("^\\s{0,3}(\\d{1,9})[.)]\\s+(.*)$")
static var _rule := RegEx.create_from_string("^\\s{0,3}([-*_])(\\s*\\1){2,}\\s*$")
static var _table_sep := RegEx.create_from_string("^\\s*\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?\\s*$")
static var _autolink := RegEx.create_from_string("^(https?://[^\\s<>\\[\\]]*[^\\s<>\\[\\].,:;!?)'\"])")
const _SIZES := [0, 26, 22, 19, 17, 16, 15]

static func _merge(a: Array) -> Array:
	var out := []
	for x in a:
		if x is String and out.size() > 0 and out[-1] is String:
			out[-1] += x
		else:
			out.append(x)
	return out

static func _blank(l: String) -> bool:
	return l.strip_edges() == ""

## The block structure, line by line, into out (separated by blank lines as paragraphs are).
static func _blocks(lines: PackedStringArray, out: Array) -> void:
	var i := 0
	var first := true
	while i < lines.size():
		var l := lines[i]
		if _blank(l):
			i += 1
			continue
		if not first:
			out.append("\n\n")
		first = false
		var fence := l.strip_edges(true, false)
		if fence.begins_with("```") or fence.begins_with("~~~"):
			var mark := fence.substr(0, 3)
			var code := []
			i += 1
			while i < lines.size() and not lines[i].strip_edges().begins_with(mark):
				code.append(lines[i])
				i += 1
			i += 1
			out.append("[code]" + escape("\n".join(code)) + "[/code]")
			continue
		var h := _heading.search(l)
		if h != null:
			var n := h.get_string(1).length()
			out.append("[font_size=%d][b]" % _SIZES[n])
			_inline(h.get_string(2), out)
			out.append("[/b][/font_size]")
			i += 1
			continue
		if _rule.search(l) != null:
			out.append("[center]────────[/center]")
			i += 1
			continue
		if l.strip_edges(true, false).begins_with(">"):
			var inner := PackedStringArray()
			while i < lines.size() and not _blank(lines[i]) and lines[i].strip_edges(true, false).begins_with(">"):
				var q := lines[i].strip_edges(true, false).substr(1)
				inner.append(q.substr(1) if q.begins_with(" ") else q)
				i += 1
			out.append("[indent][color=#888888]┃[/color] ")
			_blocks(inner, out)
			out.append("[/indent]")
			continue
		if _bullet.search(l) != null or _ordered.search(l) != null:
			var ordered := _bullet.search(l) == null
			var re := _ordered if ordered else _bullet
			out.append("[ol]" if ordered else "[ul]")
			var items := 0
			while i < lines.size() and re.search(lines[i]) != null:
				if items > 0:
					out.append("\n")
				var m := re.search(lines[i])
				_inline(m.get_string(2 if ordered else 1), out)
				items += 1
				i += 1
				while i < lines.size() and not _blank(lines[i]) and re.search(lines[i]) == null and lines[i].begins_with("  "):
					out.append(" ")
					_inline(lines[i].strip_edges(), out)
					i += 1
			out.append("[/ol]" if ordered else "[/ul]")
			continue
		if l.contains("|") and i + 1 < lines.size() and _table_sep.search(lines[i + 1]) != null:
			var head := _cells(l)
			out.append("[table=%d]" % head.size())
			for c in head:
				out.append("[cell][b]")
				_inline(c, out)
				out.append("[/b][/cell]")
			i += 2
			while i < lines.size() and not _blank(lines[i]) and lines[i].contains("|"):
				var row := _cells(lines[i])
				for k in head.size():
					out.append("[cell]")
					_inline(row[k] if k < row.size() else "", out)
					out.append("[/cell]")
				i += 1
			out.append("[/table]")
			continue
		# a paragraph: to a blank line or another block
		var para := []
		while i < lines.size() and not _blank(lines[i]):
			var p := lines[i]
			if para.size() > 0 and (_heading.search(p) != null or p.strip_edges(true, false).begins_with(">") or p.strip_edges(true, false).begins_with("```")
					or _bullet.search(p) != null or _ordered.search(p) != null):
				break
			para.append(p)
			i += 1
		for k in para.size():
			var p: String = para[k]
			var hard := p.ends_with("  ") or p.ends_with("\\")
			_inline(p.strip_edges().trim_suffix("\\"), out)
			if k < para.size() - 1:
				out.append("\n" if hard else " ")

static func _cells(l: String) -> Array:
	var s := l.strip_edges()
	s = s.trim_prefix("|").trim_suffix("|")
	var out := []
	for c in s.split("|"):
		out.append(c.strip_edges())
	return out

## A line's inline syntax into out: code spans, images, links, autolinks, emphasis, escapes.
static func _inline(s: String, out: Array) -> void:
	var i := 0
	var text := ""
	while i < s.length():
		var c := s[i]
		if c == "\\" and i + 1 < s.length() and "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".contains(s[i + 1]):
			text += s[i + 1]
			i += 2
			continue
		if c == "`":
			var n := 1
			while i + n < s.length() and s[i + n] == "`":
				n += 1
			var close := s.find("`".repeat(n), i + n)
			if close > 0:
				_flush(out, text); text = ""
				out.append("[code]" + escape(s.substr(i + n, close - i - n).strip_edges()) + "[/code]")
				i = close + n
				continue
		if c == "!" and i + 1 < s.length() and s[i + 1] == "[":
			var l := _link_at(s, i + 1)
			if not l.is_empty():
				_flush(out, text); text = ""
				var dest: String = l.dest
				if dest.begins_with("attachment:") and dest.length() > 11:
					out.append({"image": dest.substr(11), "alt": l.text})
				else:
					out.append(escape(l.text)) # never a remote image
				i = l.end
				continue
		if c == "[":
			var l := _link_at(s, i)
			if not l.is_empty():
				_flush(out, text); text = ""
				var dest: String = l.dest
				if dest.begins_with("http://") or dest.begins_with("https://") or dest.begins_with("mailto:"):
					out.append("[url=" + _url(dest) + "]")
					_inline(l.text, out)
					out.append("[/url]")
				else:
					_inline(l.text, out)
				i = l.end
				continue
		if c == "<":
			var close := s.find(">", i)
			if close > 0:
				var u := s.substr(i + 1, close - i - 1)
				if (u.begins_with("http://") or u.begins_with("https://") or u.begins_with("mailto:")) and not u.contains(" "):
					_flush(out, text); text = ""
					out.append("[url=" + _url(u) + "]" + escape(u) + "[/url]")
					i = close + 1
					continue
		if c == "h" and (i == 0 or " \t(*_~".contains(s[i - 1])):
			var m := _autolink.search(s.substr(i))
			if m != null:
				_flush(out, text); text = ""
				var u := m.get_string(1)
				out.append("[url=" + _url(u) + "]" + escape(u) + "[/url]")
				i += u.length()
				continue
		if c == "*" or c == "_" or c == "~":
			var d := c
			if i + 1 < s.length() and s[i + 1] == c:
				d = c + c
			if d == "~":
				text += c
				i += 1
				continue
			var close := _closing(s, i + d.length(), d)
			var intraword := c == "_" and i > 0 and s[i - 1].is_valid_identifier()
			if close > 0 and not intraword:
				_flush(out, text); text = ""
				var tag := "s" if d == "~~" else ("b" if d.length() == 2 else "i")
				out.append("[" + tag + "]")
				_inline(s.substr(i + d.length(), close - i - d.length()), out)
				out.append("[/" + tag + "]")
				i = close + d.length()
				continue
		text += c
		i += 1
	_flush(out, text)

static func _flush(out: Array, text: String) -> void:
	if text != "":
		out.append(escape(text))

## Where the closing delimiter is (-1: none): not right after the opening, not after a space.
static func _closing(s: String, from: int, d: String) -> int:
	if from >= s.length() or s[from] == " ":
		return -1
	var j := from + 1
	while j <= s.length() - d.length():
		if s.substr(j, d.length()) == d and s[j - 1] != " " and s[j - 1] != "\\":
			if d.length() == 1 and j + 1 < s.length() and s[j + 1] == d:
				j += 2
				continue
			return j
		j += 1
	return -1

## A link's [text](dest) at i: {text, dest, end}, or {}.
static func _link_at(s: String, i: int) -> Dictionary:
	var depth := 0
	var j := i
	while j < s.length():
		if s[j] == "\\":
			j += 2
			continue
		if s[j] == "[":
			depth += 1
		elif s[j] == "]":
			depth -= 1
			if depth == 0:
				break
		j += 1
	if j >= s.length() or j + 1 >= s.length() or s[j + 1] != "(":
		return {}
	var close := s.find(")", j + 2)
	if close < 0:
		return {}
	var dest := s.substr(j + 2, close - j - 2).strip_edges()
	if dest.contains(" "):
		dest = dest.get_slice(" ", 0) # (a title after it: left out)
	return {"text": s.substr(i + 1, j - i - 1), "dest": dest.trim_prefix("<").trim_suffix(">"), "end": close + 1}

## A URL safe inside [url=…]: no brackets or spaces.
static func _url(u: String) -> String:
	return u.replace("[", "%5B").replace("]", "%5D").replace(" ", "%20")
