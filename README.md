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
| `/at profil`, `/at bot`, `/at botan`, `/at botaus` | Playerbot-Profil und Selbstmodus |
| `/at karte <id>`, `/at karten` | Karten-ID erzwingen / Kartentabelle neu aufbauen |
| `/at optionen`, `/at panel`, `/at knopf`, `/at debug` | Oberflaeche und Diagnose |

## Playerbot-Selbstmodus

Optional steuert das Addon den Selbstmodus von mod-playerbots mit (Profile wie
*Verteidigen*, *Aggressiv*, eigene Profile). Gesendet werden nur Strategiebefehle
(`co`, `nc`, `ll`); `new rpg` wird in jedem festen Profil abgeschaltet, weil es
Ausruestung wechseln kann. Der Erbstueckschutz legt ein vom Bot abgelegtes
Erbstueck wieder an.

* `.playerbots bot self` ist ein **Umschalter**: derselbe Befehl schaltet ein und
  aus. Das Addon liest die Antwort des Servers mit ("SelfBot is now active." /
  "... deactivated."), statt den Zustand zu raten.
* Der Server kann den Selbstmodus verweigern (`AiPlayerbot.SelfBotLevel`; Standard
  1 = nur Spielleiter). Das Addon sagt dann, warum, und verwirft die
  Strategiebefehle, die schon in der Warteschlange standen.
* **Nicht zusammen mit BotPad** betreiben. Beide wuerden dem Bot bei jedem
  Einschalten Strategien schicken. BotPad erkennt AutoTravel und stellt seine
  Strategiesteuerung dann ab.

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

`/at debug` zeigt jeden gesendeten Befehl und die Diagnosemeldungen des Servers.

## Gespeicherte Daten

`AutoTravelDB` (je Charakter): Einstellungen, Fensterposition, aktives Profil.
`AutoTravelGlobalDB` (kontoweit): eigene Playerbot-Profile.
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
