# Vault 路线在 K8s 镜像拉取问题域的结构性 Gap

> 配套 PoC-2。本文说明：**在不引入额外的 distribution registry / proxy / admission webhook 的前提下，Vault（含 VSO / ESO / ClusterExternalSecret）做不到"业务 Pod spec 不持有 imagePullSecret 引用就能拉私有 registry 镜像"**。这是协议层 + K8s 内核行为决定的结构性约束，不是 Vault 的功能缺失。

---

## 1. 问题域回顾

Connectors 当前路径（`inputs/01-connectors-domain-map.md` §2）的核心能力：

- 用户在 Pod 上打 `connectors.cpaas.io/connector: <ns>/<connector>` annotation + `connectors.cpaas.io/proxy-inject: "true"` label
- `OCI/Harbor PodWebhook`（mutating admission）把 `image: harbor.example.com/team-a/app:v1` 改写为 `<reverse-proxy>/namespaces/<ns>/connectors/harbor/team-a/app:v1`
- kubelet 走 reverse proxy 拉镜像；imagePullSecret 用的是该 ns 一个 SA token 包装的 docker-registry secret，token 校验在 reverse proxy 完成
- 真正的 Harbor robot 密码只存在 `connectors-system` 的 `Connector` Secret 里

**业务团队的体验**：在 ns 里 `kubectl apply` 一个 Workload，**spec 里不需要写 `imagePullSecrets`，也不需要事先 `kubectl create secret docker-registry ...`**。只在 Pod / template 上加 annotation 即可。

---

## 2. Vault 路线能覆盖的部分

仅一项：**把一份 dockerconfigjson 类型的 K8s Secret 同步到任意 ns**。等价工具：

| 工具 | 做的事 |
|------|--------|
| VSO（Vault Secrets Operator）`VaultStaticSecret` | watch vault path → 渲染为 K8s Secret |
| ESO（External Secrets Operator）`ExternalSecret` + `ClusterExternalSecret` | 同上，支持跨 ns 批量复制 |
| 手写 CronJob（本 PoC 的替身） | 同上的最小手撸版 |

PoC-2 用 `vault-sync-secret.yaml` 里的 Job 演示了这条路径 —— 同步成功 → ns 内确实多了一个 `vault-synced-dockercfg`（`type=kubernetes.io/dockerconfigjson`）。

**但这只完成了"Secret 出现在 ns"，没有解决"业务 Pod spec 是否要引用它"**。下面三条结构性 gap 解释为什么 Vault 体系不可能再往前一步。

---

## 3. 结构性 Gap

### Gap 1 ── kubelet 拉镜像协议只认 `imagePullSecrets`（或全局 credential provider）

**根因**：kubelet 的镜像拉取走 OCI Distribution Spec（HTTP `/v2/*`）。对 private registry 的鉴权，K8s 只承认以下三种来源：

1. Pod spec `imagePullSecrets[*].name` 指向的 dockerconfigjson Secret
2. Pod 的 `serviceAccountName` 关联 SA 的 `imagePullSecrets[*]`（admission 时会 merge 进 Pod 的 `imagePullSecrets`，本质还是同一回事）
3. kubelet 的 [credential provider plugin](https://kubernetes.io/docs/tasks/administer-cluster/kubelet-credential-provider/) — **节点级配置**，需在 `/var/lib/kubelet/config.json` / `--image-credential-provider-config` 注册二进制插件，需要 root 权限改 node、不归 vault 管。

**Vault 没有任何机制能介入 kubelet 的拉镜像鉴权过程**。即使 ns 内有 1000 个 vault 同步出来的 dockerconfigjson，Pod spec 不引用、SA 不绑定，kubelet 一律视而不见。本 PoC 的 `poc2-scenario1-no-pullsecret` Pod 就证明了这一点 —— 它跟 `vault-synced-dockercfg` 在同 ns，但 spec 里没写 `imagePullSecrets`，于是 kubelet 直接报 `ErrImagePull`，没有任何"找一找 ns 内是否有可用 dockercfg"的行为。

> 注：把 SA 的 `imagePullSecrets` 改写也算一种"曲线救国"，但那也需要 webhook 或 controller 改 SA，且会污染 SA 给该 ns 所有 Pod —— 跟 Connectors 的"按 Pod annotation 精准命中"是两种语义。

### Gap 2 ── Vault 体系没有 Pod admission webhook 改 image 到集中 proxy

**根因**：Connectors 的 imagePullSecret-less 体验依赖 **两步**：

1. PodWebhook **改写 `spec.containers[*].image`** 到集中 reverse proxy 地址
2. 该 proxy 完成"前置真凭据 → 后端 Harbor"的 token 交换

Vault / VSO / ESO **从未提供** Pod admission webhook 来改写 image —— 这不在 secret 同步工具的职责范围。HashiCorp 官方 `vault-agent-injector` 只改写 Pod 的 `spec.containers[*].env` 和注入 init/sidecar 容器，**不改 image 字段**。

第三方可以补这个 webhook（Kyverno `mutate` 规则、jsPolicy、自写 admission webhook），但**仅改 image 还不够 —— 必须有一个能讲 OCI Distribution 协议的 proxy** 来接 kubelet 的 `/v2/*` 请求并替它走真凭据。Vault 不是 distribution proxy（**它没有 `/v2/*` 端点**），即使有 webhook 改了 image 也无处可去。

**结论**：Vault 路线即便补一个第三方 webhook，仍需自建 distribution proxy。这就**等于把 connectors-oci / connectors-harbor 这套基础设施重做一遍** —— 那已经不是"用 Vault 替代 Connectors"，而是"用 Vault + 自建 OCI proxy 替代 Connectors"，第二项才是真正的工程主体。

### Gap 3 ── ns 数量越多，写操作面越发散；轮换波及面失控

**根因**：要让 Vault 同步出的 dockercfg 在 N 个 ns 都可用，必须：

1. 对每个 ns 创建一个 `VaultStaticSecret` / `ExternalSecret`（或一个 `ClusterExternalSecret` 列举 ns 选择器）
2. 让每个 ns 的业务 Workload Author 知道 secret 名字、在自己的 Deployment / Job / Pod template 里写 `imagePullSecrets`
3. （可选）跟 ns 默认 SA 绑定 imagePullSecrets，但这会污染 ns 内所有 Pod

| 维度 | Vault 路线 | Connectors 路线 |
|------|-----------|----------------|
| ns 内 Secret 物化 | **每个 ns 一份**（同步） | 每个 ns 一份（SA token 包装） |
| 业务 Workload 改造 | **必须显式 `imagePullSecrets`** | **不需要**（PodWebhook 改 image，imagePullSecret 由 webhook 注入） |
| 真凭据轮换影响范围 | 同步 Job 重跑 → 所有 ns 的同步 Secret 全部刷新；运行中 Pod 不感知（已挂载的 dockercfg 不重读 —— kubelet 拉镜像时再读一次） | proxy 内 cache 失效 → 下一个请求用新凭据；已运行 Pod 完全无感（真凭据从未到达 Pod） |
| 真凭据传播半径 | **每个 ns 都有一份明文 dockerconfigjson**（base64 编码 ≠ 加密） | 真凭据只在 `connectors-system` |

> "明文传播半径"是关键差异：Vault 把真 dockerconfigjson 复制到每个业务 ns 后，**ns 内任何能 `get secret` 的人都能 `base64 -d` 拿到 Harbor robot 密码**，跟"vault 加密存储"完全无关。

### Gap 4（附带）── 跨多 registry 时配置爆炸

Pod 一次拉取可能涉及多个 registry（base image、应用镜像、init image），imagePullSecrets 是 list 形态，但维护 ns 内多个 dockercfg + 业务 spec 一一对应仍需治理；Connectors 的"按 annotation 选 Connector → 该 Connector 知道走哪个 Harbor"在语义上更精炼。

---

## 4. 三条 Gap 的共同结论

**Vault 是 secret store，不是 distribution proxy + admission webhook 的合集**。任何"用 Vault 替代 Connectors 在镜像拉取问题域上的体验"方案，都必须额外引入：

- 一个真正讲 OCI Distribution 协议的 reverse proxy（功能等价 connectors-oci/connectors-harbor）
- 一个 Pod admission webhook（改 image + 注 imagePullSecret，功能等价 OCI PodWebhook）
- 一套 SA token 校验机制（让 proxy 把客户端鉴权换成后端真凭据，功能等价 connectors proxy 的 token review）

**这三块加起来就是 Connectors 本身**。Vault 只在最末端的"真凭据存储"角色上有重叠，且 Connectors 现在已经把真凭据存在 K8s Secret —— 即使要换成 vault 来管这一份 secret，连接器架构的其他部分一行都改不了。

---

## 5. 对覆盖矩阵第 2 项（K8s 镜像拉取无 per-ns imagePullSecret）的回扣

| 维度 | Vault 单独 | Vault + VSO 同步 dockercfg | Connectors 当前 |
|------|------------|---------------------------|----------------|
| ns 内是否需要 dockerconfigjson Secret | N/A | **是** | **是**（SA token 包装） |
| Pod spec 是否要写 `imagePullSecrets` | N/A | **是** | **否**（PodWebhook 处理） |
| 真凭据是否离开 connectors-system / vault-system | N/A | **是**（每 ns 复制明文 dockercfg） | **否**（永远在 connectors-system） |
| 轮换是否影响已运行 Pod | N/A | 不影响（kubelet 下次拉镜像才读） | 不影响（运行中 Pod 不需要重拉镜像） |
| 治理粒度 | N/A | 同步 Job 控制范围 | annotation + RBAC + Connector scope |

**结论**：Vault 路线在该维度的覆盖率严格地等于"VSO 同步 dockercfg 替代手工 `kubectl create secret docker-registry`"这一点，**对 imagePullSecret-less 这个核心体验贡献为 0**。
