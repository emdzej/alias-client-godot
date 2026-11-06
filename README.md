# alias-support for Godot

`addons/alias_support`: the ALIAS client for Godot 4 in GDScript. The product draws its own UI; the addon
gives it a screenshot redactor and Markdown as BBCode. Copy
the folder into a project's `addons/`. It follows [the spec](https://github.com/emdzej/alias-releases/blob/main/spec/openapi.yaml): one coroutine per
operation, its operationId in snake_case (`get_product`, `report`, `claim_transfer`…), as in every client.

```gdscript
var alias := AliasSupport.new()
alias.url = "https://alias.help"
alias.key = PRODUCT_KEY
alias.app_version = ProjectSettings.get_setting("application/config/version")
alias.context_provider = func() -> Dictionary: return {"level": level_name}
alias.telemetry_provider = func() -> Dictionary: return {"fps": Engine.get_frames_per_second()}
add_child(alias)

var r: Dictionary = await alias.report("The door won't open", get_viewport().get_texture().get_image())
if not r.ok:
	show_error(r.error) # the service's words (a telemetry schema miss says where)
alias.answered.connect(func(u: Dictionary): notify("Support answered #%d" % u.ticket))
alias.watch()
```

- Every call returns `{ok, status, data, error}` (`status` 0: no answer).
- **The identity is the service's** (`POST /api/v1/identity`): made on the first call that needs one, kept in
  `user://alias_support.cfg` under `identity_name` (one per product in a game). Never made here: the web
  and gasm builds have no `Crypto`. `forget()`, `use_identity(id, secret)` (checked first), `erase_me()`
  (erased at the service, then forgotten), `identity_changed`.
- **Moving it:** `new_transfer()` gives a code to type on the other device, `claim_transfer(code)` there.
- **Contact, only if the user gives it, with their consent:** show `get_product()`'s `contact_consent.text`
  whole by the field, with an unticked "I agree", and only then `set_contact("email" | "other", value,
  contact_consent)`: the service records the consent with that text. `get_contact()`, `withdraw_contact()`
  (the consent's record stays, ended, until the identity goes).
- **Screenshots and files:** `report(note, screenshot, context, telemetry, attachments, format)` (and
  `reply(id, body, …)` the same). The screenshot is an `Image` (sent as a JPEG) or JPEG bytes. Attachments
  are `[{name, data}]`, where `data` is a `PackedByteArray` or an `Image`. With files the request goes as
  multipart/form-data; a screenshot alone goes as JSON, as before. The product says how many files,
  how many bytes and which types it takes (`product.attachments`). The service tells the type from the
  bytes and strips image metadata. `attachment(ticket_id, attachment_id)` gives a file back as bytes.
  Context and telemetry come from the providers unless given to the call.
- **Format:** `"text/plain"` (the default) or `"text/markdown"`, for the note or the reply, and for
  support's answers too (each ticket and entry has `format`).
- **Redaction, before it goes:** the product's rules (`GET /api/v1/product`, asked once and kept in `product`)
  are applied to the note, context and telemetry of every report and reply (`AliasRedact`; `redact =
  false` turns that off here). The service applies them again, and alone does `hash`. A rule
  `client:<name>` is the app's own:
  `AliasRedact.register_redactor("name", func(value, rule): return …)`. Return `AliasRedact.DROP` to drop
  the value, and pass `Callable()` to unregister before the bound object goes.
- **What the user sees before sending:** `preview_telemetry()` gives `{telemetry, context, removable}`
  with the rules applied, and the product's removable paths that are present. Let the user untick
  those, then `AliasSupport.remove_paths(telemetry, chosen)` and pass the result to `report`.
- **Hiding things in a screenshot:** `AliasRedactor.open(parent, image)` opens a full-screen editor with
  solid boxes, a brush, undo, clear, cancel and done (mouse, touch, Esc, Ctrl+Z). Then
  `await r.finished` gives the flattened `Image`, or null if cancelled. There's no blur: blur can be
  undone. `AliasRedactor.jpeg(img)` or `.png(img)` encodes it with no metadata. The ops are a list you
  can apply headless: `AliasRedactor.apply(image, ops)`.
- **Showing notes and answers:** `AliasMarkdown.to_bbcode(text, format, image_path)` turns text into
  BBCode for a `RichTextLabel` with `bbcode_enabled`. `AliasMarkdown.render(label, text, format,
  texture)` adds the attachments' images as textures. Every `[` the user wrote is escaped, links go
  only to http, https and mailto, and images come only from the report's own attachments, never remote.
- **Live answers:** `watch()` polls `/api/v1/updates` every `poll_every` seconds and, natively, keeps a stream
  open (`/api/v1/events`, by `HTTPClient`); on the web and gasm it polls alone. Each answer is signalled once.
  `stop()`; `events()` says the stream's state.
- **Live conversations:** when `get_product()`'s `live.user_may_ask`, `request_live(id)` takes the ticket
  live (at once if someone's at the desk, else asked for). While watching, the `live` signal brings the
  ticket's `mode`, support's `typing` (with `name`) and `read` events; send yours with `typing(id)` (passed on
  once every 2 s) and `mark_read(id)`.
- **A revoked key:** a failed call's result has `code` `"key_revoked"` when this build's key was revoked,
  and `reason`, support's words for the player when they gave some ("This version is no longer
  supported"), to show as they are.
- **Agents:** a thread entry with `agent` true was written by an agent (a service account: an AI agent, a
  script), not a person. Say so where you show it, for example "Automated reply".

Tests: `GODOT=path/to/godot test/run.sh` builds the server from this repo, starts it with a memory store,
makes the product on its admin API, and runs `test/run_tests.gd` headless. Redaction is held to
`docs/redact-vectors.json`, as the service's is.
