-- AT_ConsumableData.lua
-- ---------------------------------------------------------------------------
-- ERZEUGT von tools/gen_consumables.py aus der Welt-Datenbank von AzerothCore
-- (item_template, spell_group, spell_ranks). Nicht von Hand aendern: neu erzeugen.
--
-- Eintrag je Gegenstand:  [Gegenstand] = { Art, Zauber, Stufe, Gegenstandsstufe [, Familie, Rang] }
--
--   Art      flask     Flaeschchen: belegt Kampf- UND Waechterplatz
--            battle    Kampfelixier   (je Charakter wirkt nur eines)
--            guardian  Waechterelixier (ebenso)
--            scroll    Schriftrolle: eine Familie (strength ...) mit Rang. Die sechs Werte teilen sich
--                      beim Server EINEN Platz (spell_group 1087, exklusiv); nur die
--                      Runenschriftrolle (fortitude) hat einen eigenen
--   Zauber   der Zauber, der als Buff auf dem Charakter liegt (meist der des Gegenstands; die Runen-
--            schriftrolle benutzt ein Script, der Buff ist ein anderer Zauber)
--
-- Nur Buffs, die im Kampf nuetzen. Wasseratmung, Unsichtbarkeit erkennen und andere
-- Hilfsmittel stehen nicht darin: der Server fasst sie nicht in die Elixiergruppen.
-- ---------------------------------------------------------------------------

AutoTravel = AutoTravel or {}
local AT = AutoTravel

AT.ConsData = {
   [954] = { "scroll", 8118, 1, 1, "strength", 1 },   -- Scroll of Strength
   [955] = { "scroll", 8096, 1, 1, "intellect", 1 },   -- Scroll of Intellect
   [1180] = { "scroll", 8099, 1, 1, "stamina", 1 },   -- Scroll of Stamina
   [1181] = { "scroll", 8112, 1, 1, "spirit", 1 },   -- Scroll of Spirit
   [1477] = { "scroll", 8116, 15, 25, "agility", 2 },   -- Scroll of Agility II
   [1478] = { "scroll", 8094, 15, 25, "protection", 2 },   -- Scroll of Protection II
   [1711] = { "scroll", 8100, 15, 20, "stamina", 2 },   -- Scroll of Stamina II
   [1712] = { "scroll", 8113, 15, 25, "spirit", 2 },   -- Scroll of Spirit II
   [2289] = { "scroll", 8119, 15, 25, "strength", 2 },   -- Scroll of Strength II
   [2290] = { "scroll", 8097, 15, 25, "intellect", 2 },   -- Scroll of Intellect II
   [2454] = { "battle", 2367, 1, 5 },   -- Elixir of Lion's Strength
   [2457] = { "battle", 2374, 2, 12 },   -- Elixir of Minor Agility
   [2458] = { "guardian", 2378, 2, 12 },   -- Elixir of Minor Fortitude
   [3012] = { "scroll", 8115, 1, 1, "agility", 1 },   -- Scroll of Agility
   [3013] = { "scroll", 8091, 1, 1, "protection", 1 },   -- Scroll of Protection
   [3382] = { "guardian", 3219, 1, 8 },   -- Weak Troll's Blood Elixir
   [3383] = { "guardian", 3166, 10, 20 },   -- Elixir of Wisdom
   [3388] = { "guardian", 3222, 15, 25 },   -- Strong Troll's Blood Elixir
   [3389] = { "guardian", 3220, 16, 26 },   -- Elixir of Defense
   [3390] = { "battle", 3160, 18, 28 },   -- Elixir of Lesser Agility
   [3391] = { "battle", 3164, 20, 30 },   -- Elixir of Ogre's Strength
   [3825] = { "guardian", 3593, 25, 35 },   -- Elixir of Fortitude
   [3826] = { "guardian", 3223, 26, 36 },   -- Major Troll's Blood Elixir
   [4419] = { "scroll", 8098, 30, 40, "intellect", 3 },   -- Scroll of Intellect III
   [4421] = { "scroll", 8095, 30, 40, "protection", 3 },   -- Scroll of Protection III
   [4422] = { "scroll", 8101, 30, 40, "stamina", 3 },   -- Scroll of Stamina III
   [4424] = { "scroll", 8114, 30, 40, "spirit", 3 },   -- Scroll of Spirit III
   [4425] = { "scroll", 8117, 30, 40, "agility", 3 },   -- Scroll of Agility III
   [4426] = { "scroll", 8120, 30, 40, "strength", 3 },   -- Scroll of Strength III
   [5997] = { "guardian", 673, 1, 5 },   -- Elixir of Minor Defense
   [6373] = { "battle", 7844, 18, 28 },   -- Elixir of Firepower
   [6662] = { "battle", 8212, 8, 18 },   -- Elixir of Giant Growth
   [8949] = { "battle", 11328, 27, 37 },   -- Elixir of Agility
   [8951] = { "guardian", 11349, 29, 39 },   -- Elixir of Greater Defense
   [9088] = { "guardian", 11371, 38, 48 },   -- Gift of Arthas
   [9155] = { "battle", 11390, 37, 47 },   -- Arcane Elixir
   [9179] = { "guardian", 11396, 37, 47 },   -- Elixir of Greater Intellect
   [9187] = { "battle", 11334, 38, 48 },   -- Elixir of Greater Agility
   [9206] = { "battle", 11405, 38, 48 },   -- Elixir of Giants
   [9224] = { "battle", 11406, 40, 50 },   -- Elixir of Demonslaying
   [9264] = { "battle", 11474, 40, 50 },   -- Elixir of Shadow Power
   [10305] = { "scroll", 12175, 40, 50, "protection", 4 },   -- Scroll of Protection IV
   [10306] = { "scroll", 12177, 40, 50, "spirit", 4 },   -- Scroll of Spirit IV
   [10307] = { "scroll", 12178, 40, 50, "stamina", 4 },   -- Scroll of Stamina IV
   [10308] = { "scroll", 12176, 40, 50, "intellect", 4 },   -- Scroll of Intellect IV
   [10309] = { "scroll", 12174, 40, 50, "agility", 4 },   -- Scroll of Agility IV
   [10310] = { "scroll", 12179, 40, 50, "strength", 4 },   -- Scroll of Strength IV
   [12820] = { "battle", 17038, 45, 50 },   -- Winterfall Firewater
   [13445] = { "guardian", 11348, 43, 53 },   -- Elixir of Superior Defense
   [13447] = { "guardian", 17535, 44, 54 },   -- Elixir of the Sages
   [13452] = { "battle", 17538, 46, 56 },   -- Elixir of the Mongoose
   [13453] = { "battle", 17537, 45, 55 },   -- Elixir of Brute Force
   [13454] = { "battle", 17539, 47, 57 },   -- Greater Arcane Elixir
   [13510] = { "flask", 17626, 50, 60 },   -- Flask of the Titans
   [13511] = { "flask", 17627, 50, 60 },   -- Flask of Distilled Wisdom
   [13512] = { "flask", 17628, 50, 60 },   -- Flask of Supreme Power
   [13513] = { "flask", 17629, 50, 60 },   -- Flask of Chromatic Resistance
   [17708] = { "battle", 21920, 28, 38 },   -- Elixir of Frost Power
   [20004] = { "guardian", 24361, 53, 58 },   -- Mighty Troll's Blood Elixir
   [20007] = { "guardian", 24363, 40, 50 },   -- Mageblood Elixir
   [21546] = { "battle", 26276, 40, 50 },   -- Elixir of Greater Firepower
   [22824] = { "battle", 28490, 50, 61 },   -- Elixir of Major Strength
   [22825] = { "battle", 28491, 50, 61 },   -- Elixir of Healing Power
   [22827] = { "battle", 28493, 50, 64 },   -- Elixir of Major Frost Power
   [22831] = { "battle", 54494, 55, 66 },   -- Elixir of Major Agility
   [22833] = { "battle", 28501, 50, 64 },   -- Elixir of Major Firepower
   [22834] = { "guardian", 28502, 55, 69 },   -- Elixir of Major Defense
   [22835] = { "battle", 28503, 60, 70 },   -- Elixir of Major Shadow Power
   [22840] = { "guardian", 28509, 60, 70 },   -- Elixir of Major Mageblood
   [22848] = { "guardian", 28514, 60, 70 },   -- Elixir of Empowerment
   [22851] = { "flask", 28518, 65, 70 },   -- Flask of Fortification
   [22853] = { "flask", 28519, 65, 70 },   -- Flask of Mighty Restoration
   [22854] = { "flask", 28520, 65, 70 },   -- Flask of Relentless Assault
   [22861] = { "flask", 28521, 65, 70 },   -- Flask of Blinding Light
   [22866] = { "flask", 28540, 65, 70 },   -- Flask of Pure Death
   [23444] = { "guardian", 29348, 0, 10 },   -- Goldenmist Special Brew
   [27498] = { "scroll", 33077, 50, 60, "agility", 5 },   -- Scroll of Agility V
   [27499] = { "scroll", 33078, 50, 60, "intellect", 5 },   -- Scroll of Intellect V
   [27500] = { "scroll", 33079, 50, 60, "protection", 5 },   -- Scroll of Protection V
   [27501] = { "scroll", 33080, 50, 60, "spirit", 5 },   -- Scroll of Spirit V
   [27502] = { "scroll", 33081, 50, 60, "stamina", 5 },   -- Scroll of Stamina V
   [27503] = { "scroll", 33082, 50, 60, "strength", 5 },   -- Scroll of Strength V
   [28102] = { "battle", 33720, 50, 60 },   -- Onslaught Elixir
   [28103] = { "battle", 54452, 50, 60 },   -- Adept's Elixir
   [28104] = { "battle", 33726, 50, 63 },   -- Elixir of Mastery
   [31679] = { "battle", 38954, 60, 67 },   -- Fel Strength Elixir
   [32062] = { "guardian", 39625, 50, 61 },   -- Elixir of Major Fortitude
   [32063] = { "guardian", 39626, 50, 63 },   -- Earthen Elixir
   [32067] = { "guardian", 39627, 50, 64 },   -- Elixir of Draenic Wisdom
   [32068] = { "guardian", 39628, 55, 66 },   -- Elixir of Ironskin
   [32596] = { "flask", 40568, 65, 70 },   -- Unstable Flask of the Elder
   [32597] = { "flask", 40575, 65, 70 },   -- Unstable Flask of the Soldier
   [32598] = { "flask", 40572, 65, 70 },   -- Unstable Flask of the Beast
   [32599] = { "flask", 40567, 65, 70 },   -- Unstable Flask of the Bandit
   [32600] = { "flask", 40573, 65, 70 },   -- Unstable Flask of the Physician
   [32601] = { "flask", 40576, 65, 70 },   -- Unstable Flask of the Sorcerer
   [32764] = { "flask", 28518, 65, 75 },   -- Flaskataur's Celestial Brew
   [32765] = { "flask", 28520, 65, 75 },   -- Flaskataur's Tears
   [32766] = { "flask", 28519, 65, 75 },   -- Flaskataur's Flask of Flaskocity
   [32767] = { "flask", 17628, 50, 60 },   -- Flaskataur's Flask of Pretty Good Power
   [32898] = { "flask", 41609, 70, 70 },   -- Shattrath Flask of Fortification
   [32899] = { "flask", 41610, 70, 70 },   -- Shattrath Flask of Mighty Restoration
   [32900] = { "flask", 41611, 70, 70 },   -- Shattrath Flask of Supreme Power
   [32901] = { "flask", 41608, 70, 70 },   -- Shattrath Flask of Relentless Assault
   [33208] = { "flask", 42735, 65, 70 },   -- Flask of Chromatic Wonder
   [33457] = { "scroll", 43194, 60, 70, "agility", 6 },   -- Scroll of Agility VI
   [33458] = { "scroll", 43195, 60, 70, "intellect", 6 },   -- Scroll of Intellect VI
   [33459] = { "scroll", 43196, 60, 70, "protection", 6 },   -- Scroll of Protection VI
   [33460] = { "scroll", 43197, 60, 70, "spirit", 6 },   -- Scroll of Spirit VI
   [33461] = { "scroll", 43198, 60, 70, "stamina", 6 },   -- Scroll of Stamina VI
   [33462] = { "scroll", 43199, 60, 70, "strength", 6 },   -- Scroll of Strength VI
   [34537] = { "battle", 45373, 70, 70 },   -- Bloodberry Elixir
   [35716] = { "flask", 46837, 70, 70 },   -- Shattrath Flask of Pure Death
   [35717] = { "flask", 46839, 70, 70 },   -- Shattrath Flask of Blinding Light
   [37091] = { "scroll", 48099, 70, 80, "intellect", 7 },   -- Scroll of Intellect VII
   [37092] = { "scroll", 48100, 80, 90, "intellect", 8 },   -- Scroll of Intellect VIII
   [37093] = { "scroll", 48101, 70, 80, "stamina", 7 },   -- Scroll of Stamina VII
   [37094] = { "scroll", 48102, 80, 90, "stamina", 8 },   -- Scroll of Stamina VIII
   [37097] = { "scroll", 48103, 70, 80, "spirit", 7 },   -- Scroll of Spirit VII
   [37098] = { "scroll", 48104, 80, 90, "spirit", 8 },   -- Scroll of Spirit VIII
   [39666] = { "battle", 28497, 70, 80 },   -- Elixir of Mighty Agility
   [40068] = { "battle", 53746, 70, 80 },   -- Wrath Elixir
   [40070] = { "battle", 33721, 70, 80 },   -- Spellpower Elixir
   [40072] = { "guardian", 53747, 70, 80 },   -- Elixir of Spirit
   [40073] = { "battle", 53748, 70, 80 },   -- Elixir of Mighty Strength
   [40076] = { "battle", 53749, 70, 80 },   -- Guru's Elixir
   [40078] = { "guardian", 53751, 70, 80 },   -- Elixir of Mighty Fortitude
   [40079] = { "flask", 53752, 70, 80 },   -- Lesser Flask of Toughness
   [40097] = { "guardian", 53763, 70, 80 },   -- Elixir of Protection
   [40109] = { "guardian", 53764, 70, 80 },   -- Elixir of Mighty Mageblood
   [43463] = { "scroll", 58450, 70, 80, "agility", 7 },   -- Scroll of Agility VII
   [43464] = { "scroll", 58451, 80, 90, "agility", 8 },   -- Scroll of Agility VIII
   [43465] = { "scroll", 58448, 70, 80, "strength", 7 },   -- Scroll of Strength VII
   [43466] = { "scroll", 58449, 80, 90, "strength", 8 },   -- Scroll of Strength VIII
   [43467] = { "scroll", 58452, 70, 80, "protection", 7 },   -- Scroll of Protection VII
   [43468] = { "scroll", 58453, 80, 80, "protection", 8 },   -- Scroll of Protection VIII
   [44325] = { "battle", 60340, 70, 80 },   -- Elixir of Accuracy
   [44327] = { "battle", 60341, 70, 80 },   -- Elixir of Deadly Strikes
   [44328] = { "guardian", 60343, 70, 80 },   -- Elixir of Mighty Defense
   [44329] = { "battle", 60344, 70, 80 },   -- Elixir of Expertise
   [44330] = { "battle", 60345, 70, 80 },   -- Elixir of Armor Piercing
   [44331] = { "battle", 60346, 70, 80 },   -- Elixir of Lightning Speed
   [44332] = { "guardian", 60347, 70, 80 },   -- Elixir of Mighty Thoughts
   [44939] = { "flask", 62380, 70, 80 },   -- Lesser Flask of Resistance
   [45006] = { "flask", 53760, 75, 85 },   -- Jillian's Tonic of Endless Rage
   [45007] = { "flask", 54212, 75, 85 },   -- Jillian's Tonic of Pure Mojo
   [45008] = { "flask", 53758, 75, 85 },   -- Jillian's Tonic of Stoneblood
   [45009] = { "flask", 53755, 75, 85 },   -- Jillian's Tonic of the Frost Wyrm
   [45621] = { "battle", 63729, 15, 20 },   -- Elixir of Minor Accuracy
   [46376] = { "flask", 53755, 75, 85 },   -- Flask of the Frost Wyrm
   [46377] = { "flask", 53760, 75, 85 },   -- Flask of Endless Rage
   [46378] = { "flask", 54212, 75, 85 },   -- Flask of Pure Mojo
   [46379] = { "flask", 53758, 75, 85 },   -- Flask of Stoneblood
   [49632] = { "scroll", 72590, 80, 90, "fortitude", 1 },   -- Runescroll of Fortitude
}

-- Zaubergruppen des Servers, mit allen Stufen. Nicht nur Elixiere und Flaeschchen: Wirkt irgendein Zauber
-- der Gruppe, ist der Platz belegt, und ein neuer Buff wuerde ihn ersetzen (oder wird abgewiesen).
AT.ConsGroups = {
   -- spell_group 1 und 2: Kampf- und Waechterelixiere (Regel 1, einer wirkt); auch Juju, Zanza, R.O.I.D.S.,
   -- Wasserwandeln u. a. stehen darin
   battle = {
      2367, 2374, 3160, 3164, 7844, 8212, 10667, 10669, 11328, 11334, 11390, 11405, 11406, 11474,
      16322, 16323, 16329, 17038, 17537, 17538, 17539, 17626, 17627, 17628, 17629, 21920, 26276,
      28490, 28491, 28493, 28497, 28501, 28503, 28518, 28519, 28520, 28521, 28540, 33053, 33720,
      33721, 33726, 38954, 40567, 40568, 40572, 40573, 40575, 40576, 41608, 41609, 41610, 41611,
      42735, 45373, 46837, 46839, 53746, 53748, 53749, 53752, 53755, 53758, 53760, 54212, 54452,
      54494, 60340, 60341, 60344, 60345, 60346, 62380, 63729, 67016, 67017, 67018,
   },
   guardian = {
      673, 2378, 2380, 3166, 3219, 3220, 3222, 3223, 3593, 10668, 10692, 10693, 11319, 11348,
      11349, 11371, 11396, 15231, 15233, 16321, 16325, 16326, 16327, 17535, 17626, 17627, 17628,
      17629, 24361, 24363, 24382, 24383, 24417, 27652, 27653, 28502, 28509, 28514, 28518, 28519,
      28520, 28521, 28540, 29348, 39625, 39626, 39627, 39628, 40567, 40568, 40572, 40573, 40575,
      40576, 41608, 41609, 41610, 41611, 42735, 46837, 46839, 53747, 53751, 53752, 53755, 53758,
      53760, 53763, 53764, 54212, 60343, 60347, 62380, 67016, 67017, 67018,
   },
   -- spell_group 1084, "Single Stamina Buffs" (Regel 4: nur der staerkste wirkt): Machtwort und Gebet der
   -- Seelenstaerke, Schriftrollen der Ausdauer, Runenschriftrolle. Eine Runenschriftrolle neben einem
   -- staerkeren dieser Buffs ist umsonst: der Kern verwirft den schwaecheren Buff, nachdem der Gegenstand
   -- verbraucht ist.
   stamina = {
      1243, 1244, 1245, 2791, 8099, 8100, 8101, 10937, 10938, 12178, 21562, 21564, 23947, 23948,
      25389, 25392, 33081, 43198, 48101, 48102, 48161, 48162, 72590,
   },
}
