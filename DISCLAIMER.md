# Disclaimer

Dit project is een **experimentele, educatieve omgeving** om te leren hoe AI-assistants — concreet [Claude Code](https://code.claude.com) van Anthropic — ingezet kunnen worden voor softwareontwikkeling, met aandacht voor de kaders, richtlijnen en standaarden van de Nederlandse overheid. De container is bedoeld voor hackathons en oefenwerk; niet voor productiegebruik.

## De container is geen officiële overheidsvoorziening

Deze repository wordt onderhouden door het [Rijks ICT Gilde](https://github.com/RijksICTGilde) als open-source initiatief. De inhoud is geen officieel product, beleidsstuk of standaard van het Rijk; de keuzes voor schakelbare uitbreidingen, plugins en skills weerspiegelen wat handig bleek tijdens hackathons, niet een formeel vastgesteld advies.

## AI-output is geen bron

Claude Code en andere generatieve AI-tools die in deze container draaien, produceren tekst en code op basis van statistische modellen. De output kan onvolledig, onjuist of verouderd zijn. Inhoud die je tijdens een sessie genereert — code, uitleg, README-stukken, samenvattingen van standaarden — is **geen vervanging** voor de officiële bron.

Voor de officiële, juridisch bindende definities van Nederlandse overheidsstandaarden verwijzen wij naar:

- [Forum Standaardisatie](https://www.forumstandaardisatie.nl/open-standaarden) — de beheerder van de lijst met verplichte en aanbevolen open standaarden
- De **beheerorganisaties** van de betreffende standaarden (Logius, Geonovum, internet.nl, etc.)
- De **gepubliceerde specificatiedocumenten** zelf

Bij twijfel of tegenstrijdigheid geldt altijd de officiële, gepubliceerde versie van een standaard.

## `--dangerously-skip-permissions` blijft binnen de container

De container is zo opgezet dat Claude met `--dangerously-skip-permissions` veilig kan draaien: een iptables-firewall beperkt uitgaand verkeer (in de standaard `OPEN_HTTPS=true`-modus alle HTTPS, in de strikte `OPEN_HTTPS=false`-modus alleen een gewhiteliste lijst hosts), een apart `claude-home`-volume isoleert state, en je host-bestandssysteem is alleen via de gemounte `projects/`-map bereikbaar. Draai deze flag **nooit** rechtstreeks op je host of in een omgeving zonder vergelijkbare isolatie.

## Geen echte persoonsgegevens of vertrouwelijke gegevens

Prompts, bestandsinhoud en context die je tijdens een sessie aanbiedt, worden door Claude Code naar Anthropic verstuurd. Plaats daarom **geen echte persoonsgegevens, vertrouwelijke gegevens of geheime credentials** in prompts, in bestanden in de gemounte `projects/`-map, of in test-code. Gebruik fictieve data voor experimenten.

## Gebruik van generatieve AI binnen de overheid

Overheidsorganisaties die generatieve AI inzetten — waaronder het gebruik van deze container en de output die ermee wordt gegenereerd — dienen te voldoen aan het [Overheidsbreed standpunt voor de inzet van generatieve AI](https://open.overheid.nl/documenten/bc03ce31-0cf1-4946-9c94-e934a62ebe73/file) en aan eigen beleid en kaders over AI. Zie [verantwoording](docs/verantwoording.md) voor hoe dit project zich daartoe verhoudt.

## Geen garantie

Dit project wordt aangeboden zonder enige garantie van volledigheid, juistheid, actualiteit of geschiktheid voor een specifiek doel. Gebruik is op eigen risico. Zie de [LICENSE](LICENSE) voor de juridische voorwaarden.
