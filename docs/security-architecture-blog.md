# Drei Schichten am Rand: Routing, Reputation, Inhalt

Wer einen Cluster ins Internet stellt, stapelt schnell mehrere Schutzmechanismen übereinander — eine WAF, ein IPS, dazu das Ingress-Routing. Die interessante Frage ist selten, welches Produkt man nimmt, sondern welche Frage jede Schicht überhaupt beantwortet. Denn sie beantworten drei völlig verschiedene, und sie sehen jeweils nur das, was die Schicht davor durchgelassen hat.

## Schicht 1 — Routing: Gibt es diesen Pfad überhaupt?

Die Gateway API beschreibt in einer `HTTPRoute`, welche Pfade eine Anwendung veröffentlicht. Was nicht matcht, wird gar nicht erst weitergereicht — der Proxy antwortet mit `404 route_not_found`, und sämtliche Filter der Route laufen dabei nie an.

Das wird gern unterschätzt. Ein typischer Schwachstellen-Scanner klopft Hunderte PHP-Pfade ab, `/admin.php`, `/wp-content/…`, `/aa.php`. Trifft keiner davon ein deklariertes Präfix, ist der Fall auf der billigsten denkbaren Ebene erledigt: eine Präfix-Prüfung, kein Backend-Kontakt, keine Inspektion.

Wichtig ist dabei die Match-Semantik. Gateway API vergleicht `PathPrefix` **elementweise**, nicht als Zeichenkette:

> Die Pfade `/abc`, `/abc/` und `/abc/def` matchen alle das Präfix `/abc` — `/abcd` jedoch nicht.

Damit lässt sich ein Präfix gezielt verengen, ohne dass ein geschickt gewählter Name es wieder aufweitet. Wer etwa bei einem Identity Provider nur ein bestimmtes Realm veröffentlichen will, schreibt `/realms/produktiv` statt `/realms` — und der Admin-Realm ist damit schlicht nicht mehr routbar. Kein Regelwerk, keine Ausnahme, keine Laufzeitkosten.

## Schicht 2 — Reputation: Darf diese Quelle?

Ein IPS wie CrowdSec arbeitet nicht am einzelnen Request, sondern am Verhalten über Zeit. Ein Agent liest die Zugriffslogs des Proxys, wertet sie gegen Szenarien aus — Port- und Pfad-Scans, Credential Stuffing, Bot-Muster — und schreibt daraus Entscheidungen in eine lokale API. Der Proxy fragt diese Entscheidungen pro Request über einen `ext_authz`-Filter ab.

Das ist bewusst asymmetrisch: Die Analyse läuft nachgelagert und darf teuer sein, die Abfrage im Request-Pfad ist ein Cache-Lookup im Millisekundenbereich. Zusätzlich lässt sich eine Community-Blockliste einspielen, sodass IPs blockiert werden, die anderswo bereits auffällig wurden.

Entscheidend ist das Ausfallverhalten. Dieser Filter sitzt vor **jedem** Dienst. Steht er auf `failOpen`, passiert Verkehr, wenn die Komponente ausfällt; steht er auf `failClose`, ist bei einem Ausfall alles dunkel — inklusive der Anmeldung, über die man den Cluster administriert. Für eine Reputationsprüfung ist `failOpen` fast immer die richtige Wahl.

## Schicht 3 — Inhalt: Was steht in diesem Request?

Erst hier kommt die eigentliche WAF ins Spiel. Coraza ist eine ModSecurity-kompatible Engine, die sich als WASM-Filter direkt in den Proxy-Prozess laden lässt. Kein zusätzlicher Pod, kein Netzwerk-Hop — der Filter läuft im selben Prozess wie das Routing.

Der zweite Vorteil ist die Granularität: Eine `EnvoyExtensionPolicy` hängt an einer einzelnen `HTTPRoute`. Man kann also eine Anwendung mit voller Inhaltsprüfung betreiben und eine andere nicht — was praktisch wichtig ist, denn Body-Inspektion und ein Datei-Sync-Dienst mit mehreren Gigabyte pro Upload vertragen sich nicht.

Inhaltlich lassen sich zwei gegensätzliche Modelle fahren:

**Negativ (Blocklist).** Das OWASP Core Rule Set beschreibt bekannte Angriffsmuster — SQL-Injection, XSS, Path Traversal — und vergibt Punkte. Überschreitet ein Request die Schwelle, wird er verworfen. Der Vorteil: es funktioniert ohne Wissen über die Anwendung. Der Preis: generische Muster erzeugen Fehlalarme, und die muss man pro Anwendung ausschließen. Genau dafür existieren die CRS-Exclusion-Pakete für verbreitete Software.

**Positiv (Allowlist).** Die Umkehrung: Man beschreibt, was die Anwendung veröffentlicht, und markiert alles andere. Das ist aufwendiger, aber präziser — und es findet Dinge, die eine Blocklist prinzipiell nie sehen kann, weil sie kein Angriffsmuster sind, sondern ein unbeabsichtigt exponierter Endpunkt.

Beides schließt sich nicht aus. In der Praxis ist ein sinnvoller Einstieg: CRS außerhalb des blockierenden Pfads mitlaufen lassen, gezielte Signaturen für bekannte CVEs scharf schalten, und die Allowlist dort ansetzen, wo die URL-Oberfläche klein und stabil ist.

## Warum die Reihenfolge zählt

Die Schichten sind nach Kosten sortiert, und das ist kein Zufall:

| Schicht | Kosten | Erledigt |
|---|---|---|
| Routing | Präfix-Vergleich | den Großteil des Scanner-Rauschens |
| Reputation | ein Lookup | bekannte Angreifer, bevor Inhalt geprüft wird |
| Inhaltsprüfung | Regex über den ganzen Request | den Rest |

Die teuerste Prüfung sieht damit nur, was die beiden günstigeren durchgelassen haben. Wer die WAF an den Anfang stellt, lässt sie an Verkehr arbeiten, den ein Präfix-Vergleich schon hätte abweisen können.

## Die Falle: Der Kreislauf füttert sich selbst

Hier lohnt ein genauer Blick, denn dieser Fehler ist leicht zu bauen und schwer zu sehen.

Das IPS liest die Zugriffslogs des Proxys. In diesen Logs steht **auch jede Blockade, die es selbst ausgelöst hat** — und jede, die die WAF ausgelöst hat. Für die Scan-Erkennung sieht ein 403 aber aus wie ein 403: eine Anfrage, die nicht durchkam.

Damit entsteht eine Rückkopplung. Ist eine IP einmal gesperrt, beantwortet der Proxy jede weitere Anfrage mit einer Blockseite. Ein Client, der schlicht weiter versucht — ein Sync-Programm, ein Monitoring, ein Browser-Tab —, produziert im Sekundentakt weitere Fehlerantworten. Der Agent liest sie, wertet sie als Scan, und erneuert die Sperre. Die Sperre hält sich selbst am Leben, unabhängig davon, ob der ursprüngliche Anlass noch besteht.

Der Ausweg ist, selbst erzeugte Blockaden von der Auswertung auszunehmen. Und zwar präzise: nicht über den Statuscode, sondern über Metadaten des Proxys, die verraten, wer die Antwort erzeugt hat. Ein `403` vom Backend und ein `403` vom Filter davor sind im Log unterscheidbar — über Felder wie die Antwortdetails und die Frage, ob überhaupt ein Upstream kontaktiert wurde. Blockaden bleiben also voll wirksam, sie verstärken sich nur nicht mehr selbst.

## Was das am Ende bringt

Ein nüchterner Befund zum Schluss: In der ersten Beobachtungsphase produzierte das generische Regelwerk ausschließlich Fehlalarme — eine einzelne Regel, die einen veralteten Cookie-Namen für Shell-Code hielt. Die Angreifer, die dabei auffielen, hatte das IPS längst unabhängig erkannt.

Substanzielles fand stattdessen die Allowlist: einen Verwaltungs-Endpunkt, der öffentlich erreichbar war, obwohl die zugehörige Oberfläche längst intern lag. Kein Angriffsmuster — nur ein Pfad, der da nicht hingehörte. Der sauberste Fix lag dann nicht in der WAF, sondern eine Schicht darüber, im Routing.

Das ist vielleicht die brauchbarste Lehre: Eine WAF ist kein Ersatz für eine enge Oberfläche. Sie ist die Rückfallebene für das, was durch eine enge Oberfläche legitim hindurch muss.
