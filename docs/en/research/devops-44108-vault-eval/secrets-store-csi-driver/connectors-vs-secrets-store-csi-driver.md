# Connectors vs Secrets Store CSI Driver — 关系、边界、Roadmap 启发

> **结论摘要**：两者都用 **CSI 卷把东西挂进 Pod**，但挂的"东西"根本不同——这是最尖锐的分水岭。
> **Secrets Store CSI Driver 挂的是 RAW secret material**（从外部 store 取回的明文密钥/证书，原样落进 Pod 的 tmpfs 文件）；**Connectors 的 CSI 挂的是 RENDERED 工具配置**（`.gitconfig` / `glab config` / `settings.xml` 之类模板 + 短期 SA token + 集群内 Proxy 地址）——**真凭据从不进 Pod**，Pod 看到的只是"指向 Proxy 的配置"，真凭据由 Proxy 在出栈方向注入。一句话：**injection 模型 vs secretless-proxy 模型**。
> **基于源**：`secrets-store-csi-driver-capabilities-guide.md` + 官方文档 URL
> **覆盖范围**：全 OSS（Apache-2.0，kubernetes-sigs）
> **不覆盖**：各 provider 的具体配置；Connectors 完整 11 问题域（仅取重合的几域，见 §2）

---

## §1 Connectors 问题域（仅列与本对比相关的几域）

| 问题域 | Connectors 的解法 | 体验 |
|---|---|---|
| CI Secretless | Proxy 在 `connectors-system` 持真凭据；CSI 用 Pod SA 签短 token（默认 30m），挂面向工具的**渲染配置文件**（`.gitconfig` / `settings.xml`）+ Proxy 地址；出栈方向工具层认证注入 | 业务进程当普通配置读，**真凭据不进 Pod** |
| K8S 镜像无凭据拉取 | OCI/Harbor reverse proxy + `PodWebhook` 改写 image 到 proxy 地址；kubelet 走 proxy 拉镜像 | Pod 加 annotation，无 imagePullSecret |
| 凭据短期化/吊销 | 客户端只拿短期 SA token；吊销=撤 RBAC（每请求 SubjectAccessReview），非等 lease 过期 | 客户端零感知 |

**Connectors 边界**：不是通用 KV / secret store；不存 secret；不取代外部 store。

---

## §2 Secrets Store CSI Driver vs Connectors 能力对比

> 重合面很窄——只在 Connectors 问题域 2（K8s 镜像拉取，部分）、7（凭据短期化，部分）、以及二者共用的 **CSI 挂载通道**这一机制点上交叠。

### §2.1 在 Connectors 问题域内的对比

| 问题域 | Connectors 解法 | Secrets Store CSI Driver 解法 | 关键差异 |
|---|---|---|---|
| **CSI 挂载内容**（核心分水岭） | 挂**渲染后的工具配置**（模板 + 短期 SA token + Proxy 地址），真凭据不进 Pod | 挂**外部 store 的原始明文 secret** 到 tmpfs 文件 | injection：Pod 拿到真 secret 明文 `cat` 可见 vs secretless：Pod 只拿到"指向 Proxy 的配置" |
| **CI Secretless** | data-plane proxy，client 看不到真凭据 | 把真凭据原文挂进 Pod 文件（明文）；应用直接持有 | **仅 Connectors 真 secretless**；CSI Driver 是 secret-injection |
| **K8s 镜像无凭据拉取** | `PodWebhook` 改 image + 透明走 proxy 拉 | 可同步成 K8s Secret 当 imagePullSecret（可选，默认关，`syncSecret.enabled`），但 **Pod/SA 仍须引用**、无 image-rewrite | **仅 Connectors 透明**；CSI Driver 仅"投递 Secret" |
| **凭据短期化/吊销** | 客户端短期 SA token；吊销=撤 RBAC，秒级 | 轮换=kubelet 周期重挂重新取数（alpha），值新旧取决于后端 store；无主动吊销已发明文 | Connectors 吊销作用于"使用权限"；CSI Driver 只能等下次重挂刷新 |

**哲学差异（散文点明）**：Secrets Store CSI Driver 的 CSI 卷是 **secret-injection 的一种载体**——把外部 store 的明文 secret 搬进 Pod，应用此后**直接持有真凭据**（`cat` 文件 / core dump 可见）。Connectors 的 CSI 卷虽是**同一个 K8s 机制（CSI inline volume）**，挂的却是**渲染后的工具配置 + 短期 SA token + Proxy 地址**——真凭据始终死守在 `connectors-system` 的 Proxy 内存，由 Proxy 在出栈请求时注入。**同一通道、相反范式**：一个把真凭据送进 Pod，一个让真凭据永远到不了 Pod。

### §2.2 不在 Connectors 问题域内的 Secrets Store CSI Driver 能力

| CSI Driver 能力 | 在 Connectors 问题域之外的原因 | Connectors 如何旁路/集成 |
|---|---|---|
| 通用 secret 挂载（任意 KV/证书） | Connectors 只代理"外部工具"协议，不做通用 secret 卷 | 客户用 CSI Driver 挂通用 secret 不影响 Connectors |
| 接多种外部 store 的 provider 模型 | Connectors 不做 store 抽象（凭据来源固定为 K8s Secret） | 可作 Connectors `SecretBackend` 演进的参照（见 §3） |
| 同步成任意 K8s Secret | Connectors 不把真凭据落成 Secret 给业务 | 业务自需通用 Secret 时各自接 CSI Driver |

---

## §3 集成方向与 Roadmap 启发

**思路方向，不写实施草案。**

**自然边界**
- CSI Driver 不替代 Connectors：它把真凭据搬进 Pod（injection），结构上做不到 CI secretless / 透明镜像拉取 / 工具透传 API / Pipeline UI 选资源 / 运行时按调用审批。
- Connectors 不替代 CSI Driver：通用 secret 卷挂载、接多种外部 store 的 provider 模型，不在 Connectors 问题域。

**核心思路**
> **CSI Driver 解决"外部 store 的明文 secret 怎么进 Pod"，Connectors 解决"真凭据怎么永远不进 Pod"。** 二者用的是同一个 K8s CSI 机制，差别全在"挂什么"。这正是对外讲清 Connectors 差异化最好的对照物——因为机制相同，差异不能被归因于"技术不同"，只能归因于"范式不同"。

### 集成方向

**方向 1：把 CSI Driver 的 provider 模型作为 Connectors `SecretBackend` 抽象的参照**
- CSI Driver 用 gRPC over UDS 的 provider DaemonSet 解耦"从哪个 store 取数"——这是一个成熟、社区验证的 store 解耦形态。
- Connectors 若引入 `SecretBackend` 抽象（默认 K8s Secret，可选 Vault/OpenBao/云 SM），可借鉴其 provider 接口分层；但 Connectors 取数发生在**控制面 Proxy 内存**，不是节点侧 driver——形态借鉴，落点不同。
- **定位**：架构参照，不是直接复用代码。

**方向 2：明确"同一 CSI 通道、相反范式"作为对外定位锚点**
- 客户极易把"Connectors 也有 CSI driver"误读为"和 Secrets Store CSI Driver 同类"。需准备话术：**通道相同（CSI inline volume），内容相反（渲染配置+短 token vs 原始明文 secret）**。
- 这是销售/SE 最易混淆的点，值得做成一张"挂载内容对照图"。

### 🟡 待审视：轮换/刷新机制对位
- **重合点**：CSI Driver 有 alpha 轮换（kubelet 周期重挂重新取数）；Connectors 有"热轮换不断流"（短期 SA token TTL + 请求级注入）。
- **差异面**：CSI Driver 轮换刷新的是**已投递给 Pod 的明文**（仍在 Pod 内）；Connectors 刷新的是**短期 token / 出栈注入**，真凭据始终不在 Pod。
- **未决问题**：无需借鉴——范式不同，Connectors 的请求级注入在"不重启 Pod、客户端零感知"上已结构性更优。
- **结论**：**待审视后再下定论**，倾向不引入 injection 式轮换。

---

## §4 哲学差异（1 段散文）

> **Secrets Store CSI Driver 的哲学**是"把外部 store 的明文 secret 通过标准 CSI 卷挂进 Pod，应用直接读文件"——它是 secret-injection 在 CSI 通道上的实现，真凭据进入 Pod 地址空间。**Connectors 的哲学**是"业务进程永不持有真凭据，CSI 卷里只有指向集群内 Proxy 的渲染配置 + 短期身份，Proxy 在数据平面做认证注入"。两者**复用同一个 K8s CSI 机制**，却是**相反的范式**——这恰恰让二者成为彼此最干净的对照：不是替代关系，是"真凭据进 Pod"与"真凭据不进 Pod"两条路。

---

**相关文档**
- `secrets-store-csi-driver-capabilities-guide.md` — driver 自身能力（能力地图 + 5 段式 + provider 模型 + alpha 边界）
- （同环 ③ 参考）`../infisical/connectors-vs-infisical.md`、`../connectors-vs-vault.md` — 同为"injection vs proxy"分水岭的对照
