# Maximale isolatie op Linux: Kata Containers (eigen kernel)

**Status:** handleiding / optioneel. **Niet getest in deze omgeving** — de stappen
zijn versie- en distro-afhankelijk; verifieer op je eigen host.

## Waarom (en alleen op Linux nodig)

De podman-in-docker-opzet (zie `host-agents/maven/podman/README.md`) draait
Testcontainers genest in de sandbox, maar deelt de **host-kernel**. Het dominante
restrisico is daarom een kernel-exploit: een escape uit de (bewust versoepelde:
apparmor/seccomp/systempaths) outer container landt op de host-kernel — bij
rootless beperkt tot je unprivileged user, maar nog steeds jouw account.

**Kata Containers** sluit die laag: het draait de container in een lichte
**microVM met een eigen guest-kernel** (via KVM). Een container- of kernel-escape
blijft dan in die VM en raakt de host-kernel niet. Het is de concrete invulling van
"Optie D" uit ADR 0001.

### Mac en Windows hebben dit al — Kata niet nodig
Daar draaien de Linux-containers sowieso in een VM met eigen kernel:

| OS | Eigen-kernel-grens | Kanttekening |
|---|---|---|
| **macOS** | Docker Desktop / Rancher / `podman machine` draaien in een Lima/QEMU-VM | Grens is er gratis; resterende zorg is de gedeelde `projects`-bind-mount, niet de kernel |
| **Windows** | Docker Desktop / Rancher via **WSL2** (of Hyper-V-backend) = VM met eigen Linux-kernel | WSL2 heeft bewuste host-integratie (drvfs `/mnt/c`, interop die Windows-`.exe` kan starten) die de grens verzacht; de Docker-Desktop-utility-VM staat daar verder vanaf dan je interactieve WSL-distro |
| **Linux (native)** | **Geen** — host-kernel gedeeld | Hier voegt Kata de ontbrekende laag toe |

Kata draait zelf alleen op Linux (vereist KVM); op Mac/Windows is het noch
mogelijk noch nodig.

## Voorwaarden (Linux-host)

```bash
ls -l /dev/kvm                         # KVM-device aanwezig?
egrep -c '(vmx|svm)' /proc/cpuinfo     # >0 = hardware-virtualisatie (Intel VT-x / AMD-V)
```
- Draait je host **zelf al in een VM**? Dan moet **nested virtualisatie** aan staan
  op de buitenste hypervisor (anders geen `/dev/kvm` in de gast).
- Je user moet bij `/dev/kvm` kunnen (meestal group `kvm`).

## Kata installeren

Gebruik bij voorkeur de officiële `kata-deploy`/release-artefacten of het
distro-pakket (`kata-containers` / `kata-runtime`); versienamen variëren per
distro. Verifieer daarna:
```bash
kata-runtime check        # of: kata-ctl check  — meldt of KVM/host geschikt is
```

## Kata koppelen aan de runtime

> **Belangrijke nuance:** Kata integreert het schoonst met **containerd
> (`nerdctl`)** of CRI-O/Kubernetes via de shim `containerd-shim-kata-v2`. Met
> **plain Docker Engine + `docker compose`** (wat deze repo gebruikt) is het
> fiddly en versie-afhankelijk: recente Kata is shim-v2-georiënteerd, terwijl het
> oude OCI-`kata-runtime`-pad voor Docker is uitgefaseerd. Kies bewust:

**Pad A — Docker Engine (als jouw Docker+Kata-versies de runtime ondersteunen):**
`/etc/docker/daemon.json`:
```json
{
  "runtimes": {
    "kata": { "path": "/usr/bin/containerd-shim-kata-v2" }
  }
}
```
```bash
sudo systemctl restart docker
```
In de podman-override een runtime per service (verifieer dat jouw Compose-versie
de `runtime:`-key honoreert):
```yaml
services:
  claude:
    runtime: kata
```
of ad-hoc: `docker run --runtime kata ...`.

**Pad B — containerd + nerdctl (native Kata-pad):**
```bash
nerdctl run --runtime io.containerd.kata.v2 ...
# nerdctl compose -f compose.yml -f compose.override.podman-linux.yml up -d
```
Dit wijkt af van `docker compose` maar is de minst wrijvende Kata-route.

## Sandbox onder Kata draaien + verifiëren

1. Bouw/start de sandbox onder de Kata-runtime (Pad A of B), met de podman-override.
2. Verifieer dat je in een microVM zit en draai de smoke:
   ```bash
   docker compose exec claude bash -lc 'uname -r'   # eigen guest-kernel, ≠ host
   docker compose exec claude bash -lc \
     "source ~/.sdkman/bin/sdkman-init.sh && \
      /home/claude/projects/<repo>/claude-sandbox/host-agents/maven/podman/smoke-test.sh"
   ```

## Interactie met de podman-in-docker-hardening (kan simpeler onder Kata)

Onder Kata heeft de sandbox een **eigen guest-kernel**, zónder de Ubuntu/Tuxedo
`apparmor_restrict_unprivileged_userns`-restrictie die op de host de blokkade was.
Gevolg:
- `setup-host.sh` en het AppArmor-`userns`-profiel zijn dan vermoedelijk **niet
  nodig** (er is geen host-AppArmor die de geneste userns blokkeert).
- De overige relaxaties (`systempaths=unconfined`, seccomp-blocklist) raken nu de
  *guest*-kernel in de VM, niet de host — dus minder zwaarwegend.
- In principe kun je Testcontainers binnen de Kata-VM zelfs eenvoudiger draaien.
  Houd het toch bij de bestaande podman-set als je **één** config wilt die met én
  zonder Kata werkt.

Verifieer per setup; bovenstaande is logisch afgeleid, niet getest.

## Caveats

- **Nested virt + performance**: microVM-start en I/O zijn trager dan kale
  containers; per-container een VM kost geheugen.
- **Testcontainers in Kata** = containers-in-podman-in-microVM (extra nesting-laag).
  Werkt in principe (Kata geeft een echte kernel), maar test je workload.
- **`/dev/kvm`-toegang** is vereist; in CI/gedeelde hosts niet altijd beschikbaar.
- Kata's hypervisor (QEMU/Cloud-Hypervisor/Firecracker-backend) heeft zelf een —
  klein — aanvaloppervlak; kleiner dan een volledige VM zoals VirtualBox, groter
  dan nul.
