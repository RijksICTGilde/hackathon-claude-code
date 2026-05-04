# Oefeningen: plugins, skills en tools

Deze categorie gaat over de skills, plugins en CLI-tools die in de container zitten. Ze bouwen voort op een kale Claude Code-installatie met domeinkennis, gespecialiseerde review-agents en context-optimalisatie. Wie ze bewust inzet haalt meer uit de container dan wie ze links laat liggen.

## Snelle vs diepe vergelijking

Iedere oefening hieronder bevat een "probeer zelf"-stap waarin je het verschil ervaart tussen *met* en *zonder* een plugin. Dat kan op twee manieren:

- **Snel (per plugin, runtime, omkeerbaar):** `claude plugin disable <naam>` schakelt één plugin uit zonder rebuild. Je commando's en skill-discovery werken meteen alsof de plugin er niet is. Terugzetten met `claude plugin enable <naam>`. Vanuit een lopende Claude-sessie kan dit ook via het slash-commando `/plugin` (opent een interactief menu waar je plugins in- en uitschakelt). Dit is in vrijwel alle gevallen afdoende.
- **Diep (per groep, build-time):** een `INSTALL_*`-toggle op `false` in `.env` plus image-rebuild en volume-recreate (zie [README claude-sandbox](../../claude-sandbox/README.md#optionele-componenten)). Pas nodig als je écht wil zien hoe de container draait zonder dat de plugin ooit geïnstalleerd is — bijvoorbeeld om autoload-effecten of disk-footprint te onderzoeken.

> **Granulariteit:** de build-time toggles zijn grof. `INSTALL_OVERHEID_PLUGINS=false` haalt alle DON-plugins ineens weg, `INSTALL_ANTHROPIC_PLUGINS=false` alle Anthropic-plugins. De runtime-disable lost dat op: je kunt één enkele plugin uitzetten zonder de rest te raken.

De oefeningen hieronder gebruiken standaard de snelle variant en noemen de diepe waar die extra inzicht oplevert.

---

### Wat doet de overheid-marketplace voor je werk?

**Achtergrond:** De container bevat skills uit `developer-overheid-nl/skills-marketplace`: `standaarden`, `nerds`, `internet`, `geo`, `developer-overheid` en `zad-actions`. Ze zijn relevant als je werk dicht bij Nederlandse overheidsstandaarden ligt — denk aan API-design, authenticatie, berichtenuitwisseling of geodiensten. Zonder deze skills leunt Claude op generieke kennis en mist hij NL-specifieke regels zoals problem+json, ADR, OIN of Digikoppeling.

**Vergelijk:**
- *Bad practice:* een REST-API bouwen zonder de skills aan te roepen — Claude schrijft een generieke API zonder rekening te houden met de API Design Rules, ADR-linting of het problem+json-formaat.
- *Good practice:* dezelfde challenge starten met "gebruik `standaarden:ls-api` om de API te toetsen aan de ADR" en zo NL-specifieke regels automatisch meenemen.

**Probeer zelf:** Pak een challenge die op je dagelijks werk lijkt (bv. een REST-endpoint, een koppelvlak of een kaartdienst). Doe hem twee keer:

1. Plugin uit: `claude plugin disable standaarden` (of `geo`, `nerds`, `internet` afhankelijk van je challenge). Draai de challenge.
2. Plugin aan: `claude plugin enable standaarden`. Draai dezelfde challenge en roep de skill expliciet aan, bv. "gebruik `standaarden:ls-api` om de API te toetsen aan de ADR".

Welke skills bij welk werk passen: REST API → `standaarden:ls-api` (ADR/linting/problem+json); koppelvlak/auth → `standaarden:ls-iam`, `standaarden:ls-fsc`; basisregistratie → `standaarden:ls-dk` (Digikoppeling); notificatie/event → `standaarden:ls-notif` (CloudEvents); kaart/geo → `geo:*` skills.

> **Diepe variant:** zet `INSTALL_OVERHEID_PLUGINS=false` in `.env` en herbouw de image (rebuild + volume-recreate). Hiermee verdwijnen alle DON-plugins ineens — handig als je wil zien hoe de container draait zonder enige NL-overheidskennis.

**Wat je leert:** Je ziet concreet welke NL-overheidsspecifieke kennis de marketplace toevoegt ten opzichte van generieke Claude-kennis.

---

### Wanneer voegt rtk (token reduction) merkbaar waarde toe?

**Achtergrond:** `rtk` knipt overbodige tokens uit — witruimte, comments, herhalende structuren — voordat input naar Claude gaat. Het werkt via een hook die bepaalde commando's automatisch herschrijft (bv. `git status` → `rtk git status`). Dat helpt bij grote codebases of lange bestanden waarbij je context snel vol raakt, maar je nog niet precies weet welk deel je nodig hebt. Bij kleine, gerichte vragen levert het weinig extra op.

**Vergelijk:**
- *Bad practice:* een groot project automatisch laden in context terwijl je maar 5% van de bestanden nodig hebt — context raakt vol, Claude verliest het overzicht en de antwoordkwaliteit daalt.
- *Good practice:* rtk inzetten op grote bestanden of mappen waar je het exacte relevante deel nog niet weet; zo maak je ruimte voor wat echt telt.

**Probeer zelf:** Pak een lange context (bv. een groot README plus meerdere source-bestanden), stuur dezelfde vraag eenmaal met en eenmaal zonder rtk. Vergelijk de antwoordkwaliteit en het tokenverbruik — gebruik `/cost` om het verschil meetbaar te maken (zie de [oefening over runtime-instellingen](claude-code.md)). Probeer dit bij [codingchallenges.fyi](https://codingchallenges.fyi/) met een challenge waarvan de codebase al flink gegroeid is.

`rtk` is geen plugin maar een CLI met hook, dus `claude plugin disable` werkt hier niet. Bypass-opties:
- **Per commando:** `rtk proxy <cmd>` draait het commando zónder rtk-filtering, terwijl de hook actief blijft voor andere calls.
- **Hele sessie:** verwijder de rtk-hook tijdelijk uit `~/.claude/settings.json` (knip het hook-blok uit en bewaar het lokaal) en herstart Claude.

> **Diepe variant:** zet `INSTALL_RTK=false` in `.env` en herbouw. Hiermee is rtk volledig afwezig — geen binary, geen hook. Nodig als je wil meten of de hook zelf overhead toevoegt.

**Wat je leert:** Je ontwikkelt een gevoel voor de grenzen waarbij rtk de moeite waard is en wanneer je beter handmatig context selecteert.

---

### Welke `superpowers`-skill past bij wat voor situatie?

**Achtergrond:** De `superpowers`-plugin levert process-skills: `superpowers:brainstorming`, `superpowers:test-driven-development`, `superpowers:systematic-debugging`, `superpowers:writing-plans` en `superpowers:executing-plans`. Elk is ontworpen voor een specifiek soort werk. De skills sturen Claude's aanpak en volgorde van redeneren, niet alleen de output — dat maakt ze anders dan een gewone instructie in de prompt.

**Vergelijk:**
- *Bad practice:* meteen code beginnen schrijven voor een feature die nog helemaal niet uitgedacht is — Claude bouwt iets concreets op basis van aannames die jij later pas corrigeert, wat leidt tot veel herwerk.
- *Good practice:* `superpowers:brainstorming` aanroepen vóór de eerste regel code; `superpowers:systematic-debugging` bij een hardnekkige bug; `superpowers:test-driven-development` voor algoritmes met duidelijke acceptatiecriteria.

**Probeer zelf:** Pak één van je oefen-challenges van [codingchallenges.fyi](https://codingchallenges.fyi/) en doe hem twee keer:

1. Plugin uit: `claude plugin disable superpowers`. Begin "blanco" — geen process-skill beschikbaar.
2. Plugin aan: `claude plugin enable superpowers`. Doe dezelfde challenge met de bijpassende skill (`superpowers:brainstorming` als de aanpak nog onduidelijk is, `superpowers:test-driven-development` als de verwachte output precies omschreven is).

Wat verandert aan tempo en kwaliteit?

> **Diepe variant:** zet `INSTALL_ANTHROPIC_PLUGINS=false` in `.env` en herbouw — let op dat dit alle Anthropic-plugins ineens weghaalt (ook github, code-review, etc.). De per-plugin runtime-disable hierboven is in de meeste gevallen genoeg.

**Wat je leert:** Je herkent welke process-skill bij welke fase hoort en wanneer een skill meer oplevert dan een simpele instructie in de prompt.

---

### Wat doet de Ralph-loop voor je en wanneer gebruik je hem?

**Achtergrond:** De Ralph-loop, oorspronkelijk beschreven door [Geoffrey Huntley](https://ghuntley.com/ralph/), zet Claude in een loop met dezelfde prompt zodat hij vanzelf blijft itereren tot een taak af is. Perfect voor challenges waar je gewoon wilt dat het eindresultaat er komt zonder dat je zelf elke iteratie hoeft te starten. In deze container zit Anthropic's officiële [`ralph-wiggum`](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum) plugin standaard mee (in de marketplace ook bekend als [`ralph-loop`](https://claude.com/plugins/ralph-loop)). Hij levert de slash-commands `/ralph-loop` en `/cancel-ralph`, een Stop-hook die sessie-exits onderschept, en `--max-iterations` als veiligheidsnet. De [zelf-review-oefening](claude-code.md) is een natuurlijke bouwsteen: een sterke review-prompt geeft de loop iets concreets om elke iteratie aan af te meten.

**Vergelijk:**
- *Bad practice:* een vage prompt loslaten zonder iteratielimiet — Claude itereert eindeloos zonder richting, verbrandt tokens en convergeert niet.
- *Good practice:* heldere completion-criteria in je prompt én een harde iteratielimiet — `--max-iterations` is je primaire veiligheidsmaatregel, niet de exacte string-matching van `--completion-promise`.

**Probeer zelf:** Draai `/ralph-loop` op een challenge met heldere tests, bijvoorbeeld de wc-challenge van [codingchallenges.fyi](https://codingchallenges.fyi/). Geef altijd `--max-iterations` mee als veiligheidsnet en formuleer een duidelijk completion-criterium in je prompt. Vergelijk hoe ver Claude komt zonder tussenkomst — let bij het meekijken op of de iteraties écht vooruitgang boeken of dat hij in cirkels gaat.

> **Diepe variant:** `INSTALL_ANTHROPIC_PLUGINS=false` in `.env` plus rebuild — alle Anthropic-plugins ineens weg. Voor een snelle uit-test gebruik je `claude plugin disable ralph-loop`.

**Wat je leert:** Je ervaart wanneer volledig autonoom itereren sneller gaat dan zelf de loop bewaken, en welke randvoorwaarden (heldere completion-criteria, harde iteratielimiet, afgebakende taak) noodzakelijk zijn om productief te itereren in plaats van tokens te verbranden.

---

### Hoe verandert PR-review als je `pr-review-toolkit` gebruikt?

**Achtergrond:** `pr-review-toolkit` levert via `/pr-review-toolkit:review-pr` een set gespecialiseerde sub-agents: een `code-reviewer`, een `silent-failure-hunter`, een `type-design-analyzer`, een `comment-analyzer` en meer. Elk kijkt gericht naar één aspect van een PR, in plaats van een algemene beoordeling te geven. Je kunt het commando ook richten op één aspect (bijvoorbeeld `errors` of `types`) om alleen de relevante sub-agents aan het werk te zetten.

**Vergelijk:**
- *Bad practice:* één PR doorlezen en op gevoel commentaar geven — je mist stille fouten (errors die worden geslikt), vage typeringen en inconsistente naamgeving omdat je niet systematisch zoekt.
- *Good practice:* `/pr-review-toolkit:review-pr errors` op een PR met error-handling, of `/pr-review-toolkit:review-pr types` op een PR met nieuwe types — zodat alleen de bijpassende sub-agents aan het werk gaan.

**Probeer zelf:** Maak een kleine PR met bewust een paar zwakke plekken — slik een error stil, gebruik vage typen, laat een comment staan die niet meer klopt. Doe de review twee keer:

1. Plugin uit: `claude plugin disable pr-review-toolkit`. Vraag Claude de PR te reviewen op gevoel ("review deze PR"). Noteer wat hij vindt.
2. Plugin aan: `claude plugin enable pr-review-toolkit`. Draai `/pr-review-toolkit:review-pr` of een gerichte variant (`errors`, `types`). Vergelijk met je eerste pas.

Gebruik voor de codebase een [codingchallenges.fyi](https://codingchallenges.fyi/)-challenge zodat de context klein en overzichtelijk blijft.

> **Diepe variant:** zelfde als hierboven (`INSTALL_ANTHROPIC_PLUGINS=false`) — haalt alles uit de Anthropic-marketplace ineens weg.

**Wat je leert:** Je ervaart hoe gerichte review-agents dode hoeken vinden die een generieke review mist, en leert wanneer je welk aspect aanstuurt.

---

### Wat verandert `claude-md-management` aan je `CLAUDE.md`-onderhoud?

**Achtergrond:** Een `CLAUDE.md` die goed begint (zie de [opbouw-oefening](claude-code.md)) groeit mee met het project, maar wordt zelden opgeschoond — verouderde instructies, tegenstrijdige regels en overbodige context hopen zich op en sturen Claude de verkeerde kant op. De `claude-md-improver`-skill uit `claude-md-management` auditeert het bestand en stelt verbeteringen voor.

**Vergelijk:**
- *Bad practice:* `CLAUDE.md` eenmalig opstellen en nooit meer terugkijken — oude instructies blijven actief, spreken nieuwere regels tegen en leiden Claude af op momenten dat je dat niet wilt.
- *Good practice:* periodiek `claude-md-improver` draaien om instructies te valideren, tegenstrijdigheden te signaleren en overbodige regels op te schonen.

**Probeer zelf:** Pak een lopende challenge (of een [codingchallenges.fyi](https://codingchallenges.fyi/)-challenge waar je een `CLAUDE.md` voor opstelt met opzettelijk wat tegenstrijdige of verouderde instructies):

1. Plugin uit: `claude plugin disable claude-md-management`. Vraag Claude "kijk eens kritisch naar mijn CLAUDE.md" — generieke review zonder de skill.
2. Plugin aan: `claude plugin enable claude-md-management`. Draai `claude-md-improver` op hetzelfde bestand. Vergelijk wat hij signaleert en hoe gestructureerd het voorstel is.

> **Diepe variant:** zelfde als hierboven (`INSTALL_ANTHROPIC_PLUGINS=false`) — alle Anthropic-plugins ineens weg.

**Wat je leert:** Je ziet hoe `CLAUDE.md`-kwaliteit de uitkomst van je sessies beïnvloedt en leert wanneer het de moeite waard is om het bestand actief te onderhouden.

---

### Wanneer helpt `caveman` en wanneer hindert het?

**Achtergrond:** De `caveman`-plugin (third-party) drukt Claude's antwoordstijl in een ultra-compacte vorm: lidwoorden weg, fragmenten oké, geen beleefdheidsfrasen. Doel is ~75% token-reductie in de output. Dat helpt bij snelle iteratieve debug-loops waar je veel korte beurten doet, maar werkt tegen je bij uitlegtaken, code review of onboarding waar volledige zinnen de leesbaarheid bepalen. De plugin heeft drie niveaus (`lite`, `full`, `ultra`) en kun je mid-sessie aan- en uitzetten.

**Vergelijk:**
- *Bad practice:* caveman aan laten staan tijdens een lange architectuur-uitleg of code review — antwoorden worden moeilijk te lezen voor collega's en details over *waarom* iets zo is verdwijnen tussen de fragmenten.
- *Good practice:* caveman aan tijdens een snelle debug-cyclus (10+ korte beurten op een lokale bug); uit zodra je naar een schrijftaak (commit message, PR-beschrijving, uitleg in een ticket) overschakelt.

**Probeer zelf:** Doe één sessie in twee helften:

1. Caveman aan: start met `/caveman full`. Werk 10–15 minuten aan een iteratieve taak (bv. een bug stap voor stap pinpointen, of een functie tot tests groen krijgen). Let op tempo en token-verbruik.
2. Caveman uit: vraag Claude in chat "stop caveman" (chat-instructie, geen shell-commando). Doe daarna een uitleg- of review-taak (bv. "leg uit waarom deze test faalde" of "review deze diff"). Vergelijk leesbaarheid en informatiedichtheid.

Voor een zuiverder vergelijking (zonder de skill-discovery hook): `claude plugin disable caveman` en herstart Claude — dan is de plugin volledig stil.

> **Diepe variant:** `INSTALL_CAVEMAN=false` in `.env` plus rebuild. Caveman heeft een eigen toggle (zit niet in een groep), dus de diepe variant is hier proportioneel — geen kruisbesmetting met andere plugins.

**Wat je leert:** Je herkent voor welk soort werk stijl-compressie helpt en wanneer het juist informatie kost. Tegelijk zie je het verschil tussen een runtime-toggle (`/caveman`), een per-plugin disable en een build-time uitsluiting.

> **Verder integreren:** caveman heeft optionele integratie-opties die de container niet automatisch aanzet — bijvoorbeeld een statusline-badge die het actieve niveau toont (`[CAVEMAN:FULL]`) en aanvullende hook-configuratie. Zie [`JuliusBrussee/caveman`](https://github.com/JuliusBrussee/caveman) voor de volledige opties als je dieper wil gaan.
