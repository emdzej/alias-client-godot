class_name AliasWords
extends RefCounted
## The addon's words, built in: English and Polish (LANGUAGES), for AliasRedactor's buttons and for the
## UI a game draws itself (a ticket's status, who wrote an entry, "I agree" by the consent, a count of new
## answers). Any other language gets English; a game's own words go over them (AliasSupport.labels,
## AliasRedactor.labels), or bring another language whole.
##
##   var w := AliasWords.words(alias.language, {"done": "Wyślij"})
##   status_label.text = w["status_" + ticket.status]
##   badge.text = AliasWords.plural(3, w.new_answers, alias.language) # "3 nowe odpowiedzi"

const LANGUAGES := ["en", "pl"]

const WORDS := {
	"en": {
		"box": "Box", "brush": "Brush", "undo": "Undo", "clear": "Clear", "cancel": "Cancel", "done": "Done",
		"status_open": "Open", "status_in_progress": "In progress", "status_waiting": "Waiting on you",
		"status_resolved": "Resolved", "status_closed": "Closed",
		"you": "You", "support": "Support", "agent": "Automated reply", "agree": "I agree",
		"new_answers": ["{n} new answer", "{n} new answers"],
	},
	"pl": {
		"box": "Prostokąt", "brush": "Pędzel", "undo": "Cofnij", "clear": "Wyczyść", "cancel": "Anuluj", "done": "Gotowe",
		"status_open": "Otwarte", "status_in_progress": "W toku", "status_waiting": "Czeka na Ciebie",
		"status_resolved": "Rozwiązane", "status_closed": "Zamknięte",
		"you": "Ty", "support": "Wsparcie", "agent": "Odpowiedź automatyczna", "agree": "Zgadzam się",
		"new_answers": ["{n} nowa odpowiedź", "{n} nowe odpowiedzi", "{n} nowych odpowiedzi"],
	},
}

## The built-in language for a tag ("pl", "pl_PL", "pl-PL"): its first part, if built in, else "en".
static func lang_of(tag: String) -> String:
	var l := tag.to_lower().replace("_", "-").get_slice("-", 0)
	return l if l in LANGUAGES else "en"

## The words for a language, the overrides over them (a new dictionary).
static func words(language: String, overrides := {}) -> Dictionary:
	var w: Dictionary = (WORDS[lang_of(language)] as Dictionary).duplicate(true)
	w.merge(overrides, true)
	return w

## Which of a language's plural forms n takes. English: 0 one, 1 other. Polish: 0 one (1), 1 few (2-4,
## 22-24, not 12-14), 2 many (the rest).
static func plural_form(n: int, language: String) -> int:
	n = absi(n)
	if lang_of(language) == "pl":
		if n == 1:
			return 0
		return 1 if n % 10 >= 2 and n % 10 <= 4 and not (n % 100 >= 12 and n % 100 <= 14) else 2
	return 0 if n == 1 else 1

## The form for n of forms (one, other; Polish: one, few, many), {n} replaced by n.
static func plural(n: int, forms: Array, language: String) -> String:
	if forms.is_empty():
		return str(n)
	return String(forms[mini(plural_form(n, language), forms.size() - 1)]).replace("{n}", str(n))
