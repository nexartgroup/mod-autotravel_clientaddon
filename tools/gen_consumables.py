#!/usr/bin/env python3
"""
Erzeugt AT_ConsumableData.lua aus der Welt-Datenbank von AzerothCore.

    tools/gen_consumables.py <pfad-zu-azerothcore>      schreibt AT_ConsumableData.lua neu
    tools/gen_consumables.py <pfad-zu-azerothcore> --check
                                                         bricht ab, wenn die Datei veraltet ist

Gelesen werden drei Tabellen aus data/sql/base/db_world des Checkouts:

  item_template   Gegenstaende der Klasse "Verbrauchsgut": Flaeschchen (Unterklasse 3), Elixiere (2)
                  und Schriftrollen (4), je mit dem Zauber, den sie beim Benutzen wirken.
  spell_group     Gruppe 1 = Kampfelixiere, Gruppe 2 = Waechterelixiere. Das ist die Regel des
                  SERVERS: je Gruppe wirkt nur ein Zauber, ein Flaeschchen steht in beiden. Wer
                  in keiner Gruppe steht (Wasseratmung, Unsichtbarkeit erkennen, Traumsicht ...),
                  ist kein Kampfbuff und wird nicht aufgenommen.
                  Gruppe 1087 ("Scrolls", Regel 1 = exklusiv in spell_group_stack_rules) fasst die
                  sechs Werte der Schriftrollen zusammen: eine neue Schriftrolle ENTFERNT die alte,
                  auch die eines anderen Werts. Es gibt also nur einen Schriftrollenplatz.
  spell_ranks     Die Stufen eines Zaubers: spell_group nennt nur den ersten Rang.
  spell_script_names  Zauber, die ein Script des Kerns ausfuehrt. Der Zauber eines Gegenstands kann nur
                  ein solches Script sein, das den eigentlichen Buff erst wirkt: die Runenschriftrolle
                  der Seelenstaerke benutzt Zauber 69377 (SCRIPT_EFFECT), der Buff auf dem Charakter ist
                  Zauber 72590 (spell_item_runescroll_of_fortitude). Solche Gegenstaende stehen in
                  AURA_OVERRIDE; ein anderer Gegenstand mit Script-Zauber bricht die Erzeugung ab.

Neben den Gegenstaenden gibt das Ergebnis die vollstaendigen Zaubermengen der Gruppen 1 und 2 aus
(AT.ConsGroups): auch Juju, Zanza, R.O.I.D.S., Wasserwandeln u. a. belegen den Platz, obwohl sie
kein Elixier sind. Wirkt einer davon, darf das Addon dort kein Elixier benutzen. Dazu kommt Gruppe
1084 ("Single Stamina Buffs", Regel 4: nur der staerkste wirkt): Machtwort: Seelenstaerke, Gebet der
Seelenstaerke, Schriftrollen der Ausdauer und die Runenschriftrolle. Eine Runenschriftrolle, die
neben einem staerkeren dieser Buffs benutzt wird, ist verbraucht und der Buff sofort wieder weg.

Aufnahmeregeln
  Flaeschchen   Zauber in Gruppe 1 UND 2
  Elixier      Zauber in genau einer der beiden Gruppen (battle / guardian); "Elixier der
               Wasserwanderung" steht ausnahmsweise in Gruppe 2, ist aber keiner (AUSGENOMMEN)
  Schriftrolle Name "Scroll of <Wert> [Rang]" mit Wert in Staerke, Beweglichkeit, Intelligenz,
               Ausdauer, Willenskraft, Schutz (Ruestung); dazu die Runenschriftrolle der
               Seelenstaerke. Rueckruf-Schriftrollen u. a. fehlen absichtlich.

Das Ergebnis haengt nur an Kennungen (Gegenstand, Zauber): es ist unabhaengig von der Sprache
des Clients.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "AT_ConsumableData.lua"

# Gegenstaende, die in der Datenbank in einer Elixiergruppe stehen, aber kein Kampfbuff sind
EXCLUDED_ITEMS = {
    8827: "Elixir of Water Walking",
}

SCROLL_FAMILIES = {
    "Strength": "strength",
    "Agility": "agility",
    "Intellect": "intellect",
    "Stamina": "stamina",
    "Spirit": "spirit",
    "Protection": "protection",
}
# spell_group 1087 "Scrolls": die sechs Werte, gegenseitig ausschliessend (Regel 1)
SCROLL_GROUP = 1087
# spell_group 1084 "Single Stamina Buffs" (Regel 4, der staerkste gewinnt)
STAMINA_GROUP = 1084

# Gegenstaende, deren Zauber nur ein Script ist: der Buff auf dem Charakter ist ein anderer Zauber.
AURA_OVERRIDE = {
    49632: 72590,   # Runescroll of Fortitude: 69377 ist SCRIPT_EFFECT, das Script wirkt 72590 (Stufe >= 70)
}

# Flaeschchen, die absichtlich fehlen. Jedes andere Flaeschchen, dessen Zauber nicht in beiden Gruppen
# steht, bricht die Erzeugung ab: es wuerde sonst unbemerkt fehlen.
KNOWN_SKIPPED_FLASKS = {
    47499: "Flask of the North: Zauber 67019 ist ein Script, das je nach Werten 67016, 67017 oder 67018 wirkt",
    # Die Mixtures der Alchemisten (Unterklasse "Flaeschchen", Stufe 0): ihre Zauber 65252 bis 65255 stehen in
    # keiner Elixiergruppe, der Server behandelt sie also weder als Flaeschchen noch als Elixier; was sie
    # wirken, steht nicht in der Datenbank.
    40082: "Mixture of the Frost Wyrm (Zauber 65253, in keiner Elixiergruppe)",
    40083: "Mixture of Stoneblood (Zauber 65255, in keiner Elixiergruppe)",
    40084: "Mixture of Endless Rage (Zauber 65252, in keiner Elixiergruppe)",
    40404: "Mixture of Pure Mojo (Zauber 65254, in keiner Elixiergruppe)",
}
ROMAN = {"I": 1, "II": 2, "III": 3, "IV": 4, "V": 5, "VI": 6, "VII": 7, "VIII": 8, "IX": 9, "X": 10}
SCROLL_RE = re.compile(r"^Scroll of (%s)(?: (%s))?$" % ("|".join(SCROLL_FAMILIES), "|".join(ROMAN)))


# ---------------------------------------------------------------------------
# Ein kleiner Leser fuer mysqldump-INSERTs
# ---------------------------------------------------------------------------

def _parse_row(s, i):
    assert s[i] == "("
    i += 1
    row = []
    n = len(s)
    while True:
        c = s[i]
        if c == "'":
            i += 1
            buf = []
            while True:
                c = s[i]
                if c == "\\":
                    nxt = s[i + 1]
                    buf.append({"n": "\n", "r": "\r", "t": "\t", "0": "\0", "Z": "\x1a", "b": "\b"}.get(nxt, nxt))
                    i += 2
                elif c == "'":
                    if i + 1 < n and s[i + 1] == "'":
                        buf.append("'")
                        i += 2
                    else:
                        i += 1
                        break
                else:
                    buf.append(c)
                    i += 1
            row.append("".join(buf))
        else:
            j = i
            while s[j] not in ",)":
                j += 1
            tok = s[i:j]
            if tok == "NULL":
                row.append(None)
            else:
                try:
                    row.append(int(tok))
                except ValueError:
                    try:
                        row.append(float(tok))
                    except ValueError:
                        row.append(tok)
            i = j
        c = s[i]
        if c == ",":
            i += 1
            continue
        if c == ")":
            return row, i + 1
        raise ValueError("unerwartetes Zeichen %r an Stelle %d" % (c, i))


def read_table(path, table):
    """Spaltennamen und Zeilen einer Tabelle aus einem mysqldump."""
    data = Path(path).read_text(encoding="utf-8", errors="replace")
    m = re.search(r"CREATE TABLE `%s` \((.*?)\n\) ENGINE" % re.escape(table), data, re.S)
    if not m:
        raise SystemExit("Tabelle %s nicht gefunden in %s" % (table, path))
    cols = [mm.group(1) for line in m.group(1).splitlines() for mm in [re.match(r"\s+`(\w+)`", line)] if mm]

    marker = "INSERT INTO `%s` VALUES" % table
    rows = []
    pos = 0
    while True:
        p = data.find(marker, pos)
        if p < 0:
            break
        i = p + len(marker)
        while data[i] in " \n\r\t":
            i += 1
        while True:
            row, i = _parse_row(data, i)
            rows.append(row)
            if data[i] == ",":
                i += 1
                while data[i] in " \n\r\t":
                    i += 1
                continue
            break
        pos = i
    return cols, rows


def group_members(by_group, gid, seen=None):
    """Alle Zauber einer Gruppe; Eintraege mit negativer Kennung verweisen auf eine Untergruppe."""
    seen = seen if seen is not None else set()
    if gid in seen:
        return set()
    seen.add(gid)
    out = set()
    for sp in by_group.get(gid, []):
        if sp < 0:
            out |= group_members(by_group, -sp, seen)
        else:
            out.add(sp)
    return out


def with_ranks(spells, ranks):
    """Zu jedem ersten Rang alle Raenge (spell_ranks: first_spell_id, spell_id, rank)."""
    by_first = {}
    for first, spell, _rank in ranks:
        by_first.setdefault(first, set()).add(spell)
    out = set()
    for sp in spells:
        out.add(sp)
        out |= by_first.get(sp, set())
    return out


def collect_groups(world):
    """Zaubermengen der Elixiergruppen und der Schriftrollengruppe, mit allen Raengen."""
    world = Path(world)
    _, groups = read_table(world / "spell_group.sql", "spell_group")
    _, ranks = read_table(world / "spell_ranks.sql", "spell_ranks")
    by_group = {}
    for gid, sp in groups:
        by_group.setdefault(gid, []).append(sp)
    return {
        "battle": with_ranks(group_members(by_group, 1), ranks),
        "guardian": with_ranks(group_members(by_group, 2), ranks),
        "scroll": with_ranks(group_members(by_group, SCROLL_GROUP), ranks),
        "stamina": with_ranks(group_members(by_group, STAMINA_GROUP), ranks),
    }


# ---------------------------------------------------------------------------
# Auswahl
# ---------------------------------------------------------------------------

def collect(world_dir):
    """Rueckgabe: (Gegenstaende, Probleme). Probleme sind Dinge, die das Ergebnis unbrauchbar machen."""
    world = Path(world_dir)
    _, groups = read_table(world / "spell_group.sql", "spell_group")
    battle = {s for g, s in groups if g == 1}
    guardian = {s for g, s in groups if g == 2}
    _, scripts = read_table(world / "spell_script_names.sql", "spell_script_names")
    script_spells = {sp for sp, _name in scripts}

    cols, rows = read_table(world / "item_template.sql", "item_template")
    ix = {c: i for i, c in enumerate(cols)}

    out = {}
    problems = []
    for r in rows:
        if r[ix["class"]] != 0:
            continue
        sub = r[ix["subclass"]]
        if sub not in (2, 3, 4):
            continue
        entry = r[ix["entry"]]
        name = r[ix["name"]]
        spell = r[ix["spellid_1"]]
        req = r[ix["RequiredLevel"]]
        ilvl = r[ix["ItemLevel"]]
        if not spell or entry in EXCLUDED_ITEMS:
            continue

        # Der Zauber des Gegenstands ist nur ein Script: der Buff ist ein anderer Zauber.
        use_spell = spell
        if entry in AURA_OVERRIDE:
            spell = AURA_OVERRIDE[entry]

        if sub == 3:                                   # Flaeschchen
            if spell in battle and spell in guardian:
                out[entry] = ("flask", spell, req, ilvl, None, None, name)
            elif entry not in KNOWN_SKIPPED_FLASKS:
                problems.append("Flaeschchen %d %s (Zauber %d) steht nicht in beiden Elixiergruppen und ist nicht als "
                                "ausgelassen vermerkt" % (entry, name, spell))
        elif sub == 2:                                 # Elixier
            if spell in battle and spell not in guardian:
                out[entry] = ("battle", spell, req, ilvl, None, None, name)
            elif spell in guardian and spell not in battle:
                out[entry] = ("guardian", spell, req, ilvl, None, None, name)
        else:                                          # Schriftrolle
            m = SCROLL_RE.match(name)
            if m:
                out[entry] = ("scroll", spell, req, ilvl, SCROLL_FAMILIES[m.group(1)],
                              ROMAN[m.group(2)] if m.group(2) else 1, name)
            elif name == "Runescroll of Fortitude":
                # Steht NICHT in Gruppe 1087 (nur in 1084, "Single Stamina Buffs", Regel 4): wirkt
                # neben einer Schriftrolle der sechs Werte, hat also einen eigenen Platz -- aber
                # er teilt sich mit jedem anderen Ausdauerbuff.
                out[entry] = ("scroll", spell, req, ilvl, "fortitude", 1, name)

        if entry in out and use_spell in script_spells and entry not in AURA_OVERRIDE:
            problems.append("%d %s: der Zauber %d ist ein Script des Kerns (spell_script_names); der Buff auf dem "
                            "Charakter ist ein anderer Zauber. In AURA_OVERRIDE eintragen." % (entry, name, use_spell))
    return out, problems


def check_scrolls(items, groups):
    """Jede Schriftrolle der sechs Werte muss in der exklusiven Gruppe des Servers stehen, die
    Runenschriftrolle darf es nicht. Stimmt das nicht mehr, hat der Server die Regel geaendert."""
    problems = []
    for entry, (kind, spell, _req, _ilvl, family, _rank, name) in sorted(items.items()):
        if kind != "scroll":
            continue
        inside = spell in groups["scroll"]
        if family == "fortitude":
            if inside:
                problems.append("%d %s steht in der Schriftrollengruppe (eigener Platz angenommen)" % (entry, name))
            if spell not in groups["stamina"]:
                problems.append("%d %s: Zauber %d steht nicht in Gruppe %d (Ausdauerbuffs)" % (entry, name, spell, STAMINA_GROUP))
        elif not inside:
            problems.append("%d %s steht nicht in der Schriftrollengruppe %d" % (entry, name, SCROLL_GROUP))
    return problems


def _wrap_ids(ids, indent="      ", width=100):
    lines, cur = [], indent
    for sp in sorted(ids):
        piece = "%d, " % sp
        if len(cur) + len(piece) > width:
            lines.append(cur.rstrip())
            cur = indent
        cur += piece
    if cur.strip():
        lines.append(cur.rstrip())
    return "\n".join(lines)


def render(items, groups):
    lines = [
        "-- AT_ConsumableData.lua",
        "-- ---------------------------------------------------------------------------",
        "-- ERZEUGT von tools/gen_consumables.py aus der Welt-Datenbank von AzerothCore",
        "-- (item_template, spell_group, spell_ranks). Nicht von Hand aendern: neu erzeugen.",
        "--",
        "-- Eintrag je Gegenstand:  [Gegenstand] = { Art, Zauber, Stufe, Gegenstandsstufe [, Familie, Rang] }",
        "--",
        "--   Art      flask     Flaeschchen: belegt Kampf- UND Waechterplatz",
        "--            battle    Kampfelixier   (je Charakter wirkt nur eines)",
        "--            guardian  Waechterelixier (ebenso)",
        "--            scroll    Schriftrolle: eine Familie (strength ...) mit Rang. Die sechs Werte teilen sich",
        "--                      beim Server EINEN Platz (spell_group 1087, exklusiv); nur die",
        "--                      Runenschriftrolle (fortitude) hat einen eigenen",
        "--   Zauber   der Zauber, der als Buff auf dem Charakter liegt (meist der des Gegenstands; die Runen-",
        "--            schriftrolle benutzt ein Script, der Buff ist ein anderer Zauber)",
        "--",
        "-- Nur Buffs, die im Kampf nuetzen. Wasseratmung, Unsichtbarkeit erkennen und andere",
        "-- Hilfsmittel stehen nicht darin: der Server fasst sie nicht in die Elixiergruppen.",
        "-- ---------------------------------------------------------------------------",
        "",
        "AutoTravel = AutoTravel or {}",
        "local AT = AutoTravel",
        "",
        "AT.ConsData = {",
    ]
    for entry in sorted(items):
        kind, spell, req, ilvl, family, rank, name = items[entry]
        extra = ', "%s", %d' % (family, rank) if family else ""
        lines.append("   [%d] = { \"%s\", %d, %d, %d%s },   -- %s" % (entry, kind, spell, req, ilvl, extra, name))
    lines.append("}")
    lines.append("")
    lines += [
        "-- Zaubergruppen des Servers, mit allen Stufen. Nicht nur Elixiere und Flaeschchen: Wirkt irgendein Zauber",
        "-- der Gruppe, ist der Platz belegt, und ein neuer Buff wuerde ihn ersetzen (oder wird abgewiesen).",
        "AT.ConsGroups = {",
        "   -- spell_group 1 und 2: Kampf- und Waechterelixiere (Regel 1, einer wirkt); auch Juju, Zanza, R.O.I.D.S.,",
        "   -- Wasserwandeln u. a. stehen darin",
        "   battle = {",
        _wrap_ids(groups["battle"]),
        "   },",
        "   guardian = {",
        _wrap_ids(groups["guardian"]),
        "   },",
        "   -- spell_group 1084, \"Single Stamina Buffs\" (Regel 4: nur der staerkste wirkt): Machtwort und Gebet der",
        "   -- Seelenstaerke, Schriftrollen der Ausdauer, Runenschriftrolle. Eine Runenschriftrolle neben einem",
        "   -- staerkeren dieser Buffs ist umsonst: der Kern verwirft den schwaecheren Buff, nachdem der Gegenstand",
        "   -- verbraucht ist.",
        "   stamina = {",
        _wrap_ids(groups["stamina"]),
        "   },",
        "}",
        "",
    ]
    return "\n".join(lines)


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    check = "--check" in argv
    if len(args) != 1:
        print(__doc__)
        return 2
    world = Path(args[0]) / "data" / "sql" / "base" / "db_world"
    if not (world / "item_template.sql").exists():
        print("item_template.sql nicht gefunden in %s" % world, file=sys.stderr)
        return 2

    items, problems = collect(world)
    groups = collect_groups(world)
    problems += check_scrolls(items, groups)
    if problems:
        for line in problems:
            print("Warnung: " + line, file=sys.stderr)
        return 1
    text = render(items, groups)
    # nur ASCII: die Namen der Datenbank sind englisch, aber ein Apostroph o. A. darf nie die Datei sprengen
    text = text.encode("ascii", "replace").decode("ascii")

    if check:
        cur = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if cur != text:
            print("AT_ConsumableData.lua ist veraltet: tools/gen_consumables.py <azerothcore> ausfuehren.")
            return 1
        print("AT_ConsumableData.lua ist aktuell (%d Gegenstaende)." % len(items))
        return 0

    OUTPUT.write_text(text, encoding="utf-8", newline="\n")
    kinds = {}
    for v in items.values():
        kinds[v[0]] = kinds.get(v[0], 0) + 1
    print("AT_ConsumableData.lua geschrieben: %d Gegenstaende %s" % (len(items), dict(sorted(kinds.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
