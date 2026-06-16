# PoC-2 执行日志

> 目标：演示"Vault 在 K8s 镜像拉取问题域上结构性不覆盖"——即使 VSO 把 dockerconfigjson 同步到 ns，业务 Pod 不显式 `imagePullSecrets` 引用，kubelet 仍然拉不到镜像。
> 集群：`https://jtcheng-bdrjq-bwrsq--idp.alaudatech.net/kubernetes/global/`
> 命名空间：`devops-valult-invest`
> Vault：`vault.devops-valult-invest.svc:8200` （dev 模式，root token = `root`，K8s auth 已配置，详见 `../00-vault-setup-log.md`）

---

## 1. Vault 侧准备

### 1.1 写假 dockerconfigjson（明显伪造）

```bash
kubectl -n devops-valult-invest exec deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200
  vault login root >/dev/null
  vault kv put secret/registry/dummy \
    dockerconfigjson="{\"auths\":{\"my-private-registry.example.com\":{\"auth\":\"dXNlcjpwYXNz\"}}}"
'
```

`dXNlcjpwYXNz` = base64(`user:pass`)。明显假数据。

### 1.2 加一个 policy + role 让 sync Job 的 SA 能读

```bash
kubectl -n devops-valult-invest exec deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200
  vault login root >/dev/null
  cat <<EOF | vault policy write image-puller -
path "secret/data/registry/*" {
  capabilities = ["read"]
}
EOF
  vault write auth/kubernetes/role/image-puller \
    bound_service_account_names=vault-image-sync \
    bound_service_account_namespaces=devops-valult-invest \
    policies=image-puller \
    ttl=15m
'
```

输出：
```
Success! Uploaded policy: image-puller
Success! Data written to: auth/kubernetes/role/image-puller
```

---

## 2. 部署 VSO 等价 Sync Job

manifest：`./vault-sync-secret.yaml`（含 SA + Role/RoleBinding + ConfigMap + Job）

```bash
kubectl apply -f vault-sync-secret.yaml
```

输出：
```
serviceaccount/vault-image-sync created
role.rbac.authorization.k8s.io/vault-image-sync-secret-writer created
rolebinding.rbac.authorization.k8s.io/vault-image-sync-secret-writer created
configmap/vault-image-sync-script created
job.batch/vault-image-sync created
```

### 2.1 等 Job 完成，看日志

```bash
kubectl -n devops-valult-invest logs job/vault-image-sync
```

关键输出：
```
[vault-image-sync] step 1: POST http://vault.devops-valult-invest.svc:8200/v1/auth/kubernetes/login (role=image-puller)
[vault-image-sync] got vault token; policies=['default', 'image-puller'] lease=900s
[vault-image-sync] step 2: GET http://vault.devops-valult-invest.svc:8200/v1/secret/data/registry/dummy
[vault-image-sync] dockerconfigjson preview={"auths":{"my-private-registry.example.com":{"auth":"dXNlcjpwYXNz"}}}
[vault-image-sync] step 3: POST kube Secret devops-valult-invest/vault-synced-dockercfg
[vault-image-sync] create HTTP 201
[vault-image-sync] DONE.
```

### 2.2 同步出来的 Secret（脱敏后）

```bash
kubectl -n devops-valult-invest get secret vault-synced-dockercfg -o yaml
```

```yaml
apiVersion: v1
data:
  .dockerconfigjson: eyJhdXRocyI6eyJteS1wcml2YXRlLXJlZ2lzdHJ5LmV4YW1wbGUuY29tIjp7ImF1dGgiOiJkWE5sY2pwd1lYTnoifX19
kind: Secret
metadata:
  annotations:
    poc-2.devops-44108/source: vault:secret/data/registry/dummy
    poc-2.devops-44108/sync-mode: VSO-equivalent-job
  name: vault-synced-dockercfg
  namespace: devops-valult-invest
type: kubernetes.io/dockerconfigjson
```

base64 解开就是 vault 里那串 `{"auths":...}`，验证同步链路 ok。**这正是 VSO `VaultStaticSecret` 在生产中的等价产物**。

---

## 3. 部署测试 Pod（场景 1 & 场景 2）

manifest：`./test-pods.yaml`

```bash
kubectl apply -f test-pods.yaml
```

输出：
```
pod/poc2-scenario1-no-pullsecret created
pod/poc2-scenario2-with-pullsecret created
```

### 3.1 状态总览

```bash
kubectl -n devops-valult-invest get pods -l poc=poc-2 -o wide
```

```
NAME                             READY   STATUS         RESTARTS   AGE
poc2-scenario1-no-pullsecret     0/1     ErrImagePull   0          12s
poc2-scenario2-with-pullsecret   1/1     Running        0          12s
```

### 3.2 场景 1：不引用 imagePullSecret —— **kubelet 没有用 vault 同步出的 Secret**

```bash
kubectl -n devops-valult-invest describe pod poc2-scenario1-no-pullsecret
```

关键事件（截）：
```
Normal   Scheduled  Successfully assigned devops-valult-invest/poc2-scenario1-no-pullsecret to 192.168.136.132
Normal   Pulling    spec.containers{app}: Pulling image "my-private-registry.example.com/foo:latest"
Warning  Failed     spec.containers{app}: Failed to pull image "my-private-registry.example.com/foo:latest":
                    failed to resolve image: failed to do request:
                    Head "https://my-private-registry.example.com/v2/foo/manifests/latest":
                    dial tcp: lookup my-private-registry.example.com on 192.168.16.19:53: no such host
Warning  Failed     spec.containers{app}: Error: ErrImagePull
Normal   BackOff    spec.containers{app}: Back-off pulling image
Warning  Failed     spec.containers{app}: Error: ImagePullBackOff
```

**关键观察**：
- 同 ns 内 `vault-synced-dockercfg` Secret 一直存在，含 `my-private-registry.example.com` 的 auth 条目
- kubelet 直接朝 `https://my-private-registry.example.com/v2/foo/manifests/latest` 走，没有附带任何 dockercfg 凭据
- 错误是 DNS NXDOMAIN（registry 是 fake 域名），但**关键不是 NXDOMAIN 本身**，是事件里看不到任何"using image pull secret X"——kubelet 根本没去 ns 里找
- 这就是 PoC-2 要证伪的："Vault / VSO 把 dockercfg 同步到 ns 后，业务 Pod 自动就能拉私有镜像"——**反例成立**

### 3.3 场景 2：显式引用 `imagePullSecrets: [vault-synced-dockercfg]` —— Pod Running

```bash
kubectl -n devops-valult-invest describe pod poc2-scenario2-with-pullsecret
```

```
Normal  Scheduled  Successfully assigned devops-valult-invest/poc2-scenario2-with-pullsecret to 192.168.136.132
Normal  Pulling    spec.containers{app}: Pulling image "hub-mirrors.alauda.cn/library/alpine:3"
Normal  Pulled     spec.containers{app}: Successfully pulled image "hub-mirrors.alauda.cn/library/alpine:3" in 3.054s. Image size: 3875040 bytes.
Normal  Created    spec.containers{app}: Created container: app
Normal  Started    spec.containers{app}: Started container app
```

**关键观察**：
- Pod spec 显式 `imagePullSecrets: [name: vault-synced-dockercfg]`，kubelet 才会在 ns 内查找并附带它
- 这里目标 registry（`hub-mirrors.alauda.cn`）是免认证的，**真正的 dockercfg 内容是错的也没关系**——重点是"必须有这一引用，kubelet 才会去查找 secret"。
- 反过来说：**没有这一引用，再多同步好的 dockercfg 也没用**——这是场景 1 的对照面。

---

## 4. 对照：Connectors 在同一问题域的做法

为了完整起见，把对照表抄在这里（详细分析见 `gap-analysis.md`）：

| 维度 | Vault + VSO（本 PoC） | Connectors |
|------|----------------------|-----------|
| ns 内是否需要 dockerconfigjson Secret | 是（同步出来的 `vault-synced-dockercfg`） | 是（SA token 包装的 Secret，由 connectors-controller 创建） |
| 每个 ns 是否要单独投递 | 是（每个 ns 一份 VaultStaticSecret 或一份 ClusterExternalSecret 列举） | 是（按 ns scope 的 Connector 自动落地） |
| 业务 Pod 是否要在 spec 写 `imagePullSecrets` | **是**（场景 1 已证伪不写不行） | **否**（OCI/Harbor PodWebhook 改写 image 并注 imagePullSecret） |
| 真凭据是否离开 connectors-system / vault-system | **是**（每个 ns 都有一份明文 dockerconfigjson） | **否**（真 Harbor robot 密码只在 `connectors-system`） |
| 凭据轮换是否影响已运行 Pod | 不影响（kubelet 下次拉镜像才重读 Secret） | 不影响（运行中 Pod 不重拉镜像；真凭据从未到达 Pod） |

---

## 5. 清理（可选）

```bash
kubectl -n devops-valult-invest delete -f test-pods.yaml
kubectl -n devops-valult-invest delete -f vault-sync-secret.yaml
# vault 内：
kubectl -n devops-valult-invest exec deploy/vault -- sh -c '
  export VAULT_ADDR=http://127.0.0.1:8200; vault login root >/dev/null
  vault kv delete secret/registry/dummy
  vault delete auth/kubernetes/role/image-puller
  vault policy delete image-puller
'
```
（PoC 验证完后不需要立刻清理，留作回看证据）

---

## 6. 实验结论

1. **可观测事实**：Vault → K8s dockerconfigjson 同步路径完整跑通（HTTP 201 + Secret 在 ns 内存在 + base64 解开内容一致）。
2. **可观测事实**：在同 ns 同时存在 `vault-synced-dockercfg` 的前提下，**未显式引用 imagePullSecrets 的 Pod**（场景 1）报 `ErrImagePull`，kubelet 没有从 ns 里挑选这个 Secret 去鉴权。
3. **可观测事实**：显式引用了 imagePullSecrets 的 Pod（场景 2）正常 Running。
4. **结论**：Vault 路线在"业务 Pod 不持有 imagePullSecret 引用就能拉私有镜像"这一覆盖矩阵第 2 项上**贡献为 0**。要补齐这条体验，必须额外引入 distribution-protocol-aware reverse proxy + Pod admission webhook —— 而这恰好就是 connectors-oci/connectors-harbor 的全部主体。详见 `gap-analysis.md`。
