# Hardening verifiëren

Handmatig testprotocol voor de isolatiemaatregelen van de sandbox-container:
de setuid-strip, de privilege-drop van root naar `claude`, het AppArmor-profiel
en de egress-allowlist. Waarom die maatregelen er zijn en welke laag welke
escape sluit, staat in
[ADR 0001](../../docs/adr/0001-maven-testcontainers-sandbox-isolatie.md) —
dit document controleert alleen of ze in de praktijk doen wat daar staat.

**Wanneer draaien.** Na een wijziging aan de Dockerfile, een van de entrypoints,
`init-firewall.sh`, het AppArmor-profiel of het seccomp-profiel. CI dekt dit
niet: de statische controles daar (shellcheck, JSON-validatie, compose-parse)
zeggen niets over het gedrag van een draaiende container.

**Wat je nodig hebt.**

- Een draaiende container, gestart met de podman-override:
  `docker compose -f compose.yml -f compose.override.podman-linux.yml up --build -d --force-recreate`
- Voor sectie 1 volledig: een Linux-host met AppArmor. Op macOS en Rancher is
  `apparmor=unconfined` de legitieme stand en zit er een VM-kernelgrens onder;
  daar is de profielcontrole niet van toepassing.
- `sudo` op de host voor `aa-status` en `aa-enforce`.

Twee dingen moeten allebei kloppen: de escape is dicht (sectie 1 en 2) én de
sandbox werkt nog (sectie 3). Een half gedraaid protocol bewijst niets.

## 1. De escape moet dicht zijn

Open een shell als `claude`:

```
docker exec -tiu claude claude-sandbox bash
```

| Commando | Verwacht |
|---|---|
| `id -un` | `claude` |
| `sudo -E /usr/local/bin/init-firewall.sh` | `bash: sudo: command not found` |
| `command -v sudo` | geen output, exit 1 |
| `ls /etc/sudoers.d/` | leeg, of geen `claude-firewall` |
| `echo test > /proc/sys/kernel/core_pattern` | `Permission denied` |
| `cat /proc/self/status \| grep CapEff` | `CapEff: 0000000000000000` |
| `cat /proc/self/attr/current` | `claude-sandbox-podman (enforce)` op een gehardende Linux-host; `unconfined` op macOS/Rancher (VM-grens eronder). **Nooit `(complain)`** — de entrypoint hoort daar al op te falen |
| `find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null` | alleen `newuidmap`, `newgidmap` — geen `su`/`mount`/`passwd`/`fusermount3`/… |
| `getcap -r / 2>/dev/null` | geen binary met `cap_sys_admin`/`cap_setuid` buiten wat rootless podman nodig heeft — de setuid-strip raakt géén file-capabilities, dus hier apart controleren |

De `core_pattern`-write, het enforce-profiel en de setuid-enumeratie zijn de
kern. Die drie lagen sluiten de escape onafhankelijk: de setuid-strip sluit de
weg naar `CAP_SYS_ADMIN`, het enforce-profiel sluit de `/proc/sys`-write. Slaagt
de `core_pattern`-write wél, dan mediateert het AppArmor-profiel niet —
controleer of de container met `--security-opt apparmor=claude-sandbox-podman`
draait en of het profiel in enforce-modus staat:

```
sudo aa-status | grep claude-sandbox-podman
```

Draai je multi-uid, controleer dan dat `CAP_SYS_ADMIN` (bit 21) wél in de
bounding set zit maar níét effectief is — dat is de bewuste trade-off:

| Commando | Verwacht |
|---|---|
| `grep Cap /proc/self/status` | `CapEff: 0000000000000000`, `CapBnd` met bit 21 gezet (bevat `...a82425fb` of vergelijkbaar) |

## 2. De egress-allowlist mag niet meer self-service zijn

Nog steeds als `claude`:

| Commando | Verwacht |
|---|---|
| `OPEN_HTTPS=true /usr/local/bin/init-firewall.sh` | faalt op ontbrekende rechten voor iptables |
| `iptables -L` | `Permission denied` of `must be root` |

## 3. De sandbox moet blijven werken

| Commando | Verwacht |
|---|---|
| `docker logs claude-sandbox \| head -30` | firewall-regels opgezet, geen FATAL |
| `id -un` in de container | `claude`, niet `root` |
| `echo $HOME` | `/home/claude` |
| `ls -la /home/claude/.config/containers/storage.conf` | bestaat, eigendom `claude` |
| `podman info --format '{{.Host.Security.Rootless}}'` | `true` |
| `cd /home/claude/projects/<repo>/claude-sandbox && ./podman/smoke-test.sh` | groen |

Draai je multi-uid, dan hoort de smoke-test ook `PostgresSmokeTest` te doen:

| Commando | Verwacht |
|---|---|
| `podman info --format '{{.Host.IDMappings.UIDMap}}'` | twee mappings, bv. `[{0 1000 1} {1 100000 65536}]` |
| `cd claude-sandbox && ./podman/smoke-test.sh` | `Tests run: 2, Failures: 0, Errors: 0` |

Eén mapping in plaats van twee betekent dat setuid-root `newuidmap` geen
privileges meer wint. Controleer dan of er ergens `no_new_privs` is
binnengeslopen — dat is precies de reden dat de privilege-drop in
`entrypoint-root.sh` `--no-new-privs` bewust weglaat.

## 4. Als het AppArmor-profiel te strak blijkt

```
sudo aa-complain /etc/apparmor.d/claude-sandbox-podman
# reproduceer de fout
sudo dmesg | grep -i 'apparmor.*DENIED'
sudo aa-enforce /etc/apparmor.d/claude-sandbox-podman
```

`entrypoint-root.sh` weigert standaard te starten als het profiel in
complain-modus staat (dat is de borging uit sectie 1). Om in complain te kunnen
reproduceren, recreate de container eenmalig met `ALLOW_APPARMOR_COMPLAIN=true`
in de environment; dan degradeert die check tot een waarschuwing. Zet de env weer
weg zodra je klaar bent.

Verruim het profiel gericht op basis van die output. Val niet terug op
`flags=(unconfined)`: dan is de escape uit sectie 1 weer open.

## Uitkomst rapporteren

Noteer per sectie wat je zag. Een half gedraaid protocol is geen bevestiging —
sectie 1 en 3 moeten allebei volledig groen zijn voordat deze hardening als
werkend geldt.
