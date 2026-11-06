class_name AliasRedactor
extends Control
## The user hides what shouldn't go (a name, a chat, a face) before a screenshot is sent: solid boxes
## and a thick brush, painted into the pixels. No blur or pixelation (they can be undone). The result is a
## new Image, flattened: nothing under the paint is kept, and AliasRedactor.jpeg/png encode it with no
## metadata.
##
##   var r := AliasRedactor.open(self, get_viewport().get_texture().get_image())
##   var img: Image = await r.finished # null: cancelled
##   if img: await alias.report(note, null, null, null, [{"name": "screen.jpg", "data": AliasRedactor.jpeg(img)}])
##
## The ops (a box: {kind: "box", rect: Rect2i}; a stroke: {kind: "brush", points: PackedVector2Array,
## radius}) are in the image's pixels; AliasRedactor.apply paints them, so the model runs headless.

signal done(image: Image)
signal cancelled
signal finished(image: Variant) # done's image, or null when cancelled

const BOX := "box"
const BRUSH := "brush"

@export var paint := Color.BLACK
@export var brush_radius := 18.0 # in the image's pixels

var source: Image
var ops: Array = []
var tool := BOX

var _view: TextureRect
var _tex: ImageTexture
var _drag: Variant = null # the op being drawn
var _start := Vector2.ZERO
var _tools := {}

## A redactor over the parent (full rect), for this image.
static func open(parent: Node, image: Image) -> AliasRedactor:
	var r := AliasRedactor.new()
	r.source = image
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	parent.add_child(r)
	return r

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.85)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 8)
	add_child(box)
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(bar)
	_tools[BOX] = _button(bar, "Box", func() -> void: _set_tool(BOX), true)
	_tools[BRUSH] = _button(bar, "Brush", func() -> void: _set_tool(BRUSH), true)
	_button(bar, "Undo", undo)
	_button(bar, "Clear", clear)
	_button(bar, "Cancel", cancel)
	var ok := _button(bar, "Done", finish)
	ok.add_theme_color_override("font_color", Color(0.6, 1, 0.6))
	_view = TextureRect.new()
	_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.gui_input.connect(_canvas_input)
	_view.draw.connect(_draw_drag)
	box.add_child(_view)
	_set_tool(tool)
	_refresh()
	grab_focus()

func _button(bar: HBoxContainer, text: String, f: Callable, toggle := false) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = toggle
	b.pressed.connect(f)
	bar.add_child(b)
	return b

func _set_tool(t: String) -> void:
	tool = t
	for k in _tools:
		_tools[k].set_pressed_no_signal(k == t)

# --- the model ---

func add_op(op: Dictionary) -> void:
	ops.append(op)
	_refresh()

func undo() -> void:
	if ops.size() > 0:
		ops.pop_back()
		_refresh()

func clear() -> void:
	ops.clear()
	_refresh()

## The image with the ops painted in: a new one, RGB8 (no alpha left to see through).
func result() -> Image:
	return apply(source, ops, paint)

func finish() -> void:
	var img := result()
	done.emit(img)
	finished.emit(img)
	queue_free()

func cancel() -> void:
	cancelled.emit()
	finished.emit(null)
	queue_free()

## The ops painted into a copy of the image.
static func apply(image: Image, list: Array, colour := Color.BLACK) -> Image:
	var img := image.duplicate() as Image
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGB8)
	var c := Color(colour.r, colour.g, colour.b, 1.0)
	var bounds := Rect2i(Vector2i.ZERO, img.get_size())
	for op in list:
		match String(op.get("kind", "")):
			BOX:
				var r: Rect2i = (op.rect as Rect2i).abs().intersection(bounds)
				if r.has_area():
					img.fill_rect(r, c)
			BRUSH:
				var pts: PackedVector2Array = op.points
				var rad := maxf(1.0, float(op.get("radius", 18.0)))
				for i in pts.size():
					var a := pts[i]
					var b := pts[i + 1] if i + 1 < pts.size() else a
					var steps := maxi(1, ceili(a.distance_to(b) / (rad * 0.5)))
					for s in steps + 1:
						_dot(img, a.lerp(b, float(s) / steps), rad, c, bounds)
	return img

static func _dot(img: Image, at: Vector2, rad: float, c: Color, bounds: Rect2i) -> void:
	var r := int(ceil(rad))
	for dy in range(-r, r + 1):
		var w := int(sqrt(maxf(0.0, rad * rad - dy * dy)))
		var row := Rect2i(int(at.x) - w, int(at.y) + dy, 2 * w + 1, 1).intersection(bounds)
		if row.has_area():
			img.fill_rect(row, c)

## Encoded with nothing but its pixels (Godot writes no EXIF).
static func jpeg(image: Image, quality := 0.85) -> PackedByteArray:
	return image.save_jpg_to_buffer(quality)

static func png(image: Image) -> PackedByteArray:
	return image.save_png_to_buffer()

# --- the canvas ---

func _refresh() -> void:
	if _view == null or source == null:
		return
	var img := result()
	if _tex == null or _tex.get_size() != Vector2(img.get_size()):
		_tex = ImageTexture.create_from_image(img)
		_view.texture = _tex
	else:
		_tex.update(img)
	_view.queue_redraw()

## Where the image is drawn in the view: its offset and scale.
func _fit() -> Array:
	var vs := _view.size
	var is_ := Vector2(source.get_size())
	var k := minf(vs.x / is_.x, vs.y / is_.y)
	return [(vs - is_ * k) / 2.0, k]

func _to_image(p: Vector2) -> Vector2:
	var f := _fit()
	var o: Vector2 = f[0]
	var k: float = f[1]
	return (p - o) / k

func _to_view(p: Vector2) -> Vector2:
	var f := _fit()
	var o: Vector2 = f[0]
	var k: float = f[1]
	return p * k + o

func _canvas_input(ev: InputEvent) -> void:
	var down := false
	var up := false
	var pos := Vector2.ZERO
	var moved := false
	if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT:
		down = ev.pressed
		up = not ev.pressed
		pos = ev.position
	elif ev is InputEventScreenTouch and ev.index == 0:
		down = ev.pressed
		up = not ev.pressed
		pos = ev.position
	elif (ev is InputEventMouseMotion and _drag != null) or (ev is InputEventScreenDrag and ev.index == 0):
		moved = true
		pos = ev.position
	else:
		return
	var p := _to_image(pos)
	if down:
		_start = p
		_drag = {"kind": BRUSH, "points": PackedVector2Array([p]), "radius": brush_radius} if tool == BRUSH else {"kind": BOX, "rect": Rect2i(Vector2i(p), Vector2i.ZERO)}
	elif moved and _drag != null:
		if _drag.kind == BRUSH:
			_drag.points.append(p)
		else:
			_drag.rect = Rect2i(Vector2i(_start), Vector2i(p - _start))
	elif up and _drag != null:
		var op: Dictionary = _drag
		_drag = null
		if op.kind == BRUSH or (op.rect as Rect2i).abs().has_area():
			add_op(op)
	_view.queue_redraw()
	_view.accept_event()

func _draw_drag() -> void:
	if _drag == null:
		return
	if _drag.kind == BOX:
		var r: Rect2 = Rect2((_drag.rect as Rect2i).abs())
		var k: float = _fit()[1]
		_view.draw_rect(Rect2(_to_view(r.position), r.size * k), paint)
	else:
		var pts: PackedVector2Array = _drag.points
		var k: float = _fit()[1]
		var w: float = float(_drag.radius) * 2.0 * k
		for i in pts.size():
			_view.draw_circle(_to_view(pts[i]), w / 2.0, paint)
			if i > 0:
				_view.draw_line(_to_view(pts[i - 1]), _to_view(pts[i]), paint, w)

func _unhandled_key_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed:
		if ev.keycode == KEY_ESCAPE:
			cancel()
		elif ev.keycode == KEY_Z and (ev.ctrl_pressed or ev.meta_pressed):
			undo()
		elif ev.keycode == KEY_ENTER:
			finish()
