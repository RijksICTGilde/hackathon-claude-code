# Oefeningen: werken met Claude Code

Deze categorie gaat over Claude Code zelf — niet over wat je bouwt, maar over hoe je werkt. Je onderzoekt slash-commands zoals `/clear`, plan mode, `--dangerously-skip-permissions`, zelf-review en de Ralph-loop. Wie ze bewust inzet, wint tempo en krijgt betere output. Als startpunt voor nog meer ideeën is de [cc.storyfox.cz cheat sheet](https://cc.storyfox.cz/) een handig naslagwerk dat je naast deze oefeningen kunt houden.

---

### Wanneer moet je `/clear` gebruiken?

**Achtergrond:** Claude onthoudt alle context binnen één sessie. Bij lange sessies met meerdere ongerelateerde onderwerpen loopt de context vol en begint Claude eerder bereikte conclusies of stijlkeuzes uit eerdere taken door te mengen in latere antwoorden. `/clear` gooit de volledige sessie-context weg en geeft Claude een schone lei.

**Vergelijk:**
- *Bad practice:* één sessie open houden voor de wc-challenge, daarna overschakelen naar een JSON-parser, daarna een bug fixen in de wc-code — Claude trekt conclusies op basis van alle drie de contexten door elkaar.
- *Good practice:* `/clear` gebruiken tussen ongerelateerde taken, en ook tussendoor als je merkt dat Claude afdwaalt of dingen herhaalt die nergens meer op slaan.

**Probeer zelf:** Kies een eenvoudige challenge van [codingchallenges.fyi](https://codingchallenges.fyi/). Doe de bad-variant: houd één sessie open, wissel midden in de implementatie van onderwerp (vraag iets over een andere taal of een ander probleem) en ga daarna verder met de challenge. Observeer waar en hoe Claude afdwaalt. Herhaal de challenge met `/clear` op het juiste moment en vergelijk de kwaliteit van de output.

**Wat je leert:** Je herkent het moment waarop context ruis wordt en `/clear` meer oplevert dan doorgaan in dezelfde sessie.

---

### Wanneer schakelt plan mode iets toe wat je anders mist?

**Achtergrond:** Plan mode dwingt Claude tot een expliciet plan vóórdat hij code aanpast. In plaats van meteen code te schrijven legt hij zijn aanpak voor, zodat jij kunt bijsturen voordat er werk verzet is dat je toch niet wilt.

**Vergelijk:**
- *Bad practice:* bij een complexe bug meteen "fix dit" roepen; Claude probeert iets, jij wijst af, hij probeert iets anders — een iteratief zoekproces zonder overzicht.
- *Good practice:* plan mode aan, het voorgestelde plan reviewen en eventueel corrigeren, daarna uitvoeren laten.

**Probeer zelf:** Pak een redelijk grote refactor in een bestaande challenge (bijvoorbeeld: zet een imperatief stuk code om naar een functionele stijl, of splits een grote klasse op). Doe de refactor twee keer: één keer direct zonder plan mode, één keer met plan mode aan. Vergelijk de uitkomst en de tijd die je kwijt was aan correcties.

**Wat je leert:** Je ervaart wanneer een expliciet plan de totale doorlooptijd verlaagt doordat je minder werk hoeft terug te draaien.

---

### Hoe verandert je workflow met `--dangerously-skip-permissions` aan?

**Achtergrond:** Binnen deze container kun je Claude desgewenst met `--dangerously-skip-permissions` draaien — gebruik de alias `claude-danger` als afkorting. De container-sandbox — firewall en volume-isolatie — beperkt de risico's, maar neemt ze nooit volledig weg. Buiten deze container is dezelfde vlag gevaarlijk en gebruik je hem niet. Met de vlag kan Claude files beheren, shell-commando's uitvoeren, packages installeren en git-operaties doen zonder per actie te bevestigen.

**Vergelijk:**
- *Bad practice:* zonder de vlag werken: bij elke file-edit en elk shell-commando moet je handmatig bevestigen — dat onderbreekt de strakke test-fix-test-feedback-loop continu.
- *Good practice:* binnen de sandbox vrij laten draaien; Claude ziet zelf de testuitvoer, herstelt de fout en draait de tests opnieuw — zonder dat jij er tussen zit.

**Probeer zelf:** Pak een challenge met een testsuite (bijv. de wc-challenge). Draai hem één keer met Claude in de normale modus, waarbij je elke actie handmatig bevestigt. Draai hem daarna opnieuw met `claude-danger`. Noteer de doorlooptijd en het aantal keer dat je de prompt raakte.

**Wat je leert:** Je begrijpt welke waarde de sandbox-aanpak van deze container heeft en waarom `--dangerously-skip-permissions` hier een bewuste keuze is, niet een noodgreep.

---

### Wat verandert er als je Claude zijn eigen werk laat reviewen?

**Achtergrond:** Na een implementatie kun je Claude een aparte review-prompt geven: vraag hem naar edge cases, error handling of performance. Claude kijkt dan met andere ogen naar zijn eigen code en vindt regelmatig issues die hij in de eerste pass heeft overgeslagen — niet omdat hij het vergeten was, maar omdat een gerichte review-prompt een ander deel van zijn redenering activeert. Dit is ook een belangrijke bouwsteen voor de Ralph-loop hieronder: een goede zelf-review-prompt is precies wat een autonome iteratie productief houdt.

**Vergelijk:**
- *Bad practice:* één pass schrijven en direct als af beschouwen; de code werkt voor de happy path, maar edge cases en foutafhandeling zijn onbehandeld.
- *Good practice:* na de implementatie expliciet om review vragen, daarna fixen wat Claude zelf vindt.

**Probeer zelf:** Schrijf een feature of los een challenge op zonder hints over kwaliteit. Vraag daarna:

```
Review de code die je net hebt geschreven. Kijk naar edge cases, missende
error handling en performance-issues.
```

Doe dit een tweede keer, maar vraag nu gerichter:

```
Review de code. Focus specifiek op: wat gebeurt er bij lege invoer, bij
extreem grote bestanden en bij niet-UTF-8 tekens?
```

Vergelijk wat elke reviewvorm oplevert.

**Wat je leert:** Je ontdekt hoe de specificiteit van je review-prompt bepaalt hoe diep Claude graaft, en dat een tweede pass bijna altijd iets oplevert.

---

### Wat doet de Ralph-loop voor je en wanneer gebruik je hem?

**Achtergrond:** De Ralph-loop, oorspronkelijk beschreven door [Geoffrey Huntley](https://ghuntley.com/ralph/), zet Claude in een loop met dezelfde prompt zodat hij vanzelf blijft itereren tot een taak af is. Perfect voor challenges waar je gewoon wilt dat het eindresultaat er komt zonder dat je zelf elke iteratie hoeft te starten. In deze container zit Anthropic's officiële [`ralph-wiggum`](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) plugin standaard mee (in de marketplace ook bekend als [`ralph-loop`](https://claude.com/plugins/ralph-loop)). Hij levert de slash-commands `/ralph-loop` en `/cancel-ralph`, een Stop-hook die sessie-exits onderschept, en `--max-iterations` als veiligheidsnet. De zelf-review-oefening hierboven is een natuurlijke bouwsteen: een sterke review-prompt geeft de loop iets concreets om elke iteratie aan af te meten.

**Vergelijk:**
- *Bad practice:* een vage prompt loslaten zonder iteratielimiet — Claude itereert eindeloos zonder richting, verbrandt tokens en convergeert niet.
- *Good practice:* heldere completion-criteria in je prompt én een harde iteratielimiet — `--max-iterations` is je primaire veiligheidsmaatregel, niet de exacte string-matching van `--completion-promise`.

**Probeer zelf:** Draai `/ralph-loop` op een challenge met heldere tests, bijvoorbeeld de wc-challenge van [codingchallenges.fyi](https://codingchallenges.fyi/). Geef altijd `--max-iterations` mee als veiligheidsnet en formuleer een duidelijk completion-criterium in je prompt. Vergelijk hoe ver Claude komt zonder tussenkomst — let bij het meekijken op of de iteraties écht vooruitgang boeken of dat hij in cirkels gaat.

**Wat je leert:** Je ervaart wanneer volledig autonoom itereren sneller gaat dan zelf de loop bewaken, en welke randvoorwaarden (heldere completion-criteria, harde iteratielimiet, afgebakende taak) noodzakelijk zijn om productief te itereren in plaats van tokens te verbranden.
