# Eine weitere App unter die WAF nehmen

Vorgehen für Coraza als Envoy-WASM-Filter. Entspricht dem, was man in Azure
AppGw als Detection → Tuning → Prevention kennt, nur über Manifeste und Logs
statt über eine UI.

---

## Ausgangslage

Die `EnvoyExtensionPolicy` hängt per `targetRefs` an **genau einer**
`HTTPRoute`. Jede App braucht also eine eigene Policy — das ist der Grund,
warum wir CrowdSec AppSec verworfen haben, wo es alles oder nichts gewesen
wäre.

Routen am externen Gateway (Stand 2026-08-19):

| Route | Host | WAF |
|---|---|---|
| `keycloak/keycloak` | auth.… | ja, enforcing |
| `snipeit/snipeit` | wms.… | nein |
| `nextcloud/nextcloud` | nextcloud.… | nein — siehe Warnung |
| `envoy-gateway-system/pve` | pve.… | nein |
| `envoy-gateway-system/vodafone` | vodafone.… | nein |
| `kube-system/kube-apiserver` | k8s.… | nein |

---

## Zwei Dinge vor dem Anfangen

**Speicher — der eigentliche Engpass.** Jede Policy erzeugt eigene WASM-VMs,
eine pro Envoy-Worker-Thread (`concurrency` in
`resources/envoy-gateway.yaml`, aktuell 4).

Gemessen mit *einer* Policy (Keycloak):

| | |
|---|---|
| ohne WAF | 34 MiB |
| kurz nach Aktivierung | 313 MiB |
| nach ~44 h Laufzeit | **507 MiB** von 1 GiB Limit |

Der Wert **wächst über die Laufzeit**. Envoys eigene Statistik erklärt ihn
nicht: `allocated` liegt bei 96 MiB, `total_physical_bytes` bei 194 MiB — die
Differenz zum Container-RSS ist Speicher der WASM-Runtime, den Envoy nicht
mitzählt.

Daraus folgt: **eine zweite Policy ist knapp, drei passen sicher nicht.** Vor
dem Hinzufügen den aktuellen Stand messen und danach beobachten:

```bash
kubectl top pod -n envoy-gateway-system --containers | grep external

# Envoys eigene Sicht (zeigt, wieviel davon NICHT von Envoy stammt)
EP=$(kubectl get pods -n envoy-gateway-system \
     -l gateway.envoyproxy.io/owning-gateway-name=envoy-gateway-external \
     -o jsonpath='{.items[0].metadata.name}')
kubectl port-forward -n envoy-gateway-system pod/$EP 19000:19000 &
curl -s localhost:19000/memory
```

Wenn der Wert weiter steigt, sind die Stellschrauben: `concurrency` senken
(weniger VMs), das Limit anheben, oder die Policy auf weniger Routen
beschränken. Ein OOMKill trifft **den gesamten externen Gateway**, nicht nur
die Route mit der WAF.

**Nextcloud ist ein Sonderfall.** `@recommended-conf` aktiviert:

```
SecRequestBodyAccess On
SecRequestBodyLimit 131072          (128 KB)
SecRequestBodyLimitAction Reject    ← größere Bodies werden VERWORFEN
```

Bei `upload_max_filesize = 16G` würde damit jeder nennenswerte Upload
scheitern. Diese Route braucht entweder eine eigene Konfiguration ohne
Body-Inspektion oder gar keine WAF.

---

## Schritt 1 — Policy anlegen, Detect-Modus

Neue Datei unter `flux/clusters/tokamak/resources/`, Namespace = der der
Ziel-App. Beispiel Snipe-IT:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: coraza-waf
  namespace: snipeit
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: snipeit
  wasm:
    - name: coraza
      rootID: waf
      # Nicht optional. Ein fehlgeschlagener Filter-Init darf die App nicht
      # mitreißen — bei auth.* hinge daran auch der kubectl-Zugang.
      failOpen: true
      code:
        type: Image
        image:
          url: ghcr.io/corazawaf/coraza-proxy-wasm:0.6.0
          # Digest des linux/amd64-Plattform-Manifests, NICHT des OCI-Index.
          # Der Index-Digest führt zu: "module downloaded from ... has checksum
          # 65d6009b..., which does not match: d66f9448..." → reason: Invalid
          sha256: 65d6009b9da2e8965e592a08b74a86725435fc01aa39c756dce0bd5ea64b3f4e
      config:
        # REIHENFOLGE ZÄHLT. @recommended-conf setzt selbst SecRuleEngine
        # DetectionOnly. Jede Engine-Direktive muss DANACH stehen, sonst wird
        # sie stillschweigend zurückgesetzt.
        directives_map:
          default:
            - "Include @recommended-conf"
            - "SecRuleEngine DetectionOnly"
            - "SecAuditEngine RelevantOnly"
            - "Include @crs-setup-conf"
            - "Include @owasp_crs/*.conf"
        default_directives: default
```

In `resources/kustomization.yaml` eintragen, committen, dann prüfen:

```bash
kubectl get envoyextensionpolicy coraza-waf -n snipeit \
  -o jsonpath='{.status.ancestors[0].conditions[*].type}={.status.ancestors[0].conditions[*].status}'
```

Muss `Accepted=True` liefern. Die WASM-VM übernimmt die Config nicht sofort —
nach dem Rollout ein bis zwei Minuten warten, bevor man testet.

---

## Schritt 2 — Beobachten

**Voraussetzung, sonst ist die Phase wertlos:** Das Container-Log ist ein
rotierender Puffer. Nach ein paar Stunden sind ältere Zeilen weg. Für eine
Auswertung über Wochen müssen die Coraza-Zeilen in den Victoria-Logs-Stack.
Ohne das schaut man am Ende wieder auf zwei Tage.

Wie lange? So lange, bis der reale Nutzungsalltag abgedeckt ist — andere
Browser, Mobilgeräte, Sync-Clients, Token-Refreshes über mehrere Tage. Zur
Einordnung: bei Keycloak lagen nach 1,5 Tagen ganze **32 Browser-Requests und
ein einziger interaktiver Login** vor. Das ist eine Stichprobe, keine
Beobachtungsphase.

---

## Schritt 3 — Auswerten

Der entscheidende Teil ist nicht *welche* Regel feuert, sondern **wo** sie
gematcht hat:

```bash
EP=$(kubectl get pods -n envoy-gateway-system \
     -l gateway.envoyproxy.io/owning-gateway-name=envoy-gateway-external \
     -o jsonpath='{.items[0].metadata.name}')

# Regel-ID + Fundort
kubectl logs -n envoy-gateway-system "$EP" -c envoy \
  | grep -i "coraza:" \
  | grep -oE '\[id "[0-9]+"\].*?\[data "[^"]*"\]' \
  | sed -E 's/\[id "([0-9]+)"\].*within ([A-Z_]+[^:]*).*/\1  \2/' \
  | sort | uniq -c | sort -rn

# Welche Pfade sind betroffen?
kubectl logs -n envoy-gateway-system "$EP" -c envoy \
  | grep -i "coraza:" | grep -oE '\[uri "[^"]*"\]' \
  | sed 's/?.*//' | sort | uniq -c | sort -rn

# Wer löst aus? Scanner oder echte Nutzer?
kubectl logs -n envoy-gateway-system "$EP" -c envoy \
  | grep -i "coraza:" | grep -oE '\[client "[^"]*"\]' | sort | uniq -c | sort -rn
```

Die `within`-Angabe entscheidet über die Gegenmaßnahme:

| Fundort | Bedeutung |
|---|---|
| `ARGS:feldname` | ein bestimmtes Formularfeld — feldgenauer Ausschluss möglich |
| `REQUEST_COOKIES_NAMES` | ein Cookie-*Name* — fast immer Fehlalarm |
| `REQUEST_BODY` | Nutzdaten — genau hinsehen, kann echt sein |
| `REQUEST_URI` | Pfad oder Query — kann echt sein |

Und immer prüfen, **wer** auslöst. Sind es nur Scanner-IPs, ist es kein
Fehlalarm, sondern die WAF bei der Arbeit.

---

## Schritt 4 — Ausschlüsse bauen

Drei Formen, nach Präzision sortiert:

```
# a) feldgenau — Regel bleibt sonst voll aktiv
SecRuleUpdateTargetById 942100 "!ARGS:beschreibung"

# b) nach Tag — ein Feld aus allen CRS-Regeln nehmen
SecRuleUpdateTargetByTag "OWASP_CRS" "!ARGS:password"

# c) Regel ganz entfernen — grob, wirkt aber immer
SecRuleRemoveById 932160
```

Alle drei müssen **nach** `Include @owasp_crs/*.conf` stehen, weil sie geladene
Regeln referenzieren.

### Die wichtigste Einschränkung

**(a) und (b) wirken in diesem Build nicht zuverlässig.**

`coraza-proxy-wasm` ist mit *multiphase evaluation* gebaut. Regeln werden in der
frühestmöglichen Phase ausgewertet, nicht in der deklarierten. Eine Phase-2-Regel,
die auf Cookies zielt, wird nach Phase 1 vorgezogen — und dorthin propagiert das
Target-Update offenbar nicht.

Konkret beobachtet:

* `SecRuleUpdateTargetByTag "OWASP_CRS" "!ARGS:password"` → **wirkt**
  (XSS-Regeln bleiben in Phase 2)
* `SecRuleUpdateTargetById 932160 "!REQUEST_COOKIES_NAMES"` → **wirkt nicht**.
  Stand in der Live-Config, Regel feuerte unverändert weiter auf genau diesem
  Target und blockte 12 Stunden lang jeden Client mit einem Legacy-`$Path`-Cookie.

Erkennungsmerkmal im Log: Blockmeldungen sagen `Access denied (phase 1)` und
nennen **949111** statt 949110 — das ist die Phase-1-Blocking-Evaluation.

Wenn ein Ausschluss nicht greift: `SecRuleRemoveById`. Vertretbar, wenn die
Auswertung zeigt, dass *alle* Treffer dieser Regel aus der Fehlalarmquelle kamen.
Bei 932160 waren es 393 von 393 aus `REQUEST_COOKIES_NAMES`, keiner aus ARGS oder
Body — und von den 12 Regeln der RCE-Familie blieben 11 aktiv.

---

## Schritt 5 — Ausschluss verifizieren, NOCH im Detect-Modus

Dieser Schritt ist der, den man weglässt, und genau der, der weh tut.

Nach dem Ausrollen des Ausschlusses noch einmal auswerten. **Die Regel-ID muss
aus dem Log verschwinden.** Tut sie das nicht, hat der Ausschluss nicht
gewirkt — und im Detect-Modus merkt man es folgenlos, im Enforcing-Modus merken
es die Nutzer.

```bash
kubectl logs -n envoy-gateway-system "$EP" -c envoy --since=2h \
  | grep -i "coraza:" | grep -oE '\[id "[0-9]+"\]' | sort | uniq -c
```

---

## Schritt 6 — Scharf schalten

```
- "SecRuleEngine DetectionOnly"   →   - "SecRuleEngine On"
```

Rollback ist dasselbe Wort zurück.

---

## Schritt 7 — Gegenprüfen, mit echten Requests

Nicht annehmen, messen. Vier Prüfungen, alle müssen stimmen:

```bash
B=https://wms.menofgaming.de

# 1) Der behobene Fehlalarm ist weg          → erwartet 200
curl -s -o /dev/null -w '%{http_code}\n' -H 'Cookie: $Path=/' "$B/"

# 2) Echte Angriffe werden weiterhin geblockt → erwartet 403
curl -s -o /dev/null -w '%{http_code}\n' "$B/?x=%3Cscript%3Ealert(1)%3C/script%3E"
curl -s -o /dev/null -w '%{http_code}\n' "$B/?id=1%27%20OR%201=1--"

# 3) Ausgenommene Felder kommen durch         → erwartet != 403
# 4) Legitimer Verkehr unverändert            → erwartet 200
curl -s -o /dev/null -w '%{http_code}\n' "$B/"
```

---

## Verweise

* Referenzimplementierung: `flux/clusters/tokamak/resources/coraza-waf.yaml`
  (Keycloak, enforcing, mit kommentierten Ausschlüssen)
* Worker-Threads und Speicherlimit: `flux/clusters/tokamak/resources/envoy-gateway.yaml`
* CrowdSec-Whitelists, damit WAF-Blockaden keine IP-Bans auslösen:
  `flux/apps/crowdsec/release.yaml`, Abschnitt `parsers.s02-enrich`
* Architekturüberblick: `docs/security-architecture-blog.md`
