# Voor wie verder wil — experimenteer en draag bij

Deze categorie is voor deelnemers die de andere oefeningen al kennen of al eerder met Claude Code werkten en nu iets nieuws willen proberen. In plaats van een vaste oefening kies je zelf een idee — een verbetering op dit project, iets wat je elders las, een experiment dat je in je hoofd hebt, of een irritatie in je workflow. Als het experiment werkt, is dat de kans om het bij te dragen aan de container, zodat andere deelnemers er bij een volgende editie baat bij hebben.

---

## Inspiratiebronnen

Geen volledige catalogus, maar een handvol startpunten waar je je eigen pad in vindt.

- [Anthropic blog](https://www.anthropic.com/news) — release-aankondigingen en techniek-posts over Claude.
- [Anthropic prompt engineering guide](https://docs.claude.com/en/docs/build-with-claude/prompt-engineering/overview) — diepgaande prompting-naslag.
- [Claude Code GitHub Discussions](https://github.com/anthropics/claude-code/discussions) — wat anderen aan het bouwen zijn.
- [Geoffrey Huntley's blog](https://ghuntley.com/) — Ralph-loop en aanverwante ideeën.
- [`anthropics/claude-plugins-official`](https://github.com/anthropics/claude-plugins-official) — beschikbare plugins om mee te experimenteren.
- [`developer-overheid-nl/skills-marketplace`](https://github.com/developer-overheid-nl/skills-marketplace) — overheid-skills die in deze container zitten.
- [Custom slash-commands](https://code.claude.com/docs/en/slash-commands) — eigen herhaalbare prompts in `.claude/commands/<naam>.md` of `~/.claude/commands/`. Laagdrempelig: één markdown-bestand is genoeg.
- [Hooks](https://code.claude.com/docs/en/hooks) — deterministisch werk koppelen aan events als `PostToolUse` of `SessionStart` (bv. altijd `gofmt` na een Go-edit). `rtk` werkt via een hook in `~/.claude/settings.json`; `caveman` bundelt zijn hooks ín de plugin zelf — twee verschillende patronen om te bestuderen.
- [MCP-servers](https://code.claude.com/docs/en/mcp) — Claude Code koppelen aan externe systemen (database, issue-tracker, eigen API). `filesystem` of `fetch` zijn laagdrempelige eerste experimenten.

---

## Iets bijdragen

Werkt je experiment? Zo zet je het om in een bijdrage — groot of klein.

### Issue openen

Heb je een pijnpunt gevonden maar nog geen uitgewerkte oplossing? Open een issue. Het helpt als je het pijnpunt en een voorgestelde richting in dezelfde issue zet, zodat een ander makkelijk kan oppakken wat jij bent begonnen. Gebruik gerust deze vorm:

> Probleem: ..., Voorgestelde oplossing: ..., Waarom dit nuttig is voor de hackathon: ...

Issues vind je via [../../issues](../../issues).

### Pull request

Heb je iets uitgewerkt dat de container beter maakt? Een pull request is welkom voor: een nieuwe oefencategorie, een aanpassing aan de Dockerfile of container-configuratie, of een nieuwe skill of plugin in de bundel. Kijk voor de scope-overwegingen in de [verantwoording](../verantwoording.md) — die beschrijft bewuste keuzes die bepalend zijn voor wat er wel en niet in de container hoort. Dat bespaart je een ronde feedback achteraf.

### Wat past wel/niet in deze container

De scope van deze container is *hackathon-leeromgeving*, niet productie. Dat betekent dat de lat voor "is dit nuttig?" lager ligt dan in een productiesysteem, maar dat productie-gerichte voorzieningen buiten scope vallen.

Voorbeelden van wat past: een nieuwe skill die concreet werk in de hackathon versnelt, een Dockerfile-flag waarmee een feature aan- of uitgezet kan worden, een nieuwe oefencategorie die iets tastbaars laat ervaren. Voorbeelden van wat niet past: secrets-management voor productie, supply-chain-policies voor release-pipelines, een formele logging-stack. De sectie "Doel en toepassingsgebied" in de [verantwoording](../verantwoording.md) legt dit verder uit.
