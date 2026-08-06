# Oefeningen: werken met Claude Code

Deze categorie gaat over Claude Code zelf — niet over wat je bouwt, maar over hoe je werkt. Je onderzoekt slash-commands zoals `/clear`, plan mode, `--dangerously-skip-permissions`, subagents en zelf-review. Wie ze bewust inzet, wint tempo en krijgt betere output. Als startpunt voor nog meer ideeën is de [cc.storyfox.cz cheat sheet](https://cc.storyfox.cz/) een handig naslagwerk dat je naast deze oefeningen kunt houden.

---

### Wanneer gebruik je `/clear` of `/compact`?

**Achtergrond:** Bij lange sessies loopt de context vol — Claude haalt details door elkaar of vermengt eerdere conclusies met latere antwoorden. `/clear` gooit de context weg; `/compact` laat Claude eerst samenvatten en gaat verder met die samenvatting. Kies `/clear` voor onderwerpwisseling, `/compact` voor doorlopend werk dat te lang werd.

**Vergelijk:**
- *Bad practice:* één sessie open houden voor de wc-challenge, daarna een JSON-parser, daarna een bug fixen in de wc-code — Claude trekt conclusies over alle drie de contexten heen.
- *Good practice:* `/clear` tussen ongerelateerde taken (en als Claude afdwaalt); `/compact` als de context bijna vol is maar je nog in dezelfde taak zit en de rode draad wil behouden.

**Probeer zelf:** Kies een eenvoudige challenge van [codingchallenges.fyi](https://codingchallenges.fyi/). Houd één sessie open, wissel midden in de implementatie van onderwerp en ga daarna verder met de challenge — observeer waar Claude afdwaalt. Herhaal met `/clear` op het wisselmoment en vergelijk de kwaliteit. Werk daarna door tot je context merkbaar gevuld is en probeer `/compact`: herken je je eigen aanpak nog in de samenvatting?

**Wat je leert:** Je herkent het moment waarop context ruis wordt, en kiest tussen wegdoen (`/clear`) en condenseren (`/compact`) op basis van of je de rode draad nog nodig hebt.

---

### Hoe bouw je een goede `CLAUDE.md` op?

**Achtergrond:** `CLAUDE.md` is het per-project instructiebestand dat Claude in elke sessie meeneemt. Een goed bestand vangt projectconventies, pijnpunten, hoe je tests draait en wat Claude juist *niet* moet doen — kort, concreet, geen herhaling van code die hij toch al ziet. `/init` levert een eerste schets; daarna verfijn je het zelf. Naast project-`CLAUDE.md` bestaat ook een globale `~/.claude/CLAUDE.md` voor instructies die voor al je werk gelden (taalvoorkeur, default review-stijl). De project-versie heeft voorrang bij conflict.

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

Voor onderhoud van een groeiend bestand — opschonen, tegenstrijdigheden signaleren — is de `claude-md-improver`-skill nuttig. Zie de [bijbehorende oefening](plugins-skills-tools.md#wat-verandert-claude-md-management-aan-je-claudemd-onderhoud) in de plugins-categorie.

**Wat je leert:** Je herkent welk soort instructies waarde toevoegen en welke alleen maar context kosten, en je ontwikkelt een gevoel voor de juiste lengte van een `CLAUDE.md`.

---

### Wat onthoudt Claude tussen sessies via memory?

**Achtergrond:** Naast `CLAUDE.md` heeft Claude Code automatisch geheugen: tijdens je werk noteert hij wat hij in een volgende sessie nuttig acht — een correctie, een conventie die uit een bug bleek, een herhaalde voorkeur. Verschil met `CLAUDE.md`: dat schrijf jij bewust; memory bouwt Claude zelf op. Memory wordt opgeslagen in `~/.claude/projects/<project>/memory/` — alle worktrees binnen dezelfde repo delen één memory-directory ([Anthropic docs: Storage location](https://code.claude.com/docs/en/memory#storage-location)). Met `/memory` bekijk en bewerk je wat er staat.

**Vergelijk:**
- *Bad practice:* dezelfde correctie meerdere sessies geven ("gebruik `pnpm` niet `npm`") — zonder memory blijft Claude de fout maken.
- *Good practice:* één keer corrigeren, in `/memory` controleren of het is opgeslagen, bij twijfel handmatig bijsturen.

**Probeer zelf:** Open `/memory` aan het begin van een sessie. Geef tijdens je werk een duidelijke correctie of voorkeur ("schrijf geen overbodige comments"). Sluit de sessie, start een nieuwe en kijk of Claude het zonder herinnering toepast. Open `/memory` opnieuw — staat de regel erin? Probeer ook iets uit memory te verwijderen ("vergeet wat ik zei over X" of via `/memory`) en controleer of dat werkt.

**Wat je leert:** Je begrijpt het verschil tussen `CLAUDE.md` (handgeschreven, expliciet) en memory (door Claude opgebouwd, kan stilletjes verouderen), en weet wanneer je actief moet bijsturen.

---

### Hoe stuur je per sessie het model, de denkdiepte en de kosten?

**Achtergrond:** Drie commando's geven runtime-controle over hoe Claude werkt:

- `/model` — kies tussen modellen (Opus voor complex redeneren, Sonnet voor de meeste taken, Haiku voor licht/snel werk).
- `/effort` — stel reasoning-diepte in. Zie [model-config: effort levels](https://code.claude.com/docs/en/model-config#adjust-effort-level).
- `/cost` — toont je verbruik in de huidige sessie (tokens, kosten, modelverdeling).

Deze drie samen geven je een knop om verbruik en kwaliteit per taak af te stemmen — een 10-regelige helper hoeft geen Opus + max, een architectuurschets verdient geen Haiku. Voor andere instellingen, zie `/help` of de [model configuration docs](https://code.claude.com/docs/en/model-config).

**Vergelijk:**
- *Bad practice:* default-instellingen voor alles — Opus + xhigh op een rename verbrandt budget; Haiku op complexe refactor mist diepte.
- *Good practice:* per taak bewust kiezen — zwaarder model/hogere effort voor planning, ontwerp, complex debuggen; lichter voor mechanische edits, kleine fixes, eenvoudige scripts. `/cost` af en toe checken.

**Probeer zelf:** Pak een challenge en voer dezelfde substantiële taak (feature met meerdere stappen) twee keer uit: één keer met de standaardinstellingen voor model en effort, één keer met een lichter model of een lager effort-level (effort werkt niet op Haiku). Noteer doorlooptijd en `/cost` van beide. Doe daarna ook een lichte taak (typo-fix, rename) op de standaardinstellingen én op een lager niveau — zie je verschil?

**Wat je leert:** Je krijgt gevoel voor welke combinatie bij welk soort werk past, en voor de prijs/kwaliteit-curve van het model+effort-paar.

---

### Wanneer voegt plan mode iets toe dat je anders mist?

**Achtergrond:** Plan mode dwingt Claude een expliciet plan voor te leggen vóórdat hij code aanpast, zodat jij kunt bijsturen voordat er werk verzet is dat je toch niet wilt.

**Vergelijk:**
- *Bad practice:* bij een complexe bug meteen "fix dit" roepen; Claude probeert iets, jij wijst af, hij probeert iets anders — iteratief zoekproces zonder overzicht.
- *Good practice:* plan mode aan, plan reviewen en eventueel corrigeren, dan laten uitvoeren.

**Probeer zelf:** Pak een redelijk grote refactor (bv. imperatief naar functioneel, of grote klasse opsplitsen). Doe hem twee keer: één keer direct, één keer met plan mode aan. Vergelijk uitkomst en correctietijd.

**Wat je leert:** Je ervaart wanneer een expliciet plan totale doorlooptijd verlaagt doordat je minder werk hoeft terug te draaien.

> Plan mode en subagents werken vaak goed samen: laat Claude in de hoofdsessie het plan opstellen en delen van de uitvoering — denk aan brede zoekacties of samenvatten — aan een subagent delegeren. Zie de [subagent-oefening](#wanneer-delegeer-je-aan-een-subagent) hieronder.

---

### Hoe verandert je workflow met `--dangerously-skip-permissions` aan?

**Achtergrond:** Binnen deze container kun je Claude met `--dangerously-skip-permissions` draaien — alias `claude-danger`. De sandbox (firewall + volume-isolatie) beperkt risico's, neemt ze niet volledig weg. Buiten deze container is de vlag gevaarlijk en gebruik je hem niet. Met de vlag mag Claude files beheren, shell-commando's draaien, packages installeren en git-operaties doen zonder per actie te bevestigen.

**Vergelijk:**
- *Bad practice:* zonder de vlag werken — elke file-edit en shell-commando vraagt bevestiging, dat breekt de test-fix-test-loop continu.
- *Good practice:* binnen de sandbox vrij laten draaien; Claude ziet zelf de testuitvoer, herstelt de fout en draait de tests opnieuw zonder dat jij er tussen zit.

**Probeer zelf:** Pak een challenge met testsuite (bv. wc-challenge). Draai hem één keer in normale modus met handmatige bevestiging, daarna opnieuw met `claude-danger`. Noteer doorlooptijd en aantal prompts.

**Wat je leert:** Je ziet de waarde van de sandbox-aanpak en waarom `--dangerously-skip-permissions` hier een bewuste keuze is, geen noodgreep.

---

### Wat verandert er als je Claude zijn eigen werk laat reviewen?

**Achtergrond:** Na een implementatie kun je Claude een aparte review-prompt geven: vraag naar edge cases, error handling of performance. Een gerichte review-prompt activeert ander redeneerwerk dan de implementatie en vindt regelmatig issues die de eerste pass overslaat. Dit is ook de bouwsteen onder de [Ralph-loop-oefening](plugins-skills-tools.md#wat-doet-de-ralph-loop-voor-je-en-wanneer-gebruik-je-hem): een sterke review-prompt houdt autonome iteratie productief.

**Vergelijk:**
- *Bad practice:* één pass schrijven en als af beschouwen; happy path werkt, edge cases en foutafhandeling onbehandeld.
- *Good practice:* na de implementatie expliciet om review vragen, daarna fixen wat Claude zelf vindt.

**Probeer zelf:** Schrijf een feature zonder hints over kwaliteit. Vraag eerst een algemene review:

```
Review de code die je net hebt geschreven. Kijk naar edge cases, missende
error handling en performance-issues.
```

Doe het daarna gerichter:

```
Review de code. Focus specifiek op: wat gebeurt er bij lege invoer, bij
extreem grote bestanden en bij niet-UTF-8 tekens?
```

Vergelijk wat elke vorm oplevert.

**Wat je leert:** Specificiteit van je review-prompt bepaalt hoe diep Claude graaft, en een tweede pass levert bijna altijd iets op.

---

### Wanneer delegeer je aan een subagent?

**Achtergrond:** De Task/Agent-tool start een subagent in een eigen contextvenster. Die doet zijn werk — bestanden zoeken, logs uitpluizen, diff analyseren — en stuurt alleen een samenvatting terug. Verbose tussenstappen (search-output, logregels, file-dumps) belanden niet in jouw hoofdcontext. Bij brede zoektaken op grote codebases scheelt dat vaak ruimte voor de implementatie zelf. Review-plugins zoals `pr-review-toolkit` werken intern via subagents — maar je kunt de Agent-tool ook expliciet zelf inroepen.

**Vergelijk:**
- *Bad practice:* Claude in je hoofdsessie laten zoeken naar "alle plekken waar functie X aangeroepen wordt" in een grote codebase — `grep`-resultaten en file-fragmenten vullen je context, en de daadwerkelijke fix moet daarna plaatsvinden in een sessie waarvan de context al vol is.
- *Good practice:* "Gebruik een subagent om alle aanroepen van X in kaart te brengen en alleen een lijst van bestand:regel-paren terug te geven" — de zoektocht blijft in de geïsoleerde context, jij krijgt een nette tabel terug en houdt ruimte voor de fix.

**Probeer zelf:** Pak een [codingchallenges.fyi](https://codingchallenges.fyi/)-challenge waar al wat code in zit. Doe dezelfde verkenning twee keer:

1. Zonder subagent: vraag Claude rechtstreeks "vind alle plekken waar X gebruikt wordt en leg uit hoe ze samenhangen". Bekijk hoe vol je context wordt — gebruik `/cost` om het verbruik te zien.
2. Met subagent: vraag "Gebruik een Agent-tool / subagent om alle plekken waar X gebruikt wordt op te sommen, geef alleen bestand:regel terug". Vergelijk hoeveel je context nu nog vrij is.

Doe daarna een vervolgstap (bijvoorbeeld een refactor van X) en kijk in welke variant Claude meer ruimte heeft om kwalitatief te werken.

**Wat je leert:** Je herkent welke taken zich lenen voor delegatie — typisch breed-zoeken, samenvatten, of werk waarvan alleen de conclusie telt — en welke je beter in je hoofdsessie houdt omdat je elke tussenstap zelf wil zien.

> Voor volledig autonoom itereren tot een taak af is, zie de [`ralph-loop`-oefening](plugins-skills-tools.md#wat-doet-de-ralph-loop-voor-je-en-wanneer-gebruik-je-hem) in de plugins-categorie.
