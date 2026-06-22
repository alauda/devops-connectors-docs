# Secrets Store CSI Driver 能力调研指南

> **状态**：已完成（聚焦机制对照，篇幅有意精简）
> **覆盖版本**：driver `v1.x`（RequiresRepublish 轮换路径自 v1.6.0 起；rotation/sync 标注见各章）（截至 2026-06-16）
> **基于源**：官方文档 `secrets-store-csi-driver.sigs.k8s.io` + kubernetes-sigs 仓库（逐条带 URL）
> **许可 / 治理**：Apache-2.0，kubernetes-sigs 项目（全 OSS，无 Enterprise edition）
> **不覆盖**：每个 provider（Vault/AWS/Azure/GCP/Akeyless/Conjur/OpenBao）的 provider-specific 配置；与 Connectors / ACP 的对比（见 `connectors-vs-secrets-store-csi-driver.md`）
> **未实测**：本指南未在集群实跑 demo，命令/YAML 均"未实测，基于官方文档"。

本文档**只讲 Secrets Store CSI Driver 自身**：它是什么、解决什么问题、基本抽象、哪些能力稳定 / 哪些 alpha。

---

## §0 心智模型 + 能力地图速览

**心智模型（3 行）**：Secrets Store CSI Driver 是一个 **CSI inline volume 驱动**，把外部 secret store（Vault / AWS / Azure / GCP …）里的**原始密钥/证书**通过 CSI 卷**挂进 Pod 的 tmpfs 文件系统**。它自身**不存 secret、不实现取数逻辑**——取数交给可插拔的 **provider**（各跑成 DaemonSet，通过 gRPC over Unix socket 被调用）。可选把挂载内容**同步成原生 K8s Secret**（可选、默认关闭，由 `syncSecret.enabled` 门控）、可选**自动轮换**（alpha）。

**一句话定位**：把外部 store 的明文 secret 当成卷挂进 Pod 的"通用 mount 适配层"。

**许可 / air-gap**：Apache-2.0、kubernetes-sigs（[LICENSE](https://github.com/kubernetes-sigs/secrets-store-csi-driver/blob/main/LICENSE)）。driver + provider 均为容器镜像，Helm Chart 部署，无 phone-home、无 license——**air-gap 友好**（前提：镜像与所选 provider 镜像离线可得；后端 secret store 自身的 air-gap 性取决于 store）。

### 能力地图速览（30 秒看全貌）

一行 = 一章。全部 OSS，无付费分表；用 `稳定 / alpha` 区分成熟度。

| § | 能力 | 解决什么问题 | 大致逻辑 | 成熟度 | 典型场景 |
|---|---|---|---|---|---|
| §1 | SecretProviderClass CRD | 声明"挂哪些 secret、用哪个 provider" | namespace 级 CR，driver 据此向 provider 取数 | 稳定 | 一个应用一份 SPC |
| §2 | Provider 模型 | 把"从哪个 store 取数"做成可插拔 | provider DaemonSet + gRPC over UDS | 稳定 | 接 Vault / AWS SM / Azure KV |
| §3 | tmpfs 卷挂载 | 把 secret 以文件形态喂进 Pod | CSI inline volume，mount 到容器路径 | 稳定 | 应用 `cat` 读密钥文件 |
| §4 | 同步成 K8s Secret | 让 `envFrom` / 镜像拉取等消费原生 Secret | `secretObjects` → 建/删原生 Secret | 可选（默认关） | env 注入 / imagePullSecret |
| §5 | 自动轮换 | 后端改了值传导到 Pod | RequiresRepublish + kubelet 周期重挂 | **alpha** | DB 密码轮换后刷新 |
| §6 | 部署模型 | driver 怎么落到集群 | driver DaemonSet（每节点）+ provider DaemonSet | 稳定 | Helm 装 kube-system |

### 反查索引：我想做 X → 看哪节

| 我想做的事 | 看哪节 |
|---|---|
| 声明一个应用要挂哪些 secret | §1 |
| 接 Vault / AWS / Azure / GCP 做后端 | §2 |
| 让 Pod 以文件方式读到 secret | §3 |
| 让 secret 变成原生 K8s Secret 给 `envFrom` 用 | §4（可选，默认关） |
| 后端改了密钥让 Pod 自动拿到新值 | §5（alpha） |
| 装这个 driver | §6 |

---

## §1 SecretProviderClass CRD（稳定）

**解决什么问题**：给"这个工作负载要挂哪些外部 secret、用哪个 provider、可选同步成哪个 K8s Secret"一个声明式、可随应用一起搬迁的载体。

**核心模型/原理**：`SecretProviderClass`（namespace 级 CR，apiGroup `secrets-store.csi.x-k8s.io/v1`）描述三件事：`provider`（哪个 provider 取数）、`parameters`（provider-specific 的"取哪些对象"）、可选 `secretObjects`（要不要同步成原生 K8s Secret，见 §4）。Pod 不直接引用 secret，而是引用一个 CSI inline volume，volume 的 `volumeAttributes.secretProviderClass` 指向这个 CR。

**核心能力**：
- 一个 CR 描述一组 secret 对象 + provider 选择 · namespace 隔离
- `parameters` 段是 provider 自定义 schema（driver 不解析其语义，透传给 provider）
- 可选 `secretObjects` 段（§4）开启同步成 K8s Secret
- 提供 pod portability（同一份 CR 可在不同集群/store 复用）

**最小命令示例**
> 未实测，基于官方文档 <https://secrets-store-csi-driver.sigs.k8s.io/getting-started/usage>
```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: my-provider
  namespace: app
spec:
  provider: vault            # akeyless / aws / azure / gcp / vault / conjur / openbao
  parameters:                # provider-specific，由 provider 解析
    # ...（取哪些 secret 对象）
```

**一句话本质**：声明"挂哪些外部 secret、走哪个 provider"的 namespace 级 CR。

---

## §2 Provider 模型（稳定）

**解决什么问题**：把"从哪个外部 store、用什么协议取数"这件事从 driver 解耦出去，让一个 driver 接多种 store。

**核心模型/原理**：driver 自身**不知道**怎么连 Vault / AWS / Azure——它只负责 CSI 卷生命周期，把"取数"委托给 **provider**。每个 provider 跑成**独立 DaemonSet**，与 driver 同节点，在 `/etc/kubernetes/secrets-store-csi-providers/<provider-name>.sock` 暴露 **Unix domain socket**；driver 用 **gRPC** 调它（[providers](https://github.com/kubernetes-sigs/secrets-store-csi-driver/blob/main/docs/book/src/providers.md)）。provider name 须匹配 `^[a-zA-Z0-9_-]{0,30}$`，与 SPC 的 `spec.provider` 对应。

**已知 provider**（官方列出，[providers](https://secrets-store-csi-driver.sigs.k8s.io/concepts)）：AWS、Azure、GCP、HashiCorp Vault、Akeyless、Conjur、OpenBao。官方文档称这 7 个均支持"同步成 K8s Secret"与"轮换"；仅 **Azure** 额外支持 Windows（AWS **不**支持 Windows），多数提供 Helm Chart 部署。

**核心能力**：
- gRPC over UDS 的 provider 接口（provider 实现 driver 提供的 stub）
- provider 与 driver 解耦、各自独立部署/升级
- 一个集群可同时装多个 provider，按 SPC `spec.provider` 路由

**最小命令示例**
> 未实测，基于官方文档 <https://github.com/kubernetes-sigs/secrets-store-csi-driver/blob/main/docs/book/src/providers.md>
```bash
# provider 以独立 DaemonSet 部署（以 Vault provider 为例），
# 在每个节点暴露 /etc/kubernetes/secrets-store-csi-providers/vault.sock
helm install vault hashicorp/vault \
  --set "csi.enabled=true"
```

**一句话本质**：driver 管卷、provider 管取数，二者 gRPC over UDS 解耦。

---

## §3 tmpfs 卷挂载（稳定）

**解决什么问题**：让应用以**读文件**的方式拿到外部 secret，而不把它写进 K8s Secret、不预埋进镜像。

**核心模型/原理**：这是 driver 的**主路径、唯一稳定能力**。Pod 声明一个 CSI inline volume（`driver: secrets-store.csi.k8s.io`、`readOnly: true`）；Pod 调度到节点 → kubelet 调 driver 的 `NodePublishVolume` → driver 按 `volumeAttributes.secretProviderClass` 找到 SPC → 经 gRPC 调对应 provider 取回 secret → driver 把内容写进**为该 Pod 准备的 tmpfs 卷**，mount 进容器指定路径。secret 以**文件**出现（一个对象一个文件），**驻留内存（tmpfs）不落盘**。

**处理流程（CR → 驱动 → Pod 全链路）**：
1. Pod spec 引用 CSI volume，`volumeAttributes.secretProviderClass: my-provider`。
2. Pod 调度到节点，kubelet 向 driver（该节点 DaemonSet pod）发 `NodePublishVolume`。
3. driver 读同 namespace 的 `SecretProviderClass` → gRPC 调 `spec.provider` 对应 provider socket，传 `parameters`。
4. provider 连后端 store 取回 secret，返回给 driver。
5. driver 写入该 Pod 专属 tmpfs，mount 到容器路径；容器内 `cat <mountPath>/<objectName>` 即读到**原始明文 secret**。

**最小命令示例**
> 未实测，基于官方文档 <https://secrets-store-csi-driver.sigs.k8s.io/getting-started/usage>
```yaml
# Pod 片段：挂载 SPC 指向的 secret 卷
volumes:
  - name: secrets-store-inline
    csi:
      driver: secrets-store.csi.k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: "my-provider"
# 容器 volumeMounts.mountPath 下出现一个对象一个文件
```

**一句话本质**：把外部 store 的明文 secret 以文件形态挂进 Pod 的 tmpfs。

---

## §4 同步成 K8s Secret（可选，默认关闭）

**解决什么问题**：有些消费方式（`envFrom`、imagePullSecret、第三方 controller）只认**原生 K8s Secret**，而 §3 的纯卷挂载不建 Secret 对象——本能力补这条路。

**核心模型/原理**：在 SPC 里加 `secretObjects` 段，声明把挂载内容里的哪些对象、映射成哪个 K8s Secret 的哪些 key。driver 在挂卷时**额外创建/更新一个原生 K8s `Secret`**（值 base64=明文）。**关键约束**：
- **必须先有卷挂载**——"The volume mount is required for the Sync With Kubernetes Secrets"；secret 只有在**有 Pod 挂载**后才同步（[sync-as-kubernetes-secret](https://secrets-store-csi-driver.sigs.k8s.io/topics/sync-as-kubernetes-secret)）。
- **消费 Pod 全删后，同步出的 K8s Secret 也被删**——"When all the pods consuming the secret are deleted, the Kubernetes secret is also deleted"（同源）。
- 此能力**可选、默认关闭**（由 `syncSecret.enabled` 门控），启用需在 driver 安装时开 `syncSecret.enabled`（Helm，默认 `false`，[values.yaml](https://github.com/kubernetes-sigs/secrets-store-csi-driver/blob/main/charts/secrets-store-csi-driver/values.yaml)）。它与轮换同在 v0.0.15 引入，但其官方页面**未**像轮换那样标注显式 `[alpha]` Feature State 横幅，亦无明确的 GA-promotion 横幅记载（[sync-as-kubernetes-secret](https://secrets-store-csi-driver.sigs.k8s.io/topics/sync-as-kubernetes-secret)）。

**最小命令示例**
> 未实测，基于官方文档 <https://secrets-store-csi-driver.sigs.k8s.io/topics/sync-as-kubernetes-secret>
```yaml
spec:
  provider: vault
  secretObjects:                 # [OPTIONAL] 同步成原生 K8s Secret
    - secretName: foosecret
      type: Opaque
      data:
        - objectName: secretalias  # 须对应 parameters 里挂载的对象
          key: username
```

**一句话本质**：把挂载内容额外落成原生 K8s Secret，可选、默认关闭（`syncSecret.enabled`），且生命周期绑定消费 Pod。

---

## §5 自动轮换（alpha）

**解决什么问题**：后端 store 里的 secret 改了，让已挂载的 Pod / 同步出的 K8s Secret 拿到新值，无需重建 Pod。

**核心模型/原理**：driver **不是**靠独立 controller 主动 watch 后端，而是复用 **kubelet 的 CSI `RequiresRepublish` 周期重挂**机制（自 driver v1.6.0；早期为独立 rotation reconciler）。kubelet 周期性对已挂卷发 republish 调用，driver **仅当 `--enable-secret-rotation=true` 时**才在这些调用里**重新向 provider 取数**并更新 tmpfs 与（若配了）同步的 K8s Secret（[secret-auto-rotation](https://secrets-store-csi-driver.sigs.k8s.io/topics/secret-auto-rotation)）。

**处理流程（轮换如何传导到运行中 Pod）**：
1. driver 安装时设 `--enable-secret-rotation=true`（Helm `enableSecretRotation: true`）。
2. kubelet 按 `requiresRepublish` 周期对已挂卷发 republish。
3. 每次 republish，driver 重新 gRPC 调 provider 取最新值（受 `--rotation-poll-interval` 节流，默认 `2m`，为两次取数之间的最小缓存周期）。
4. driver 更新该 Pod 的 tmpfs 文件；若 SPC 配了 `secretObjects`，同步更新对应 K8s Secret。
5. 应用需自行感知文件/Secret 变化（driver **不重启 Pod**）；env 注入的值通常需 Pod 重启才生效，故官方建议轮换场景配合"挂载文件 + 同步 Secret + 应用 watch 文件变化"。

**关键边界**：
- alpha 能力，"as of v0.0.15" 文档仍标 alpha（[secret-auto-rotation](https://secrets-store-csi-driver.sigs.k8s.io/topics/secret-auto-rotation)）。
- 单设 `requiresRepublish: true` **不**等于开启轮换——"the driver ignores republish calls for already-mounted volumes unless `--enable-secret-rotation=true` is set"（同源）。
- 它是**重新拉取并重挂**，不是"动态凭据/现造"——值新旧取决于后端 store 自己有没有轮换/换值。

**最小命令示例**
> 未实测，基于官方文档 <https://secrets-store-csi-driver.sigs.k8s.io/topics/secret-auto-rotation>
```bash
helm upgrade -n kube-system csi-secrets-store \
  secrets-store-csi-driver/secrets-store-csi-driver \
  --set enableSecretRotation=true \
  --set rotationPollInterval=3600s
```

**一句话本质**：靠 kubelet 周期重挂重新取数刷新 tmpfs/Secret，alpha，不重启 Pod。

---

## §6 部署模型（稳定）

**解决什么问题**：driver 要在每个节点拦 CSI 卷请求，必须节点级常驻。

**核心模型/原理**：driver 以 **DaemonSet** 部署（典型 `kube-system`），每节点一个 pod 注册为 CSI 驱动 `secrets-store.csi.k8s.io`；**每个 provider 也各跑一个 DaemonSet**（§2），与 driver 同节点通过 UDS 通信。Helm Chart 是官方部署方式。

**核心能力**：
- driver DaemonSet（每节点）+ N 个 provider DaemonSet
- Helm Chart 安装 / 升级；rotation、syncSecret 等 alpha 能力靠安装期 flag/values 开关
- Linux + Windows（部分 provider）

**最小命令示例**
> 未实测，基于官方文档 <https://secrets-store-csi-driver.sigs.k8s.io/getting-started/installation>
```bash
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi-secrets-store \
  secrets-store-csi-driver/secrets-store-csi-driver -n kube-system
```

**一句话本质**：driver 与各 provider 均为节点级 DaemonSet，Helm 部署。

---

## §7 OSS 能力组合回顾 + 边界

driver 全 OSS（Apache-2.0），无付费分级。**稳定**能力：SecretProviderClass、provider 模型、tmpfs 卷挂载、DaemonSet 部署。**可选 / off-by-default**：同步成 K8s Secret（`syncSecret.enabled`，默认 `false`；与轮换同在 v0.0.15 引入，但官方页面无显式 `[alpha]` 横幅、亦无 GA-promotion 横幅记载）。**alpha**能力：自动轮换（官方页面带 `[alpha]` Feature State 横幅）——生产用前须确认成熟度并固定版本。

**边界（这个 driver 不做的事）**：
- **不存 secret、不实现取数**——后端 store + provider 才是 secret 来源；driver 只是"挂载适配层"。
- **不做动态凭据/现造**——只挂"store 里已有的值"，轮换=重新拉取，不会现造账号。
- **不做代理/出栈注入**——secret 原文进 Pod 文件系统，应用直接持有明文。
- **不做审批/门控/审计**（driver 层面）——这些靠后端 store 与 K8s RBAC。
- **不管 Pod 重启**——轮换后值变了，应用要自己 reload。

---

## §8 许可 / air-gap 边界

- **许可**：Apache-2.0，kubernetes-sigs（[LICENSE](https://github.com/kubernetes-sigs/secrets-store-csi-driver/blob/main/LICENSE)）。无 Enterprise edition、无 license 校验、无 phone-home。
- **provider 许可各异**：driver 本体 Apache-2.0，但各 provider（AWS/Azure/GCP/Vault/…）由各自厂商/社区维护，许可与发布渠道独立（未逐一核实 →（未确认））。
- **air-gap**：driver + provider 均为镜像 + Helm，可离线部署；后端 store（Vault/云 SM）自身的 air-gap 性独立于本 driver——云托管 SM（AWS SM/Azure KV/GCP SM）在 air-gap 下不可达，仅 Vault/OpenBao 等可自托管 provider 适配 air-gap。

---

**相关文档**：`connectors-vs-secrets-store-csi-driver.md`（与 Connectors 的对比 + 边界 + roadmap 启发）。
