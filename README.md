# AutoTravel (Client-Addon)

Addon fuer **World of Warcraft 3.3.5a (Interface 30300)** auf einem
**AzerothCore**-Server mit dem Modul
[mod-autotravel](https://github.com/nexartgroup/mod-autotravel).

```
Carbonite   ->  wohin      das gesetzte Ziel und die Wegpunkte dorthin
Addon       ->  bedienen   auslesen, umrechnen, Panel, Uebergabe an den Spieler
Servermodul ->  wie        NavMesh, Gelaende, Reittier, Flugmeister, Transporte
```

Ein 3.3.5a-Addon kann den Charakter nicht bewegen (`MoveForwardStart()` & Co.
sind protected) und kennt weder Gelaendehoehen noch NavMesh. Deshalb schickt das
Addon nur das Ziel; der Server faehrt.

## Voraussetzungen

| Was | Warum |
|---|---|
| Client 3.3.5a | Interface 30300 |
| **mod-autotravel** auf dem Server | ohne das Modul passiert nichts (das Addon meldet es) |
| **Carbonite** (3.3.5a-Fassung) | Zielquelle; optional im Sinne des Addon-Loaders |
| mod-playerbots | nur fuer den Selbstmodus des Bots (Profile); AutoTravel funktioniert auch ohne |

## Installation

Ordner `mod-autotravel_clientaddon` nach
`World of Warcraft/Interface/AddOns/AutoTravel/` kopieren (der Ordnername muss
`AutoTravel` lauten, passend zu `AutoTravel.toc`). Spiel neu starten oder UI
neu laden. Beim Anmelden meldet das Addon seine Version und fragt das Servermodul
ab.

## Bedienung

**Ziel setzen** in Carbonite (ein Goto-Wegpunkt; AutoTravel liest das Ziel und
die Wegpunkte dorthin aus). Dann:

| | |
|---|---|
| **START / STOP** (Panel, `/at`, Minimap links) | Reise beginnen oder abbrechen |
| **Uebernehmen / Weiter** (Panel, Minimap Mitte, Taste) | Steuerung uebernehmen bzw. zurueckgeben |
| **Neu berechnen** | Weg von der aktuellen Position neu suchen |
| **Teleport** (Panel, Minimap rechts) | direkt zum Ziel -- nur, wenn der Server es diesem Spieler erlaubt |

Tasten belegen unter *Optionen -> Tastaturbelegung -> AutoTravel*:
Reise starten/stoppen, Steuerung uebernehmen/zurueckgeben, Playerbot-Selbstmodus.

### Uebergabe an den Spieler

Der Autopilot haelt die Steuerung **nur, solange er faehrt**. Sie geht sofort an
dich zurueck bei Kampf, Tod, Kartenwechsel, Flug oder wenn du **Uebernehmen**
drueckst.

* **Ausdruecklich uebernommen** (Knopf, Taste, Mittelklick): der Halt endet nur,
  wenn du auf **Weiter** klickst. Er laeuft nie von selbst aus.
* **Nach einem Kampf**: der Autopilot wartet, bis du eine Weile ruhig bist.
  Danach laeuft ein sichtbarer **Countdown** (Standard 3 s), den jede Eingabe
  abbricht. Erst dann faehrt er weiter.

Was als "Eingabe" zaehlt: Bewegung, Fallen, Mausblick, Maustasten, merkliche
Mausbewegung, Umschalt-/Strg-/Alt-Taste, Zaubern, Kampf, offener Chat, offene
Fenster (Beute, Haendler, Quest, Post, Bank, Flugmeister, Karte, Charakter ...)
und ein Gegenstand am Mauszeiger. Ruhezeit und Countdown stellst du in den
Optionen oder mit `/at ruhe <sekunden>` ein; die automatische Rueckgabe laesst sich
abschalten.

> **Warum kein Haken auf WASD?** 3.3.5a meldet Tastendruecke nicht an Addons;
> `SetPropagateKeyboardInput` gibt es erst ab Cataclysm, und
> `MoveForwardStart()` ist protected. Uebernommen wird deshalb per Knopf,
> zurueckgegeben wird beobachtend. Das kostet keinen einzigen Tastendruck.

### Berechtigungen

Beim Anmelden meldet der Server, was **dieser Spieler** darf. Das Addon sperrt
Bedienelemente, die ohnehin abgewiesen wuerden, und sagt im Tooltip warum:

* **Teleport**: Standard nur Spielleiter (`AutoTravel.TeleportSecurity`).
* **Serverweite Einstellungen** (natuerliche Navigation, Contour): nur
  Spielleiter. Sie gelten fuer *alle* Spieler.
* Zielradius und Wartezeit nach dem Kampf gelten nur fuer die eigene Reise und
  sind fuer jeden frei.

Die Pruefung bleibt beim Server; die gesperrten Knoepfe sind nur Komfort.

## Befehle

| | |
|---|---|
| `/at` | Reise starten / stoppen |
| `/at pause`, `/at weiter` | Steuerung uebernehmen / zurueckgeben |
| `/at tp` | zum Ziel teleportieren |
| `/at info` | Version, Verbindung, Faehigkeiten, Einstellungen |
| `/at hello` | Servermodul erneut abfragen |
| `/at diag` | warum scheitert der Pfad zu diesem Ziel? |
| `/at target`, `/at route`, `/at koords` | erkanntes Ziel, Wegpunkte, Weltkoordinaten |
| `/at knoten` | Zustand des Playerbot-Knotengraphen |
| `/at ziel <yd>` | Zielradius der eigenen Reise |
| `/at ruhe <s>` | Ruhezeit bis zur Uebernahme |
| `/at profil`, `/at profil <name>` | Profile anzeigen / ein Profil waehlen |
| `/at profil bearbeiten` | Profil-Editor oeffnen |
| `/at profil reset <name>`, `/at profil reset alle` | vorgegebene Profile auf die Standardwerte zuruecksetzen |
| `/at bot`, `/at botan`, `/at botaus` | Playerbot-Steuerung / Selbstmodus |
| `/at karte <id>`, `/at karten` | Karten-ID erzwingen / Kartentabelle neu aufbauen |
| `/at optionen`, `/at panel`, `/at knopf`, `/at debug` | Oberflaeche und Diagnose |
| `/at ui` | Diagnose: Zustand der Panel-Knoepfe (frei / gesperrt), Zaehler fuer Betreten und Klicks des Uebernehmen-Knopfes, was unter der Maus liegt |
| `/at strat` | Diagnose: erkannte Druidengestalt, zuletzt gesendete Gestaltstrategie, Gestaltliste; fragt den Bot per `co ?` und `nc ?` nach seinen aktiven Strategien |

## Ziel: Name und Zielanker

Das Addon schickt dem Server zum Ziel nur Kartenkoordinaten (x/y) und das **Label**, das
Carbonite dazu anzeigt -- bei einem NPC dessen Name, bei einem Questziel der Name oder Text
des Ziels. Carbonite zeigt ihn **englisch**, auch wenn der Client deutsch ist ("High Chief
Stillpine" statt "Oberhaeuptling der Tannenruhfeste"); der Server vergleicht ihn deshalb mit
den englischen Namen seiner Datenbank. Eine Hoehe (Z) gibt es im Client nicht. Wo mehrere
Etagen uebereinanderliegen (die Exodar liegt rund 130 yd *unter* dem Gelaende darueber),
legt der Server die Etage fest: ist das Ziel ein NPC, ein Objekt oder ein Questziel, nimmt
er dessen Spawnposition (Servermodul 4.0.6, "Zielanker"). Am Protokoll aendert das nichts.

Seit 11.3 geht das Label sauber hinaus: Farbcodes (`|cffff0000...|r`), Links
(`|Hquest:...|h[Titel]|h`) und Texturen werden entfernt, der Text bleibt, und die Kuerzung auf
64 Bytes schneidet kein UTF-8-Zeichen durch (vorher blieben Reste wie `cffff0000Bankr`, und
Umlaute konnten halbiert werden). Ausserdem verwirft die Route ihren **letzten Punkt** nicht
mehr, wenn er auf dem vorigen liegt: der letzte Punkt ist das Ziel und ersetzt den vorigen
(vorher wurde das Ziel still auf den Zwischenpunkt davor verschoben -- bis zu 7 yd auf einer
Stadtkarte, 24 yd auf einer Zonenkarte).

## Playerbot-Selbstmodus

Optional steuert das Addon den Selbstmodus von mod-playerbots mit (Profile wie
*Verteidigen*, *Aggressiv*, eigene Profile). Gesendet werden nur Strategiebefehle
(`co`, `nc`, `ll`) und, seit 11.5, die Haltung des Begleiters (`pet aggressive|defensive|passive`);
`new rpg` wird in jedem festen Profil abgeschaltet, weil es
Ausruestung wechseln kann. Der Erbstueckschutz legt ein vom Bot abgelegtes
Erbstueck wieder an.

Der Selbstmodus wird erst eingeschaltet (und das Profil gesendet), **wenn der Server den
Start angenommen hat**. Lehnt er ab -- etwa "keine Verbindung ueber die Kartengrenze" --,
bleibt der Bot aus und es geht keine Flustermeldung hinaus. (Bis 11.1 schaltete schon der
Klick auf Start den Bot ein, auch bei einer Absage, und sendete das Profil bei jedem
Versuch erneut.) "Selbstmodus am Reiseende ausschalten" greift nur nach einer Reise, die
den Bot selbst eingeschaltet hat -- nicht nach einem Stop vor der Antwort des Servers und
nicht, wenn die Oberflaeche (`/reload`) waehrend der Reise neu geladen wurde: dann kennt das
Addon den Zustand des Bots nicht und laesst ihn, wie er ist (der Ausschalter ist ein
Umschalter und koennte ihn sonst einschalten).

### Profile

Sechs vorgegebene Profile (Minimal, Aengstlich, Verteidigen, Normal, Aggressiv, Plus) und
drei eigene. **Normal** lootet: es setzt `nc +loot` und `ll normal` und wartet nach dem Kampf
7 s, damit der Bot die Beute aufnehmen kann, bevor der Autopilot weiterlaeuft. (Bis 11.0
stand dort `-loot`, das Profil nannte sich Normal und lootete nie.) Normal sammelt dabei keine
Berufsressourcen (`-gather`; `nc !` schaltet `gather` sonst von selbst an) -- das ist der
Unterschied zu **Plus**. Wer Beute aufnimmt, kann auch Ausruestung bekommen, die der Bot
anlegt, wenn sie besser ist; Erbstuecke schuetzt der Erbstueckschutz. Minimal, Aengstlich und
Verteidigen lassen die Beute bewusst liegen.

**Die vorgegebenen Profile sind aenderbar.** Unter *Interface -> AddOns -> AutoTravel ->
Profile* (oder `/at profil bearbeiten`) waehlst du ein Profil und stellst Strategien,
Zusatzbefehle und die Wartezeit nach dem Kampf ein. Geaenderte Profile tragen ein `*`.
**Auf Standard zuruecksetzen** (oder `/at profil reset <name>`, `/at profil reset alle`)
verwirft die Aenderungen; der Standard bleibt im Addon und geht nie verloren. Ein geaendertes
Profil behaelt seine Werte, auch wenn eine spaetere Version den Standard anpasst -- erst
das Zuruecksetzen holt den neuen Standard. Stellst du alles von Hand auf den Standard
zurueck, verschwindet die Aenderung von selbst. Die Wartezeit liegt zwischen 0,1 und 30 s
(der Server liest 0 als "keine Vorgabe"); Wartezeit und Zusatzbefehle speichert die
Eingabetaste.

Jede Strategie eines vorgegebenen Profils hat **drei Zustaende**, ein Klick wechselt:
*nicht gesetzt* (grau: es bleibt, was `co !` / `nc !` als Standard hinterlassen), *an* (`+`)
und *aus* (`-`). Die vorgegebenen Profile setzen bewusst nicht alles -- Normal etwa fasst
`tank` und `boost` nicht an --, und mit nur zwei Zustaenden wuerde das erste Speichern aus
jeder nicht gesetzten Strategie ein ausdrueckliches `-` machen. Bei eigenen Profilen gilt
wie bisher: jede Strategie wird ausdruecklich mit `+` oder `-` gesetzt.

Wird das gerade laufende Profil bearbeitet, geht es eine Sekunde nach der letzten Aenderung
einmal neu an den Bot (nicht bei jedem Klick).

* `.playerbots bot self` ist ein **Umschalter**: derselbe Befehl schaltet ein und
  aus. Das Addon liest die Antwort des Servers mit ("SelfBot is now active." /
  "... deactivated."), statt den Zustand zu raten.
* Der Server kann den Selbstmodus verweigern (`AiPlayerbot.SelfBotLevel`; Standard
  1 = nur Spielleiter). Das Addon sagt dann, warum, und verwirft die
  Strategiebefehle, die schon in der Warteschlange standen.
* **BotPad (ab 1.2) laeuft daneben.** BotPad erkennt AutoTravel beim Anmelden und
  setzt dem Bot dann keine Strategien (Moduswahl und "Strategien beim
  Ausschalten zuruecksetzen" sind auf seiner Einstellungsseite gesperrt). Es gibt
  die Meldungen des Servermoduls nicht noch einmal aus und filtert keine
  `[AT]`-Zeilen; das uebernimmt AutoTravel. Umschalten des Selbstmodus und der
  Teleport zum Carbonite-Ziel bleiben bei BotPad. BotPad erkennt AutoTravel nur
  am Geladensein: auch mit ausgeschaltetem "Playerbot-Selbstmodus mitsteuern" setzt es dann
  keine Strategien. Aeltere BotPad-Staende (vor 1.2) schickten dem Bot weiter
  eigene Strategien und gaben jede Meldung doppelt aus.

### Traenke, Wartung und Begleiter (ab 11.5)

Die Profile steuern jetzt auch, was mod-playerbots dafuer anbietet. Geprueft wurde das am Quelltext
von mod-playerbots, nicht geraten:

| Wunsch | Was der Bot dafuer hat | Im Profil |
|---|---|---|
| Heiltraenke benutzen | Kampfstrategie `potions`: Gesundheitsstein oder Heiltrank bei kritischer Gesundheit, Manatrank bei wenig Mana. Der Server schaltet sie von sich aus **an** | Kampfflagge `potions` |
| Rezepte lernen, verzaubern, Questgegenstaende benutzen | Nichtkampfstrategie `maintenance` (Standard: **aus**): bei Gelegenheit `use random recipe`, `enchant random item` und `disenchant random item` (Beruf noetig), `use random quest item`, Questlog aufraeumen, Quests teilen und `smart destroy item` | Nichtkampfflagge `maintenance` -- nur als Buendel, die Teile lassen sich nicht einzeln schalten |
| Questobjekte einsammeln | steckt in `nc +loot`: der Bot nimmt Leichen **und Objekte** in der Naehe auf, auch Questobjekte, fuer die eine Quest laeuft; `ll normal` laesst Questgegenstaende zu | Nichtkampfflagge `loot` (schon vorhanden: Normal, Aggressiv, Plus) |
| Haltung des Begleiters | Chatbefehl `pet aggressive`, `pet defensive`, `pet passive` (kein Strategiewert) | Knopf *Haltung* im Profil: unveraendert / aggressiv / defensiv / passiv |
| Schriftrollen, Elixiere, Flaeschchen benutzen | **nichts**: der Bot benutzt sie nie von selbst. `buff` zeigt sie nur an, `s`/`b`/`give` verkaufen oder verschieben sie | nicht moeglich |

* **`potions`** ist in den vorgegebenen Profilen nicht gesetzt (der Server-Standard bleibt: an). In
  einem vorgegebenen Profil schaltet ein Klick durch *nicht gesetzt - an - aus*; `-potions` spart die
  eigenen Traenke. In **eigenen Profilen** gilt fuer ein Profil, das vor 11.5 gespeichert wurde, der Standard
  des Servers (an) -- nichts aendert sich still --; abwaehlen speichert ausdruecklich `-potions`.
* **`maintenance`** ist aus, solange du es nicht einschaltest. Das Buendel kann bei fast vollen Taschen
  (ab 90 %) Ueberfluessiges **vernichten** (`smart destroy item`) und zufaellig verzaubern oder entzaubern;
  schalte es nur ein, wenn du das willst. Verzaubern und Entzaubern brauchen den Beruf.
* **Begleiter.** Die Haltung geht beim Anwenden des Profils als `pet <Haltung>` an den Bot, aber nur, wenn du
  einen Begleiter hast (sonst antwortet der Bot mit einer Fehlermeldung). Rufst du ihn spaeter (Jaeger,
  Hexenmeister, Magier-Elementar, Schattengeist ...), zieht das Addon die Haltung eine Sekunde nach
  dem Ereignis `UNIT_PET` nach. Der Wert wird nur aus den drei erlaubten Woertern gebildet; ein beschaedigter
  Eintrag in der gespeicherten Datei wird verworfen und nie als Befehl gesendet. *unveraendert* sendet nichts.
  Die vorgegebenen Profile setzen keine Haltung; stell sie nach Wunsch ein (Minimal und Aengstlich
  etwa auf passiv).

## Verbindung und Protokoll

Das Addon sendet Befehle als Chatzeilen (`.at ...`). Ohne das Servermodul
antwortet AzerothCore einem normalen Spieler bei jedem davon mit "Es gibt keinen
solchen Befehl" -- und auf Servern mit `AllowPlayerCommands = 0` (nicht Standard)
behandelt der Core die Zeile sogar als gewoehnlichen Text, sodass der Charakter
`.at start ...` in /sagen riefe. Deshalb gilt:

1. Nach dem Anmelden (2,5 s Verzoegerung) geht `.at hello` hinaus.
2. Erst nach der Antwort `[AT]H|...` gehen weitere Modulbefehle hinaus. Befehle,
   die vorher anfallen, werden vorgemerkt und danach in Reihenfolge gesendet.
3. Kommt keine Antwort, gibt es einen zweiten Versuch; danach gilt das Modul als
   nicht vorhanden (`ABSENT`), und Modulbefehle werden **abgelehnt**, nicht
   gesendet. `/at hello` versucht es erneut. Kommt spaeter doch eine Statuszeile
   des Moduls (Antwort verloren, Neuladen mitten in der Reise), gilt es sofort
   wieder als vorhanden, damit Stop nie abgelehnt wird, waehrend der Autopilot
   faehrt.
4. Meldet das Modul sich als abgeschaltet oder zu alt, werden vorgemerkte Befehle
   verworfen und ein wartender Start zurueckgenommen.

Die Abfrage beim Anmelden laesst sich in den Optionen abschalten; dann erfolgt sie
erst beim ersten Start. Ein Server ohne Modul hoert in jedem Fall hoechstens ein-
oder zweimal `.at hello` (und antwortet darauf mit "Es gibt keinen solchen Befehl").

Befehle gehen mit Abstand hinaus (0,45 s -- knapp ueber der Befehlsbremse des
Servers von 400 ms; dringende wie Stop, Pause, Weiter 0,1 s und vor den anderen).
Ein noch wartender Start (auch hinter dem Handschlag) wird von Stop verworfen,
sodass er den Stop nicht auf der Leitung ueberholt. Gleichartige wartende Befehle ersetzen einander, sodass ein
Regler nur seinen letzten Wert meldet. Das Format der Nachrichten und die
Versionsregeln stehen in der README von mod-autotravel (Abschnitt "Protokoll").
Das Addon spricht Protokoll 4 und versteht auch Module mit Protokoll 3.

## Aenderungen in 11.5

* **Neue Profilwerte**: Kampfflagge `potions`, Nichtkampfflagge `maintenance` und die Haltung des
  Begleiters (siehe "Traenke, Wartung und Begleiter"). Eigene Profile aus aelteren Versionen behalten ihr
  Verhalten: `potions` gilt dort als an, `maintenance` als aus, die Haltung ist nicht gesetzt.
* Tests: 88 neue Pruefungen; `UnitExists` steht in den erlaubten Namen von luacheck.
* Das Protokoll aendert sich nicht.

## Aenderungen in 11.4

**Uebernehmen und Neu berechnen reagieren zuverlaessig.**

* Die Knoepfe werden nicht mehr ueber `Disable()` / `Enable()` des Clients gesperrt (nach
  vielen Wechseln verwarf der Client Klicks), sondern ueber einen eigenen Merker. Ein
  gesperrter Knopf bleibt sichtbar, ignoriert Klicks und nennt im Tooltip den Grund. Liegt die
  Maus schon auf dem Knopf, wenn er frei wird, ist er sofort hervorgehoben.
* **Ohne eigenen Stand der Reise** (nach `/reload`, per Chat gestartet) bleiben **Uebernehmen**
  und **Neu berechnen** klickbar, solange das Servermodul erreichbar ist (Zustand nicht
  `ABSENT`, `INCOMPATIBLE` oder `DISABLED`). Uebernehmen sendet dann `.at pause` und
  `.at status`, Neu berechnen `.at repath`; der Server entscheidet. Vorher meldete Uebernehmen
  nur "Keine Reise aktiv".
* Die Umlaute der Bedienelemente ("Uebernehmen" und die Tooltips) stehen jetzt als echte
  Umlaute im Panel (die Dateien sind UTF-8 ohne BOM).

**Pause in mehr Zustaenden.** Bei einer Reise, die das Addon kennt, ist Uebernehmen in jedem
Zustand moeglich, ausser im Kampf, bei der Uebergabe (dort heisst der Knopf Weiter) und in dem
kurzen Zustand "Startet" zwischen Klick auf START und erster Statuszeile (die Pause wuerde den
noch wartenden Start ueberholen). Vorher ging es nur bei "Berechnet neu", "Unterwegs", "Sitzt
auf" und "Hebt ab". Im Flug, auf einem Transport und beim Warten auf die Verbindung geht die
Anfrage an den Server; er lehnt dort mit einer Erklaerung ab ("in diesem Abschnitt steuert
niemand"), und das Addon zeigt keine Pause an.

**Laufende Reise nach dem Neuladen.** Nach dem Handschlag fragt das Addon einmal `.at status`
ab, noch vor den vorgemerkten Befehlen. Eine Reise, die der Server weiterfuehrt, erscheint
damit nach `/reload` wieder im Panel (Anzeige, Stop, Weiter, Uebernehmen). Wartet schon ein
Start auf den Handschlag, entfaellt die Abfrage; seine Statuszeile ist die Antwort.

**Playerbot-Strategien.**

* Die vorgegebenen Profile setzen `+dps assist` statt `+dps,+assist` und setzen `dps` und `heal`
  nicht mehr. Beides sind Klassenstrategien (beim Druiden Katzengestalt bzw. Wiederherstellung,
  die nicht angreift); `co !` waehlt die zum Talentbaum passende. In der Strategieliste des
  Editors heisst der Eintrag nun `dps assist`; `assist` allein gibt es dort nicht mehr. Wer
  `assist` schon in einem eigenen oder geaenderten Profil gespeichert hat, sendet es damit
  nicht mehr und setzt im Editor `dps assist` neu.
* **Druiden: die Strategie folgt der Gestalt.** Das Addon liest die aktuelle Gestalt (Baer,
  Katze, Mondkin, Baum des Lebens) und sendet die passende Kampfstrategie (`co +bear`,
  `co +cat`, `co +balance`, `co +resto`) hinter die Profilstrategien. Ohne Gestalt und in
  Reise-, Wasser- und Fluggestalt bleibt es bei der Vorgabe von `co !`. Bei Baer und Katze
  ohne Talentbaum Wilder Kampf (ab Stufe 10 der mit den meisten Punkten) kommt
  `,-aoe,-cc,-boost,-cure` dazu: diese Strategien haengen am Gleichgewichts-Zauber des Servers
  und scheitern in Tiergestalt.
* Bei einem Gestaltwechsel (`UPDATE_SHAPESHIFT_FORM`) wartet das Addon kurz (0,6 s) und sendet
  nur die Kampfstrategien neu: kein `nc`, keine Wartezeit, keine Profilmeldung. Das geschieht
  nur, wenn der Selbstmodus laeuft und sich die Gestalt wirklich geaendert hat.

**Diagnosebefehle.** `/at ui` und `/at strat` (siehe Befehle) zeigen, warum ein Knopf nicht
reagiert bzw. welche Strategien der Bot gerade hat.

## Fehlersuche

| Beobachtung | Ursache / Abhilfe |
|---|---|
| "Keine Antwort von mod-autotravel" | Modul fehlt oder ist nicht aktiv; Serverlog pruefen, dann `/at hello` |
| "Das Servermodul ist zu alt" | Modul auf 3.0 oder neuer bringen |
| "Carbonite nicht gefunden" | Carbonite (3.3.5a) installieren und aktivieren |
| "Zone ... konnte keiner WoW-Karte zugeordnet werden" | `/at karten`; sonst `/at karte <id>` |
| Teleport-Knopf grau | der Server erlaubt ihn dir nicht (`AutoTravel.TeleportSecurity`) |
| Optionen "Natuerliche Navigation" grau | serverweit, nur fuer Spielleiter |
| "Der Server verweigert den Playerbot-Selbstmodus" | `AiPlayerbot.SelfBotLevel` am Server |
| Weg wird nicht gefunden | `/at diag`; fehlen mmaps/vmaps fuer die Kachel? |
| Ein Knopf im Panel reagiert nicht | `/at ui`: zeigt, ob er gesperrt ist, ob Klicks ankommen und was unter der Maus liegt |

`/at debug` zeigt jeden gesendeten Befehl und die Diagnosemeldungen des Servers.

## Gespeicherte Daten

`AutoTravelDB` (je Charakter): Einstellungen, Fensterposition, aktives Profil.
`AutoTravelGlobalDB` (kontoweit): eigene Playerbot-Profile (`custom`) und deine Aenderungen
an den vorgegebenen (`builtin`; nur Profile, die du geaendert hast).
Beim Aktualisieren aus einer aelteren Fassung bleiben alle Werte erhalten; fehlende
neue Einstellungen erhalten Standardwerte. Der fruehere Standardbefehl
`.playerbots bot self on/off` wird auf den heutigen Umschalter umgestellt, falls du
ihn nie geaendert hast.

## Pruefen ohne Spiel

```
tests/check.sh
```

Benoetigt `lua5.1` (die Version, die WoW 3.3.5a benutzt), optional `luacheck`.
Drei Schritte: `luacheck` (findet nicht vorhandene Namen, etwa einen Aufruf vor
seiner Deklaration), Syntaxpruefung, und `tests/run.lua`: laedt das Addon in eine
Attrappe der WoW-API (`tests/mock_wow.lua`) und prueft Handschlag,
Warteschlange, Protokoll, Uebergabe, Routenaufteilung und Berechtigungen.

**Was das nicht prueft:** Aussehen und Anordnung, und ob die echte API sich so
verhaelt wie die Attrappe. Die Attrappe kennt nur Funktionen, die es in 3.3.5a
gibt, ersetzt aber keinen Test im Spiel.

## Dateien

| Datei | Inhalt |
|---|---|
| `AT_Net.lua` | Handschlag, Sendewarteschlange, Protokoll-Parser |
| `AT_Handover.lua` | Uebernehmen, Ruhe-Erkennung, Countdown |
| `AT_Core.lua` | Ziel und Route, Start/Stop, Teleport, Slash-Befehle |
| `AT_UI.lua` | Panel und Minimap-Knopf |
| `AT_Options.lua`, `AT_Profiles.lua` | Einstellungsseiten (mit Scrollbereich) |
| `AT_Bot.lua`, `AT_Gear.lua` | Playerbot-Selbstmodus, Erbstueckschutz |
| `AT_Carbonite.lua`, `AT_MapIds.lua` | Ziel aus Carbonite, Zonenname -> Karten-ID |
| `Bindings.xml` | Tastenbelegung |

## Lizenz

Dieses Repository enthaelt keine Lizenzdatei. Bevor es weitergegeben wird, sollte
der Eigentuemer eine festlegen.
