# Verkenning van een sandboxed Claude Code-container voor hackathons

**Toetsing en verantwoording i.h.k.v. Overheidsbreed Standpunt Generatieve AI**

## Beschrijving

Deze repository levert een **Docker-container** die [Claude Code](https://code.claude.com) van Anthropic draait in een netwerk- en bestandssysteem-geïsoleerde omgeving. De container is bedoeld voor hackathons en oefenwerk waarin deelnemers leren hoe ze een AI-assistent effectief kunnen aansturen voor softwareontwikkeling — met expliciete aandacht voor Nederlandse overheidsstandaarden wanneer de overheid-marketplace is ingeschakeld.

De container is configureerbaar via environment-switches in `.env`. Optionele uitbreidingen kunnen los worden aan- of uitgezet, afhankelijk van wat de hackathon of deelnemer nodig heeft, waaronder:

- algemene Anthropic-plugins en lokale skills,
- de overheid-marketplace (`standaarden`, `nerds`, `internet`, `geo`, `developer-overheid`, `zad-actions`),
- de JVM-toolchain via SDKman (Java/Kotlin language servers).

De container is zo opgezet dat Claude desgewenst met `--dangerously-skip-permissions` gedraaid kan worden — gebruikers kiezen daar zelf voor door de optie mee te geven of de `claude-danger`-alias te gebruiken. Juist díe combinatie — volledige autonomie binnen een sandbox — maakt het leerdoel mogelijk: zien wat een AI-assistent zelfstandig oplost in een strakke feedback-loop, zonder dat dat consequenties heeft voor de host of het netwerk daarbuiten.

Het experiment ontwikkelt zelf geen AI-systeem. Alle code die *door* Claude in de container wordt gegenereerd, ontstaat in het kader van wegwerp-oefeningen (challenges van [codingchallenges.fyi](https://codingchallenges.fyi)) en gaat niet in productie. De container zelf — Dockerfiles, firewall-script, entrypoints — is met de hand geschreven, met inzet van AI ter ondersteuning waar dat efficiënt was.

## Verantwoording

We doorlopen hieronder het globale stappenplan uit hoofdstuk 4 van de [Overheidsbrede handreiking Verantwoorde inzet van generatieve AI](https://open.overheid.nl/documenten/9c273b71-cebb-4e11-b06f-fa20f7b4b90e/file).

### 1) Doel en toepassingsgebied

*Doel:* Onderzoeken hoe AI-assistenten praktisch ingezet kunnen worden voor softwareontwikkeling, en hoe een veilige sandbox eruit ziet waarin deelnemers durven te experimenteren met `--dangerously-skip-permissions`.

*Toepassingsgebied:* Hackathons, workshops en zelfstudie. De containers zijn niet bedoeld voor het ontwikkelen van productiesoftware — daarvoor ontbreken o.a. supply-chain-controles, secrets-management en logging die je in een echte ontwikkelstraat verwacht.

### 2) Mensen en vaardigheden

Deelnemers brengen hun eigen ontwikkelervaring in. [oefeningen.md](oefeningen.md) bevat onderzoeksvragen en experimenten zodat ook deelnemers die nieuw zijn met AI-assistenten snel productief kunnen worden. Mentoren zorgen tijdens hackathons voor uitleg over zowel de container (firewall, volumes) als over wat een AI-assistent wel en niet betrouwbaar kan.

### 3) Governance

Het project wordt onderhouden door het [Rijks ICT Gilde](https://github.com/RijksICTGilde) als open-source initiatief. Er is geen formele opdrachtgever, stuurgroep of vastgesteld eindproduct: keuzes worden gemaakt op basis van wat in hackathons en oefenwerk nuttig bleek. Wel houden we het [Overheidsbreed standpunt voor de inzet van generatieve AI](https://open.overheid.nl/documenten/bc03ce31-0cf1-4946-9c94-e934a62ebe73/file) en de bijbehorende handreiking aan als leidraad voor keuzes.

Wijzigingen aan de container lopen via pull requests op GitHub; daarmee is de geschiedenis van keuzes (wat is toegevoegd, wat is bewust *niet* toegevoegd) publiek navolgbaar.

### 4) Risicoanalyse

De gangbare assessment-instrumenten gaan uit van organisaties die zelf een AI-systeem bouwen of structureel inzetten. Dat is hier niet het geval: we gebruiken Claude Code als gereedschap, draaien geen AI-software in productie, en verwerken geen persoonsgegevens of vertrouwelijke gegevens. Toch blijven de volgende aandachtspunten van toepassing:

#### a. EU AI-verordening

De verplichtingen uit de AI-verordening rusten primair op de aanbieder van het model — in dit geval Anthropic. Anthropic is een van de ondertekenaars van de [General Purpose AI Code of Practice](https://digital-strategy.ec.europa.eu/en/policies/contents-code-gpai), wat door de Europese Commissie wordt gezien als [voldoende bewijs van naleving](https://digital-strategy.ec.europa.eu/en/library/commission-opinion-assessment-general-purpose-ai-code-practice).

Deze container fungeert als gebruiker van zo'n model en dient daarvan transparant te zijn: dat doen we via deze verantwoording en de [DISCLAIMER](../DISCLAIMER.md).

#### b. AVG en persoonsgegevens

Tijdens het bouwen of gebruiken van de container worden geen persoonsgegevens verwerkt. Hackathon-deelnemers wordt gevraagd om geen echte persoonsgegevens in test-code op te nemen; gebruik fictieve data.

Authenticatie-tokens (GitHub CLI, git credentials) blijven binnen het `claude-home`-volume op de host van de gebruiker en worden nooit naar derden verstuurd buiten de reguliere git/GitHub-flow om.

#### c. BIO en beveiliging

De container is een leeromgeving, niet een productiesysteem; BIO-verplichtingen zijn dus niet één-op-één van toepassing. Wel zijn op meerdere niveaus mitigaties aanwezig om experimenten met `--dangerously-skip-permissions` veilig te maken:

- Een iptables-firewall (`init-firewall.sh`) blokkeert alle uitgaand verkeer behalve HTTPS en DNS; in de strikte modus (`OPEN_HTTPS=false`) alleen naar een vooraf goedgekeurde lijst hosts.
- Het `claude-home`-volume is geïsoleerd van de hostpaden van de gebruiker; alleen de bewust gemounte `projects/`-directory is voor Claude bereikbaar.
- Image-builds zijn reproduceerbaar via Dockerfiles en versiebeheer; geen handmatige stappen op de host.

Deelnemers blijven verantwoordelijk voor wat ze in de container clonen of installeren — schadelijke code uit een gecloonde repo blijft schadelijk, ook achter de firewall.

#### d. Datadeling met de AI-aanbieder

Claude Code stuurt prompts en bestandsinhoud naar Anthropic om te kunnen reageren. Deelnemers wordt geadviseerd:

- Geen vertrouwelijke gegevens, persoonsgegevens of geheime credentials in prompts of project-bestanden te zetten.
- Per gebruikt account/abonnement het [trainingsbeleid van Anthropic](https://privacy.anthropic.com/en/articles/10023555-how-do-you-use-personal-data-in-model-training) te verifiëren. Voor commerciële API-toegang (zoals `ANTHROPIC_API_KEY`-gebruik vanuit deze container) staat training op input standaard uit; voor consumer-abonnementen op Claude.ai geldt een opt-out die je zelf moet zetten.
- Bij gebruik vanuit een overheidsorganisatie te werken via een organisatie-licentie waarin opt-outs en datavoorwaarden zijn vastgelegd.

#### e. Schijnzekerheid

Het feit dat een AI-assistent met de overheid-marketplace ingeschakeld toegang heeft tot overheidsspecifieke skills (`standaarden`, `nerds`, `internet`, `geo`, `developer-overheid`, `zad-actions`) betekent **niet** dat de output automatisch voldoet aan de bijbehorende standaarden. Skills zijn samenvattingen en interpretaties; officiële brondocumenten zijn altijd leidend. Verantwoordelijkheid voor compliance ligt bij de organisatie die de gegenereerde code uiteindelijk in productie zou nemen.

#### f. Kwaliteit van AI-output

Code en uitleg die Claude produceert moeten worden gereviewd zoals je elke pull request reviewt: tests draaien, documentatie checken, edge cases doordenken. De [oefeningen rond prompting](oefeningen/prompting.md) geven onderzoeksvragen voor het effectief inzetten van Claude in een test-driven loop, juist om kwaliteitsrisico's te beperken.

#### g. Vendor lock-in

De container is op dit moment specifiek gebouwd rond Claude Code (Anthropic). Dat is een bewuste keuze voor één volwaardige implementatie binnen de scope van een hackathon, maar het beperkt de keuze van de gebruiker. Mitigaties:

- De skills die via de overheid-marketplace worden geleverd (zoals die van [developer-overheid-nl/skills-marketplace](https://github.com/developer-overheid-nl/skills-marketplace)) zijn ontworpen om met meerdere AI-assistenten te werken; het format is open.
- De Dockerfiles en het firewall-script zijn niet Anthropic-specifiek en kunnen hergebruikt worden als basis voor containers rond andere AI-assistenten (bv. lokale modellen, andere CLI-clients).

Een variant met een open-source of Europese AI-assistent past binnen de scope van toekomstig werk.

#### h. Auteursrecht en licenties

Per gebruikte plugin/skill wordt door de respectievelijke maintainers gedocumenteerd welke licentie geldt. Deze repository zelf is open-source (zie [LICENSE](../LICENSE)). Deelnemers die met Claude code genereren op basis van bestaande code of standaarden, blijven zelf verantwoordelijk voor het respecteren van de bijbehorende licenties en bronvermeldingen.

#### i. Uitlegbaarheid

Alles in deze repo — Dockerfiles, scripts, skills die via plugins worden geladen — is in voor mensen leesbare vorm beschikbaar. Wat Claude tijdens een sessie doet is zichtbaar in de terminal-output. Er is geen verborgen pipeline of geautomatiseerde beslislaag.

#### j. AI-geletterdheid

[oefeningen.md](oefeningen.md) is bewust opgezet om deelnemers snel een goed mentaal model te geven van wat Claude wel en niet doet. Tijdens hackathons is mondelinge uitleg en peer-learning de tweede kennisdragende laag.

### 5) Inkoop en bouw

De container zelf wordt **niet** ingekocht: het is open-source en zelf te bouwen vanuit de Dockerfiles. Voor het draaien van Claude Code is een Anthropic-account met API-toegang of een Claude-abonnement nodig — die licentie regelt de gebruiker zelf. Bij hackathons wordt aanbevolen om gebruik te maken van een organisatie-licentie waarin opt-out voor modeltraining en eventuele aanvullende privacy-afspraken zijn geregeld.

Wanneer de overheid-marketplace via een switch wordt ingeschakeld, wordt aanvullend gebruikgemaakt van die plugin-marketplace; die is eveneens open-source en gratis te gebruiken.

---

Vragen, opmerkingen of verbetervoorstellen kunnen via een [issue](../issues) of pull request worden ingediend.
