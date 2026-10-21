---
name: mcp-k8s-hazards
description: Load before editing p5-mcp-k8s behavior-relevant code — why each hazard exists: RBAC-only, lazy discovery, plural lookup, silent tier 3, 409 regex, env-only config.
user-invocable: false
model: inherit
---

# mcp-k8s-hazards

Die zehn Verbote aus `.claude/rules/mcp-k8s-rules.md` — hier steht der Grund
dahinter. Das Rules-File trägt das Verbot, diese Skill trägt den Mechanismus und
das, was beim Verstoß bricht. Beides lesen: das Verbot ohne den Grund wird
optimiert weg, der Grund ohne das Verbot gilt nicht.

Die Architektur selbst steht in `mcp-k8s-core` — diese Skill ersetzt sie nicht.

## 1. RBAC ist die einzige Autorisierungsschicht

Der Server filtert **nicht** applikationsseitig. Was RBAC erlaubt, darf das LLM.
Das ist Absicht: eine zweite Filterschicht im Server wäre eine Lücke, die man
pflegen muss, während RBAC die Wahrheit am Cluster bleibt.

- **Keine application-side Filterung einbauen.** Wer Geheimnisse vom LLM fernhalten
  will, schränkt das Role ein — das ist ein Rollout, kein Patch.
- **Ein Wunsch wie „hide secrets from the LLM in the server" ist ein Ticket**, kein
  Refactoring. Er verändert die Sicherheitsarchitektur und gehört vor den
  Maintainer.

## 2. `can_do` nimmt den Plural, nicht den Kind

RBAC spricht Plural (`pods`), die API spricht Kind (`Pod`). `can_do('list', 'Pod')`
liefert still `0` — das sieht exakt wie eine fehlende Berechtigung aus und lässt
den Aufrufer „Permission denied" vermuten, wo der Server nur falsch pluralisiert
hat. **Immer erst `_resource_plural`**, dann `can_do`.

Ein Fehler, der wie ein Permission-Problem aussieht, ist fast immer Pluralisierung.

## 3. Discovery ist lazy — und das ist eine Zusage

`MCP::K8s->new` ist ohne Cluster konstruierbar; darauf baut die halbe Testsuite.
`BUILD` registriert nur Tools, der erste RBAC-Call passiert in `ensure_discovered`,
ausgelöst durch einen Tool-Call oder `run_stdio`.

- **Nichts in `BUILD` schieben, das `->api` anfasst.** Das bricht die Testsuite
  (kein Cluster in der CI) und jede Einbettung, die den Server nur baut.
- **Der Test braucht keinen Cluster und darf keinen brauchen** — die Mocks in
  `t/` sind die Oberfläche, an der sich Code messen lässt.

## 4. Vier Wildcard-Zweige in `can_do`, alle live

Expliziter Verb · Wildcard-Verb (`*` auf der Ressource) · Wildcard-Ressource mit
Verb · `*`/`*`.

Wer einen Zweig wegoptimiert, bekommt cluster-admin kaputt, ohne dass ein
narrow-Role-Test rot wird — die Tests decken den engen Fall ab, nicht den
weiten. Die Zweige sind billig; die Fehlstellung ist teuer.

## 5. Tool-Beschreibungen sind Funktionalität

Die Beschreibungen sagen dem LLM „Available: default: pods, deployments;
production: pods", damit es nicht raten muss. Sie werden genau einmal
umgeschrieben, in `_update_tool_descriptions` (Guard `_descriptions_updated`),
über `_tool_desc_map`.

- **Ein neu registriertes Tool ohne Eintrag in `_tool_desc_map` behält für immer
  seine statische Beschreibung** — das Tool existiert, ist aber für das LLM
  unsichtbar.
- **Beschreibungen nicht "aufräumen"**: bei >10 Ressourcen wird auf 10 + `...`
  gekürzt, bei `*` steht „all resources".

## 6. Plural-Tier 3 schluckt jeden Fehler — by design

Schlägt die API-Discovery fehl, bleibt der Cache leer und Tier 4 (Heuristik)
greift. Ein Cluster ohne Discovery-Rechte soll den Server nicht umbringen.

- **Den Fallstumm halten.** Eine falsche Pluralisierung sieht aus wie ein
  Permission-Denied; genau deshalb darf hier nichts Lautes passieren.
- **Keine neuen stillen Fallbacks danebenstellen.** Jeder weitere stille Zweig
  macht die Fehlersuche schlechter, nicht besser.

## 7. `_resolve_namespace` liefert `undef` bei mehreren Namespaces

Der Namespace wird nur gefüllt, wenn **genau einer** erreichbar ist. Sonst
`undef` — das Tool muss den Fall selbst behandeln (nachfragen oder ablehnen).

- **Nicht auf „nimm den ersten" ändern.** Bei mehreren erreichbaren Namespaces
  wäre das eine stille Fehlbedienung mit echten Folgen: der Agent schreibt in
  den falschen Namespace.

## 8. `k8s_apply` erkennt den Create-Konflikt per Regex

`_is_conflict_error` prüft `/409|AlreadyExists/i` gegen den Fehlerstring.

- **Warum Regex und nicht strukturiert:** `Kubernetes::REST` croakt einen
  einfachen String; nur deren veraltete v0-Module tragen typisierte Fehler. Es
  gibt nichts Strukturiertes zu prüfen. Eine Verengung auf das aktuelle
  Croak-Format wäre schlimmer — ein Upstream-Reformulieren wird dann zum
  falschen Negativ.
- **Revisitieren, wenn der Client typisierte Fehler bekommt** — nicht vorher.
- **Wenn du den Pfad anfasst: Regressionstest liegen lassen.**

## 9. Nur Env-Vars, keine Kommandozeilen-Flags

Die Konfiguration ist vollständig env-basiert, damit sie in MCP-Client-JSON
(`.mcp.json`, Claude Desktop) ausdrückbar ist.

- **Ein Flag hinzuzufügen bricht diese Zusage.** Wer eine Option braucht, muss
  sie in die Env-Matrix (`MCP_K8S_*`, `KUBECONFIG`, `MCP_K8S_CONTEXT`) oder in
  die Konfiguration des Clients.

## 10. `sub server { $_[0] }` ist dokumentierte API

`$k8s->server` an `Net::Async::MCP` übergeben ist der dokumentierte Raider-Pfad
im README. Das ist Rückwärtskompatibilität, **kein** toter Code.

- **Verifiziert gegen MCP 0.15 + Net::Async::MCP 0.004**; 0.003 scheitert mit
  `-32602 Missing protocol version`. Vor der nächsten Meldung „toter Code" also
  die installierte `Net::Async::MCP`-Version prüfen.

## Cluster-Zugriff — der Grund hinter der Sektion im Rules-File

Die Testsuite braucht keinen Cluster. Alles andere ist ein **echter Cluster des
Maintainers**: `kubectl` oder ein Live-API-Call in diesem Repo trifft Produktion.

- **Lesende Inspection zum Reproduzieren ist in Ordnung**, wenn der Maintainer
  auf einen Kontext gezeigt hat.
- **Alles Mutierende — create, patch, delete, rollout restart — braucht für jeden
  einzelnen Schritt eine ausdrückliche Freigabe.**
- **„Nur ein ConfigMap" ist keine Ausnahmekategorie.** Ein ConfigMap kann
  Pods auslösen, die ein Deployment ersetzen; die Kategorie entscheidet nichts,
  die Wirkung schon.
