#!/usr/bin/env python3
"""
Erzeugt AT_ConsumableData.lua aus der Welt-Datenbank von AzerothCore.

    tools/gen_consumables.py <pfad-zu-azerothcore>      schreibt AT_ConsumableData.lua neu
    tools/gen_consumables.py <pfad-zu-azerothcore> --check
                                                         bricht ab, wenn die Datei veraltet ist

Gelesen werden zwei Tabellen aus data/sql/base/db_world des Checkouts:

  item_template   Gegenstaende der Klasse "Verbrauchsgut": Flaeschchen (Unterklasse 3), Elixiere (2)
                  und Schriftrollen (4), je mit dem Zauber, den sie beim Benutzen wirken.
  spell_group     Gruppe 1 = Kampfelixiere, Gruppe 2 = Waechterelixiere. Das ist die Regel des
                  SERVERS: je Gruppe wirkt nur ein Zauber, ein Flaeschchen steht in beiden. Wer
                  in keiner Gruppe steht (Wasseratmung, Unsichtbarkeit erkennen, Traumsicht ...),
                  ist kein Kampfbuff und wird nicht aufgenommen.

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


# ---------------------------------------------------------------------------
# Auswahl
# ---------------------------------------------------------------------------

def collect(world_dir):
    world = Path(world_dir)
    _, groups = read_table(world / "spell_group.sql", "spell_group")
    battle = {s for g, s in groups if g == 1}
    guardian = {s for g, s in groups if g == 2}

    cols, rows = read_table(world / "item_template.sql", "item_template")
    ix = {c: i for i, c in enumerate(cols)}

    out = {}
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

        if sub == 3:                                   # Flaeschchen
            if spell in battle and spell in guardian:
                out[entry] = ("flask", spell, req, ilvl, None, None, name)
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
                out[entry] = ("scroll", spell, req, ilvl, "fortitude", 1, name)
    return out


def render(items):
    lines = [
        "-- AT_ConsumableData.lua",
        "-- ---------------------------------------------------------------------------",
        "-- ERZEUGT von tools/gen_consumables.py aus der Welt-Datenbank von AzerothCore",
        "-- (item_template, spell_group). Nicht von Hand aendern: neu erzeugen.",
        "--",
        "-- Eintrag je Gegenstand:  [Gegenstand] = { Art, Zauber, Stufe, Gegenstandsstufe [, Familie, Rang] }",
        "--",
        "--   Art      flask     Flaeschchen: belegt Kampf- UND Waechterplatz",
        "--            battle    Kampfelixier   (je Charakter wirkt nur eines)",
        "--            guardian  Waechterelixier (ebenso)",
        "--            scroll    Schriftrolle: eine Familie (strength ...) mit Rang; hoechster Rang gilt",
        "--   Zauber   der Zauber, den der Gegenstand wirkt und der als Buff auf dem Charakter liegt",
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

    items = collect(world)
    text = render(items)
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
