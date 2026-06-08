# Nexus REST API research notes (DEVOPS-43952)

Scratchpad for the design author. Findings tagged `[live-verified]` (curl-tested against the test instance) or `[doc-only]` (from Sonatype docs / swagger only).

Test instance: `nexus-1-nxrm-ha` in namespace `devops-nexus` on cluster `jtcheng-bdrjq-bwrsq`. Reached via `kubectl port-forward svc/nexus-1-nxrm-ha 18081:80`. All `curl` examples assume `N=http://localhost:18081` and `$NEXUS_TOKEN` = `admin:07Apples@` basic-auth string.

## 1. Live instance fingerprint `[live-verified]`

- **Version**: `Nexus/3.76.0-03 (OSS)` — read from the `Server:` response header on every reply. (`/service/rest/v1/status` returns health JSON, not version; only the header has it.)
- **Edition**: OSS / Community.
  - `GET /service/rest/v1/system/license` → **402** `"Missing or invalid license"` (PRO would return 200 with `licensed:true`).
  - `/v1/security/user-tokens` → **404**, confirming user-tokens are PRO-only on 3.76.
  - `/v1/security/jwt` → **404**, JWT realm not exposed in CE.
- **Active realm**: `["NexusAuthenticatingRealm"]` (local users only).
- **Available realms** (for opt-in): `ConanToken`, `DefaultRole`, `DockerToken`, `LdapRealm`, `NexusAuthenticatingRealm`, `NpmToken`, `NuGetApiKey`, `rutauth-realm`. **No** user-token, JWT, or SAML realm in CE.
- **Anonymous user**: enabled by default. `userId=anonymous`, role `nx-anonymous`. Unauthenticated upload returns **401** (not 403). We should plan to either leave anonymous read-only or disable it cluster-wide (independent of our feature).
- **Supported repo formats (CE swagger)**: apt, cocoapods, conan, conda, docker, gitlfs, go, helm, huggingface, maven, npm, nuget, p2, pypi, r, raw, rubygems, yum. Each format has its own endpoint shape `/v1/repositories/<format>/<hosted|proxy|group>`.
- **Default repos** present: `maven-*` (releases/snapshots/central/public), `nuget-*`, no npm/pypi/raw/docker — we have to create them.

## 2. Repository CRUD `[live-verified]` for maven2/npm/pypi/raw/docker

Pattern: per-format URLs. **No** universal `POST /v1/repositories` — you must dispatch on `<format>/<type>` in the path. Update is PUT to `/{format}/{type}/{name}` (no top-level update). Delete is `DELETE /v1/repositories/{name}` (format-agnostic).

| Op | Path | Body | Result |
|---|---|---|---|
| Create maven hosted | `POST /v1/repositories/maven/hosted` | see below | **201** |
| Create maven proxy | `POST /v1/repositories/maven/proxy` | + `proxy.remoteUrl` | (doc-only; same shape as npm proxy below) |
| Create maven group | `POST /v1/repositories/maven/group` | `group.memberNames:[]` | **201** |
| Create npm hosted | `POST /v1/repositories/npm/hosted` | no extra block | **201** |
| Create npm proxy | `POST /v1/repositories/npm/proxy` | `proxy.remoteUrl`, `httpClient`, `negativeCache` | **201** |
| Create pypi hosted | `POST /v1/repositories/pypi/hosted` | minimal | **201** |
| Create raw hosted | `POST /v1/repositories/raw/hosted` | `strictContentTypeValidation:false` | **201** |
| Create docker hosted | `POST /v1/repositories/docker/hosted` | `docker.v1Enabled,forceBasicAuth` | **201** |
| Update | `PUT /v1/repositories/maven/hosted/{name}` | full body | **204** |
| Delete | `DELETE /v1/repositories/{name}` | — | **204** |
| List | `GET /v1/repositories` | — | **200** array |
| Get one | `GET /v1/repositories/{name}` | — | **200** (only top-level fields, no `storage`/`maven` block — to read full config use `GET /v1/repositories/<format>/<type>/{name}`) |

Minimal maven hosted body (verified):
```json
{"name":"proj-pilot-maven","online":true,
 "storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"},
 "maven":{"versionPolicy":"RELEASE","layoutPolicy":"STRICT","contentDisposition":"INLINE"}}
```
Re-POST same body → **400** `"Duplicate key"` (so create is **not** idempotent — caller must `GET` first or treat 400 as a soft conflict and PUT).

Delete behaves synchronously enough for our purposes: `DELETE`→**204**, immediate re-`POST` of same name → **201** (no transient name-collision window observed). `[live-verified]`

## 3. Identity model (CE-compatible) `[live-verified]`

**User CRUD**: `POST /v1/security/users`, `PUT /v1/security/users/{userId}`, `DELETE …`, `PUT …/change-password`.
- Body fields required: `userId`, `firstName`, `lastName`, `emailAddress`, `password`, `status`, `roles` (array of role IDs).
- **Password constraint**: only `must not be empty`. Single-character passwords accepted (tested `"a"` → 200). No length/complexity rules enforced server-side in this version. Caller is responsible for generating strong creds.
- `change-password` endpoint takes the new password as **plain text body** (Content-Type: `text/plain`), not JSON — 204 on success.
- Re-POST same userId → **HTTP 500** `DuplicateUserException` (not 409). Caller must check existence first.

**Role CRUD**: `POST/PUT/DELETE /v1/security/roles[/{id}]`.
- `privileges:[]` lists privilege names; `roles:[]` lists nested role IDs.
- Re-POST same id with a non-existent privilege referenced → 400 `"Privilege 'X' not found"`.
- **Delete role while a user references it: succeeds (204)**. The user is left with a stale role reference. This is the most surprising rollback hazard — see §6.

**Privilege types in CE**: `application`, `repository-admin`, `repository-view`, `repository-content-selector`, `script`, `wildcard`. (Confirmed by listing existing built-ins and by swagger `/v1/security/privileges/{type}` endpoints.) No PRO-only types observed.
- **`repository-content-selector` is in CE** — this is the critical primitive. Endpoint: `POST /v1/security/privileges/repository-content-selector`. Fields: `name`, `description`, `actions` (subset of `read,browse,edit,add,delete`), `format`, `repository`, `contentSelector`.
- `repository-view` lets you grant blanket actions on a whole repo (no path filter): same shape minus `contentSelector`.

**Content selectors**: `POST /v1/security/content-selectors`, `PUT /v1/security/content-selectors/{name}`, `DELETE …`, `GET …`.
- Body: `name`, `description`, `expression`.
- Expression syntax is CSEL: e.g. `format == "maven2" and path =^ "/com/acme/proj-pilot/"`. Logical operator is `and` (lowercase) — **not** `&&`. (The brief's example `&&` would fail.)
- POST returns **204** (no body) on create — not 201. `[live-verified]`
- Re-POST same name → 400 (treat as conflict).

**User-tokens**: **not available in CE** (404). Our only non-interactive credential is `userId + password` (basic auth) or `userId + password` exchanged for an `NXSESSIONID` cookie. No bearer JWT.

## 4. Scoping experiment (the critical risk validation) `[live-verified]`

Full end-to-end run on the live cluster, in this order:

1. Created hosted repo `proj-pilot-maven` (maven2).
2. Created content selector `proj-pilot-csel` with expression `format == "maven2" and path =^ "/com/acme/proj-pilot/"`.
3. Created privilege `proj-pilot-csel-priv` (type `repository-content-selector`, actions `[read,browse,add,edit,delete]`, format `maven2`, repo `proj-pilot-maven`, selector `proj-pilot-csel`).
4. Created privilege `proj-pilot-view-priv` (type `repository-view`, actions `[browse,read]`, format `maven2`, repo `proj-pilot-maven`).
5. Created role `proj-pilot-role` referencing both privileges.
6. Created user `proj-pilot-user` with role `proj-pilot-role`.

Then as that user (no admin rights anywhere else):

| Test | URL | Expected | Actual |
|---|---|---|---|
| Upload IN scope | `PUT /repository/proj-pilot-maven/com/acme/proj-pilot/widget/1.0.0/widget-1.0.0.jar` | accept | **201** ✅ |
| Upload OUT of scope | `PUT /repository/proj-pilot-maven/com/other/Y/1.0.0/Y-1.0.0.jar` | deny | **403** ✅ |
| Read OUT of scope (path doesn't exist either) | `GET /repository/proj-pilot-maven/com/other/anything.jar` | deny | **404** (selector denies without revealing) |
| Read IN scope | `GET /repository/proj-pilot-maven/com/acme/proj-pilot/widget/1.0.0/widget-1.0.0.jar` | accept | **200** ✅ |
| Delete the repo | `DELETE /v1/repositories/proj-pilot-maven` | deny | **403** ✅ |
| Create another repo | `POST /v1/repositories/maven/hosted` | deny | **403** ✅ |
| Anonymous upload | (no auth) PUT to in-scope path | deny | **401** ✅ |

**Conclusion**: CE has more-than-enough fine-grained scoping for our use case. The repository-content-selector privilege confines a user to a path prefix on a shared hosted repo. No need for one-repo-per-project unless we want that for blob accounting reasons.

**Subtle pitfall**: out-of-scope GET returns **404**, not 403. Distinguish "blocked by selector" from "object missing" at the protocol level isn't possible — that's by design (information hiding). If we want to surface "this is denied" to UI, we have to inspect grants ourselves.

## 5. Group / proxy reuse `[live-verified]`

Created `proj-pilot-maven-group` with members `[proj-pilot-maven, maven-central]`.

- User can only reach the group if the role grants browse on the **group repo itself** — view priv on a member is not transitive. (`403 Forbidden` before granting group-view, then `200` after.)
- Once `repository-view` browse/read is granted on the group, the user can fetch **any** path on the group: project-owned artifacts AND central-proxied artifacts (junit-4.12.pom succeeded). The content selector applied to the hosted repo **does not constrain reads via the group URL** unless we also build a CSEL-based privilege on the group.
- Direct writes via group URL return **403** — groups are read-only by Nexus design.

**Design implication**: if you want a project user to push to its hosted repo AND pull from the shared central proxy in one virtual endpoint, granting blanket `repository-view` browse/read on the group is the easy path; granting a CSEL on the group is the tight path. The wider the group's blanket grant, the more leakage of other-format/other-project content. Recommend tight (CSEL on the group) for production; blanket for v1 if simplicity is preferred.

## 6. Rollback primitives `[live-verified]`

| Question | Answer |
|---|---|
| Is there a transaction? | **No.** Each REST call is independent. |
| Is create idempotent? | **No.** Re-create returns 400 (repo, csel, priv, role) or **500** (user). Caller must `GET` first or handle dup as success. |
| Does delete refuse on dependent objects? | **Inconsistent.** Content selector: refuses with **500** if a privilege references it. Privilege: succeeds even if a role references it (stale ref). Role: succeeds even if a user references it (stale ref). |
| Cleanest delete order | user → role → priv-view → priv-csel → content-selector → group repo → hosted repo. Tested. |

Implication for the controller: we have to track our own dependency graph and detect/clean stale references during reconcile (because deleting a role does NOT detach it from users). The state must be reconstructable from the live API; consider naming convention `proj-<projectID>-<kind>` so we can list-and-filter.

The non-uniform 500 vs 4xx for "in use" / "duplicate" is also a hazard — a 500 from Nexus is sometimes a normal "you violated a constraint" answer, not a server fault. We should parse the response body's `IllegalStateException` / `DuplicateXException` text rather than blanket-retry on 5xx.

## 7. API auth options `[live-verified]`

| Mode | How | Notes |
|---|---|---|
| **Basic auth** | `Authorization: Basic <base64(user:pass)>` on every call | Simplest; what we'll use from Tekton tasks. |
| **Session cookie** | `POST /service/rapture/session` body `username=<b64>&password=<b64>` → sets `NXSESSIONID` cookie | 204 on success. Subsequent calls with `-b cookies` work. Anti-CSRF token (`NX-ANTI-CSRF-TOKEN`) only needed for browser-side state-changing requests; basic-auth and cookie+plain-curl bypass it. |
| **Bearer / JWT** | `Authorization: Bearer …` | **PRO only**, 404 in CE. |
| **User-tokens** | `Authorization: Basic <b64(token-name:token-pass)>` | **PRO only**, 404 in CE. |
| **Format-specific tokens** | Docker/npm/Conan/NuGet bearer tokens from per-format realms | Used by clients, not by our admin task. |

Our Task will use plain basic auth with the admin (or "automation") account for provisioning, and the per-project generated `userId+password` is what we hand back to the consumer.

## 8. What is missing / surprising

1. **CSEL operator is `and`, not `&&`.** Brief's example would fail. `or`, `==`, `=^` (starts-with regex), `=~` (regex), `=$` (ends-with).
2. **Out-of-scope GET returns 404**, not 403 — information hiding. Cannot tell "wrong path" from "denied" externally.
3. **POST returns mixed 200/201/204** depending on resource. Csel POST → 204; user POST → 200; repo POST → 201; priv POST → 201; role POST → 200. Don't assume 201.
4. **500 means "your fault" in some cases** — `DuplicateUserException`, `Content selector ... is in use` come back as 500 with stack-trace-flavor messages. Parse body, don't retry.
5. **GET /v1/repositories** returns thin records (name/format/type/url/attributes only). For full config, hit `/v1/repositories/<format>/<type>/{name}`. Mixed shapes — caller has to know the format.
6. **Repo/user/role names are case-sensitive everywhere.** Tested implicitly. Keep generated names lowercase + hyphen-only.
7. **Role privilege validation is at create-time only.** After role creation, you can delete a privilege the role references and the role keeps the dangling name (200 on subsequent GET role). Stale.
8. **No bulk endpoints.** N round-trips for N privileges. A 5-object project = ~6 calls (repo, csel, priv-csel, priv-view, role, user). Plan latency budget accordingly.
9. **Repository-admin** type privilege exists in CE (we didn't grant it to the pilot user — and that gave us the desired "can't delete repo" behavior). Useful if you DO want a project to delete its own repos.
10. **`storage.strictContentTypeValidation:true` is the default and required for raw repos to be useful — but the pilot raw repo was created with it false to allow arbitrary content.** Decide per-format default in the controller.
11. **Format auto-detection from CR is impossible** — every format has a distinct endpoint and distinct body shape. The controller has to dispatch on a `format` field.

## 9. Recommendation

Given the live findings, **Option (i) — one local user + custom role + content-selector — is feasible AND clean in CE**. Justification:

- Scoping experiment proved that a repository-content-selector privilege locks a user to a path prefix on a shared hosted repo. The 403/404 split matches what enterprise consumers expect.
- It minimises blob-store fragmentation (one shared hosted repo per format, prefix per project) — important because OSS does not have blob-store quotas, but operationally one big repo is easier than N.
- It keeps the API object count bounded per project: 1 csel + 2 privileges (csel + view) + 1 role + 1 user = 5 objects (plus 1 view priv on the group if we expose a group). Cheap to reconcile.
- Naming convention `proj-<projectID>-{maven,csel,csel-priv,view-priv,role,user}` makes the inverse-list-and-clean trivial.

**Cautions baked into the design**:
- Per format, decide whether to use a shared hosted repo + CSEL (Option i) or per-project hosted repo (Option ii). Formats where path-prefix scoping is unsafe or unidiomatic (docker — tags don't carry "project path"; gitlfs — content-addressed) should fall back to Option ii.
- Stale-reference cleanup must be modeled (because Nexus won't enforce it on delete).
- All 4xx and `IllegalStateException`/`Duplicate*Exception` 5xx must be classified as "user-fixable conflict" rather than retried.

For maven2, npm, pypi, raw — go Option (i).
For docker, gitlfs — go Option (ii) (one repo per project, full RW via repository-view, no content selector).

## Open questions for design author

1. **Format scoping**: do we expose `format` as a per-`ConnectorClass` discriminator (one ConnectorClass per format) or as a field on the `Connector` CR (one connector flips between formats)? The API is format-routed so a per-class model maps cleanly to controller code; a per-CR model means dispatch in the reconcile.
2. **Group repo policy**: do we provision a per-project group that fronts the hosted + a shared central proxy, or do we let projects address the hosted directly and rely on a downstream tool config (settings.xml / .npmrc) to merge upstream? The first improves UX; the second halves the object count and avoids the CSEL-on-group leakage trap.
3. **Anonymous user handling**: the test cluster has anonymous enabled by default with read access. Do we (a) leave it alone (Nexus admin's call), (b) disable globally as part of our install, or (c) check and warn-but-not-block? Affects pull-without-auth scenarios that customers may rely on for read-only mirrors.
