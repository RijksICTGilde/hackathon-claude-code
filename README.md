# Claude Code Container — Hackathon Editie

Een sandboxed Docker-container met Claude Code voor hackathons en coding challenges. Gebaseerd op de [devcontainer-opzet van Anthropic](https://code.claude.com/docs/en/devcontainer) en bedoeld om `claude --dangerously-skip-permissions` veiliger te draaien dan op je hostsysteem — geïsoleerd via netwerk- en volume-restricties. De container bevat optioneel skills en plugins uit de Nederlandse overheid-marketplace voor wie aan publieke standaarden werkt.

> **EXPERIMENTEEL** — Dit is een leer- en hackathon-omgeving, geen productiesetup. De container draait generatieve AI (Claude Code) en de output ervan is geen officiële bron. Zie onze [verantwoording](docs/verantwoording.md) en [DISCLAIMER](DISCLAIMER.md) voor meer informatie.

## Voor wie?

Deelnemers met verschillende instapniveaus die willen leren hoe je een AI-assistant aanstuurt voor softwareontwikkeling. Of je nu voor het eerst met een AI-coding-tool werkt of al ervaring hebt met Claude Code — de [oefeningen](docs/oefeningen.md) zijn opgesplitst in vier categorieën zodat je kunt instappen op je eigen niveau.

## Veiliger experimenteren met `--dangerously-skip-permissions`

In deze container kun je Claude desgewenst met `--dangerously-skip-permissions` draaien — gebruik de alias `claude-danger` als afkorting. Dan mag Claude files maken, commando's draaien en packages installeren zonder steeds te vragen. Een iptables-firewall en een geïsoleerd `claude-home`-volume beperken het risico binnen de sandbox, maar nemen het nooit volledig weg — gecloonde of geïnstalleerde code blijft schadelijk als hij dat is. Lees in [`claude-sandbox/`](claude-sandbox/) hoe je hem opzet en wat de firewall- en volume-keuzes zijn.

## Onderdelen

- **[claude-sandbox/](claude-sandbox/)** — de container zelf (Dockerfile, firewall, plugins, skills). Lees daar hoe je hem opstart.
- **[docs/oefeningen.md](docs/oefeningen.md)** — wat je in de container kunt doen: vier categorieën onderzoeksvragen.
- **[docs/verantwoording.md](docs/verantwoording.md)** — toetsing aan het Overheidsbreed Standpunt Generatieve AI.
- **[DISCLAIMER.md](DISCLAIMER.md)** — risico's en aansprakelijkheid.
- **[LICENSE](LICENSE)** — EUPL-1.2.
