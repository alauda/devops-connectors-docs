# Harbor CLI Config Tech Design

## 0. Design Goal

Expose `harbor-cli-config` for `harbor-cli` without exposing the original Harbor password or robot token in the Pod. Reuse the existing Connectors proxy model and keep runtime usage stable for Kubernetes workloads and CI jobs.

---

## 1. Research

### 1.1 Harbor CLI config format

Official `harbor-cli` uses `config.yaml`. Lookup order:

1. `--config`
2. `HARBOR_CLI_CONFIG`
3. `$XDG_CONFIG_HOME/harbor-cli/config.yaml`
4. `$HOME/.config/harbor-cli/config.yaml`

example:

```yaml
current-credential-name: <context-name>
credentials:
  - name: <context-name>
    username: <username>
    password: <encrypted-password>
    serveraddress: <harbor-url>
```

Key fields:

- `current-credential-name`: active context
- `credentials[].name`: context name
- `credentials[].serveraddress`: Harbor address
- `credentials[].username`: Harbor username
- `credentials[].password`: encrypted password value

- `harbor context list`
- `harbor context switch <context>`

### 1.2 Password encryption behavior

Harbor CLI encrypts the stored password before writing it into `config.yaml`. Key lookup order:

1. `HARBOR_ENCRYPTION_KEY`
2. system keyring
3. file keyring under `~/.harbor/keyring`

So `config.yaml` alone is not enough. A matching key is also required at runtime.

### 1.3 Forward proxy support

`config.yaml` does not define a forward proxy field. Official Harbor CLI client code uses Go's `ProxyFromEnvironment`, so proxy settings must come from runtime environment variables such as `HTTP_PROXY`, `HTTPS_PROXY`, and `NO_PROXY`.

Relevant code:

- Harbor CLI client creation: [`harbor-cli/pkg/utils/client.go`](https://github.com/goharbor/harbor-cli/blob/main/pkg/utils/client.go)
- go-client transport selection: [`go-client/pkg/harbor/client.go`](https://github.com/goharbor/go-client/blob/main/pkg/harbor/client.go)

Current implementation note: Harbor CLI does not construct a custom verifying transport here. It leaves `Transport` unset, and `go-client` falls back to `InsecureTransport`, which sets `tls.Config{InsecureSkipVerify: true}`. This is current default behavior, not a user-configurable override in Harbor CLI.

### 1.4 Reverse proxy limitation

If reverse proxy style design treats a connector token as Harbor CLI password input, it conflicts with Harbor CLI password validation. Official `ValidatePassword` requires:

- length `8-256`
- at least one lowercase letter
- at least one uppercase letter
- at least one digit

Long opaque proxy tokens may violate length or format rules. This is a Harbor CLI client-side constraint. For Harbor CLI, it is safer to keep `serveraddress` as the original Harbor address and inject proxy behavior at runtime.

Relevant code:

- password validation: [`harbor-cli/pkg/utils/helper.go`](https://github.com/goharbor/harbor-cli/blob/main/pkg/utils/helper.go)
- login view: [`harbor-cli/pkg/views/login/create.go`](https://github.com/goharbor/harbor-cli/blob/main/pkg/views/login/create.go)
- password change view: [`harbor-cli/pkg/views/password/change/view.go`](https://github.com/goharbor/harbor-cli/blob/main/pkg/views/password/change/view.go)

---

## 2. Implementation Plan

### 2.1 Forward proxy vs reverse proxy

**Reverse proxy approach**: rewrite Harbor CLI access to a reverse proxy endpoint and pass connector identity or token as Harbor CLI credential material.

Issues:

- Harbor CLI password validation is unsuitable for connectors proxy tokens

**Forward proxy approach**: keep `serveraddress` as the original Harbor URL, inject `HTTP_PROXY` and `HTTPS_PROXY` at runtime, and let Connectors forward proxy handle outbound access and RBAC.

Benefits:

- matches Harbor CLI runtime behavior
- keeps generated contexts readable
- does not expose original Harbor secret in the Pod
- fits existing Connectors proxy architecture

Decision: `harbor-cli-config` uses the **forward proxy** approach.

### 2.2 Harbor ConnectorClass and runtime options

All options generate the same Harbor CLI context structure:

- `serveraddress` keeps the original Harbor address
- `username` is fixed to `connector-proxy`
- `password` is a dummy encrypted value required by Harbor CLI config format

The mounted files do not expose the original Harbor password.

**Option A: dedicated keyring file output**

ConnectorClass provides:

- `config.yaml`
- `harbor-cli_harbor-cli-encryption-key`

Runtime usage:

1. source the CSI built-in `.env`
2. provide `HARBOR_CLI_CONFIG` or use Harbor CLI default config path
3. copy `harbor-cli_harbor-cli-encryption-key` to `~/.harbor/keyring/harbor-cli_harbor-cli-encryption-key`

Pros:

- matches Harbor CLI fallback behavior
- no need to export `HARBOR_ENCRYPTION_KEY`
- keeps key material in Harbor CLI's expected location

Cons:

- requires `mkdir/cp/chmod`
- depends on a writable home directory

**Option B: env file output**

ConnectorClass provides:

- `config.yaml`
- `HARBOR_ENCRYPTION_KEY`

The `HARBOR_ENCRYPTION_KEY` file content is:

```bash
HARBOR_ENCRYPTION_KEY=<base64-encoded-key>
```

Runtime usage:

1. source the CSI built-in `.env`
2. provide `HARBOR_CLI_CONFIG` or use Harbor CLI default config path
3. source `HARBOR_ENCRYPTION_KEY` before running Harbor CLI

Pros:

- simpler startup command
- does not depend on `~/.harbor/keyring`
- lower understanding cost for users

Cons:

- still relies on explicit environment injection
- less aligned with Harbor CLI's default keyring behavior

**Option C: raw value file output**

ConnectorClass provides:

- `config.yaml`
- `HARBOR_ENCRYPTION_KEY`

The `HARBOR_ENCRYPTION_KEY` file content is:

```text
<base64-encoded-key>
```

Runtime usage:

1. source the CSI built-in `.env`
2. provide `HARBOR_CLI_CONFIG` or use Harbor CLI default config path
3. choose one of the following:
   - `export HARBOR_ENCRYPTION_KEY=$(cat HARBOR_ENCRYPTION_KEY)`
   - copy the file to `~/.harbor/keyring/harbor-cli_harbor-cli-encryption-key`

Pros:

- supports both env var and keyring consumption
- avoids embedding shell syntax into the file content
- lower understanding cost than a dedicated keyring-only file

Cons:

- users still need one explicit runtime step

Decision: use **raw value file output** as the primary design. It is more flexible than a dedicated keyring file and simpler than an env-style file.

### 2.3 Certificate handling decision

The current Harbor CLI API path does not make mounted CA configuration a hard requirement.

- Harbor CLI does not build a custom verifying transport here.
- `go-client` falls back to `InsecureTransport`.
- That transport sets `tls.Config{InsecureSkipVerify: true}`.

So `SSL_CERT_FILE` is not required for the current default API path.

This is a current implementation fact, not a long-term guarantee. If Harbor CLI later switches to normal TLS verification, workloads may need `SSL_CERT_FILE` or another standard CA trust mechanism when the target CA is not already trusted by the image.

Relevant code:

- Harbor CLI client creation: [`harbor-cli/pkg/utils/client.go`](https://github.com/goharbor/harbor-cli/blob/main/pkg/utils/client.go)
- go-client insecure transport: [`go-client/pkg/harbor/client.go`](https://github.com/goharbor/go-client/blob/main/pkg/harbor/client.go)
- SDK client using provided transport: [`go-client/pkg/sdk/v2.0/client/harbor_api_client.go`](https://github.com/goharbor/go-client/blob/main/pkg/sdk/v2.0/client/harbor_api_client.go)

### 2.4 Operational requirements

At runtime, users still need:

- `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` from built-in `.env`
- make the mounted `HARBOR_ENCRYPTION_KEY` value available through either env var export or Harbor CLI keyring fallback
- either `HARBOR_CLI_CONFIG` or Harbor CLI default config path
- service account permission for the connector proxy subresource

---

## 3. Summary

The final design combines Harbor CLI-compatible `config.yaml`, runtime forward proxy environment variables, and Harbor CLI encryption key material. `config.yaml` alone is insufficient because it does not carry forward proxy settings and Harbor CLI also requires a matching encryption key for stored passwords.

Current Harbor CLI transport behavior also means custom CA configuration is not the controlling factor on this API path today, because the default client falls back to `InsecureSkipVerify: true`.

Selected design:

- keep Harbor address unchanged in Harbor CLI contexts
- inject proxy behavior at runtime
- prefer raw value file delivery for encryption key material
- expose the file as `HARBOR_ENCRYPTION_KEY`
- allow both env-var export and keyring-file consumption

This matches official Harbor CLI behavior and the Connectors proxy architecture.
