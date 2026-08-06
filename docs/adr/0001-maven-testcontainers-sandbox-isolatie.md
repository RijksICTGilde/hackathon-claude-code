# ADR 0001 — Isolatie voor Maven/Testcontainers-builds in de sandbox

**Status:** Geaccepteerd — host-agent verwijderd. — 2026-08-03
(voorgesteld 2026-06-10)
**Bekrachtigd:** via de PR die de host-agent verwijdert, in het kader van issue
[#44](https://github.com/RijksICTGilde/hackathon-claude-code/issues/44).
**Context-issue:** [#44](https://github.com/RijksICTGilde/hackathon-claude-code/issues/44)

Dit document is de canonieke plek voor de isolatie-afwegingen van de sandbox.
Code verwijst hierheen met sectienummer én titel, bijvoorbeeld
`ADR 0001 §2.3.3 "Privilege-drop zonder --no-new-privs"`. Herhaal de
onderbouwing niet in comments — zet daar wat je moet weten om díé regel te
begrijpen, en verwijs voor het waarom hierheen.

Het oorspronkelijke ontwerpdocument met meetresultaten
(`docs/superpowers/specs/2026-06-10-maven-podman-in-docker-design.md`) is een
historisch verslag van het onderzoek. Bij verschil is dit document leidend.

## 1. Context

De sandbox-container bevat geen Docker-daemon, dus Maven-builds met
Testcontainers werken niet rechtstreeks. De oplossing wás een **host-side Maven
MCP-agent** die `mvn` op de host draaide namens Claude — per ontwerp een
container→host code-execution-bridge. Die agent is met deze beslissing
verwijderd.

Waarom dat moest (uit #44): Claude beheerst `pom.xml` en `mvnw` in de gedeelde
`projects`-map, en `mvn` voerde die plugins ongezien uit als de host-user die
`run.sh` startte. Draaide die user in de `docker`-group of met sudo, dan was
host-escalatie mogelijk. Op Linux bond de agent bovendien auth-loos op
`0.0.0.0:7777`.

## 2. Beslissing

### 2.1 Podman in de sandbox in plaats van een host-bridge

Rootless Podman **ín** de sandbox draait Testcontainers genest. Geen
host-bridge, geen Docker-socket, geen `--privileged`. `mvn` en pom-plugins
draaien in de sandbox als non-root `claude`; Testcontainers-children zijn
geneste rootless-userns-children. Daarmee verdwijnt de container→host
code-execution van #44.

Het geheel is **opt-in**: `INSTALL_PODMAN=false` is de default, en de
runtime-relaxaties uit §2.5 zitten in een aparte compose-override die je
expliciet met `-f` meegeeft.

Geverifieerd op een echt project: een Quarkus-module met Redis-stack
Dev-Services plus integratietests draaide 289 + 46 tests groen.

### 2.2 Bouwfase (image)

#### 2.2.1 Rootless podman als opt-in

`INSTALL_PODMAN=true` installeert `podman`, `uidmap`, `passt` en `slirp4netns`.
Staat de vlag op `false`, dan is er geen podman in de image en zijn de
relaxaties uit §2.5 niet nodig.

#### 2.2.2 Single-uid default, multi-uid opt-in

**Single-uid** (default) verwijdert de subuid/subgid-range voor `claude`. Zonder
subuid-entry mapt podman alleen de eigen uid als root en gebruikt het
`newuidmap` niet. Prijs: images die naar een tweede uid chownen — postgres,
mysql, mariadb en de meeste DB-images — starten niet met
`chown: ...: Invalid argument`.

**Multi-uid** (`PODMAN_MULTIUID=true`) zet die range juist wél. Dat vereist
`newuidmap`, en de kernel laat een uid_map-write alleen toe aan wie
`CAP_SYS_ADMIN` heeft in de doel-namespace óf er de eigenaar van is. `newuidmap`
is setuid-root, dus euid 0 terwijl de namespace van uid 1000 is — de
eigenaars-route valt weg en de capability is vereist. Docker houdt
`CAP_SYS_ADMIN` uit de bounding set, dus dit werkt alleen met
`compose.override.podman-multiuid.yml` erbij. Wat die keuze kost, staat in §4.2.

#### 2.2.3 Setuid-strip

De Dockerfile stript alle setuid- en setgid-bits, op `newuidmap` en `newgidmap`
na. Dit is de dragende laag onder §4.1.

Zonder deze strip kan `claude` na de privilege-drop euid 0 winnen via élke
setuid-root-binary (`su`, `mount`, `passwd`, …), omdat de drop bewust géén
`--no-new-privs` zet (§2.3.3) en de bounding set intact laat. De kernel vult bij
zo'n setuid-exec de permitted caps uit de bounding set — in de multi-uid opt-in
inclusief `CAP_SYS_ADMIN`. De strip raakt ook setuid-`mount`/`umount`, wat de
proc-remount-bypass op binary-niveau dichtzet; rootless podman mount via de
syscall in zijn eigen userns en heeft die binaries niet nodig.

Geverifieerd gestript: `su`, `mount`, `umount`, `passwd`, `chsh`, `chfn`,
`chage`, `expiry`, `gpasswd`, `newgrp`, `ssh-agent`, `ssh-keysign`,
`unix_chkpwd`.

### 2.3 Rootfase bij container-start

De container start als root en dropt in `entrypoint-root.sh` onherroepelijk naar
`claude`. Alles hieronder gebeurt vóór die drop; daarna is er geen weg terug.

Trivy meldt hierop `DS-0002` ("last USER should not be root"). Die melding is
onderdrukt in `.trivyignore`, met de onderbouwing daar. Het alternatief — de
firewall in een aparte init-service — staat in
[#98](https://github.com/RijksICTGilde/hackathon-claude-code/issues/98).

#### 2.3.1 Firewall vóór de privilege-drop

`init-firewall.sh` vereist `NET_ADMIN`/`NET_RAW` en draait daarom in deze fase.
`OPEN_HTTPS` en `ALLOWED_DOMAINS` worden alleen hier gelezen.

Dat sluit de egress-allowlist als self-service. Eerder liep de firewall via
`sudo -E` met een sudoers-regel die de `SETENV`-tag droeg; die tag liet
`BASH_ENV` de `env_reset` van sudo overleven, waarmee
`sudo BASH_ENV=/tmp/p.sh init-firewall.sh` willekeurige code als root draaide.
Daarnaast kon `claude` datzelfde commando zelf opnieuw draaien met
`OPEN_HTTPS=true` in zijn eigen omgeving. Er is nu geen `sudo` en geen
sudoers-regel meer.

#### 2.3.2 AppArmor-enforce-borging

Staat het profiel uit §2.5.2 in *complain*-modus, dan worden de
`/proc/sys`-denies niet afgedwongen. `entrypoint-root.sh` faalt daarom hard in
dat geval, zodat de sandbox niet stil met een gat start. Alleen ons eigen
profiel wordt gecheckt: op macOS en Rancher is `apparmor=unconfined` de
legitieme stand, met een VM-kernelgrens eronder.

`ALLOW_APPARMOR_COMPLAIN=true` degradeert die fatal tot een waarschuwing, voor
het diagnoserecept in `claude-sandbox/docs/hardening-verificatie.md`. Alleen de
operator kan die env zetten bij container-start; `claude` bereikt deze fase
niet.

#### 2.3.3 Privilege-drop zonder --no-new-privs

De drop gebruikt `setpriv --reuid --regid --init-groups --inh-caps=-all` en zet
bewust **geen** `--no-new-privs`.

Dat lijkt gratis hardening, maar setuid-root `newuidmap` wint er geen privileges
meer mee, waarna multi-uid rootless podman degradeert naar single-uid en
DB-images falen op `chown: Invalid argument`. Dat is gemeten, niet aangenomen.

De bescherming die `--no-new-privs` zou geven, komt in plaats daarvan van de
setuid-strip uit §2.2.3. De bounding set blijft staan omdat setuid-root
`newuidmap` daar in de multi-uid opt-in `CAP_SYS_ADMIN` uit moet kunnen trekken.

#### 2.3.4 Optionele sshd in de rootfase

`INSTALL_SSHD=true` bouwt een OpenSSH-server mee; `ENABLE_SSHD=true` (gezet door
`compose.override.kepler.yml`) start hem. De schakelaar is de runtime-var en niet
de aanwezigheid van de binary, zodat een image die één keer met de toggle
gebouwd is niet bij elke start een poort openzet.

De start staat hier om dezelfde reden als de firewall: sshd bindt poort 22 en
heeft root nodig voor zijn privilege separation, en na de drop is dat er niet
meer. Hij draait wel met een verkleinde bounding set (`-net_admin,-net_raw`) —
die capabilities heeft de container voor de firewall, en een pre-auth-lek in
OpenSSH zou er anders `iptables -F` mee kunnen doen.

Host-keys worden bij eerste start op het `claude-home` volume gemaakt, niet in de
image: een privésleutel in een layer geeft iedereen met die image de identiteit
van elke container die eruit draait. Omdat `/home/claude` van `claude` is, wordt
type en eigendom van dat pad elke start gecontroleerd — anders kiest de
ingesloten partij zelf welke host-identiteit Kepler in `known_hosts` pint. `authorized_keys` schrijft
`entrypoint.sh` ná de drop, zodat `~/.ssh` van `claude` blijft: wie de
env-variabele leeg laat, beheert dat bestand zelf op het volume.

### 2.4 Gebruikersfase

Vanaf hier draait alles als `claude`. `entrypoint.sh` weigert te starten als het
als root wordt aangeroepen.

#### 2.4.1 Storage: alleen vfs

`storage.conf` wordt bij elke start gegenereerd met driver `vfs`.

`fuse-overlayfs` is sneller maar vereist dat `/dev/fuse` wordt doorgegeven aan
de container. Dat opent de FUSE-laag van de host-kernel voor code in de sandbox
— extra syscall-oppervlak in een kernel die met de host gedeeld wordt, en FUSE
heeft een lopende stroom CVE's. De winst is snelheid, niet functionaliteit, en
de filesystem-snelheid met vfs voldoet. Daarom wordt overlay-storage niet
ondersteund: het pakket zit niet in de image en er is geen configuratievlag om
het aan te zetten.

`ignore_chown_errors` staat aan in single-uid modus, zodat images die naar een
niet-gemapte uid chownen bij extractie niet hard falen. In multi-uid bestaan die
uids wél en zou de optie een echte fout maskeren — daar blijft hij weg.

#### 2.4.2 Netwerk: pasta

De entrypoint zet `netns = "pasta"` in `containers.conf`, voor álle geneste
containers — ook die Testcontainers via de podman-Docker-API start.

Voor een netavark-**bridge** zet podman een IPv6-sysctl op een interface in de
netwerknamespace van de buitenste container. Dat faalt met
`netavark: failed to set autoconf sysctl: Permission denied`, want die namespace
wordt door de host geowned (er is geen userns-remap) en rootless podman mag er
`/proc/sys/net` niet schrijven. Pasta geeft elke container een eigen netwerk met
port-forwarding naar `localhost` en omzeilt de bridge.

Nevenwinst voor de egress-controle: pasta-verkeer is user-mode en lokaal
gegenereerd, dus nested egress passeert de OUTPUT-chain van de firewall en valt
onder dezelfde domein-allowlist als de sandbox zelf. Een netavark-bridge
routeerde nested verkeer via de FORWARD-chain, waar de allowlist niet zit —
pasta sluit dat gat.

Beperking: containers die elkáár over een gedeeld netwerk moeten bereiken
(Testcontainers `Network`) werken niet. Dat vereist userns-remap op de buitenste
container — [#82](https://github.com/RijksICTGilde/hackathon-claude-code/issues/82).

#### 2.4.3 Podman-socket bij container-start

De entrypoint start `podman system service` bij container-start, niet per
build-sessie.

Het éérste podman-commando maakt het pause-proces aan dat de user-namespace
vastlegt; alles daarna joint dat proces. Lukt die eerste aanmaak niet met de
volledige subuid-range, dan blijft de hele container in single-uid hangen — ook
nadat de oorzaak weg is. Dat gebeurt bijvoorbeeld als het eerste commando onder
`no_new_privs` draait. Door de socket in een schone omgeving op te zetten vóór
er iets anders draait, joinen latere aanroepen een gezonde namespace.

De socket geeft geen nieuwe rechten: alles wat als `claude` draait kon al podman
aanroepen.

### 2.5 Relaxaties op de buitenste container

Deze staan in `compose.override.podman-linux.yml` en `-macos.yml`, die je
expliciet met `-f` meegeeft. Ze zijn niet actief bij een gewone
`docker compose up`.

#### 2.5.1 seccomp-blocklist

Een eigen profiel met `defaultAction=ALLOW`, in plaats van `unconfined`.

Een allowlist is hier niet werkbaar: die zet `clone`, `unshare`, `mount` en
`setns` achter `CAP_SYS_ADMIN` en breekt rootless podman — Docker-default
seccomp faalt op precies dat punt met "cannot clone". De blocklist re-blokkeert
wél de kernel-escape-syscalls: module-load, kexec, reboot, raw-IO, klok-zetten,
bpf, `perf_event_open`, `open_by_handle_at`, `userfaultfd`, `io_uring_*`,
quotactl, syslog en legacy-io.

De kernel-keyring-syscalls (`keyctl`, `add_key`, `request_key`) staan bewust
toe: crun maakt bij container-start een session-keyring en blokkeren breekt
geneste podman.

#### 2.5.2 AppArmor-profiel met userns

Afgeleid van `docker-default`, met twee afwijkingen: `userns,` toegevoegd, en
`deny mount,` vervangen door expliciet toegestane `mount`/`umount`/`pivot_root`
die geneste rootless podman nodig heeft. De `/proc/sys`-denies blijven staan —
die doen het eigenlijke werk, zie §4.3.

`userns,` is nodig op gehardende Ubuntu en Tuxedo
(`kernel.apparmor_restrict_unprivileged_userns=1`), zodat alleen deze container
user-namespaces mag gebruiken zonder de host-hardening systeembreed uit te
zetten. Installeren met `claude-sandbox/podman/setup-host.sh`.

#### 2.5.3 systempaths=unconfined

Docker maskeert delen van `/proc` (`kcore`, `sysrq-trigger`, `/proc/sys`, …).
Een geneste container die een nieuwe procfs mount zou die maskering ontsluieren,
en de kernel weigert dat met "mount proc: Operation not permitted".
`systempaths=unconfined` heft de gemaskeerde en read-only `/proc`-paden op de
buitenste container op.

Dit pelt de hardening van de buitenste sandbox verder af en is de reden dat het
AppArmor-profiel uit §2.5.2 er moet zijn — zie §4.3.

Op SELinux-hosts staat daarnaast `label=disable`; elders is dat een no-op.

#### 2.5.4 Als het profiel te strak blijkt

Een te strak profiel laat podman geen geneste containers meer starten. Zet het
dan tijdelijk in klaagmodus, reproduceer de fout, en kijk wat er geweigerd
wordt:

```
sudo aa-complain /etc/apparmor.d/claude-sandbox-podman
# reproduceer de fout
sudo dmesg | grep -i 'apparmor.*DENIED'
sudo aa-enforce /etc/apparmor.d/claude-sandbox-podman
```

`entrypoint-root.sh` weigert standaard te starten zolang het profiel in
klaagmodus staat (§2.3.2). Recreate de container daarom eenmalig met
`ALLOW_APPARMOR_COMPLAIN=true` in de environment, en haal die env weg zodra je
klaar bent.

Verruim het profiel gericht op basis van de `DENIED`-regels. Val niet terug op
`flags=(unconfined)`: dan staat de escape uit §4.1 weer open.

## 3. Overwogen en verworpen

- **Host-side Maven-agent** (de vorige oplossing). Verworpen als container→host
  code-execution-bridge (§1). Ook géén aantrekkelijk *alternatief* voor wie de
  relaxaties uit §2.5 wil mijden: die verbreden het kernel-oppervlak van de
  *container*, en een escape vereist dan nog een kernel-exploit — terwijl de
  host-agent code **direct op de host** uitvoert als de host-user. Voor wie
  beducht is op container-escape is dat juist een zwakker model. Daarom niet
  bewaard als terugvaloptie.
- **Runner-container met een gemounte Docker-socket.** Verworpen: wie bij de
  Docker-socket kan, kan een container starten met `--privileged` en het
  host-filesystem gemount, en is daarmee host-root. Een socket doorgeven is
  functioneel gelijk aan root op de host weggeven.
- **`--no-new-privs` bij de privilege-drop.** Gemeten en verworpen; zie §2.3.3.
- **fuse-overlayfs als snellere storage.** Verworpen om het
  kernel-aanvaloppervlak; zie §2.4.1.

## 4. Security-balans

### 4.1 Wat dicht is

- **De container→host code-execution-bridge van #44.** Er is geen host-agent
  meer en geen Docker-socket; alle projectcode draait in de sandbox.
- **De route van uid 1000 naar container-root**, langs twee gesloten paden. De
  sudo-route is dicht doordat de firewall vóór de drop draait en `sudo` en de
  sudoers-regel weg zijn (§2.3.1). De setuid-route is dicht door de
  setuid-strip (§2.2.3).
- **De egress-allowlist als self-service.** `OPEN_HTTPS` en `ALLOWED_DOMAINS`
  worden alleen vóór de drop gelezen, dus `claude` kan de firewall niet meer
  heropenen (§2.3.1).
- **De `core_pattern`→host-root-escapeklasse**, ook met `systempaths=unconfined`
  (§2.5.3). Het AppArmor-profiel behoudt de `/proc/sys`-denies, en de
  enforce-borging uit §2.3.2 voorkomt dat het profiel stil in complain blijft
  staan.

Eén geval valt buiten de runtime-check: "profiel helemaal niet toegepast" op een
Linux-host is niet te onderscheiden van de legitieme macOS-stand `unconfined`.
Het handmatige protocol in `claude-sandbox/docs/hardening-verificatie.md` vangt
dat wel.

### 4.2 Wat open blijft

- **De relaxaties op de buitenste container** uit §2.5: seccomp is een blocklist
  en geen allowlist, `systempaths=unconfined` staat aan, en op SELinux-hosts
  geldt `label=disable`.
- **`CAP_SYS_ADMIN` in de bounding set bij multi-uid** (§2.2.2). `claude` heeft
  `CapEff=0` en krijgt hem niet rechtstreeks; alleen setuid-root `newuidmap` en
  `newgidmap` trekken hem eruit, en die geven geen shell. Maar er is geen
  userns-remap, dus container-root is host-root-uid. Áls er ooit tóch een
  escalatie naar container-root met `CAP_SYS_ADMIN` is, is die host-breed en
  niet container-breed. Draai deze opt-in daarom niet met een profiel op
  `flags=(unconfined)` en niet met een image zonder de setuid-strip.
- **Het AppArmor-profiel staat `mount,`, `pivot_root,`, `capability,` en `file,`
  toe**, want geneste podman heeft mount nodig. Het sluit dus de
  `/proc/sys`-usermode-helper-escapeklasse, niet elke capability van
  container-root. De proc-mount-bypass in het profiel zelf blokkeren vergt
  vermoedelijk een child-profiel voor de geneste runtime.
- **De optionele sshd** (§2.3.4) voegt inbound oppervlak toe. De poort wordt
  host-side alleen op `127.0.0.1` gepubliceerd, maar binnen het container-netwerk
  luistert sshd op `0.0.0.0:22` en accepteert de firewall het hele bridge-subnet:
  een andere container op datzelfde netwerk bereikt hem rechtstreeks. De daemon
  draait als root, dus een pre-auth-kwetsbaarheid weegt zwaarder dan een
  gecompromitteerde sessie. `openssh-server` komt ongepind uit apt en valt
  buiten Dependabot; de `sshd-hardening`-job in `build-image.yml` scant de
  gebouwde variant daarom met Trivy (`scan-type: image`), zodat een kwetsbare
  sshd wél een signaal geeft. Die variant is de default-image plus openssh, dus
  dezelfde scan dekt ook wat de gewone image meebrengt. De fix is dan een rebuild — regelmatig herbouwen
  is hier een beveiligingseis, geen hygiëne. Draai deze opt-in
  bij voorkeur in een VM.
- **Kernel-escapes** blijven buiten bereik van al deze maatregelen.

### 4.3 Welke laag welke escape sluit

De rootfase plus de setuid-strip sluiten het *bereiken* van container-root met
`CAP_SYS_ADMIN`. Dat is de dragende laag. Het AppArmor-profiel sluit daar
bovenop het *directe* `/proc/sys`-usermode-helper-pad (`core_pattern` en
verwanten).

De twee zijn niet symmetrisch. De setuid-laag houdt óók als AppArmor faalt.
AppArmor alléén is niet voldoende tegen een houder van `CAP_SYS_ADMIN`: de
`/proc/sys`-deny is *padgebonden* aan `/proc`, en een verse proc-mount elders
zou hem omzeilen. AppArmor is dus defense-in-depth voor het directe pad, geen
zelfstandige vervanger van de setuid-strip.

Praktisch: zet het profiel niet terug op `flags=(unconfined)`, en lever de image
niet zonder de setuid-strip.

### 4.4 Verificatie

`claude-sandbox/docs/hardening-verificatie.md` bevat het testprotocol, inclusief
de negatieve tests die aantonen dat de escape dicht is.

### 4.5 Weging

Geschikt voor het reële dreigingsbeeld van #44: Claude die rogue gaat of via
prompt-injectie wordt aangestuurd, in semi-vertrouwde code. Niet geschikt voor
volledig vijandige, kernel-exploit-capabele code — daar hoort een eigen kernel
bij (VM, Kata of gVisor). Die route is uitgesteld; een eerste uitwerking staat in
[#99](https://github.com/RijksICTGilde/hackathon-claude-code/pull/99), nog
ongetest.

## 5. Consequenties

- Projecten die Testcontainers nodig hebben gebruiken de podman-set
  (`claude-sandbox/podman/README.md`).
- **De host-agent is verwijderd.** Hosts waar podman-in-de-sandbox niet
  bevestigd is — Docker Desktop op Mac en Windows, WSL2, rootless
  `podman machine` — hebben geen Testcontainers-route meer. Dat is een bewuste
  afweging: het risico van een container→host code-execution-bridge weegt
  zwaarder dan de dekking, en **binnen dit team** zijn er geen gebruikers op die
  platforms. Een hergebruiker met wél zulke werkplekken — Windows met WSL2 is
  bij veel overheidsorganisaties de standaard — moet deze afweging opnieuw maken
  en de opzet daar eerst bevestigen met `podman/setup-host.sh` en
  `podman/smoke-test.sh`. Welke platforms bevestigd zijn, staat in
  `claude-sandbox/podman/README.md`.
- **Overlay-storage is niet beschikbaar** (§2.4.1). Builds die veel image-lagen
  extraheren zijn daardoor trager dan met fuse-overlayfs.
- **Een eigen kernel (VM, Kata, gVisor) is uitgesteld**, niet afgewezen — zie
  [#99](https://github.com/RijksICTGilde/hackathon-claude-code/pull/99). Op Mac
  en Windows is die kernelgrens er al, omdat Docker Desktop, Rancher en
  `podman machine` in een VM draaien.
