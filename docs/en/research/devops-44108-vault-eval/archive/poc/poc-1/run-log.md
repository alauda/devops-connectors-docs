# PoC-1 执行日志 — Vault 模式 client 可见原始 PAT 演示

> 集群：默认 ACP 集群 / Namespace：`devops-valult-invest`（仅在此 ns 操作）
> 完整测试材料：`task.yaml`、原始日志 `poc-1-vault-flow.log`、对比文档 `comparison.md`
> 所有 token 在文档里均**马赛克**（保留首 6 + 末 6），原始 PAT 是无意义假 PAT，仅用于威胁演示。

## 1. 前置环境（已存在，作为输入）

```bash
# Vault Service
kubectl -n devops-valult-invest get svc vault
# vault   ClusterIP   10.4.227.232   <none>   8200/TCP

# 真实 PAT 写入 Vault（用 root token 一次性写入；实际值 = "ghp_FA...y_12345"）
kubectl -n devops-valult-invest exec deploy/vault -- sh -c \
  'VAULT_TOKEN=root vault kv put secret/git/test token=ghp_FAxxxxxxxxxxxxxxxxxxxxxxy_12345'

# Kubernetes Auth Method + git-reader role + git-reader policy 已 enable
# 绑定 SA: devops-valult-invest/default
kubectl -n devops-valult-invest exec deploy/vault -- sh -c \
  'VAULT_TOKEN=root vault read auth/kubernetes/role/git-reader'
# policies = [git-reader]
# bound_service_account_names = [default]
# bound_service_account_namespaces = [devops-valult-invest]
```

## 2. 部署并运行 Tekton Task

```bash
kubectl apply -f task.yaml
# task.tekton.dev/poc-vault-secretless created
# pipelinerun.tekton.dev/poc-vault-secretless-run created

# 等待完成（约 15s）
kubectl -n devops-valult-invest get pipelinerun poc-vault-secretless-run \
  -o jsonpath='{.status.conditions[0].reason}'
# Succeeded
```

## 3. 关键日志摘录（token 已马赛克）

### Step 1 — `step-fetch-from-vault`

```text
[fetch-from-vault] 1) 读取 Pod 自己的 SA projected token
  SA token length=1198
[fetch-from-vault] 2) 调 auth/kubernetes/login 换 vault client_token
  got vault client_token length=95           ← TokenReview → client_token 换发成功
[fetch-from-vault] 3) 直接 HTTP GET 读 secret/data/git/test 拿真实 PAT
[fetch-from-vault] 4) 把 PAT 物化到 workspace 文件（Vault 模式必经动作）
-rw-------    1 root     65532    32 /workspace/shared/.git-token     ← 真凭据落盘
[fetch-from-vault] done. token bytes written: 32
```

### Step 2 — `step-use-token`（模拟 CI client 容器）

> **以下 4 个证据轴说明：原始 PAT 在 client 容器内对 cat / env / argv 全可见。**

```text
===== [use-token] A. cat 文件即得明文 PAT =====
ghp_FA**********************y_12345          ← 文件读取路径（最直观泄漏）

===== [use-token] B. env 注入路径（Vault Agent 典型用法）=====
GIT_TOKEN_FROM_ENV_DEMO=ghp_FA**********************y_12345   ← env 路径

===== [use-token] C. 拼 URL（真实泄漏到 process args / 日志）=====
git clone https://oauth:ghp_FA**********************y_12345@gitea.example.com/foo/bar.git
                                                            ↑ 写进 Pod stdout 落到 K8s 日志
+ TOK=ghp_FA**********************y_12345                   ← `set -x` 把所有展开打入 stderr

===== [use-token] 结论: Vault 模式下 client 容器对原始 PAT 完全可见 =====
```

## 4. 直接抓 K8s log 复核（任意有 `kubectl logs` 权限的人都能看到）

```bash
POD=$(kubectl -n devops-valult-invest get tr poc-vault-secretless-run-demo \
       -o jsonpath='{.status.podName}')
kubectl -n devops-valult-invest logs $POD -c step-use-token | grep ghp_
# ghp_FA**********************y_12345                            ← A
# GIT_TOKEN_FROM_ENV_DEMO=ghp_FA**********************y_12345    ← B
# git clone https://oauth:ghp_FA**********************y_12345@…  ← C
# + TOK=ghp_FA**********************y_12345                      ← set -x
# + export 'GIT_TOKEN_FROM_ENV_DEMO=ghp_FA**********************y_12345'
```

## 5. 泄漏面盘点（这一次单次 PipelineRun 实测）

| 泄漏面 | 已观测到？ | 说明 |
|---|---|---|
| Workspace 文件（emptyDir tmpfs） | YES | `/workspace/shared/.git-token` 32 字节明文 |
| 进程 env | YES | `env | grep -i token` 直接打印出来 |
| Pod stdout/stderr → kube-apiserver log | YES | `kubectl logs` 完整可读，含 set -x trace |
| Pod argv / `/proc/<pid>/cmdline` | 可达 | C 段拼 URL 后若被 exec/curl，argv 即含 token |
| 容器镜像层 | 此实验未涉及 | `RUN echo $PAT > /etc/git-token` 类构建期注入会落进 image layer，是典型 Vault Agent 用法的子风险 |

## 6. 一句话结论

> Vault 模式必须把 PAT **物化进 client 容器**（文件 / env / K8s Secret），
> client 进程地址空间内任何 `cat`/`env`/`set -x`/拼 URL/被 exec 的命令
> 都能看到原始凭据，**这是结构性事实，不是配置失当**。
