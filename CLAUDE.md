# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

MCP::K8s ist ein stdio MCP-Server, der einem LLM Zugriff auf einen Kubernetes-Cluster
gibt. Der Kern der Idee: **RBAC ist die einzige Autorisierungsschicht.** Der Server
fragt beim Start des ersten Tool-Calls per `SelfSubjectRulesReview`, was der verbundene
ServiceAccount darf, und formt daraus die Tool-Beschreibungen. Ein Read-only-Account
bekommt Read-only-Tools, ein cluster-admin bekommt alles. Es gibt **keine**
applikationsseitige Permission-Filterung — was RBAC erlaubt, darf das LLM.

Auf CPAN unter zwei Namen: `MCP::K8s` (kanonisch) und `MCP::Kubernetes` (leere
Subklasse, nur für Auffindbarkeit).

## Projektstruktur

```
p5-mcp-k8s/
├── bin/mcp-k8s                   # Entry point: MCP::K8s->run_stdio
├── lib/MCP/
│   ├── K8s.pm                    # Server (extends MCP::Server), Tools, Auth, Plurals, Formatting
│   ├── K8s/Permissions.pm        # RBAC-Discovery + can_do/allowed_*/summary
│   └── Kubernetes.pm             # Leere Subklasse, nur CPAN-Auffindbarkeit
├── examples/                     # 3 RBAC-Manifeste + Langertha::Raider-Demo
├── t/                            # Tests, alle gegen Inline-Mocks
└── dist.ini                      # [@Author::GETTY]
```

## Key Commands

```bash
prove -l t/                 # Tests
prove -l t/01-permissions.t # Einzeltest
dzil build                  # Distribution bauen
dzil test                   # Test mit dzil
```

Stirbt **jedes** Testfile mit Exit 2 und „No plan found in TAP output", fehlt eine
Dependency, nicht Code: `perl -Ilib -MMCP::K8s -e1` zeigt welche, `cpanm --installdeps .`
holt sie nach.

## Architektur

**MCP::K8s** (lib/MCP/K8s.pm) **erbt** von `MCP::Server` (seit 0.002), komponiert ihn
nicht mehr. `sub server { $_[0] }` ist Rückwärtskompatibilität für den dokumentierten
`Net::Async::MCP->new(server => $k8s->server)`-Pfad im README — nicht entfernen.

**Discovery ist lazy, und das ist eine Zusage.** `BUILD` registriert nur Tools; der
erste RBAC-Call passiert in `ensure_discovered`, ausgelöst durch einen Tool-Call oder
`run_stdio`. Damit ist `MCP::K8s->new` ohne Cluster konstruierbar — worauf die
Testsuite und jede Einbettung bauen. Nichts in `BUILD` schieben, das `->api` anfasst.

**Jeder Tool-Call prüft vorher `can_do`.** Kein Tool ruft die API ohne vorangehende
Permission-Prüfung, auch nicht wenn die API ohnehin 403 gäbe. Die Prüfung ist das, was
dem LLM eine lesbare Absage statt eines Stacktraces gibt.

**Tool-Beschreibungen sind Funktionalität, nicht Kosmetik.** `_update_tool_descriptions`
schreibt sie genau einmal um (Guard `_descriptions_updated`), entlang `_tool_desc_map`
(`[$tool, $base_desc, $verb]` je Tool). Ergebnis: „List Kubernetes resources. Available:
default: pods, deployments; production: pods". Bei >10 Ressourcen wird auf 10 + `...`
gekürzt, bei Wildcard steht „all resources". Ein neu registriertes Tool ohne Eintrag in
der Map behält für immer seine statische Beschreibung.

### Die 10 Tools

`k8s_permissions` (immer erlaubt), `k8s_list`, `k8s_get`, `k8s_create`, `k8s_patch`,
`k8s_delete`, `k8s_logs`, `k8s_events`, `k8s_rollout_restart`, `k8s_apply` — alle in
`_register_tools`. Zwei sind zusammengesetzt:

- **`k8s_rollout_restart`** patcht die Pod-Template-Annotation
  `kubectl.kubernetes.io/restartedAt` mit Timestamp — derselbe Mechanismus wie
  `kubectl rollout restart`. Braucht `patch`, nicht `update`.
- **`k8s_apply`** versucht `create` und fällt bei 409/AlreadyExists auf einen
  Strategic-Merge-Patch zurück. Die Conflict-Erkennung ist ein Regex gegen den
  Fehlerstring (`/409|AlreadyExists/i`) — fragil per Konstruktion.

**Warum 10 generische Tools statt hunderter spezifischer:** Kubernetes hat 50+
Built-in-Typen plus beliebige CRDs. Generische Tools mit `resource`-Parameter spiegeln
`kubectl get <resource>` und halten die Tool-Liste für MCP-Clients handhabbar. Ein
`list_pods`-Tool hinzuzufügen ist eine Richtungsänderung, kein Feature.

### Resource Plurals — 4-Tier

RBAC spricht Plural (`pods`), die API spricht Kind (`Pod`). `_resource_plural`
übersetzt: (1) statische `%RESOURCE_PLURALS`-Map, (2) `IO::K8s`-Klasse via
`expand_class`+`resource_plural()`, (3) API-Discovery über `/api/v1` und `/apis`,
einmalig gecacht, Subresources (`name` enthält `/`) übersprungen, (4) Heuristik
(lowercase, `s`, `ys`→`ies`).

CRD-Support (Cilium etc.) hängt komplett an Tier 2+3. Tier 3 schluckt alle Fehler
still — Absicht, damit ein Cluster ohne Discovery-Rechte den Server nicht umbringt.
Der Preis: **eine falsche Pluralisierung sieht aus wie ein Permission-Denied.** Bei
unerwartetem „Permission denied" immer zuerst den Plural prüfen.

### Auth — 3-Tier

| Tier | Auslöser | Endpoint |
|---|---|---|
| 1 | `MCP_K8S_TOKEN` gesetzt | `MCP_K8S_SERVER`, sonst in-cluster default |
| 2 | `/var/run/secrets/kubernetes.io/serviceaccount/token` existiert | dito |
| 3 | Fallback | `Kubernetes::REST::Kubeconfig` mit `MCP_K8S_CONTEXT` |

Tier 1 und 2 hängen `ssl_ca_file` an, wenn die in-cluster CA-Datei existiert — auch bei
explizitem Token. Die Pfade sind file-scoped `my`-Variablen in `MCP/K8s.pm`.

### Namespaces

`_build_namespaces`: `MCP_K8S_NAMESPACES` → in-cluster-Namespace-Datei → Auto-Discovery
über `list('Namespace')` → `['default']`. Jede API-Nutzung darin ist in `eval`; es gibt
keinen Pfad, auf dem das stirbt.

`_resolve_namespace` füllt **nur** auf, wenn genau ein Namespace erreichbar ist, sonst
`undef`; das Tool behandelt den Fall selbst.

### Permissions (lib/MCP/K8s/Permissions.pm)

`discover` schickt je einen `SelfSubjectRulesReview` pro Namespace **plus einen mit
leerem Namespace für cluster-scoped Ressourcen** — der `''`-Key in der Map ist der
Cluster-Scope. Fehler pro Namespace werden gewarnt und übersprungen, nicht propagiert.

`can_do($verb, $plural, $ns)` trifft über vier Zweige: explizites Verb, Wildcard-Verb
auf der Ressource, Wildcard-Ressource mit Verb, Wildcard/Wildcard. Alle vier sind live —
wer einen wegoptimiert, bricht cluster-admin, ohne einen Narrow-Role-Test zu brechen.

## Env-Vars

| Variable | Default | Wirkung |
|---|---|---|
| `KUBECONFIG` | `~/.kube/config` | Kubeconfig-Pfad (Tier 3) |
| `MCP_K8S_CONTEXT` | current-context | Kubeconfig-Context |
| `MCP_K8S_TOKEN` | — | Bearer Token, aktiviert Auth-Tier 1 |
| `MCP_K8S_SERVER` | in-cluster default | API-Server-URL |
| `MCP_K8S_NAMESPACES` | Auto-Discovery | Komma-getrennte Namespace-Liste |

Es gibt **keine** Kommandozeilen-Flags. Die Konfiguration ist vollständig env-basiert,
damit sie in MCP-Client-JSON (`.mcp.json`, Claude Desktop) ausdrückbar ist. Ein Flag
hinzuzufügen bricht diese Zusage.

## Testing Notes

Alle Tests laufen gegen handgeschriebene Mock-Pakete im jeweiligen Testfile
(`MockK8sAPI`, `MockSSRR`, `MockK8sObject`, …), die die genutzte
`Kubernetes::REST`-Oberfläche nachbilden: `new_object`, `create`, `list`, `get`,
`delete`, `patch`, `expand_class`, `_request`. **Kein Test braucht einen Cluster, und
keiner darf einen brauchen.**

| Datei | Deckt ab |
|---|---|
| `t/00-load.t` | Ladbarkeit der drei Module |
| `t/01-permissions.t` | RBAC-Discovery, `can_do`-Wildcards, `allowed_*`, `summary` |
| `t/02-resource-plurals.t` | 4-Tier-Pluralisierung |
| `t/03-namespace-resolution.t` | Auto-Fill genau bei einem Namespace |
| `t/04-format-helpers.t` | Summary-/List-Formatierung |
| `t/05-server-tools.t` | Tool-Registrierung und -Ausführung inkl. `force_409`-Pfad von `k8s_apply` |
| `t/06-kubernetes-alias.t` | `MCP::Kubernetes` ist `MCP::K8s` |
| `t/07-auth-alternatives.t` | Token-/in-cluster-/Kubeconfig-Tiers |
| `t/08-resource-discovery.t` | API-Discovery-Endpunkte, Subresource-Filter |

Zwei Mock-Details, die falsch nachgebaut lautlos das Falsche testen: der
`SelfSubjectRulesReview` wird per `new_object` gebaut und per **`create`** submitted
(nicht `get`), und der Cluster-Scope ist der **leere** Namespace-String.

## Release

```bash
dzil release
```

`[@Author::GETTY]` bumpt `$VERSION`, taggt und legt das GitHub-Release an. Mechanik:
skill `perl-release-author-getty`. Release nur mit ausdrücklicher Freigabe des
Maintainers — siehe `.claude/rules/mcp-k8s-rules.md`.

## Sharp Edges (für Entwickler)

- **`can_do` nimmt den Plural, nicht das Kind.** `can_do('list', 'Pod')` gibt still `0`
  und sieht aus wie eine fehlende Permission.
- **RBAC ist die einzige Autorisierungsschicht, absichtlich.** Kann der ServiceAccount
  Secrets lesen, kann das LLM es auch. Die Antwort darauf ist eine engere Role, kein
  Filter im Server.
- `_resolve_namespace` gibt `undef` zurück, wenn mehrere Namespaces erreichbar sind —
  „nimm den ersten" wäre eine stille Fehlbedienung gegen einen echten Cluster.
- Plural-Tier 3 schluckt jeden Fehler; falscher Plural und fehlende Permission sind von
  außen ununterscheidbar. Still lassen, aber keine neuen stillen Fallbacks danebenbauen.
- `k8s_apply`s Conflict-Erkennung ist ein Regex gegen den Fehlerstring. Ändert der
  Client-Layer sein Fehlerformat, degradiert apply lautlos zu „create failed".
- POD folgt der Deklaration, nicht umgekehrt: `sub foo {`, dann `=method foo` … `=cut`,
  dann der Body; `has` gefolgt von `=attr`. `[@Author::GETTY]`-Stil, nicht nach oben
  verschieben.
- `$VERSION` steht in allen drei Modulen und muss synchron bleiben.
- Die Tool-Liste existiert an vier Stellen: `lib/MCP/K8s.pm` POD, `bin/mcp-k8s` POD,
  `README.md` und `_register_tools`. Das ist die Drift, die am ehesten ausgeliefert wird.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
principle and lane are in `.claude/rules/mcp-k8s-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `mcp-k8s-worker` |
| Write or extend tests (mechanics) | `mcp-k8s-test-writer` |
| Pre-release audit | `mcp-k8s-release-checker` |

The agents carry their skills via `briefing.skills` (see `.claude/agents/`); the main
agent delegates rather than loading them. Skill sources live under `.claude/skills/`.
The karr board (`refs/karr/*`) is the internal coordination channel — dieses Repo hat
noch keins, `karr init` legt es an.

## Links

- README.md — User-Dokumentation
- examples/ — RBAC-Manifeste (readonly / deployer / full-ops) + Raider-Demo
- dist.ini — [@Author::GETTY] config
