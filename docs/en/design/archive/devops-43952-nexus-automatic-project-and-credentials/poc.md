# POC — Nexus auto-create review-driven refinements (H1/H2/H3)

<!--
POC driven by round-1 multi-role review of DEVOPS-43952. Tests three new
hypotheses introduced during review, not covered by the prior
_research-notes-nexus-api.md spike.
-->

## Hypothesis

Nexus 3.76 OSS can support the three review-driven design refinements:
(H1) a literal `OWNER=...;FP=...;CONN=...` ownership fingerprint stored on a
Nexus object's `description` and round-tripped byte-identical; (H2) an
OWNER-prefix-based squatter check that refuses adoption of an
externally-created object; and (H3) a strict path-prefix whitelist regex
fed into a CSEL `path =^` expression that resists injection.

## Branch

- Repo: n/a — throwaway curl-only spike on live `devops-nexus` instance; no
  branch — POC artifacts deleted after run.
- Cluster: `jtcheng-bdrjq-bwrsq--idp.alaudatech.net`, namespace
  `devops-nexus`, service `nexus-1-nxrm-ha`.
- Access:
  `kubectl port-forward -n devops-nexus svc/nexus-1-nxrm-ha 18081:80` then
  `curl --user 'admin:07Apples@' http://127.0.0.1:18081/...`.
- Cleanup verified: `GET /v1/security/users`, `/v1/security/roles`,
  `/v1/security/content-selectors` contain no `bdd-poc-*` objects.

## Result

**inconclusive** — H2 and H3 are validated as-designed; **H1 invalidated as
specified** (the design's chosen carrier object — `User.description` — does
not exist in Nexus OSS). A drop-in carrier is available (`Role.description`)
and validated, but this requires a tech-design fix-up before /feature:plan.

### Evidence

#### H1 — ownership fingerprint description round-trip

H1.1 — **invalidated** `[live-verified]`. `POST
/service/rest/v1/security/users` with `description` in body returns 200 but
**silently drops the field**. `GET /v1/security/users?userId=...` returns no
`description` key at all. Confirmed against swagger:
`ApiCreateUser.properties = [userId, firstName, lastName, emailAddress,
password, status, roles]`, `ApiUser.properties = [..., status, readOnly,
roles, externalRoles]` — no description anywhere in the User schema.

H1.fallback — **validated on `Role.description`** `[live-verified]`. The
swagger shows `description` lives on `RoleXORequest/Response`,
`ApiPrivilege*`, and `ContentSelectorApi*`. Since the design already
creates a per-connector Role, switching the fingerprint carrier from User
to Role costs zero extra API calls.

```
POST /service/rest/v1/security/roles
  body: {"id":"bdd-poc-h1-role","name":"...","description":
         "OWNER=connectors-operator;FP=abcdef012345;CONN=devops-nexus/sample-conn",
         "privileges":[],"roles":[]}
-> 200, GET returns description byte-identical (Python assert: True)
```

H1.3 — **validated** `[live-verified]`. PUT update with new FP returns 204;
GET shows `FP=ffffffffffff`. Rotation works.

H1.4 — **validated** `[live-verified]`. Description with embedded `;`
(`OWNER=connectors-operator;FP=...;CONN=ns;weird/name`) PUTs and round-trips
byte-identical. **Nexus does not interpret `;`** — parser on our side must
handle "first OWNER= field wins". Confirmed parser:
`for part in desc.split(';'): if part.startswith('OWNER='): return part[6:]`
correctly returns `connectors-operator` even with junk fields after.

H1.5 — **validated, with cap** `[live-verified]`. Description is backed by
H2 column `DESCRIPTION CHARACTER VARYING(400)`. PUTs at len ≤ 400 return
204; len 500+ return **500 with `Value too long for column "DESCRIPTION
CHARACTER VARYING(400)"`**. Hard cap = **400 chars**. Our fingerprint
`OWNER=connectors-operator;FP=<12hex>;CONN=<ns>/<name>` baseline ≈ 60–120
chars, well under cap — but we should defensively truncate or reject
descriptions > ~380 chars in lib.sh.

**H1 verdict — invalidated for `User`, validated for `Role`.** Tech design
must move the fingerprint carrier from User to Role, and add a 400-char
length check.

#### H2 — squatter check via OWNER prefix

H2.1 — **validated** `[live-verified]`. Created
`bdd-poc-h2-extern` Role with `description=OWNER=external;FP=00000000;CONN=foo/bar`
(POST=200).

H2.2 — **validated** `[live-verified]`. Parser correctly returns
`OWNER=external`, predicate `owner != 'connectors-operator'` evaluates
true. Robustness table:

| input | parser output |
|---|---|
| `OWNER=external;FP=...;CONN=foo/bar` | `external` |
| `None` | `None` |
| `""` | `None` |
| `"OWNER"` (no `=`) | `None` |
| `"OWNER="` | `""` (empty owner — refuse) |
| `"FP=abc;CONN=x/y"` (missing OWNER) | `None` |
| `"OWNER=connectors-operator"` | `connectors-operator` |
| `"OWNER=connectors-operator;junk;FP="` | `connectors-operator` |
| `"garbage no equals"` | `None` |

Safe rule for lib.sh: **adopt only if parser returns exactly the literal
string `connectors-operator`**. Any other value (including `None`, `""`,
`external`, etc.) → refuse, surface a Status condition pointing the admin
at the manual-takeover procedure.

H2.3 — **validated** `[live-verified]`. `PUT
/v1/security/roles/bdd-poc-h2-extern` with description rewritten to
`OWNER=connectors-operator;FP=takenover01;CONN=...` returns 204; GET
confirms takeover. Manual-takeover procedure (admin runs one curl PUT) is
implementable.

H2.4 — **validated, with quirk** `[live-verified]`. Role created via API
with no `description` in body comes back with **`description ==
"bdd-poc-h2-empty"` — Nexus defaults the description to the role id** when
field is omitted. This is **not** `None` / empty. Parser still works
because `"bdd-poc-h2-empty"` does not start with `OWNER=`. But it means
the squatter-check predicate **must be "starts-with OWNER=connectors-operator;"
or "equals connectors-operator"**, not "description is None/empty".

**H2 verdict — validated.** No design change; one tech-design clarification:
document the Nexus default-to-id behaviour and the exact predicate.

#### H3 — `validate_path_prefix` whitelist + CSEL construction

H3.1 — **validated** `[live-verified]`. Regex `^/[a-z0-9._/-]+/$` PASSes
all design-valid prefixes: `/com/acme/proj-pilot/`, `/org/example.com/`,
`/sub/dir-1/dir_2/`.

H3.2 — **partially validated, regex needs tightening** `[live-verified]`.
The proposed regex rejects most injections (quotes, spaces, control chars,
newlines) but **passes three classes the design must care about**:

| input | proposed regex | concern |
|---|---|---|
| `/com/acme/" or path =^ "/` | REJECT | good (quote) |
| `/com/acme/' ; rm -rf /` | REJECT | good (quote/space) |
| `/com\nx/` | REJECT | good (newline) |
| `/com/acme/  ` | REJECT | good (trailing space) |
| `/com/acme//../etc/` | **PASS** | bad — `..` and `//` slip through |
| `/com/and/x/` | **PASS** | bad — CSEL keyword as segment |
| `/com/or/x/` | **PASS** | bad — CSEL keyword as segment |
| `/com/AND/x/` | REJECT | good (uppercase) |

H3.3 — **validated** `[live-verified]`. `POST
/v1/security/content-selectors` with body
`{"name":"bdd-poc-h3-csel-1","description":"poc","expression":"path =^
\"/com/acme/proj-pilot/\""}` returns **204**. GET confirms the expression
round-trips. Nexus accepts the whitelisted prefix.

H3.4 — **critical finding** `[live-verified]`. Nexus accepts CSEL
expressions **without semantic path validation**:

- `path =^ "/com/acme//../etc/"` → POST=**204**, accepted.
- `path =^ "/com/acme/foo/" or path =^ "/"` → POST=**204**, accepted —
  Nexus parses the `or` as a CSEL operator and broadens to "everything".

So the regex IS the only defense against scope-broadening injection. Any
input the regex passes will be silently accepted by Nexus.

H3.5 — **validated with tightened regex** `[live-verified]`. Stricter
form `^/([a-z0-9._-]+/)+$` (no `/` inside character class, segments must
be non-empty) plus post-checks for `..` and the CSEL keywords
`and`/`or`/`not` correctly rejects all bad cases while preserving the good
ones:

| input | tightened result |
|---|---|
| `/com/acme/proj-pilot/` | PASS |
| `/org/example.com/` | PASS |
| `/sub/dir-1/dir_2/` | PASS |
| `/com/acme//../etc/` | REJECT (empty segment) |
| `/com/and/x/` | REJECT (keyword) |
| `/com/or/x/` | REJECT (keyword) |
| `/../x/` | REJECT (dotdot) |

**H3 verdict — validated with required regex tightening.** The proposed
regex `^/[a-z0-9._/-]+/$` is **not safe**; the replacement
`^/([a-z0-9._-]+/)+$` with explicit `..` and `and|or|not` deny-list is.

## Design impact

- `tech-design.md` §"Ownership fingerprint" — **must change carrier from
  Nexus User to Nexus Role**. Nexus 3.76 OSS User has no `description`
  field (silently dropped). Role description round-trips fine. The Role
  is already in the per-connector setup flow, so no extra API call.
- `tech-design.md` §"`lib.sh::validate_path_prefix`" — **must change regex
  from `^/[a-z0-9._/-]+/$` to `^/([a-z0-9._-]+/)+$`** plus explicit
  post-checks rejecting any segment equal to `and|or|not` and any path
  containing `..`. Nexus CSEL does not validate path semantically — the
  regex is the only defense.
- `tech-design.md` §"Description length" — **add explicit 400-char
  validation** (with a comfortable safety margin, e.g., reject > 380) in
  whatever helper writes the fingerprint. DB column is
  `VARCHAR(400)`; PUTs exceeding it return 500 from Nexus, not a clean
  4xx.
- `tech-design.md` §"Squatter-check predicate" — clarify that Nexus
  defaults missing description to the object's id (not null/empty); the
  predicate must be exact `starts-with "OWNER=connectors-operator;"` (or
  exact `==`), not "description is null/empty".
- `threat-model.md` §"CSEL injection" — record that Nexus accepts any
  syntactically-valid CSEL with no path-semantic validation. The
  validation responsibility sits entirely in lib.sh.
- `product-design.md` — no user-visible change.

## Learnings

- `[live-verified]` Nexus 3.76 OSS **User API has no `description` field
  at all** — silently dropped on POST, absent on GET. Confirmed against
  swagger schema `ApiCreateUser` / `ApiUser`.
- `[live-verified]` Role/Privilege/ContentSelector descriptions are backed
  by H2 DB column `VARCHAR(400)`. Beyond 400 chars → HTTP 500 with raw
  H2 exception leaked in body. Validate length client-side.
- `[live-verified]` Nexus Role created via API without `description` in
  body defaults the field to the **role id**, not null/empty. The
  squatter-check predicate must be a positive starts-with match against
  the OWNER prefix, not a negative null/empty check.
- `[live-verified]` Nexus CSEL parser performs **no semantic validation
  on `path` literals** — `..`, double slashes, and bareword operators
  `or`/`and` in path strings are silently accepted and (in the case of
  `or`) drastically broaden scope. lib.sh is the only line of defense.
- `[live-verified]` `;` inside a description value round-trips byte-
  identical through Nexus; our internal `split(';')` + `OWNER=` filter
  handles it correctly. No need to escape `;`.
- `[live-verified]` Admin override of an existing object's description via
  PUT works (204) — the manual takeover documented in the design IS
  implementable end-to-end with a single curl.

---

_POC loops are excluded from maturity metrics. Design iteration via POC is
the workflow operating as intended when desk research cannot settle the
design._
