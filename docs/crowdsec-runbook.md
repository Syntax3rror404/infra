# CrowdSec — Aufbau und Betriebshandbuch

Wie CrowdSec hier eingebunden ist, und die Befehle, die man im Ernstfall
braucht. Entstanden aus zwei echten Selbst-Aussperrungen — die Abschnitte
[Ausgesperrt](#ausgesperrt--was-zuerst) und
[Fehlalarm entschärfen](#einen-fehlalarm-entschärfen) sind die, die man dann
wirklich liest.

---

## Aufbau

```
Envoy (extern)  ──ext_authz/gRPC──▶  crowdsec-envoy-bouncer   "ist diese IP gesperrt?"
      │                                        ▲
      │ Zugriffslog                            │ Entscheidungen
      ▼                                        │
crowdsec-agent (DaemonSet)  ──▶  crowdsec-lapi (crowdsec-service:8080)
   parst /var/log/containers/envoy-*
   wertet Szenarien aus
```

| Komponente | Art | Aufgabe |
|---|---|---|
| `crowdsec-agent` | DaemonSet, 3× | liest die Envoy-Zugriffslogs des **eigenen Nodes**, wertet Szenarien aus |
| `crowdsec-lapi` | Deployment, 1× | speichert Entscheidungen, zieht die Community-Blockliste |
| `crowdsec-envoy-bouncer` | Deployment, 1× | gRPC-`ext_authz`-Dienst, den Envoy pro Request fragt |

**Wichtig:** Der Agent liest nur die Logs seines eigenen Nodes. Für den
externen Gateway ist also nur der Agent relevant, der auf demselben Node läuft
wie der Envoy-Pod. Bei fast allen Analysen muss man den passenden erwischen —
siehe [Den richtigen Agent finden](#den-richtigen-agent-finden).

Konfiguration: `flux/apps/crowdsec/release.yaml` (Agent, LAPI, Szenarien,
Whitelists), `flux/apps/crowdsec/bouncer.yaml` (Bouncer),
`flux/clusters/tokamak/resources/crowdsec-securitypolicy.yaml` (Anbindung ans
Gateway).

Die `SecurityPolicy` hängt am **Gateway**, nicht an einer Route — jeder Request
über den externen Gateway wird also geprüft. Sie steht auf `failOpen: true`:
fällt der Bouncer aus, passiert Verkehr, statt dass alles dunkel wird.

---

## Ausgesperrt — was zuerst

Symptom: Webdienste liefern eine „Access Blocked"-Seite mit IP und Grund. Und
`kubectl` funktioniert nicht mehr:

```
error: get-token: authentication error: oidc error: oidc discovery error: 403 Forbidden
```

**Warum kubectl mitstirbt:** Der Context `oidc` holt seinen Token bei Keycloak,
und Keycloak hängt hinter demselben CrowdSec-geschützten Gateway. Ein IP-Ban
trifft damit gleichzeitig Web-Login und Clusterzugang.

**Break-glass:** Es gibt einen zweiten Context, der am Talos-Zertifikat hängt
und Keycloak nicht braucht:

```bash
kubectl --context admin@ich-talos get pods -A
```

Den bei allen folgenden Befehlen mitgeben, solange die Sperre steht. Er hat
keine Ablaufabhängigkeit von Keycloak — aber das Talos-Client-Zertifikat selbst
läuft ab, also gelegentlich `talosctl config info` prüfen.

---

## Sperren ansehen und aufheben

```bash
K="kubectl --context admin@ich-talos"

# Alle aktiven Sperren
$K exec -n crowdsec deploy/crowdsec-lapi -- cscli decisions list

# Historie zu einer IP — zeigt auch abgelaufene
$K exec -n crowdsec deploy/crowdsec-lapi -- cscli alerts list --ip 203.0.113.5

# Warum genau? Zeigt die auslösenden Requests, User-Agent, Pfade, Statuscodes
$K exec -n crowdsec deploy/crowdsec-lapi -- cscli alerts inspect <ALERT-ID> -d

# Sperre aufheben
$K exec -n crowdsec deploy/crowdsec-lapi -- cscli decisions delete --ip 203.0.113.5
```

`alerts inspect -d` ist der wichtigste davon. Der Kontextblock nennt Methode,
Statuscode, die betroffenen URIs und den User-Agent — daraus erkennt man in
Sekunden, ob ein Angreifer oder der eigene Sync-Client ausgelöst hat.

Mehrere Decisions können sich stapeln; `decisions delete --ip` räumt alle
gleichzeitig ab (bei uns einmal fünf auf einen Schlag).

---

## Die Rückkopplungsfalle

Der Grund, warum eine Sperre sich selbst am Leben halten kann:

CrowdSec liest die Envoy-Zugriffslogs. Darin steht **auch jede Blockade, die es
selbst erzeugt hat**. Für die Scan-Erkennung sieht ein 403 aus wie ein 403.

Ist eine IP gesperrt, beantwortet der Bouncer jede weitere Anfrage mit 403. Ein
Client, der einfach weiterversucht — Sync-Programm, Monitoring, offener
Browser-Tab —, produziert im Sekundentakt neue Fehlerantworten. Der Agent liest
sie, wertet sie als Scan, erneuert die Sperre. Beobachtet: **11 Events in einer
einzigen Sekunde**, alle 403 auf harmlose Pfade wie `/status.php`.

Dagegen laufen die Whitelists in `flux/apps/crowdsec/release.yaml` unter
`config.parsers.s02-enrich`:

| Whitelist | Nimmt aus |
|---|---|
| `custom/nextcloud-dav-whitelist` | ext_authz-Blockseiten (403) und fehlgeschlagene WebDAV-Uploads (PUT/MKCOL/MOVE 404) |
| `custom/coraza-block-whitelist` | Blockaden der WAF selbst |
| `custom/kube-apiserver-whitelist` | erfolgreicher, JWT-authentifizierter API-Verkehr |

Die Unterscheidung läuft über Envoy-Metadaten, nicht über den Statuscode:

```
ext_authz-Block :  "response_code_details":"ext_authz_denied"   response_flags "UAEX"
Coraza-Block    :  "response_code_details":""                   "upstream_host":null
echter 403      :  "response_code_details":"via_upstream"       upstream gesetzt
Routing-404     :  "response_code_details":"route_not_found"
```

**`route_not_found` darf NICHT ausgenommen werden.** Darüber erkennt CrowdSec
Scanner, die nach PHP-Dateien suchen — ein pauschaler Filter auf „alle Local
Replies" würde genau die Erkennung abschalten, die funktioniert. Nachgewiesen:
eine `route_not_found`-Zeile löst `http-probing`, `http-wordpress-scan`,
`http-crawl-non_statics` und `http-dos-swithcing-ua` aus.

---

## Den richtigen Agent finden

Fast alle Analysen brauchen den Agent auf dem Node, auf dem der externe Envoy
läuft:

```bash
K="kubectl --context admin@ich-talos"
EN=$($K get pods -n envoy-gateway-system \
     -l gateway.envoyproxy.io/owning-gateway-name=envoy-gateway-external \
     -o jsonpath='{.items[0].spec.nodeName}')
AG=$($K get pods -n crowdsec -l type=agent -o json | python3 -c "
import json,sys
for p in json.load(sys.stdin)['items']:
    if p['spec']['nodeName']=='$EN': print(p['metadata']['name'])")
echo "Envoy auf $EN, Agent $AG"
```

---

## Einen Fehlalarm entschärfen

Der zentrale Befehl ist `cscli explain`. Er schickt eine echte Logzeile durch
die komplette Parser- und Szenario-Kette und zeigt, was passiert wäre — ohne
etwas zu verändern.

### Zwei Stolperfallen

**Die Logzeile muss aus `/var/log/containers/` kommen, nicht aus
`kubectl logs`.** Letzteres entfernt das CRI-Präfix (`…Z stdout F `), und ohne
das schlägt der Parser fehl (`parser failure`, alle s00-raw-Parser rot).

**`--labels program:envoy` ist Pflicht.** Der Envoy-Parser filtert darauf; ohne
das Label greift er nicht.

### Ablauf

```bash
# 1. Echte Zeile holen (Beispiel: ein 403 einer bestimmten IP)
$K exec -n crowdsec $AG -c crowdsec-agent -- sh -c '
  F=$(ls /var/log/containers/envoy-*envoy-gateway-system*.log | head -1)
  grep "203.0.113.5" "$F" | grep "\"response_code\":403" | tail -1' > /tmp/probe.log

# 2. In den Agent kopieren
$K cp /tmp/probe.log crowdsec/$AG:/tmp/probe.log -c crowdsec-agent

# 3. VORHER: was löst diese Zeile aus?
$K exec -n crowdsec $AG -c crowdsec-agent -- \
  cscli explain --file /tmp/probe.log --type containerd --labels program:envoy
```

Ausgabe lesen: Unter `Scenarios` stehen die Szenarien, die feuern würden.
Steht dort `parser success, ignored by whitelist (…)`, greift bereits eine
Whitelist.

```bash
# 4. Whitelist-Entwurf testweise in den Agent legen
cat > /tmp/wl.yaml <<'EOF'
name: custom/test-whitelist
description: "Entwurf"
filter: "evt.Meta.service == 'http' && evt.Meta.target_fqdn == 'beispiel.menofgaming.de'"
whitelist:
  reason: "Begründung"
  expression:
    - evt.Meta.http_status == '403' && evt.Line.Raw contains 'ext_authz_denied'
EOF
$K cp /tmp/wl.yaml crowdsec/$AG:/etc/crowdsec/parsers/s02-enrich/custom-test.yaml -c crowdsec-agent

# 5. NACHHER: greift sie?
$K exec -n crowdsec $AG -c crowdsec-agent -- \
  cscli explain --file /tmp/probe.log --type containerd --labels program:envoy

# 6. NEGATIVKONTROLLE — das ist der Schritt, den man nicht auslassen darf.
#    Ein echter Angriff MUSS weiterhin auslösen. Testzeile mit z.B.
#    /wp-login.php bauen und erneut explain laufen lassen.

# 7. Aufräumen, dann erst ins Repo übernehmen
$K exec -n crowdsec $AG -c crowdsec-agent -- \
  rm -f /etc/crowdsec/parsers/s02-enrich/custom-test.yaml /tmp/probe.log
```

Der Testpatch im Pod ist flüchtig und überlebt keinen Neustart. Der laufende
Agent zieht ihn auch nicht automatisch — `cscli explain` startet einen eigenen
Prozess und liest die Datei frisch. Für den Dauerbetrieb muss die Whitelist ins
Repo.

**Anmerkung zur Ausdruckssyntax:** In `evt.Meta.*` liegen nur die Felder, die
der Envoy-Parser mappt (Pfad, Verb, Status, User-Agent, FQDN).
`response_code_details` und `response_flags` gehören **nicht** dazu — dafür auf
`evt.Line.Raw contains '…'` ausweichen.

---

## Zustand prüfen

```bash
# Läuft der Agent, parst er?
$K exec -n crowdsec $AG -c crowdsec-agent -- cscli metrics | grep -A5 -i acquisition

# Welche Szenarien / Parser sind geladen?
$K exec -n crowdsec $AG -c crowdsec-agent -- cscli scenarios list
$K exec -n crowdsec $AG -c crowdsec-agent -- cscli parsers list

# Simulationsmodus (Szenarien, die erkennen aber nicht handeln)
$K exec -n crowdsec $AG -c crowdsec-agent -- cscli simulation status

# Ist der Bouncer registriert und aktiv?
$K exec -n crowdsec deploy/crowdsec-lapi -- cscli bouncers list

# Wie oft hat ext_authz geblockt? (Envoy-Sicht)
EP=$($K get pods -n envoy-gateway-system \
     -l gateway.envoyproxy.io/owning-gateway-name=envoy-gateway-external \
     -o jsonpath='{.items[0].metadata.name}')
$K port-forward -n envoy-gateway-system pod/$EP 19000:19000 &
curl -s localhost:19000/stats | grep ext_authz | grep -v ' 0$'
```

Die Acquisition-Metriken sind der schnellste Gesundheitscheck: „Lines read"
muss steigen, „Lines parsed" nahe dran liegen. Ein hoher Anteil „Lines
whitelisted" ist normal und gewollt.

---

## Bekannte Betriebsfallen

**Der Init-Container hängt am GitHub-Rate-Limit.** `download-ai-user-agents`
zieht bei *jedem* Pod-Start eine Liste von `raw.githubusercontent.com`. Bei
einem Rollout sind das drei Anfragen kurz hintereinander; GitHub antwortet dann
mit 429. Früher brach der Container hart ab und blockierte mit
`maxUnavailable: 1` den **gesamten** DaemonSet-Rollout — der aktualisierte Node
wurde nie ready, also wurden die anderen nie aktualisiert. Heute wird
wiederholt und notfalls eine Platzhalterliste geschrieben.

Wichtig dabei: die Platzhalterdatei darf **nicht leer** sein. CrowdSec
registriert eine Datei mit null Einträgen nicht in der expr-Library, und das
Szenario läuft dann bei jeder Auswertung in
`file 'ai_user_agents.txt' not found in expr library`. Eine Zeile mit `-`
genügt — der Filter des Szenarios (`len(#) > 4`) macht sie unmatchbar.

**Helm-Timeout beim Rollout.** Der DaemonSet rollt sequenziell über drei Nodes,
jeder Pod braucht durch die Retry-Schleife länger. Gemessen ~6 Minuten gegen
Helms Default von 5. Deshalb steht `timeout: 15m` in der HelmRelease. Ohne das
meldet Flux „timeout waiting for DaemonSet … InProgress" und markiert den
Release als fehlgeschlagen, obwohl er kurz darauf fertig wird — was
Folge-Reconciles blockiert.

**Verwaiste Bouncer-Registrierungen.** Jeder Pod-Neustart des Bouncers
registriert sich unter seiner neuen Pod-IP (`envoybouncer@10.244.x.y`) und die
alte Registrierung bleibt bestehen — samt gültigem API-Schlüssel für einen Pod,
den es nicht mehr gibt. Nach ein paar Wochen stehen dort zwei Dutzend Leichen
(Stand 2026-08-19: 21 Einträge, 20 davon tot, ältester vom 02.07.).

Kein akutes Risiko, solange die Schlüssel nicht abfließen — aber unnötige
Angriffsfläche und macht die Liste unbrauchbar. Aufräumen:

```bash
# Aktiven Bouncer ermitteln (der mit dem jüngsten Abruf)
$K exec -n crowdsec deploy/crowdsec-lapi -- cscli bouncers list

# Alte einzeln entfernen — den aktiven auslassen!
$K exec -n crowdsec deploy/crowdsec-lapi -- cscli bouncers delete 'envoybouncer@10.244.3.35'
```

Vorsicht: `envoybouncer` ohne Suffix ist die per `BOUNCER_KEY_envoybouncer`
vorregistrierte Identität aus der HelmRelease. Die nicht löschen, sie wird beim
LAPI-Start neu angelegt.

**Whitelists brauchen einen Rollout.** Änderungen an
`config.parsers.s02-enrich` erzeugen ein neues ConfigMap und lösen einen
DaemonSet-Rollout aus. Danach prüfen, ob sie überall angekommen sind:

```bash
for p in $($K get pods -n crowdsec -l type=agent -o jsonpath='{.items[*].metadata.name}'); do
  echo -n "$($K get pod -n crowdsec $p -o jsonpath='{.spec.nodeName}'): "
  $K exec -n crowdsec $p -c crowdsec-agent -- ls /etc/crowdsec/parsers/s02-enrich/
done
```

---

## Verweise

* Konfiguration: `flux/apps/crowdsec/release.yaml`, `flux/apps/crowdsec/bouncer.yaml`
* Gateway-Anbindung: `flux/clusters/tokamak/resources/crowdsec-securitypolicy.yaml`
* WAF daneben: `docs/waf-neue-app-hinzufuegen.md`
* Architekturüberblick: `docs/security-architecture-blog.md`
