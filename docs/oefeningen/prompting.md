# Oefeningen: prompting-technieken

Er bestaan meerdere manieren om Claude te prompten voor coding-werk: van vrije, informele tekst tot een volledig uitgeschreven spec of een strak gestructureerde prompt-template. Geen stijl is universeel beter — elke stijl heeft een context waar hij het meeste oplevert. Deze categorie laat je elke stijl proberen op dezelfde challenge, zodat je het verschil voelt in plaats van erover leest. Begin bij de informele variant en werk je omhoog naar de meer gestructureerde aanpakken.

---

## 1. Informeel

Informeel prompten betekent: gewone spreektaal, geen vaste structuur, gericht op duidelijke intentie. Je beschrijft wat je wilt bereiken en laat Claude de invulling bepalen. Dat is ook precies de gulden regel:

> **Wees specifiek over *wat* je wilt, vaag over *hoe* Claude het moet doen.** Claude is op z'n best als je het gewenste resultaat beschrijft en de implementatie aan hem overlaat.
>
> ```
> Slecht:  "Schrijf een functie die een file regel voor regel leest en woorden telt"
> Goed:    "Bouw een wc-kloon in Kotlin die stdin en file-argumenten afhandelt, met
>          output conform POSIX wc"
> ```

---

### Hoe specifiek moet je zijn over de oplossing?

**Achtergrond:** Te vaag levert iets generieks op; te voorschrijvend remt Claude in zijn eigen oordeel. Het sweet spot ligt bij specifieke functionele eisen met vrije implementatie — je vertelt wat het moet doen, niet hoe de code eruit moet zien.

**Vergelijk:**
- *Bad practice (te vaag):* `"Maak een web-server"` — Claude heeft geen idee welk protocol, welke taal, welke features, welk gedrag.
- *Bad practice (te voorschrijvend):* `"Maak een bestand Parser.kt. Voeg een class toe genaamd JsonParser met een methode parse die een String parameter inputStr neemt en een Map<String, Any?> teruggeeft. Check eerst of de string met { begint..."` — je schrijft de implementatie zelf en laat Claude alleen typen.
- *Good practice:* `"Bouw een HTTP/1.1-server in Kotlin met Ktor die statische bestanden uit ./public serveert, GET- en HEAD-verzoeken afhandelt, correcte statuscodes teruggeeft (200, 404, 405) en Content-Type op extensie baseert"` — functionele eisen, vrije implementatie.

**Probeer zelf:** Kies een challenge van [codingchallenges.fyi](https://codingchallenges.fyi/) en prompt hem driemaal: één keer zo vaag dat de opdracht openstaat voor meerdere interpretaties, één keer met exact voorgeschreven klasse-namen en methode-handtekeningen, en één keer in de sweet spot met functionele eisen maar geen implementatie-details. Vergelijk de drie uitkomsten op kwaliteit en hoeveel correctie ze nodig hadden.

**Wat je leert:** Je ervaart waar de sweet spot van specificiteit ligt en waarom te veel detail de output juist slechter maakt.

---

### Wat levert het op om eerst om tests te vragen?

**Achtergrond:** Tests dwingen tot expliciete acceptatiecriteria voordat de implementatie er staat. Als je eerst de implementatie vraagt, ontdek je pas achteraf welke edge cases ontbreken — en dan moet je de code aanpassen aan een standaard die op dat moment nog niet bestond.

**Vergelijk:**
- *Bad practice:* meteen om de implementatie vragen, daarna pas zien dat edge cases ontbreken of dat het gedrag op ongeldige invoer niet gespecificeerd is.
- *Good practice:* eerst tests laten schrijven met expliciete edge cases, daarna de implementatie laten slagen:

```
Schrijf tests voor een JSON parser die afhandelt: geldige strings, escaped karakters,
geneste objects en ongeldige input. Implementeer daarna de parser zodat de tests slagen.
```

**Probeer zelf:** Pak een nieuwe challenge van [codingchallenges.fyi](https://codingchallenges.fyi/) en bouw hem twee keer: één keer test-eerst (tests schrijven, daarna implementatie), één keer code-eerst (implementatie schrijven, daarna optionele tests). Voeg na beide varianten bewust een edge case toe en vergelijk hoeveel regressies je ziet.

**Wat je leert:** Je ontdekt waarom test-eerst niet alleen bugs voorkomt, maar ook betere specificaties afdwingt.

---

### Hoe geef je context wanneer je een sessie hervat?

**Achtergrond:** Elke nieuwe sessie start zonder geheugen van vorige. Een vage hervatting leidt tot heruitleg, verkeerde aannames of dubbel werk.

**Vergelijk:**
- *Bad practice:* `"Ga verder met het Redis-project"` — Claude weet niet wat klaar is of waar de volgende stap begint.
- *Good practice:* expliciete status plus volgende concrete stap:

```
Ik bouw een Redis-kloon in Kotlin. De RESP-parser werkt en GET/SET zijn klaar.
Volgende: voeg key-expiration toe met TTL-ondersteuning.
```

**Probeer zelf:** Werk een challenge een half uur, sluit de sessie en hervat hem twee keer: alleen met de challenge-naam, en met een expliciete status-regel plus volgende stap. Meet hoe lang tot je weer productief bent.

> Alternatief: `claude --continue` (of `-c`) hervat de meest recente sessie direct; `claude --resume` (of `/resume` binnen een sessie) opent een picker voor een specifieke eerdere sessie. Handig dezelfde dag; minder geschikt na langere pauzes waarbij je liever bewust kiest welke context relevant blijft.

**Wat je leert:** Eén gerichte statusregel bij hervatting bespaart aanzienlijk tijd.

---

## 2. Spec-driven

Bij spec-driven prompten schrijf je eerst een functioneel ontwerp — een spec — voordat je Claude om code vraagt. Die spec beschrijft het gedrag, de edge cases en de gewenste evolueerbaarheid van de feature. Daarna genereer je code tegen die spec en gebruik je de spec als source of truth bij latere wijzigingen. De aanpak kost meer voorbereidingstijd dan informeel prompten, maar levert een herbruikbaar artefact op dat je kunt bijwerken en opnieuw kunt laten implementeren. Voor een volledige uitleg, zie de [JetBrains Junie blog over spec-driven development met AI](https://blog.jetbrains.com/junie/2025/10/how-to-use-a-spec-driven-approach-for-coding-with-ai/).

---

### Wanneer levert een spec-driven aanpak meer op dan informeel prompten?

**Achtergrond:** Spec-driven kost meer vooraf maar levert een herbruikbaar artefact: je werkt de spec bij en laat Claude de feature opnieuw implementeren, zonder elke keer context op te bouwen. Bij kleine helpers is die investering niet de moeite waard.

**Vergelijk:**
- *Bad practice:* spec uitschrijven voor een 50-regelige helper — overhead weegt niet op tegen eenvoud.
- *Good practice:* spec uitschrijven voor een feature met meerdere componenten, edge cases en verwachte evolutie — later pas je een requirement aan in de spec en stemt Claude de implementatie opnieuw af zonder dat je alles opnieuw hoeft uit te leggen.

**Probeer zelf:** Doe dezelfde middelgrote challenge — bv. "Build Your Own JSON Parser" van [codingchallenges.fyi](https://codingchallenges.fyi/) — één keer informeel, één keer spec-driven. Voeg daarna een nieuwe requirement toe (opmerkingen-ondersteuning, extra datatype) en vergelijk hoeveel je kunt wijzigen zonder vanaf nul te beginnen.

**Wat je leert:** Je ervaart wanneer de spec-investering terugverdiend wordt door latere flexibiliteit.

---

## 3. Structured prompt-driven

Structured prompt-driven prompten vervangt vrije proza door een vaste structuur: je splitst je prompt expliciet in rol, context, taak, gewenst output-formaat en constraints. Elke sectie heeft een eigen plek, waardoor je gedwongen wordt om elk element bewust te formuleren. Het resultaat is dat Claude precies weet wat er van hem wordt verwacht en minder hoeft te raden. De aanpak is bijzonder nuttig voor herhaalbare taken waarbij formaat-consistentie telt. Voor een volledige uitleg, zie [Martin Fowler's artikel over structured prompt-driven development](https://martinfowler.com/articles/structured-prompt-driven/).

---

### Wat verandert er aan de output als je je prompt strak structureert?

**Achtergrond:** Een gestructureerde prompt dwingt expliciete keuzes over rol, context, format en grenzen — en daarmee ook bij Claude. Onduidelijkheden die in vrije proza verstopt zitten, worden zichtbaar zodra je ze in een vak moet invullen.

**Vergelijk:**
- *Bad practice:* één lange alinea waar rol, context en taak door elkaar lopen — Claude moet zelf wegen wat het zwaarst telt en wat de grenzen zijn.
- *Good practice:* duidelijk gescheiden secties:
  - **Rol:** "Je bent een Kotlin-engineer die werkt aan een CLI-tool."
  - **Context:** "We bouwen een wc-kloon die stdin en file-argumenten afhandelt."
  - **Taak:** "Implementeer de `-w` vlag voor woordtelling."
  - **Output-formaat:** "Geef alleen de gewijzigde bestanden terug, geen uitleg."
  - **Constraints:** "Gebruik alleen de stdlib, geen externe libraries."

**Probeer zelf:** Schrijf voor dezelfde taak twee prompts — vrije proza en de vijf secties gescheiden. Vergelijk hoe goed de output binnen het gewenste formaat blijft en hoeveel correctie-rondes elke variant kost.

**Wat je leert:** Structuur in de prompt leidt tot structuur in de output; de overhead daarvan betaalt zich terug zodra je het formaat consistent moet onderhouden.

---

## Welke past bij wat?

Je hebt nu drie stijlen geprobeerd op vergelijkbaar materiaal. De hoofdlijn: informeel werkt goed voor verkenning en kleine taken; spec-driven loont bij middelgrote features met verwachte toekomstige wijzigingen; structured prompt-driven is het meest de moeite waard bij herhaalbare taken waar formaat-consistentie telt. In de praktijk schakel je voortdurend tussen deze stijlen — soms binnen dezelfde sessie.

---

### Welke stijl past bij wat voor type challenge?

**Achtergrond:** Je hebt alle drie geprobeerd. De vraag is wanneer de overhead van een stijl terugverdiend wordt door het resultaat — en wanneer je te veel werk steekt in iets wat informeel ook had gewerkt.

**Vergelijk:**
- *Bad practice:* één stijl voor alles — overhead op kleine taken (spec voor 20-regelige helper) of onderspecificatie op grote (informele prompt voor feature met vijf componenten).
- *Good practice:* per challenge bewust kiezen op omvang, evolutie-verwachting en herhaalbaarheid.

**Probeer zelf:** Kies een nieuwe challenge van [codingchallenges.fyi](https://codingchallenges.fyi/) en beslis vooraf welke stijl je gebruikt en waarom. Schrijf je redenering op. Verifieer achteraf: wat werkte, en welke stijl zou beter gepast hebben?

**Wat je leert:** Je ontwikkelt een heuristiek voor stijlkeuze en leert van het verschil tussen voorspelling en werkelijkheid.
