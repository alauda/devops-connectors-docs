# Vault PoC 部署日志 (devops-44108-vault-eval)

> 目标集群：`https://jtcheng-bdrjq-bwrsq--idp.alaudatech.net/kubernetes/global/`
> 命名空间：`devops-valult-invest`（**注意拼写 valult**，已存在）
> 用途：为 devops-44108 的 3 个 PoC 提供共享的 dev 模式 Vault

## 0. 关键信息（先看这里）

| 项目 | 值 |
|------|----|
| Vault 镜像 | `hub-mirrors.alauda.cn/hashicorp/vault:1.19.5`（免认证 mirror） |
| 部署形态 | `Deployment` (replicas=1, Recreate) + `Service` (ClusterIP) |
| Service ClusterIP | `10.4.227.232:8200` |
| Service DNS | `vault.devops-valult-invest.svc:8200` |
| Vault 模式 | `server -dev`（in-memory storage、自动 unseal） |
| Root token | `root` |
| Kubernetes auth path | `kubernetes/`（即 `auth/kubernetes/...`） |
| 已创建策略 | `git-reader`（read `secret/data/git/*`） |
| 已创建角色 | `git-reader` → 绑定 SA `devops-valult-invest/default`，token TTL 1h |
| 已创建测试 secret | `secret/git/test` → `token=dummy-pat-12345` |
| git-reader policy 验证 | **PASS**（从单独 Pod 用 default SA token 走 K8s auth 拿到 vault token，读到 secret/git/test；越权读 secret/test 返回 403） |

## 1. 部署 Vault dev 模式

manifest 文件：`./00-vault-deploy.yaml`

```bash
kubectl apply -f /home/ubuntu/jtcheng/code/src/github.com/AlaudaDevops/connectors-operator/.worktrees/devops-44108-vault-eval/research/devops-44108-vault-eval/poc/00-vault-deploy.yaml
```

输出：
```
serviceaccount/vault created
clusterrolebinding.rbac.authorization.k8s.io/vault-auth-delegator-devops-valult-invest created
service/vault created
deployment.apps/vault created
```

manifest 内容要点：

- `ServiceAccount vault`：Vault 自身使用；通过 `ClusterRoleBinding` 绑定 `system:auth-delegator`（提供 `tokenreviews.create` / `subjectaccessreviews.create` 权限），用于 K8s auth 校验外部 Pod 的 SA token。
- `Deployment vault`：单副本、`Recreate` 策略；启动参数 `server -dev -dev-root-token-id=root -dev-listen-address=0.0.0.0:8200`；`IPC_LOCK` capability（dev 模式实际不 mlock，但避免 warning）；readiness/liveness 走 `/v1/sys/health?standbyok=true&uninitcode=204&sealedcode=204`。
- `Service vault`：ClusterIP / 8200。

## 2. 自验：Pod Running + sealed=false + kv put/get

```bash
kubectl -n devops-valult-invest get pod -l app=vault -o wide
# vault-79d775d65b-4f8dg   1/1   Running   0   <age>

kubectl -n devops-valult-invest exec deploy/vault -- vault status
```

关键输出（截断）：
```
Initialized     true
Sealed          false
Total Shares    1
Threshold       1
Version         1.19.5
Storage Type    inmem
HA Enabled      false
```

写 / 读测试 secret：
```bash
kubectl -n devops-valult-invest exec deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200
  vault login root >/dev/null
  vault kv put secret/test foo=bar
  vault kv get secret/test
'
```

```
=== Data ===
Key    Value
---    -----
foo    bar
```

## 3. 配置 Kubernetes Auth Method

```bash
# 3.1 启用 kubernetes auth
kubectl -n devops-valult-invest exec deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200
  vault login root >/dev/null
  vault auth enable kubernetes
'
# Success! Enabled kubernetes auth method at: kubernetes/

# 3.2 配置 endpoint + CA（不显式提供 token_reviewer_jwt，
#     Vault 会自动用 Pod 自身的 SA token 调 TokenReview；
#     依赖 ClusterRoleBinding 已授予 system:auth-delegator）
kubectl -n devops-valult-invest exec deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200
  vault login root >/dev/null
  vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443" \
    kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
'
# Success! Data written to: auth/kubernetes/config
```

`vault read auth/kubernetes/config` 关键字段：
- `kubernetes_host=https://kubernetes.default.svc:443`
- `kubernetes_ca_cert=<kube-root-ca PEM>`
- `disable_iss_validation=true`
- `token_reviewer_jwt_set=false`（Vault 用自己 Pod 的 SA token）

## 4. 策略 + 角色 + 测试 secret

```bash
# 4.1 git-reader 策略
kubectl -n devops-valult-invest exec deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200
  vault login root >/dev/null
  cat <<EOF | vault policy write git-reader -
path "secret/data/git/*" {
  capabilities = ["read"]
}
path "secret/metadata/git/*" {
  capabilities = ["list", "read"]
}
EOF
'
# Success! Uploaded policy: git-reader

# 4.2 绑定 K8s SA devops-valult-invest/default → git-reader
kubectl -n devops-valult-invest exec deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200
  vault login root >/dev/null
  vault write auth/kubernetes/role/git-reader \
    bound_service_account_names=default \
    bound_service_account_namespaces=devops-valult-invest \
    policies=git-reader \
    ttl=1h
'
# Success! Data written to: auth/kubernetes/role/git-reader

# 4.3 写测试 secret
kubectl -n devops-valult-invest exec deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200
  vault login root >/dev/null
  vault kv put secret/git/test token=dummy-pat-12345
'
```

## 5. 端到端验证：从外部 Pod 通过 K8s auth 拿 vault token

`kubectl run` 一个一次性 Pod，使用 namespace 的 `default` SA，挂载 SA token，向 vault 调 `auth/kubernetes/login`：

```bash
kubectl -n devops-valult-invest run vault-verify --rm -i --restart=Never \
  --image=hub-mirrors.alauda.cn/hashicorp/vault:1.19.5 \
  --overrides='{"spec":{"serviceAccountName":"default"}}' \
  --env="VAULT_ADDR=http://vault.devops-valult-invest.svc:8200" \
  -- sh -c '
    SA_JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    LOGIN_JSON=$(vault write -format=json auth/kubernetes/login role=git-reader jwt="$SA_JWT")
    VTOKEN=$(echo "$LOGIN_JSON" | sed -n "s/.*\"client_token\": \"\\([^\"]*\\)\".*/\\1/p" | head -1)
    VAULT_TOKEN="$VTOKEN" vault kv get secret/git/test
    VAULT_TOKEN="$VTOKEN" vault kv get secret/test 2>&1 || echo "(denied as expected)"
  '
```

关键输出（截断）：

login JSON：
```json
{
  "auth": {
    "client_token": "hvs.CAESILz...",
    "policies": ["default", "git-reader"],
    "metadata": {
      "role": "git-reader",
      "service_account_name": "default",
      "service_account_namespace": "devops-valult-invest"
    },
    "lease_duration": 3600
  }
}
```

读 `secret/git/test`：
```
Key      Value
---      -----
token    dummy-pat-12345
```

越权读 `secret/test`（不在 `secret/git/*` 下）：
```
Code: 403. Errors:
  * permission denied
(denied as expected)
```

**结论：K8s auth + policy 绑定链路工作正常，PoC 1 / PoC 3 可基于此 vault 直接开发。**

## 6. 共享访问参数（给后续 PoC 用）

PoC manifest 中可直接复用：

```yaml
env:
  - name: VAULT_ADDR
    value: "http://vault.devops-valult-invest.svc:8200"
  # PoC 内部调用 auth/kubernetes/login 时使用：
  # role=git-reader（或后续 PoC 自定义 role）
  # jwt=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
```

如果 PoC Pod 不在 `devops-valult-invest` 命名空间，需要：
1. 在该 ns 创建一个独立 SA（例如 `pipeline-runner`）。
2. 在 vault 中再创建一个 role，`bound_service_account_namespaces` 指向该 ns、`bound_service_account_names` 指向该 SA 名。
3. 绑定到相应 policy。

## 7. 集群上残留资源清单（PoC 共享）

```
Namespace: devops-valult-invest
  ServiceAccount/vault
  Deployment/vault (1 replica)
  Service/vault (ClusterIP 10.4.227.232:8200)

Cluster-scoped:
  ClusterRoleBinding/vault-auth-delegator-devops-valult-invest
    → system:auth-delegator
    → ServiceAccount devops-valult-invest/vault
```

**未做 / 未装**（按要求）：
- 未装 Vault Agent Injector（PoC-1 决定是否走 init container 模式时再单独评估）
- 未配置 PVC / 持久化（in-memory，Pod 重启全部数据丢失）
- 未配置 TLS（HTTP listener）
- 未配置 audit log

---

## 附录：生产化要做什么（air-gap 运维成本参考）

> 用于后续文档"air-gap 运维成本"章节引用。本次 PoC 故意省掉所有生产配置；下面列出从 dev 模式走到生产可用至少需要补齐的工作，**air-gap 场景每一条都要在内网仓库 + 内网镜像源 + 内网证书体系下重新搭建**。

1. **HA 集成存储**：从 `-dev` 切到 `storage "raft"`（Integrated Storage），最少 3/5 节点奇数，StatefulSet + PVC（每节点独立 PV），跨节点反亲和；同时引入 service 内部 + 外部两个 listener、raft `retry_join` 配置、节点替换 runbook。
2. **Unseal / Auto-unseal**：dev 模式自动 unseal，生产必须显式 `vault operator init` 产 5 把 unseal key + root token，**air-gap 没有云 KMS** 可用 → 要么沿用 Shamir 多人持密钥（运维流程：每次重启走人工流程），要么对接客户自有 HSM / KMIP（成本最高），或 transit auto-unseal（再起一个最小 vault 做 unseal 兜底，引入鸡生蛋问题）。
3. **TLS**：所有 listener 启用 TLS（含 raft 内部通信），证书走客户内部 CA；证书轮换流程；K8s auth `kubernetes_ca_cert` 也要从 in-cluster CA 切到客户企业 CA。
4. **备份 / 灾备**：raft 快照（`vault operator raft snapshot save`）定时上传 air-gap 对象存储（MinIO 之类），保留策略 + 异地副本；恢复演练流程 runbook。
5. **审计 / 监控**：开启 audit device（file/socket），日志收集到 SIEM；Prometheus 抓 `/v1/sys/metrics`，告警关键指标（sealed、leader 状态、token 创建速率、storage 延迟）。
6. **policy / namespace / 多租户治理**：root token 离线封存（仅初始化用），日常运维走最小权限 admin policy；按团队 / 项目划 vault namespace（**Enterprise 特性**）或前缀；定期 review policy 变更（GitOps）。
7. **License**（关键卡点）：Vault Namespace、Performance Replication、DR Replication、HSM seal、Sentinel policy 都是 **Enterprise**，OSS 版本不带；air-gap 场景还要走线下许可证文件 + 续期管理。
8. **镜像与升级路径**：内网 mirror 持续同步上游版本，制定 CVE 跟进 + 滚动升级 SOP（raft 集群可零停升级，但需校验 plugin 兼容性、storage schema 迁移）。
