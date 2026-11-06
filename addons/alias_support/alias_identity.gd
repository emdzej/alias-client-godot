class_name AliasIdentity
extends RefCounted
## The user's anonymous identity for one product: an id and a secret the service made (POST
## /api/v1/identity: never here, gasm has no Crypto and an engine's randomness isn't a secret's), kept in
## user:// (one file, a section per product key's name). Nothing else about the user is kept.

const FILE := "user://alias_support.cfg"

var id := ""
var secret := ""
var section := "default"

static func load_for(name: String) -> AliasIdentity:
	var me := AliasIdentity.new()
	me.section = name
	var cfg := ConfigFile.new()
	cfg.load(FILE)
	me.id = String(cfg.get_value(name, "id", ""))
	me.secret = String(cfg.get_value(name, "secret", ""))
	if not valid(me.id, me.secret):
		me.id = ""
		me.secret = ""
	return me

func has() -> bool:
	return id != ""

func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(FILE)
	if id == "":
		if cfg.has_section(section):
			cfg.erase_section(section)
	else:
		cfg.set_value(section, "id", id)
		cfg.set_value(section, "secret", secret)
	cfg.save(FILE)

func clear() -> void:
	id = ""
	secret = ""
	save()

static func valid(i: String, s: String) -> bool:
	return i.length() == 36 and i.count("-") == 4 and s.length() == 64 and s.is_valid_hex_number()
