# Fundament

Met `INSTALL_FUNDAMENT=true` bevat de image alles om vanuit de sandbox met het [Fundament-platform](https://docs.fundament-poc.nl/docs/) te werken, zoals op het Fieldlab: Go 1.27, [`functl`](https://github.com/fundament-oss/fundament/tree/master/functl), `kubectl` 1.36, `helm` 4.3 en `just` 1.42. De versies van `kubectl` en `just` zijn gelijk aan die in de `mise.toml` van een nieuwe plug-in.

## Wat je krijgt en wat niet

**Log je in de sandbox in met `functl`, dan kan Claude alles wat je Fundament-account kan.** Wat dat is, hangt af van je rol:

- **Organisatiebeheerder** (`admin`): `cluster-admin` op elk cluster van de organisatie, en leden uitnodigen.
- **Projectbeheerder**: de rol `admin` in elke namespace van het project. Daarmee kan Claude ServiceAccounts, rechten en tokens aanmaken, Secrets lezen en NetworkPolicies wijzigen, en leden aan het project toevoegen.
- **Projectviewer** (`viewer`): alleen lezen, zonder Secrets.

Elk lid van een organisatie mag een API-sleutel aanmaken. Claude kan dus een nieuwe sleutel op je account zetten, en die blijft geldig tot je hem intrekt. Je eigen sleutel staat na het inloggen in `~/.config/fundament/credentials`, in het `claude-home`-volume: Claude kan hem lezen, en hij blijft na een herstart staan. Met clustertoegang loopt verkeer bovendien buiten de firewall van de sandbox om; zie [Kubernetes](kubernetes.md#wat-je-krijgt-en-wat-niet).

Wat dat beperkt:

- Werk je met Claude, wees dan liever geen organisatiebeheerder. Laat bij voorkeur een teamgenoot die niet met Claude werkt de organisatie beheren.
- Loop na elke sessie je API-sleutels na; zie [Na de sessie](#na-de-sessie).
- Zet in je projecten geen Secrets of gegevens die Claude niet mag kennen.

## Aan de slag

De [aan-de-slagpagina van het Fieldlab](https://fieldlab2026.projects.digilab.network/aan-de-slag) gaat uit van je eigen laptop. In de sandbox gaat het zo:

1. **Laptop klaarmaken en inloggen op de console (stap 1 en 2).** Doe dit op de host, zoals de pagina beschrijft: daar log je met Pleio in op de console, in je browser. In de sandbox staan `functl` en `kubectl` al; installeer ze daar niet opnieuw.
2. **De image bouwen.** Zet in `.env` de regel `INSTALL_FUNDAMENT=true`. Werk je met `OPEN_HTTPS=false`, zet dan ook de domeinen uit [Netwerk](#netwerk) in `ALLOWED_DOMAINS`. Bouw en start de sandbox vanuit `claude-sandbox/`:
   ```bash
   docker compose up --build -d
   ```
   De tools staan buiten `claude-home`: het volume hoeft niet opnieuw.
3. **Toegang tot je cluster (stap 4).** Maak in de console een API-sleutel aan (je avatar, **API keys**), en log in de sandbox in:
   ```bash
   functl auth login
   functl org list
   functl org set <org-id>
   functl cluster list
   mkdir -p ~/.kube && functl cluster kubeconfig <cluster-id> > ~/.kube/config
   kubectl get ns
   ```
   Gebruik voor Fundament niet `compose.override.kubeconfig.yml`: de kubeconfig van Fundament roept `functl` aan, en een gemounte kubeconfig die meer meegeeft dan een token weigert de sandbox bij de start.
4. **Een eigen plug-in (stap 7).** De pagina werkt met `mise`; dat zit niet in de image, omdat het zelf toolchains ophaalt buiten de vaste versies om. Laat `mise trust` en `mise install` weg, en draai de commando's zonder `mise exec --`:
   ```bash
   functl plugin create mijn-plugin --template minimal --console none --sdk-version "$(functl version)"
   cd mijn-plugin
   go mod tidy
   just build
   just test
   ```
   De `--sdk-version` is nodig: zonder die vlag pint `functl` de SDK op een revisie die upstream niet meer bestaat, en dan faalt `go mod tidy` met `unknown revision`. `functl version` geeft de versie van Fundament waaruit `functl` gebouwd is, dus de SDK komt van dezelfde commit. `functl plugin create` draait zelf ook `go mod tidy`, maar meldt een fout daarin alleen als waarschuwing; de losse stap laat hem zien.

   Het container-image bouwen gaat met podman: zet ook `INSTALL_PODMAN=true` en start met de platform-override uit [podman/README.md](../podman/README.md). Die override geeft de sandbox extra rechten; lees eerst wat dat betekent. Gebruik dan het commando van de pagina, `docker build --platform linux/amd64 -t mijn-plugin:dev .`. `just docker` werkt niet: het geeft `docker buildx build` vlaggen mee die podman niet kent (`unknown flag: --provenance`).

## Netwerk

Met `OPEN_HTTPS=false` komt de sandbox alleen bij de domeinen in `ALLOWED_DOMAINS`. De firewall zet er voor Fundament niets zelf bij. Zet erin wat je gebruikt:

- **`functl`**: `organization-api.fundament-poc.nl` en `authn.fundament-poc.nl`.
- **`kubectl`**: de host uit de regel `server:` van de kubeconfig (`kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'`). Die ken je pas na stap 3; herstart daarna de container.
- **Go-modules**: `proxy.golang.org`, `sum.golang.org` en `storage.googleapis.com`. De proxy stuurt grote downloads, zoals Fundament zelf, door naar Google Cloud Storage. Staan deze drie open, dan houdt de firewall het uitlekken van gegevens nauwelijks nog tegen:
  - Via `storage.googleapis.com` kan code in de sandbox bestanden uploaden naar de opslag van iedereen, ook naar die van een aanvaller.
  - De firewall laat IP-adressen door, geen namen. Google gebruikt dezelfde adressen voor veel diensten, dus dan zijn bijvoorbeeld ook Drive en Apps Script bereikbaar.
  - De proxy haalt een module op bij de server die in de modulenaam staat. Vraagt code `voorbeeld.nl/<gegevens>` op, dan stuurt de proxy die gegevens naar `voorbeeld.nl`.

  Ook modules op GitHub komen via de proxy; zonder `proxy.golang.org` valt Go niet terug op git. Voor een privémodule zet je de host in `ALLOWED_DOMAINS` en het modulepad in `GOPRIVATE` (`go env -w GOPRIVATE=<pad>`), anders zoekt Go hem op in de publieke checksum database.

Ook bij Fundament laat de firewall adressen door, geen namen: de diensten van Fundament delen een adres, dus met één ervan open zijn ze alle bereikbaar. De firewall zoekt de adressen alleen bij de start op. Loopt een verbinding vast op een timeout, herstart dan de container.

## Naslag

- **Versie van `functl`.** `functl` staat op een vaste commit; een wekelijkse job stelt een nieuwere voor. De pagina van het Fieldlab vraagt om de nieuwste: bouw de image op de eerste dag opnieuw, na het mergen van de laatste bump.
- **Modulecache.** Go bewaart downloads onder `~/go`, in het `claude-home`-volume; ze overleven een herstart.
- **Go-versie.** `GOTOOLCHAIN=local` staat in de Go-installatie zelf, dus ook in SSH-sessies: vraagt een `go.mod` een nieuwere Go, dan faalt de build in plaats van dat Go stil een andere toolchain ophaalt.
- **Console met Vite.** `--console vite` vraagt `bun`; dat zit niet in de image. De standaard, `--console none`, heeft het niet nodig.
- **`functl plugin dev`** werkt niet in de sandbox: het draait de plug-in in het lokale k3d-cluster van Fundament (zie hieronder) en vraagt `skaffold`, dat daarom niet in de image zit.
- **Wat niet kan.** De testomgeving van Fundament voor plug-ins (een lokaal k3d-cluster; minstens 16 GiB geheugen, 24 GiB aanbevolen) draait niet in de sandbox: k3d heeft rechten nodig die de afscherming van de container ongedaan maken. Draai dat cluster op de host; hoe de sandbox het dan bereikt, staat in [kubernetes.md](kubernetes.md).
- **Licentie.** Fundament valt onder AGPL-3.0, en daarmee ook `functl` en de plug-in-SDK (zie [`LICENSES/`](https://github.com/fundament-oss/fundament/tree/master/LICENSES)). Een plug-in die de SDK linkt, valt onder de voorwaarden van de AGPL, inclusief de netwerkclausule: draait je plug-in als dienst voor anderen, dan bied je hun de broncode aan. De scaffold schrijft standaard een Apache-2.0-`LICENSE`; de NeRDS-richtlijn voor overheidscode is EUPL-1.2 (`--license EUPL-1.2`). Laat bij twijfel toetsen welke licentie je plug-in naast de AGPL kan hebben. Verspreid je zelf een image met `INSTALL_FUNDAMENT=true`, dan zit daar een AGPL-binary in.

## Na de sessie

Kijk welke API-sleutels je account heeft en wie lid is van je project:

```bash
functl apikey list
functl project member list <project-id>
```

Trek een sleutel die je niet kent in met `functl apikey revoke <id>`, en verwijder een onbekend lid met `functl project member remove <project-id> --user-id=<user-id>`. Ruim ook op wat Claude in de namespaces van je project heeft aangemaakt, zoals ServiceAccounts, RoleBindings en pods.

Na het Fieldlab: trek ook de sleutel in waarmee je in de sandbox inlogde, en verwijder `~/.config/fundament/credentials` in de sandbox.
