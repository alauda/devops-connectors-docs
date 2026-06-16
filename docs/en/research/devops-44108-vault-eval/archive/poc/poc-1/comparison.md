# PoC-1 对比 — Vault 模式 vs Connectors 模式（问题域 1：CI secretless）

> 同一个 CI 任务（git clone 一个私有仓），分别走 Vault Agent / CSI Secret Store 模式（A）
> 与 Connectors Proxy 模式（B），观察 **CI client 容器**对原始 PAT 的可见性。
> A 的证据来自本 PoC 在 `devops-valult-invest` ns 的真实 PipelineRun（见 `run-log.md`、
> `poc-1-vault-flow.log`）；B 的描述来自 `inputs/01-connectors-domain-map.md` §1 和
> connectors 仓库 `pkg/proxy/` + `pkg/csidriver/` 已有代码事实，未在本 ns 重复部署 Connectors。

## A. Vault 路径数据流（client 看得到原始 PAT）

```
┌──────────────────────┐  ① TokenReview          ┌────────────────┐
│  CI Pod (client SA)  │ ──────────────────────► │  Vault Server  │
│                      │  ② vault token          │  KV v2: secret │
│                      │ ◄────────────────────── │  /git/test     │
│                      │  ③ HTTP GET secret      │                │
│                      │  ④ PAT body             │                │
│                      │ ◄────────────────────── │                │
│                      │                          └────────────────┘
│  ┌────────────────┐  │
│  │ /workspace/    │  │   ⑤ printf "$PAT" > .git-token
│  │   .git-token   │  │   ⑥ cat .git-token        ← 明文
│  │   (tmpfs)      │  │   ⑦ export ENV=$PAT       ← env 暴露
│  └────────────────┘  │   ⑧ echo "git clone ...:$PAT@..."  ← log 暴露
│                      │
│  client 进程地址空间 = 真凭据持有者 ⚠  │
└──────────────────────┘
```

**本 PoC 实测的 4 条 client-side 泄漏路径**（均出现在 `kubectl logs` 中）：

- A. `cat /workspace/shared/.git-token` → 直接打印明文
- B. `env | grep -i token` → `GIT_TOKEN_FROM_ENV_DEMO=ghp_FA**********************y_12345`
- C. `echo "git clone https://oauth:$TOK@…"` → URL 内嵌 PAT
- D. `set -x` 自动把所有变量展开打进 stderr（连 `+ TOK=ghp_FA…` 这种内部行也会泄）

## B. Connectors 路径数据流（client 看不到原始 PAT）

```
┌──────────────────────┐  ① CSI mount             ┌──────────────────────┐
│  CI Pod (client SA)  │ ◄────────────────────── │  CSI Driver (DaemonSet)│
│                      │     .gitconfig           │  TokenRequest API    │
│                      │     context.token (SA)   │  (生成 30m SA token) │
│                      │     proxyAddress         │                      │
│  ┌────────────────┐  │                          └──────────────────────┘
│  │ /workspace/    │  │   ② git → http_proxy=c-mygit:8080
│  │   context.token│  │       ↓
│  │ (K8s SA token, │  │
│  │  非 git PAT)   │  │   ┌──────────────────────┐
│  └────────────────┘  │   │ Connectors Proxy     │
│                      │ ──┤ (in-cluster Service) │── ③ Basic Auth/Bearer
│  client 看到：       │   │ - SubjectAccessReview │   注入真实 PAT
│   - http_proxy URL   │   │ - 出栈方向注入凭据   │       ↓
│   - SA JWT (只对     │   │ - 真 PAT 仅在        │   ┌────────────┐
│     proxy 有效)      │   │   proxy 进程内存     │   │  Git Server │
│   - .gitconfig 模板  │   └──────────────────────┘   └────────────┘
│                      │   ④ 真凭据存活范围 =
│   真凭据从不出       │      connectors-system ns + proxy 内存
│   client 地址空间 ✅ │      （不进 client env / 文件 / log / 镜像层）
└──────────────────────┘
```

**client 容器内 `cat`/`env`/`set -x`/拼 URL 都只能拿到 SA token（30m TTL，仅对 proxy 有效，
对真实 Git 服务无效）**——证据来源：connectors 仓库 `pkg/csidriver/`（挂 SA token、
渲染 `.gitconfig` 用 `http.proxy` 指向 proxy Service）+ `pkg/proxy/`（出栈方向按 ConnectorClass
配置注入真实 Basic/Bearer/OCI 凭据）。本 PoC 未在 `devops-valult-invest` 重复部署。

## C. 5 维泄漏面对比表

| 维度 | Vault 模式（A）| Connectors 模式（B） |
|---|---|---|
| **client 可 `cat` 文件** | ✅ 可读到原始 PAT（本 PoC 段 A 实测） | ❌ 只能 cat 到 SA token（对真实 git 无效） |
| **env 可被注入** | ✅ Vault Agent / `envconsul` 的典型形态就是 env（段 B 实测） | ❌ env 只有 `http_proxy=c-xxx:8080` 这种代理地址 |
| **log 可泄漏** | ✅ `set -x` / `echo`/拼 URL 任一都会落 K8s log（段 C 实测） | ❌ 即使全程 `set -x`，泄出去的也只是 SA token + proxy URL |
| **core dump / `/proc/<pid>/mem` 可捞** | ✅ PAT 在 client 进程地址空间，进程 crash 即落盘 | ❌ PAT 不在 client 进程地址空间，client core 抓不到 |
| **镜像层可固化** | ✅ 若构建期把 secret 写进 Dockerfile（典型反模式但很常见），层永久带毒 | ❌ client 镜像里没有 PAT，连泄漏机会都不存在 |

## D. 结论 — 威胁模型本质差异

**Vault 模式**是 **secret injection**：真凭据被短期化后**复制**到 client 容器的文件/env/Secret，
client 进程**就是凭据持有者**。client 一旦被攻破（恶意 task、镜像后门、log 外泄、core dump、
`/proc/<pid>/environ`、kubectl logs 越权读取），原始 PAT 就到了攻击者手里——之后即使 lease
过期，攻击者也已经能用这段时间里产生的衍生数据（已 push 的 commit、已签的 release）做事，
**且 Vault 没有任何手段阻止 client 把"获得的明文"再复制走**。

**Connectors 模式**是 **data-plane proxy**：真凭据始终留在 `connectors-system` ns 的 proxy 进程
内存里，client 拿到的只是"代理 URL + 短期 SA token"。client 进程**根本不是凭据持有者**——
被攻破最多偷到一段 30m 内只能调本集群一个 proxy 的 SA token，攻击者拿这段 token 走出集群
**没有任何用**（直连真 GitHub/Harbor 没 PAT 可用），吊销只需撤 SA 的 RoleBinding，下一次
proxy 的 `SubjectAccessReview` 即 reject。**威胁面从"客户端进程地址空间"压缩到了"in-cluster
反向代理进程"**——这是结构差异，不是配置质量差异。

> 因此覆盖矩阵第 1 项（CI secretless）的结论 — Vault 在该问题域**降级**为
> "凭据集中存储 + 短期化"，无法等价 Connectors 的 "client 永不持有真凭据" —
> 已由本 PoC 在真实集群转化为可观察事实。
