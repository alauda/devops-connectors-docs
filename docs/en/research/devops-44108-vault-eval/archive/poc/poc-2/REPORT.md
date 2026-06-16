# PoC-2 报告：Vault 在 K8s 镜像拉取问题域结构性不覆盖

> 主报告引用入口：覆盖矩阵第 2 项「K8s 镜像拉取」的实证。
> 完整材料：`vault-sync-secret.yaml`、`test-pods.yaml`、`run-log.md`、`gap-analysis.md`。

## 0. PoC-2 边界声明（必读）

本 PoC 故意只测 **"VSO + Pod 不写 imagePullSecret"** 的反例路径，**不引入 Kyverno mutating webhook**，目的是演示 "Vault 单品 + VSO 不足以达到 imagePullSecret-less" 的核心 DX 差异。

**Vault 生态可组合可达**：如果引入 **Kyverno（PodWebhook mutate，CNCF Graduated）+ VSO + 自建 / 社区 OCI reverse proxy**，Vault 路径可达 imagePullSecret-less + 集中凭据，工程量约 1-2 月集成。本 PoC 想证明的是 "Vault 单品 + VSO 不足以达到 imagePullSecret-less"，**不是** "Vault 生态在此问题域无解"。

**SA-bound 路径承认**：K8s 支持把 imagePullSecret 挂在 ServiceAccount 的 `imagePullSecrets[]` 上而非 Pod 上（VSO + Kyverno mutating webhook 可自动改 SA），从而部分缓解 "Pod 必须写 imagePullSecret" 的要求。**本 PoC 未覆盖该路径实测**。即便走 SA-bound 路径，它仍是 "显式引用 + 污染 ns 内所有用该 SA 的 Pod"，不能消除 Connectors 的核心 DX 承诺—— "Pod 无须声明 imagePullSecret，只需加一个 annotation"。

下一轮调研应补 **PoC-2b**：哪怕不真跑，至少做一个 paper design，列出 "Kyverno + ESO + Vault + 自建 OCI reverse proxy" 的资源清单与工程量估算。

## 1. 实验设计

本 PoC 把 "Vault 单品 + VSO 在 K8s 镜像拉取问题域的 DX 短板" 变成可观测事实，避免引入 helm 依赖（不装真的 VSO），用一个 K8s Job 作为最小可行替身演示 VSO 同步逻辑，再用两个对照 Pod 验证 "ns 内有同步好的 dockercfg" 与 "Pod 能否拉私有镜像" 之间的真实关系。

- **集群 / ns**：`https://...idp.alaudatech.net/kubernetes/global/` 的 `devops-valult-invest`（仅在此 ns 工作）
- **Vault**：dev 模式，复用 `00-vault-setup-log.md` 部署的实例
- **fake 私有镜像**：`my-private-registry.example.com/foo:latest`（拉不通，专门看 kubelet 鉴权阶段是否带凭据）
- **真实可拉镜像**：`hub-mirrors.alauda.cn/library/alpine:3`（免认证，用作场景 2 的正例）

## 2. 集群验证证据

### A. VSO 等价同步链路 OK（已落地真实 Secret）

```
$ kubectl -n devops-valult-invest logs job/vault-image-sync
[vault-image-sync] step 1: POST .../auth/kubernetes/login (role=image-puller)
[vault-image-sync] got vault token; policies=['default','image-puller'] lease=900s
[vault-image-sync] step 2: GET .../v1/secret/data/registry/dummy
[vault-image-sync] dockerconfigjson preview={"auths":{"my-private-registry.example.com":{"auth":"dXNlcjpwYXNz"}}}
[vault-image-sync] step 3: POST kube Secret devops-valult-invest/vault-synced-dockercfg
[vault-image-sync] create HTTP 201
[vault-image-sync] DONE.
```

ns 内 `vault-synced-dockercfg`（`type=kubernetes.io/dockerconfigjson`，annotation `poc-2.devops-44108/source=vault:secret/data/registry/dummy`）已存在，base64 解码后内容与 vault 里写的明文一致。**Vault 路线在该问题域能完成的全部能力已达到**。

### B. 场景 1（不引用 imagePullSecret，证伪"自动覆盖"）

```
poc2-scenario1-no-pullsecret   0/1   ErrImagePull   0   12s
```

Events：
```
Pulling   image "my-private-registry.example.com/foo:latest"
Failed    failed to resolve image: Head "https://my-private-registry.example.com/v2/foo/manifests/latest":
          dial tcp: lookup my-private-registry.example.com on 192.168.16.19:53: no such host
Failed    Error: ErrImagePull
```

**关键**：同 ns 同时存在 `vault-synced-dockercfg` 并含对应 registry 的 auth 条目，kubelet **不会基于 ns 内任意存在的 dockerconfigjson Secret 自动选择凭据**——直接走公网域名解析，事件里看不到任何 "using image pull secret ..."。这就是 VSO + 业务 Pod 不显式引用的真实表现。**注**：把同步出的 Secret 挂到 ServiceAccount 的 `imagePullSecrets[]` 也是一条曲线救国路径（K8s 支持，VSO + Kyverno 可自动改写），但会污染 ns 内所有用该 SA 的 Pod；本 PoC 未覆盖该路径实测。

### C. 场景 2（显式引用 imagePullSecrets，对照正例）

```
poc2-scenario2-with-pullsecret   1/1   Running   0   12s
```

Events：
```
Pulling   image "hub-mirrors.alauda.cn/library/alpine:3"
Pulled    Successfully pulled image ... in 3.054s
Started   Started container app
```

spec 显式 `imagePullSecrets: [vault-synced-dockercfg]`——证明 "只有 Pod spec 引用，kubelet 才会带它鉴权"。

## 3. 对覆盖矩阵第 2 项的回扣

| 维度 | Vault + VSO（本 PoC） | Connectors |
|---|---|---|
| ns 内是否需 dockerconfigjson | 是 | 是（SA token 包装） |
| 每 ns 是否单独投递 | 是 | 是（按 scope） |
| 业务 Pod 是否要写 imagePullSecrets | **是**（场景 1 已证伪不写不行；或将其挂到 Pod 的 ServiceAccount.imagePullSecrets[]，但这会污染 ns 内所有用该 SA 的 Pod；本 PoC 未覆盖该路径实测） | **否**（PodWebhook 改 image + 注 imagePullSecret） |
| 真凭据是否离开 secret 管理域 | **是**（每 ns 一份明文 dockerconfigjson；base64 ≠ 加密） | **否**（只在 connectors-system） |
| 凭据轮换对运行中 Pod 的影响 | 不影响 | 不影响 |

## 4. DX 差异总结（详见 `gap-analysis.md`，避免绝对化）

1. **kubelet 拉镜像协议层**：K8s 只承认 Pod spec `imagePullSecrets` / SA `imagePullSecrets` / 节点级 credential provider 三种凭据来源。Vault 无法介入任何一条 —— **必须**经过 Pod 或 SA 的 `imagePullSecrets` 显式引用，这一引用动作是 Vault 路线下每个业务 ns 都需做的额外工程，不能省。
2. **缺 admission webhook 改 image（Vault 生态可组合补）**：VSO / ESO 都不做 Pod mutation；可用 **Kyverno（CNCF Graduated）+ 自建 OCI Distribution reverse proxy** 组合补齐，工程量约 1-2 月集成。这与 connectors-oci / connectors-harbor 的主体工程量等价（即"如果走 Vault 路线，仍需重新搭建一遍"），且失去 ACP 单一供应商支持口径 + 同生命周期升级。
3. **明文传播半径**：Vault 路线必须把真 dockerconfigjson 复制到每个业务 ns，ns 内任何能 `get secret` 的人都能 `base64 -d` 还原；Connectors 路线真凭据永不离开 `connectors-system`。

## 5. 结论（精化）

**Vault 单品在 K8s 镜像拉取问题域的覆盖率严格等于 "VSO 同步 dockercfg 替代手工 `kubectl create secret docker-registry`"**——对 imagePullSecret-less 这个核心 DX 贡献为 0。**Vault 生态可组合达成 imagePullSecret-less**（Kyverno + ESO + Vault + 自建 OCI reverse proxy），但工程量等价于重新搭建 Connectors OCI/Harbor 子项目，且失去 ACP 集成度优势。Vault 在最末端的"真凭据存储"角色上有 1 项重叠，但 Connectors 已经把真凭据存在 K8s Secret 里——即使换成 vault 管这一份 secret，前述架构的其他部分一行都改不了。

**覆盖矩阵第 2 项判定（精化）**：Vault 单品不覆盖；Vault 生态需组合 Kyverno + 自建 reverse proxy 才能覆盖，且失去集成度优势。下一轮调研应补 PoC-2b（Kyverno + ESO + Vault paper design 或实测）完整覆盖反方论据。
