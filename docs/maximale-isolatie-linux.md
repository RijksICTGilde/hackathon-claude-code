# Maximale isolatie op Linux: podman in een VM

**Status:** handleiding / optioneel. **Niet getest in deze omgeving** — stappen
zijn distro-/versie-afhankelijk; verifieer op je eigen host.

## Waarom (en alleen op Linux nodig)

De podman-in-docker-opzet (zie `host-agents/maven/podman/README.md`) draait
Testcontainers genest in de sandbox, maar deelt de **host-kernel**. Het dominante
restrisico is daarom een kernel-exploit: een escape uit de (bewust versoepelde)
outer container landt op de host-kernel — bij rootless beperkt tot je
unprivileged user, maar nog steeds jouw account.

De **eigen-kernel-grens** sluit die laag: draai de hele sandbox in een
lichtgewicht **VM**. Een container- of kernel-escape blijft dan in de VM en raakt
de host-kernel niet. Dit is de invulling van "Optie D" uit ADR 0001, maar dan op
de makkelijkst beheerbare manier — geen speciale per-container-runtime.

### Mac en Windows hebben dit al — niets te doen
Daar draaien de Linux-containers sowieso in een VM met eigen kernel:

| OS | Eigen-kernel-grens | Kanttekening |
|---|---|---|
| **macOS** | Docker Desktop / Rancher / `podman machine` draaien in een Lima/QEMU-VM | Grens is er gratis; resterende zorg is de gedeelde mount, niet de kernel |
| **Windows** | Docker Desktop / Rancher via **WSL2** (of Hyper-V-backend) = VM met eigen Linux-kernel | WSL2 heeft bewuste host-integratie (drvfs `/mnt/c`, interop die Windows-`.exe` kan starten) die de grens verzacht; de Docker-Desktop-utility-VM staat daar verder vanaf dan je interactieve WSL-distro |
| **Linux (native)** | **Geen** — host-kernel gedeeld | Hier voeg je de VM toe (deze gids) |

## Aanbevolen: podman in een Lima- of Multipass-VM

Waarom dit de beste fit is voor "maximaal + makkelijk beheerbaar":
- **Echte kernel-grens**: escape blijft in de VM, niet je host.
- **Podman onveranderd**: binnen de VM draai je gewoon `podman`/`podman-compose` +
  deze sandbox; Testcontainers werkt als op bare metal.
- **Wegwerp/snapshot = recovery is triviaal**: snapshot een schone VM, rol terug of
  `destroy && recreate` na een incident.
- **Lost de in-VM-hardening op**: omdat de VM zelf de grens is, mág je de
  container-hardening *binnen* de VM versimpelen zonder de host te raken — zie
  "Vereenvoudiging" hieronder.

### Voorwaarden
```bash
ls -l /dev/kvm                       # KVM-device (VM-versnelling)
egrep -c '(vmx|svm)' /proc/cpuinfo   # >0 = hardware-virtualisatie
```
Draait je host zelf al in een VM? Dan nested virt aanzetten op de buitenste
hypervisor.

### Route A — Multipass (simpelst)
```bash
sudo snap install multipass
multipass launch --name sandbox --cpus 4 --memory 8G --disk 40G 24.04
multipass shell sandbox
# --- in de VM ---
sudo apt-get update && sudo apt-get install -y podman podman-compose git
git clone <deze-repo> && cd <repo>/claude-sandbox
# draai de sandbox (zie "Vereenvoudiging" voor de inner-config-keuze)
```
Snapshots/lifecycle: `multipass snapshot sandbox`, `multipass restore sandbox.<n>`,
`multipass stop|start|delete sandbox`.

### Route B — Lima (kan de socket naar de host exposen)
Lima is gemaakt voor "containers in een VM" (basis van Colima/Rancher). Met een
`mounts:`- en socket-config kun je de podman-socket in de VM naar je host
doorzetten, zodat ook host-side tools een `DOCKER_HOST` hebben.
```bash
limactl start --name=sandbox template://ubuntu
limactl shell sandbox
# idem: podman installeren + sandbox draaien
```

### Vereenvoudiging binnen de VM
Omdat de VM de beveiligingsgrens is, hoeft de container-hardening *in* de VM niet
zo strak als op een gedeelde host:
- Je kunt de podman-in-docker-set ongewijzigd draaien, **of** simpeler: in de VM
  `sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0` zetten (de VM is
  wegwerp — die hardening daar versoepelen raakt je host niet), of zelfs gewoon
  **Docker/rootful podman in de VM** + Testcontainers normaal.
- Let op: een **verse Ubuntu-24.04-VM heeft dezelfde userns-hardening** als je
  host. Dus óf het AppArmor-`userns`-profiel + single-uid (zoals deze repo), óf de
  sysctl in de VM op 0. Wil je één config die overal werkt → houd de bestaande
  podman-set aan.

## Shared volume: de spanning

Een **schrijfbare** gedeelde mount is precies het gat dóór de VM-grens die je net
optrok. De VM sluit de *kernel*-vector; een live mount opent de *data/exec*-vector
weer: gecompromitteerde code schrijft naar je echte host-bestanden (vergiftigde
`Makefile`/`.git/hooks/`/`.envrc`/`.vscode/tasks.json` → draait zodra jíj de map
aanraakt), of leest ze (exfil).

| Lat | Mount-aanpak |
|---|---|
| **Realistisch** (gemak telt) | Smalle mount: **alleen de projectmap**, géén `~/.ssh`/secrets erin; read-only waar kan; **geen host-side tooling** (mvnw/make/npm/direnv/git-hooks) blind op die map na Claude; diffs reviewen. |
| **Maximaal** (onvertrouwde code) | **Geen live mount.** Repo leeft ín de VM; uitwisselen via **git push/pull** (dwingt review af) of expliciete one-way sync. |

Technisch werkt delen wel (Multipass: `multipass mount <host-pad> sandbox:/pad`;
Lima: `mounts:` met virtiofs/9p), maar het is twee hops (host→VM→container) met
uid-shift en wisselende inotify-betrouwbaarheid.

## Alternatieven (waarom niet als default)

- **Kata Containers** (per-container microVM): ook eigen kernel, maar wil rootful
  + moderne Kata is shim-v2/containerd-georiënteerd → koppeling aan podman is
  versie-afhankelijk en fiddly. Minder "makkelijk beheerbaar" dan een VM.
- **gVisor (`runsc`)** (userspace-kernel via syscall-interceptie): licht en
  `podman --runtime runsc`, maar implementeert een *subset* van syscalls en draait
  **nested container-runtimes (podman-in-podman/Testcontainers) slecht** → past
  niet bij deze workload.

## Caveats

- **Overhead**: een VM kost RAM/CPU en heeft tragere I/O; grof-granulair (één VM
  voor de sandbox, niet per testcontainer).
- **Nested virt** vereist als je host al een VM is.
- **Mount-performance/uid-shift** bij een gedeelde map (zie boven).
