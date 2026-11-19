# Ontwerp — firewall-uitzondering voor een Kubernetes-API-server buiten het sandbox-netwerk

**Datum:** 2026-11-19
**Raakt:** `claude-sandbox/init-firewall.sh`, `claude-sandbox/controleer-kubeconfig.sh`,
`claude-sandbox/compose.yml`, `claude-sandbox/.env.sample`,
`claude-sandbox/docs/kubernetes.md`, `claude-sandbox/README.md`,
`.github/scripts/test-controleer-kubeconfig.sh`

## Aanleiding

Een kubeconfig die naar een API-server buiten het netwerk van de sandbox wijst,
werkt niet. `kubectl` eindigt op:

```
Unable to connect to the server: dial tcp 172.19.0.1:6443: connect: no route to host
```

Die melding wijst niet naar routing maar naar de firewall: de laatste
OUTPUT-regel is `REJECT --reject-with icmp-admin-prohibited`, en de kernel
vertaalt dat naar `EHOSTUNREACH` — "no route to host".

Twee bestaande mechanismen dekken dit geval geen van beide:

- `HOST_NETWORK` krijgt een onvoorwaardelijke ACCEPT, maar dat is het subnet van
  de sandbox zelf. Een API-server op een andere bridge van de host (`172.19.0.1`
  naast een sandbox op `10.89.0.0/24`) valt erbuiten.
- `ALLOWED_DOMAINS` opent uitsluitend poort 443, en de ipset erachter wordt
  gevuld uit DNS. Een IP-adres kan er niet in, en een API-server luistert op
  6443.

`OPEN_HTTPS=true` helpt evenmin: dat opent alleen 443.

## Scope

Eén PR. Een nieuwe environment-variabele `ALLOWED_K8S_API` met de vorm
`host:poort`, die precies één TCP-bestemming opent.

Buiten scope: een algemene `host:poort`-allowlist voor andere diensten (interne
registries, mirrors). Als die behoefte er komt, is dit ontwerp de basis, maar
een bredere variabele nu zou een groter gat openen dan de aanleiding vraagt.

## Ontwerp

### 1. `init-firewall.sh` — de uitzondering

Een nieuw blok, ná de nameserver-whitelist en vóór de afsluitende
`REJECT`-regel.

```bash
iptables -A OUTPUT -p tcp -d "$ip" --dport "$poort" -j ACCEPT
```

Ontwerpkeuzes:

- **Rechtstreekse regel, geen ipset.** De set `allowed-domains` bestaat alleen
  bij `OPEN_HTTPS=false`; de uitzondering moet in beide standen werken, want ook
  met `OPEN_HTTPS=true` is 6443 dicht. Daarom staat het blok buiten de
  `OPEN_HTTPS`-tak.
- **Host mag een IPv4-adres of een hostnaam zijn.** Een hostnaam wordt bij de
  start opgezocht met `dig A`; elk A-record krijgt een eigen regel. Dit lost
  tegelijk het geval op dat `docs/kubernetes.md` tot nu toe als onoplosbaar
  beschreef: een API-server op een hostnaam, maar niet op poort 443.
- **Geen antwoord uit DNS is fataal.** Gelijk aan de bestaande `DOMAINS`-lus:
  doorgaan zou een container opleveren die draait terwijl de reden om hem te
  starten weggevallen is.
- **Poort via `10#`.** `06443` is 6443 en niet octaal.
- **Leeg of ongezet is een no-op**, zonder melding. Is hij wél gezet, dan logt
  het script per geopend IP een regel.

Afgewezen invoer, elk met een melding die de juiste vorm toont:

| Invoer | Reden |
|---|---|
| `https://host:6443` | schema hoort er niet in |
| `host` | poort ontbreekt |
| `[::1]:6443`, `fd00::1` | de firewall blokkeert IPv6 integraal |
| poort buiten 1–65535, of niet-numeriek | geen geldige poort |
| hostnaam die niet aan de DNS-vorm voldoet | geen geldige host |

De bestaande regel die poort 6443 tegen `allowed-domains` matcht, vervalt. Die
set kan het IP van een API-server niet bevatten, dus de regel opende nooit iets.

### 2. `controleer-kubeconfig.sh` — waarschuwing bij mismatch

Dit script draait al bij elke start op de gemounte kubeconfig. `setpriv` laat de
omgeving staan bij de privilege-drop, dus `ALLOWED_K8S_API` is er leesbaar.

Het leest `.clusters[0].cluster.server`, haalt host en poort eruit (zonder poort
in de URL: 443) en schrijft één waarschuwing als die niet overeenkomen met
`ALLOWED_K8S_API`. Niet fataal, en zonder het bestaande oordeel over de
kubeconfig te wijzigen.

Geen waarschuwing in de gevallen waarin het adres al bereikbaar is:

- de poort is 443 en `OPEN_HTTPS=true`;
- de host valt binnen het eigen subnet uit `ip route` — dat is de
  k3d-op-het-sandbox-netwerk-route, waar de `HOST_NETWORK`-ACCEPT het al dekt;
- er is geen kubeconfig gemount.

De controle is een waarschuwing en geen fout, omdat een legitieme opzet de
variabele niet nodig heeft.

### 3. Doorgeven en documenteren

- `compose.yml`: `ALLOWED_K8S_API` bij `environment`, zodat de waarde de
  root-fase bereikt.
- `.env.sample`: blok bij `SANDBOX_KUBECONFIG`, met wat het opent.
- `docs/kubernetes.md`: de passage die zegt dat een IP in `server:` niet kan en
  dat 6443 ook met `OPEN_HTTPS=true` dichtblijft, klopt hierna niet meer en
  wordt vervangen. k3d op het sandbox-netwerk blijft de aanbevolen route; deze
  variabele is voor een cluster dat je niet kunt verplaatsen.
- `README.md`: de firewall-sectie noemt alleen poort 443; één regel erbij.

### 4. Verificatie

- `.github/scripts/test-controleer-kubeconfig.sh`: de `toets`-helper rekent
  stderr bij exitcode 0 nu als fout aan. Er komt een variant bij die een
  verwachte waarschuwing toelaat. Fixtures: match, mismatch, variabele ongezet,
  poort 443 met `OPEN_HTTPS=true`, host binnen het eigen subnet.
- `shellcheck --severity=warning` op beide gewijzigde scripts.
- `docker compose build --no-cache`, en een start met
  `ALLOWED_K8S_API` gezet, gevolgd door `kubectl get namespace`.

Geen bereikbaarheidstest in de firewall zelf. Het cluster hoeft bij
container-start niet te draaien, en een `verify_reachable` zou de start dan
laten falen op iets wat buiten de sandbox ligt.

## Beveiliging

Deze variabele opent een TCP-poort buiten 443 naar een bestemming die de
gebruiker kiest. Met een hostnaam geldt de regel voor élk IP dat die naam bij de
start oplevert.

Dat staat naast wat `docs/kubernetes.md` al vastlegt: met clustertoegang bereikt
Claude via het cluster meer dan de firewall van de sandbox toelaat — pods draaien
op het netwerk van het cluster, en port-forward, een Ingress of de naam van een
container-image lopen eromheen. De uitzondering hier vergroot dat niet; ze maakt
de bestaande clustertoegang bruikbaar op een API-server die niet op het
sandbox-netwerk staat.
