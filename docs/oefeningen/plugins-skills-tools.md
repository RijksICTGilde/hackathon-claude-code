# Oefeningen: plugins, skills en tools

> Deze categorie wordt opnieuw ingevuld zodra de nieuwe configureerbare
> container live is — dan zijn de feature-switches expliciet en kun je
> daadwerkelijk per skill/plugin aan- en uitzetten om het effect te ervaren.
> Tot die tijd zijn dit eerste verkenningen op de huidige container-bundel.

Deze categorie gaat over de skills, plugins en CLI-tools die in de container zitten. Ze bouwen voort op een kale Claude Code-installatie met domeinkennis, gespecialiseerde review-agents en context-optimalisatie. Wie ze bewust inzet haalt meer uit de container dan wie ze links laat liggen.

---

### Wat doet de overheid-marketplace voor je werk?

**Achtergrond:** De container bevat skills uit `developer-overheid-nl/skills-marketplace`: `standaarden`, `nerds`, `internet`, `geo`, `developer-overheid` en `zad-actions`. Ze zijn relevant als je werk dicht bij Nederlandse overheidsstandaarden ligt — denk aan API-design, authenticatie, berichtenuitwisseling of geodiensten. Zonder deze skills leunt Claude op generieke kennis en mist hij NL-specifieke regels zoals problem+json, ADR, OIN of Digikoppeling.

**Vergelijk:**
- *Bad practice:* een REST-API bouwen zonder de skills aan te roepen — Claude schrijft een generieke API zonder rekening te houden met de API Design Rules, ADR-linting of het problem+json-formaat.
- *Good practice:* dezelfde challenge starten met "gebruik `standaarden:ls-api` om de API te toetsen aan de ADR" en zo NL-specifieke regels automatisch meenemen.

**Probeer zelf:** Pak een challenge die op je dagelijks werk lijkt (bv. een REST-endpoint, een koppelvlak of een kaartdienst) en draai hem twee keer — eenmaal vrij, eenmaal met de relevante skill expliciet aangeroepen. Welke skills bij welk werk passen: REST API → `standaarden:ls-api` (ADR/linting/problem+json); koppelvlak/auth → `standaarden:ls-iam`, `standaarden:ls-fsc`; basisregistratie → `standaarden:ls-dk` (Digikoppeling); notificatie/event → `standaarden:ls-notif` (CloudEvents); kaart/geo → `geo:*` skills. Vergelijk de output.

**Wat je leert:** Je ziet concreet welke NL-overheidsspecifieke kennis de marketplace toevoegt ten opzichte van generieke Claude-kennis.

---

### Wanneer voegt rtk (token reduction) merkbaar waarde toe?

**Achtergrond:** `rtk` knipt overbodige tokens uit — witruimte, comments, herhalende structuren — voordat input naar Claude gaat. Dat helpt bij grote codebases of lange bestanden waarbij je context snel vol raakt, maar je nog niet precies weet welk deel je nodig hebt. Bij kleine, gerichte vragen levert het weinig extra op.

**Vergelijk:**
- *Bad practice:* een groot project automatisch laden in context terwijl je maar 5% van de bestanden nodig hebt — context raakt vol, Claude verliest het overzicht en de antwoordkwaliteit daalt.
- *Good practice:* rtk inzetten op grote bestanden of mappen waar je het exacte relevante deel nog niet weet; zo maak je ruimte voor wat echt telt.

**Probeer zelf:** Pak een lange context (bv. een groot README plus meerdere source-bestanden), stuur dezelfde vraag eenmaal zonder en eenmaal met rtk. Vergelijk de antwoordkwaliteit en het tokenverbruik. Probeer dit bij [codingchallenges.fyi](https://codingchallenges.fyi/) met een challenge waarvan de codebase al flink gegroeid is.

**Wat je leert:** Je ontwikkelt een gevoel voor de grenzen waarbij rtk de moeite waard is en wanneer je beter handmatig context selecteert.

---

### Welke `superpowers`-skill past bij wat voor situatie?

**Achtergrond:** De `superpowers`-plugin levert process-skills: `superpowers:brainstorming`, `superpowers:test-driven-development`, `superpowers:systematic-debugging`, `superpowers:writing-plans` en `superpowers:executing-plans`. Elk is ontworpen voor een specifiek soort werk. De skills sturen Claude's aanpak en volgorde van redeneren, niet alleen de output — dat maakt ze anders dan een gewone instructie in de prompt.

**Vergelijk:**
- *Bad practice:* meteen code beginnen schrijven voor een feature die nog helemaal niet uitgedacht is — Claude bouwt iets concreets op basis van aannames die jij later pas corrigeert, wat leidt tot veel herwerk.
- *Good practice:* `superpowers:brainstorming` aanroepen vóór de eerste regel code; `superpowers:systematic-debugging` bij een hardnekkige bug; `superpowers:test-driven-development` voor algoritmes met duidelijke acceptatiecriteria.

**Probeer zelf:** Pak één van je oefen-challenges van [codingchallenges.fyi](https://codingchallenges.fyi/) en doe hem eenmaal "blanco" en eenmaal met de bijpassende superpowers-skill. Start met `superpowers:brainstorming` als de aanpak nog onduidelijk is, of `superpowers:test-driven-development` als de verwachte output precies omschreven is. Wat verandert aan tempo en kwaliteit?

**Wat je leert:** Je herkent welke process-skill bij welke fase hoort en wanneer een skill meer oplevert dan een simpele instructie in de prompt.

---

### Hoe verandert PR-review als je `pr-review-toolkit` gebruikt?

**Achtergrond:** `pr-review-toolkit` levert via `/pr-review-toolkit:review-pr` een set gespecialiseerde sub-agents: een `code-reviewer`, een `silent-failure-hunter`, een `type-design-analyzer`, een `comment-analyzer` en meer. Elk kijkt gericht naar één aspect van een PR, in plaats van een algemene beoordeling te geven. Je kunt het commando ook richten op één aspect (bijvoorbeeld `errors` of `types`) om alleen de relevante sub-agents aan het werk te zetten.

**Vergelijk:**
- *Bad practice:* één PR doorlezen en op gevoel commentaar geven — je mist stille fouten (errors die worden geslikt), vage typeringen en inconsistente naamgeving omdat je niet systematisch zoekt.
- *Good practice:* `/pr-review-toolkit:review-pr errors` op een PR met error-handling, of `/pr-review-toolkit:review-pr types` op een PR met nieuwe types — zodat alleen de bijpassende sub-agents aan het werk gaan.

**Probeer zelf:** Maak een kleine PR met bewust een paar zwakke plekken — slik een error stil, gebruik vage typen, laat een comment staan die niet meer klopt. Revieweer hem eerst zelf. Laat daarna `/pr-review-toolkit:review-pr` erover gaan. Wat vond elk? Gebruik voor de codebase een [codingchallenges.fyi](https://codingchallenges.fyi/)-challenge zodat de context klein en overzichtelijk blijft.

**Wat je leert:** Je ervaart hoe gerichte review-agents dode hoeken vinden die een generieke review mist, en leert wanneer je welk aspect aanstuurt.

---

### Wat verandert `claude-md-management` aan je `CLAUDE.md`-onderhoud?

**Achtergrond:** `CLAUDE.md` is het per-project bestand met projectspecifieke instructies voor Claude. Het groeit mee met het project maar wordt zelden opgeschoond — verouderde instructies, tegenstrijdige regels en overbodige context hopen zich op en sturen Claude de verkeerde kant op. De `claude-md-improver`-skill uit `claude-md-management` auditeert het bestand en stelt verbeteringen voor.

**Vergelijk:**
- *Bad practice:* `CLAUDE.md` eenmalig opstellen en nooit meer terugkijken — oude instructies blijven actief, spreken nieuwere regels tegen en leiden Claude af op momenten dat je dat niet wilt.
- *Good practice:* periodiek `claude-md-improver` draaien om instructies te valideren, tegenstrijdigheden te signaleren en overbodige regels op te schonen.

**Probeer zelf:** Draai `claude-md-improver` op de `CLAUDE.md` van een lopende challenge. Kijk welke wijzigingen hij voorstelt en waarom. Heb je geen `CLAUDE.md` bij de hand? Maak er een voor een bestaande [codingchallenges.fyi](https://codingchallenges.fyi/)-challenge, voeg wat tegenstrijdige of verouderde instructies toe en kijk wat de skill ervan maakt.

**Wat je leert:** Je ziet hoe `CLAUDE.md`-kwaliteit de uitkomst van je sessies beïnvloedt en leert wanneer het de moeite waard is om het bestand actief te onderhouden.
