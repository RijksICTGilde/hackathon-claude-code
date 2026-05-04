# Oefeningen: werken met Claude Code

Deze categorie gaat over Claude Code zelf — niet over wat je bouwt, maar over hoe je werkt. Je onderzoekt slash-commands zoals `/clear`, plan mode, `--dangerously-skip-permissions`, zelf-review en de Ralph-loop. Wie ze bewust inzet, wint tempo en krijgt betere output. Als startpunt voor nog meer ideeën is de [cc.storyfox.cz cheat sheet](https://cc.storyfox.cz/) een handig naslagwerk dat je naast deze oefeningen kunt houden.

---

### Wanneer gebruik je `/clear` of `/compact`?

**Achtergrond:** Claude onthoudt alle context binnen één sessie. Bij lange sessies loopt die context vol — Claude begint eerder bereikte conclusies of stijlkeuzes door te mengen in latere antwoorden, of haalt details door elkaar uit ongerelateerde taken. Twee commando's helpen: `/clear` gooit de volledige sessie-context weg en geeft een schone lei; `/compact` laat Claude de huidige sessie eerst samenvatten en gaat verder met die samenvatting. Het verschil bepaalt wat je moet kiezen — `/clear` voor onderwerpwisseling, `/compact` voor doorlopend werk dat te lang werd.

**Vergelijk:**
- *Bad practice (geen reset):* één sessie open houden voor de wc-challenge, daarna overschakelen naar een JSON-parser, daarna een bug fixen in de wc-code — Claude trekt conclusies op basis van alle drie de contexten door elkaar.
- *Bad practice (verkeerde reset):* `/clear` gebruiken midden in een lange feature-implementatie omdat de context vol raakt — Claude vergeet waar je was en je moet de aanpak opnieuw uitleggen.
- *Good practice:* `/clear` tussen ongerelateerde taken, en ook tussendoor als Claude afdwaalt; `/compact` op het moment dat je context-bar bijna vol is terwijl je nog midden in dezelfde taak zit en de rode draad wil behouden.

**Probeer zelf:** Kies een eenvoudige challenge van [codingchallenges.fyi](https://codingchallenges.fyi/). Doe drie varianten:

1. Houd één sessie open, wissel midden in de implementatie van onderwerp (vraag iets over een andere taal of een ander probleem) en ga daarna verder met de challenge. Observeer waar en hoe Claude afdwaalt.
2. Herhaal met `/clear` op het moment van wisselen — vergelijk de kwaliteit.
3. Werk daarna door tot je context merkbaar gevuld is (lange logs, veel file-reads, meerdere correctierondes). Probeer `/compact` en kijk wat Claude in de samenvatting opneemt. Herken je je eigen aanpak nog?

**Wat je leert:** Je herkent het moment waarop context ruis wordt, en kiest tussen wegdoen (`/clear`) en condenseren (`/compact`) op basis van of je de rode draad nog nodig hebt.

---

### Hoe bouw je een goede `CLAUDE.md` op?

**Achtergrond:** `CLAUDE.md` is het per-project instructiebestand dat Claude in elke sessie meeneemt. Een goed bestand vangt projectconventies, pijnpunten, hoe je tests draait en wat Claude juist *niet* moet doen — kort, concreet en niet doublerend met code die hij toch al ziet. `/init` geeft je een eerste schets op basis van het project; daarna pas je hem aan op wat jij echt wil. Naast de project-`CLAUDE.md` is er ook een globale `~/.claude/CLAUDE.md` voor instructies die voor *al* je werk gelden (bv. taalvoorkeur, default review-stijl). De project-versie heeft voorrang waar ze elkaar tegenspreken.

**Vergelijk:**
- *Bad practice (leeg):* geen `CLAUDE.md` — Claude moet bij elke sessie raden hoe je tests draait, welke conventies tellen en wat een goede commit-message is. Iedere keer opnieuw uitleggen.
- *Bad practice (overvol):* een `CLAUDE.md` die de hele architectuur uitlegt en code-fragmenten herhaalt — Claude leest dat toch uit de codebase; jij verbruikt context aan info die hij niet nodig heeft.
- *Good practice:* korte, gerichte regels — "tests draai je met `make test`", "commit messages volgen Conventional Commits", "vermijd directe DB-queries in route-handlers" — plus een lijst met dingen waar Claude eerder fout ging in dit project.

**Probeer zelf:** Pak een lopende challenge zonder `CLAUDE.md`. Doe in deze volgorde:

1. Geen `CLAUDE.md`: vraag Claude een feature toe te voegen. Noteer hoeveel je moet bijsturen.
2. Genereer een eerste versie met `/init` en lees hem kritisch door — wat is generiek, wat is specifiek genoeg?
3. Verfijn handmatig: voeg twee à drie regels toe op basis van wat je in stap 1 telkens moest corrigeren. Haal weg wat overbodig is.
4. Doe dezelfde feature opnieuw in een verse sessie. Vergelijk hoeveel correctie je nu nog hoefde te geven.

Heb je werk dat over álle projecten gaat (bv. "antwoord altijd in het Nederlands" of "schrijf geen overbodige comments")? Zet dat in `~/.claude/CLAUDE.md` in plaats van per-project.

Voor onderhoud van een groeiend bestand — opschonen, tegenstrijdigheden signaleren — is de `claude-md-improver`-skill nuttig. Zie de [bijbehorende oefening](plugins-skills-tools.md) in de plugins-categorie.

**Wat je leert:** Je herkent welk soort instructies waarde toevoegen en welke alleen maar context kosten, en je ontwikkelt een gevoel voor de juiste lengte van een `CLAUDE.md`.

---

### Wat onthoudt Claude tussen sessies via memory?

**Achtergrond:** Naast `CLAUDE.md` heeft Claude Code een automatisch geheugen: tijdens je werk noteert hij dingen die volgens hem in een volgende sessie nuttig zijn — een corrigerende aanwijzing die je gaf, een conventie die uit een bug bleek, een voorkeur die je herhaaldelijk uitsprak. Het verschil met `CLAUDE.md` is dat `CLAUDE.md` door jou geschreven en bewust onderhouden is, terwijl memory door Claude wordt opgebouwd zonder dat je elke regel zelf typt. Per project bestaat een eigen memory-directory (gekoppeld aan de git-repo, gedeeld tussen worktrees). Met `/memory` bekijk en bewerk je wat er staat; auto-memory kun je via dezelfde plek aan- en uitzetten.

**Vergelijk:**
- *Bad practice:* dezelfde correctie meerdere sessies achter elkaar geven ("nee, gebruik `pnpm` niet `npm`", "antwoord in het Nederlands") — zonder memory blijft Claude die fout maken.
- *Good practice:* één keer corrigeren, controleren in `/memory` of het is opgeslagen, en bij twijfel handmatig bijsturen — zo wordt elke correctie hergebruikt in plaats van opnieuw uitgesproken.

**Probeer zelf:** Open `/memory` aan het begin van een sessie en kijk wat er al staat. Geef tijdens je werk een duidelijke correctie of voorkeur ("schrijf geen overbodige comments"). Sluit de sessie af, start een nieuwe en kijk of Claude het zonder herinnering toepast. Open `/memory` opnieuw — staat de regel erin? Probeer ook iets uit memory te verwijderen (zeg "vergeet wat ik zei over X" of bewerk via `/memory`) en controleer of dat werkt.

**Wat je leert:** Je begrijpt het verschil tussen `CLAUDE.md` (handgeschreven, expliciet) en memory (door Claude opgebouwd, kan stilletjes verouderen), en weet wanneer je actief moet bijsturen.

---

### Hoe stuur je per sessie het model, de denkdiepte en de kosten?

**Achtergrond:** Drie commando's geven runtime-controle over hoe Claude werkt:

- `/model` — kies tussen modellen (Opus voor complex redeneren, Sonnet voor de meeste taken, Haiku voor licht/snel werk).
- `/effort` — stel reasoning-diepte in (`low`, `medium`, `high`, `xhigh`, `max`). Hoger = dieper nadenken per stap, langzamer en duurder. `auto` zet hem terug op de default van het model.
- `/cost` — toont je verbruik in de huidige sessie (tokens, kosten, modelverdeling).

Deze drie samen geven je een knop om verbruik en kwaliteit per taak af te stemmen — een 10-regelige helper hoeft geen Opus + max, een architectuurschets verdient geen Haiku + low. Voor andere instellingen, zie `/help` of de [model configuration docs](https://code.claude.com/docs/en/model-config).

**Vergelijk:**
- *Bad practice:* default-instellingen voor alles gebruiken — Opus + xhigh op een rename-taak verbrandt budget; Haiku + low op een complexe refactor mist de diepte en levert iets oppervlakkigs op.
- *Good practice:* per taak bewust kiezen — model + effort omhoog voor planning, ontwerp en complex debuggen; omlaag voor mechanische edits, kleine fixes, eenvoudige scripts. `/cost` af en toe checken om je inschatting te toetsen.

**Probeer zelf:** Pak een challenge en voer dezelfde substantiële taak (bv. een feature met meerdere stappen) drie keer uit:

1. Default model en effort. Noteer doorlooptijd en `/cost`-resultaat.
2. Model omlaag (Sonnet of Haiku) en/of `/effort low`. Noteer hetzelfde.
3. Een lichte taak (bv. typo-fix of rename) op default én op omlaag-gezet — zie je verschil?

**Wat je leert:** Je krijgt een gevoel voor welke combinatie bij welk soort werk past, en voor de prijs/kwaliteit-curve van het model+effort-paar.

---

### Wanneer schakelt plan mode iets toe wat je anders mist?

**Achtergrond:** Plan mode dwingt Claude tot een expliciet plan vóórdat hij code aanpast. In plaats van meteen code te schrijven legt hij zijn aanpak voor, zodat jij kunt bijsturen voordat er werk verzet is dat je toch niet wilt.

**Vergelijk:**
- *Bad practice:* bij een complexe bug meteen "fix dit" roepen; Claude probeert iets, jij wijst af, hij probeert iets anders — een iteratief zoekproces zonder overzicht.
- *Good practice:* plan mode aan, het voorgestelde plan reviewen en eventueel corrigeren, daarna uitvoeren laten.

**Probeer zelf:** Pak een redelijk grote refactor in een bestaande challenge (bijvoorbeeld: zet een imperatief stuk code om naar een functionele stijl, of splits een grote klasse op). Doe de refactor twee keer: één keer direct zonder plan mode, één keer met plan mode aan. Vergelijk de uitkomst en de tijd die je kwijt was aan correcties.

**Wat je leert:** Je ervaart wanneer een expliciet plan de totale doorlooptijd verlaagt doordat je minder werk hoeft terug te draaien.

> Plan mode en subagents werken vaak goed samen: laat Claude in main het plan opstellen en delen van de uitvoering — typisch breed-zoeken, samenvatten — delegeren aan een subagent. Zie de [subagent-oefening](#wanneer-delegeer-je-aan-een-subagent) hieronder.

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

### Wanneer delegeer je aan een subagent?

**Achtergrond:** De Task/Agent-tool start een subagent in een eigen, geïsoleerd contextvenster. De subagent doet zijn werk — bestanden zoeken, logs uitpluizen, een diff analyseren — en stuurt alleen een samenvatting terug naar je hoofdsessie. Het verschil met "Claude doet het zelf" is dat de verbose tussenstappen (search-output, logregels, file-dumps) niet in jouw hoofdcontext belanden. Voor brede zoektaken op grote codebases is dat vaak het verschil tussen wel of niet ruimte overhouden voor de implementatie zelf. Specialised review-plugins zoals `pr-review-toolkit` werken intern via subagents — maar je kunt de Agent-tool ook expliciet zelf inroepen.

**Vergelijk:**
- *Bad practice:* Claude in je hoofdsessie laten zoeken naar "alle plekken waar functie X aangeroepen wordt" in een grote codebase — `grep`-resultaten en file-fragmenten vullen je context, en de daadwerkelijke fix moet daarna plaatsvinden in een al volgelopen sessie.
- *Good practice:* "Gebruik een subagent om alle aanroepen van X in kaart te brengen en alleen een lijst van bestand:regel-paren terug te geven" — de zoektocht blijft in de geïsoleerde context, jij krijgt een nette tabel terug en houdt ruimte voor de fix.

**Probeer zelf:** Pak een [codingchallenges.fyi](https://codingchallenges.fyi/)-challenge waar al wat code in zit. Doe dezelfde verkenning twee keer:

1. Zonder subagent: vraag Claude rechtstreeks "vind alle plekken waar X gebruikt wordt en leg uit hoe ze samenhangen". Bekijk hoe vol je context wordt — gebruik `/cost` om het verbruik te zien.
2. Met subagent: vraag "Gebruik een Agent-tool / subagent om alle plekken waar X gebruikt wordt op te sommen, geef alleen bestand:regel terug". Vergelijk hoeveel je context nu nog vrij is.

Doe daarna een vervolgstap (bijvoorbeeld een refactor van X) en kijk in welke variant Claude meer ruimte heeft om kwalitatief te werken.

**Wat je leert:** Je herkent welke taken zich lenen voor delegatie — typisch breed-zoeken, samenvatten, of werk waarvan alleen de conclusie telt — en welke je beter in je hoofdsessie houdt omdat je elke tussenstap zelf wil zien.

> Voor volledig autonoom itereren tot een taak af is, zie de [`ralph-loop`-oefening](plugins-skills-tools.md) in de plugins-categorie.
