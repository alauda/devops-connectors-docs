# Azure DevOps & Harness.io — Connection/Connector 与 KMS/Vault 的关系

> 基于 Microsoft Learn / Harness Developer Hub 官方文档整理,用于 Alauda Connectors 竞品定位。所有结论附 URL 出处;文档模糊处显式标注。

## Azure DevOps

**Service Connection** 是 project 级凭据资源,封闭枚举约 30 种内置类型(ARM、GitHub、Docker、K8s、npm、Maven、SSH、SonarQube...),由 `endpoint URL + auth parameters` 构成。**HashiCorp Vault 不在内置列表里**——社区只有 marketplace task(如 `HashiCorpVaultTask`)以 pipeline step 形态出现,既不是 Service Connection 类型也不是 Variable Group provider,且执行时 step 还得自己管 vault-token 这个 bootstrap 凭据。

**凭据存储模型**:Service Connection 自带 secret,加密落 ADO 数据库,pipeline 运行时解密后明文注入 task 输入——典型 secret-injection,没有 proxy 层。微软的战略方向是 **Workload Identity Federation (WIF)**:把 Service Connection 改成 Entra ID 联邦信任,运行时用 OIDC token 换短时 access token([WIF 文档](https://learn.microsoft.com/en-us/azure/devops/pipelines/release/configure-workload-identity))。但 WIF 仅覆盖 ARM/Entra 类目标;GitHub/Docker/Maven/npm 等绝大多数 connector 仍是存 PAT 的传统形态。

**KMS 集成**:Azure Key Vault **不是** Service Connection 类型,而是绕道挂在 **Variable Group → Key Vault link** 下,用一个 ARM Service Connection 作为认证代理([Link variable group to Key Vault](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/link-variable-groups-to-key-vaults))。运行时按需 GET,不缓存到 ADO DB——这条 "runtime fetch + 不落地" 路径是 ADO 集成里最干净的一条。HashiCorp Vault、AWS Secrets Manager、GCP Secret Manager 均**无原生 Variable Group provider**,只能走 marketplace task。

**Pipeline 用法**(以 KV-backed Variable Group 为例):
```yaml
variables:
  - group: prod-secrets        # ← 关联 KV 的 Variable Group
steps:
  - script: echo $(dbPassword) # ← KV secret name 直接当变量
```

**保护机制**:Service Connection 是 ADO 的 "protected resource",可挂 **approvals & checks**(N-of-M 审批、分支限制、branch protection)作为解密前的 gate。

→ ADO 的本质是 **"Service Connection 自存 secret + Variable Group 可选 KMS-backed"** 的双轨,身份和 secret material 在 Azure 内部可解耦(WIF/KV),出了 Azure 闭环就退化。

---

## Harness.io

**Connector** 是 CRUD 资源(Cloud Provider / Artifact / Code / Ticketing / Monitoring / Secret Manager 等约 30 类),关键特征是 **从不直接持有 secret 字节**,YAML 里凭据字段全是 `*Ref` 指针([Create connector via YAML](https://developer.harness.io/docs/platform/connectors/create-a-connector-using-yaml/)):

```yaml
connector:
  type: DockerRegistry
  spec:
    auth:
      type: UsernamePassword
      spec:
        username: myuser
        passwordRef: dockerhubpassword   # ← 引用 Secret,非字面值
```

`passwordRef` 指向 **Secret** 资源,Secret 又关联到 **Secret Manager Connector**。三层抽象清晰:**Connector(连哪) → Secret(逻辑命名) → Secret Manager(真正存储后端)**。

**Delegate 模型**:控制平面 SaaS Manager + 数据平面用户私网内的 Delegate。**Manager 只见密文与 ref,明文解密只在 Delegate**;运行时再注入 pipeline step 进程 env(明文最终还是会落到 Delegate 上,**没有 reverse proxy**)。

**KMS 集成**:Secret Manager 是一等公民。Built-in 默认走 Google Cloud KMS envelope encryption。HashiCorp Vault([Add Vault](https://developer.harness.io/docs/platform/secrets/secrets-management/add-hashicorp-vault))原生支持 **6 种认证**(AppRole、Token、Vault Agent、AWS Auth、**Kubernetes Auth**、JWT/OIDC),按需读取,**密钥与值都不落 Harness DB,只存 reference**,Vault token 也只在 Delegate 持有。AWS Secrets Manager / AWS KMS / Azure KV / GCP SM 都有独立 first-party Connector;企业系统(如 CyberArk Conjur)走 **Custom Secret Manager**——用户写 shell 脚本模板,Delegate 跑脚本去 fetch([Custom Secret Manager](https://developer.harness.io/docs/platform/secrets/secrets-management/custom-secret-manager/))。

**Pipeline 用法**:
```yaml
secrets:
  - name: db-password
    spec:
      secretManager: myVaultSM         # ← 引用 Vault Connector
      path: secret/data/db#password
steps:
  - step:
      type: Run
      spec:
        envVariables:
          DB_PASS: <+secrets.getValue("db-password")>  # ← runtime resolve
```

**保护机制**:Pipeline-level **Approval stage**(manual / Jira / ServiceNow)作为门控,但**不是绑在 Secret 解密事件上的细粒度 N-of-M**。

**模糊点**:Vault dynamic credentials(DB user / AWS IAM)的 lease/renew/revoke 生命周期文档没明确章节,目前判定是"按 static path 读取"近似实现;Vault namespace 多租隔离亦未单列章节(**未确认**)。

→ Harness 的本质是 **"Vault/KMS 是真相来源,Connector 只引用"** 模型,三层抽象清晰,Manager 不见明文是关键安全断言。

---

## 三方对比与启发

| 维度 | Azure DevOps | Harness | Alauda Connectors |
|------|--------------|---------|-------------------|
| Connector 持 secret 字节 | 传统:**持有**;WIF:不持有 | **从不持有**(只 `*Ref`) | 持有,锁在 `connectors-system` ns |
| KMS 与 Connector 关系 | 双轨(Variable Group 可选 KMS-backed) | **KMS = Secret Backend**(三层抽象) | 无 first-party Vault backend |
| HashiCorp Vault 一等支持 | **无**(仅 marketplace task) | **有**(6 种 auth + 按需读) | **无** |
| CI job 拿到什么 | 明文(WIF 除外) | 明文(Delegate 内) | **proxy URL + 短时 K8s SA token**(独有) |
| 控制面是否见明文 | 是 | **否** | **否** |
| N-of-M 审批 | approvals & checks 挂 protected resource | pipeline-level approval stage | AccessPolicy/AccessRequest + ApprovalTask |
| 多租户 scope | Project | Account / Org / Project | K8s namespace + RBAC |

**核心启发**:

1. **proxy 数据平面是 Alauda 独有的差异化轴** —— ADO 和 Harness 凭据在执行时刻都会落到 runner / Delegate 进程,只有我们让 CI job 从头到尾不见明文。定位文档应显著强调。
2. **Harness 三层抽象(Connector / Secret / Secret Manager)是 SecretBackend 方向的现成模板** —— 验证了"Connector 持 ref、Secret Manager 持后端"模式可行。我们若引入 `SecretBackend` CRD,Connector 只持 `SecretBackendRef + SecretPath`,由 controller reconcile 时按需 fetch + 注入 proxy 内存,可比 Harness 升一档:**业务进程从头到尾不见明文,凭据只在 reverse proxy 内存**。
3. **K8s Auth Method 是 Vault 集成首选 auth 方式** —— Harness 6 种 auth 里这条最契合 K8s native 拓扑(SA JWT → Vault role → 短时 token),应作为我们集成 Vault 的默认路径。
4. **ADO 的 "runtime fetch + 不落地" 是 baseline 行为** —— proxy 模型天然能做到,且无需依赖 KV 才有此特性。
5. **Harness 含糊点正好是我们差异化空间** —— Vault dynamic secrets 完整 lease/renew/revoke 生命周期、Vault namespace 多租显式建模(K8s namespace ↔ Vault namespace 一等字段),Harness 文档都未明确,我们若做到就有定位优势。

**反模式**:
- 不要抄 ADO "凭据塞 Service Connection 自存"——失去 WIF 这条特殊路径就退化成普通密码本。
- 不要抄 Harness "step 执行时 Delegate 持明文"——proxy 层缺失意味着 secret 必须短暂解密给"信任的 runner",这正是我们要绕开的。
- 不要"把 dynamic secret 当 static path 读"——失去 Vault lease 语义的价值。

## 来源

- [Azure Pipelines Service Connections](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints)
- [Azure Pipelines Variable Groups](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/variable-groups)
- [Link Variable Group to Azure Key Vault](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/link-variable-groups-to-key-vaults)
- [Configure Workload Identity Service Connection](https://learn.microsoft.com/en-us/azure/devops/pipelines/release/configure-workload-identity)
- [Harness Connectors category](https://developer.harness.io/docs/category/connectors/)
- [Create a Connector using YAML](https://developer.harness.io/docs/platform/connectors/create-a-connector-using-yaml/)
- [Harness Secret Manager overview](https://developer.harness.io/docs/platform/secrets/secrets-management/harness-secret-manager-overview/)
- [Add HashiCorp Vault Secret Manager](https://developer.harness.io/docs/platform/secrets/secrets-management/add-hashicorp-vault)
- [Custom Secret Manager](https://developer.harness.io/docs/platform/secrets/secrets-management/custom-secret-manager/)
