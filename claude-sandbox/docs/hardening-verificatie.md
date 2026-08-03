# Hardening verifiëren

De hardening uit PR B doet twee dingen die je niet op het woord moet geloven:
hij sluit een escape, en hij mag de sandbox niet breken. Dit protocol test
allebei. Draai het op een echte host, ná `docker compose … up --build -d
--force-recreate` met de podman-override.

De statische controles (shellcheck, JSON-validatie, compose-parse) zijn al in CI
gedraaid. Wat hieronder staat, kan alleen op een draaiende container.

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
| `cat /proc/self/status \| grep CapEff` | `0000000000000000` |

De laatste twee zijn de kern. Slaagt de `core_pattern`-write wél, dan
mediateert het AppArmor-profiel niet — controleer of de container met
`--security-opt apparmor=claude-sandbox-podman` draait en of het profiel in
enforce-modus staat:

```
sudo aa-status | grep claude-sandbox-podman
```

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
| `./podman/smoke-test.sh` | groen |

Draai je multi-uid, dan hoort de smoke-test ook `PostgresSmokeTest` te doen:

| Commando | Verwacht |
|---|---|
| `podman info --format '{{.Host.IDMappings.UIDMap}}'` | twee mappings, bv. `[{0 1000 1} {1 100000 65536}]` |
| `./podman/smoke-test.sh` | `Tests run: 2, Failures: 0, Errors: 0` |

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

Verruim het profiel gericht op basis van die output. Val niet terug op
`flags=(unconfined)`: dan is de escape uit sectie 1 weer open.

## Uitkomst rapporteren

Noteer per sectie wat je zag. Een half gedraaid protocol is geen bevestiging —
sectie 1 en 3 moeten allebei volledig groen zijn voordat deze hardening als
werkend geldt.
