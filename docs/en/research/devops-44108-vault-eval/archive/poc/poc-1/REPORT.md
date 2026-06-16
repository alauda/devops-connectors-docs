# PoC-1 报告 — Vault 模式 client 可见原始 PAT 的可观测演示

> 主报告引用入口：覆盖矩阵第 1 项「CI secretless」的实证。
> 完整材料：`task.yaml`、`run-log.md`、`comparison.md`、`poc-1-vault-flow.log`。

## 0. PoC-1 边界声明（必读）

本 PoC step 1 故意模拟 **Vault Agent 常见 file-based injection 模式**——Vault 公开文档中主要 reference 模式之一（file sink + env injection），也是 Vault 中低水平用户最常见的用法。**这不主张 Vault 强制要求此用法**。

Vault 高级模式可显著缩窄或消除 client 持有明文 token 的窗口：

- **Vault Agent Proxy mode (auto-auth + caching proxy)**：Agent 在 sidecar 起 listener，应用通过 `localhost:8100` 调任意 Vault API，Agent 自动加 token，应用代码里看不到 token。**这与 Connectors proxy 哲学同形**。
- **Vault Agent `exec` mode**：Agent 把 token 注入子进程 stdin / 命令行参数，子进程退出立即 lease revoke；token 不落 emptyDir、不进 env、不进 K8s Secret。
- **Vault Agent + Response Wrapping (cubbyhole)**：Agent 只给一次性 wrapping token。
- **SSH CA short-lived cert / GitHub App installation token**：上层方案，让 PAT 根本不进 client。

**本 PoC 下述 4 条暴露路径不代表 "Vault 必然暴露"**，而是 "如果客户工程团队选 file/env sink 模式（行业实践中常见），则 Vault 路径在 client 端比 Connectors 模式有更宽的暴露面"。下一轮调研应补 **PoC-1b**：用 Vault Agent proxy mode + 一段不触碰 token 的 git client，演示 "Vault 路径下 client 容器内 grep 不到 PAT" 的反例，让最终结论变成 "两种用法的并列对照"。

即便使用更严格的 Vault 模式，client 进程仍然在某种形式上"持有过"凭据（即便是窗口压到秒级），与 Connectors data-plane proxy 模式 **client 完全不接触真凭据** 仍有结构差异；但 Vault 高级模式可以**缩小部分暴露面**（特别是文件落盘 / env / log 几条）。

## 1. 实验设计

在 `devops-valult-invest` ns 用一段真实 Tekton `Task` 跑通 Vault Kubernetes Auth Method
端到端拉密链路，模拟"CI client 拿 Vault secret 后做事"，在同一 Pod 内观测原始 PAT
在 client 进程地址空间的 4 类暴露。Connectors 路径不在本 ns 重复部署，以代码事实
（connectors `pkg/csidriver/` + `pkg/proxy/`）和 inputs 的业务域映射为对照。

- **Vault 准备**：Service `vault.devops-valult-invest:8200`、KV v2、写入
  `secret/git/test` => `token=ghp_FA**********************y_12345`（无意义假 PAT）。
- **Auth**：Kubernetes Auth Method + role `git-reader` 绑定 ns `devops-valult-invest` /
  SA `default`，policy 仅允许读 `secret/data/git/*`。
- **Task** `poc-vault-secretless` 两步：(1) `fetch-from-vault`（vault 镜像）用 Pod SA
  projected token 调 `auth/kubernetes/login` 拿 vault client_token，再 HTTP GET
  `secret/data/git/test` 把 PAT 落到 workspace 文件；(2) `use-token`（alpine 镜像）模拟
  client，按 4 条路径触达明文 PAT。
- **PipelineRun**：default SA + emptyDir workspace，单次运行约 15s 完成。

## 2. 集群验证证据

PipelineRun 状态 = `Succeeded`，原始 log 见 `poc-1-vault-flow.log`。关键段（token 已马赛克）：

```text
[fetch-from-vault] got vault client_token length=95     # TokenReview -> vault token 换发成功
[fetch-from-vault] 4) 把 PAT 物化到 workspace 文件
-rw-------    1 root  65532  32 /workspace/shared/.git-token

A. cat /workspace/shared/.git-token  -> ghp_FA**********************y_12345
B. env | grep -i token              -> GIT_TOKEN_FROM_ENV_DEMO=ghp_FA**********************y_12345
C. echo "git clone https://oauth:$TOK@..."
                                    -> 完整 URL 含 PAT 落到 Pod stdout（kubectl logs 可读）
D. `set -x` 自动展开                 -> + TOK=ghp_FA**********************y_12345
                                       + export 'GIT_TOKEN_FROM_ENV_DEMO=ghp_FA...y_12345'
```

任意持 `kubectl logs` 权限的人都能复核：

```bash
kubectl -n devops-valult-invest logs poc-vault-secretless-run-demo-pod \
  -c step-use-token | grep ghp_
```

## 3. 对比结论（5 维 × 2 路径）

| 维度 | Vault 模式 | Connectors 模式 |
|---|---|---|
| client 可 `cat` 文件 | 是（本 PoC 实测原 PAT） | 否（只能 cat 到 SA token，对真实 git 无效） |
| env 可被注入 | 是（Vault Agent 典型形态，实测） | 否（env 只有 proxy URL） |
| log 可泄漏 | 是（`set -x`/`echo`/拼 URL 任一即泄，实测） | 否（泄出去的也只是 SA token） |
| core dump / `/proc/.../mem` | 是（PAT 在 client 地址空间，crash 即落盘） | 否（PAT 不在 client 地址空间） |
| 镜像层可固化 | 是（构建期反模式即永久落层） | 否（镜像里根本没有 PAT） |

数据流对比 ASCII 图见 `comparison.md` A/B 节。

## 4. 威胁模型本质差异（避免绝对化）

- **Vault file/env sink 模式（本 PoC）** = secret injection：真凭据被短期化后**复制**进 client 容器，client 进程**就是凭据持有者**。被攻破（恶意 task / 镜像后门 / log 外泄 / core dump / `kubectl logs` 越权）原始 PAT 即落入攻击者手中。
- **Vault Agent proxy / exec / response wrapping / SSH CA / GitHub App 等高级模式**：可显著缩窄甚至消除 client 持有明文窗口；但仍要 client 信任 Agent sidecar 并承担其复杂度。**本 PoC 未对照实测**，需 PoC-1b 补。
- **Connectors** = data-plane proxy：真凭据始终留在 `connectors-system` ns 的 proxy 进程内存，client 仅持"代理 URL + 30m TTL 的 SA token"，**根本不是凭据持有者**。被攻破最多拿到一段对本集群一个 proxy 有效的 SA token，直连真 Git/Harbor 无效；吊销 = 撤 RoleBinding，下一次 SubjectAccessReview 即拒。
- **反向 attack surface（诚实承认）**：Connectors 模式下 proxy 进程被攻破时所有客户的真凭据集中失陷；Vault dynamic 模式下凭据分散到每个 client 但每个独立。两种威胁模型各有适用场景。

威胁面核心差异 = **"凭据进入 client 进程地址空间后约束权移交"** vs **"in-cluster 反向代理进程持有凭据"** — 是结构选择，不是配置质量。

## 5. 对覆盖矩阵第 1 项的回扣

主报告 `REPORT.md` 在「问题域 1：CI secretless」一栏的结论 — **Vault file/env sink 模式下凭据进入 client 后约束权从凭据系统移交给 client 应用层；Connectors 模式 client 完全不接触真凭据** — 至此从结构论证升级为可观测演示：同一 ns 内任意有 `kubectl logs` 权限的角色，都能直接看到 Vault file/env sink 模式下泄出的原始假 PAT；Connectors 路径下即使用同样的 `cat`/`env`/`set -x` 手法，client 也只能看到对真实工具无效的 SA token。

PoC-1b（Vault Agent proxy mode 对照组）下一轮补，完成 "两种用法的并列对照"。
