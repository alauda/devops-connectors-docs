# Connectors 业务域解决方式映射（11 维 + 哲学 + 护城河）

> 目的：为 "Vault 能否替代 Connectors" 调研提供 Connectors 一侧的客观解决方式描述。所有描述聚焦"具体抽象 + data plane 路径 + ACP 平台耦合度"，不罗列功能模块。

## 1. CI secretless

Connectors 的做法是把"凭据持有者"从 CI 容器搬到集群里的 `Connectors Proxy`（`pkg/proxy/`，由 `cmd/proxy/main.go` 起的独立 data-plane 进程）。流程：管理员在某 namespace/项目/`kube-public` 创建 `Connector` CR（引用 `kubernetes.io/basic-auth` / `connectors.cpaas.io/bearer-token` / `cpaas.io/distribution-registry-token` 等 Secret），同时 `ConnectorClass` 通过 `spec.proxy.ref` 指向 proxy Service 和 `spec.configurations` 描述配置模板。Tekton Task 通过 `Connectors CSI Driver`（`pkg/csidriver/`，DaemonSet）声明 `csi.driver: connectors-csi` 卷，挂载阶段 driver 调用 K8s API 用 Pod 的 ServiceAccount 签发短期 token（默认 `token.expiration: 30m`），把渲染好的 `.gitconfig` / `http.proxy` / `context.token` / `connector.status.proxyAddress` 写进 tmpfs。Task 进程拿到的只是"代理 URL + SA token"，原始 git/harbor/npm 密码从未出现在容器、env、日志、镜像层；真正的 Basic Auth / Bearer / OCI token 由 proxy 在出栈方向注入。整个路径不依赖第三方 secret store，但**强依赖 Tekton workspace + K8s CSI + K8s ServiceAccount token API**。

## 2. K8s 镜像拉取（无 per-ns imagePullSecret）

由 `ConnectorsOCI` / `ConnectorsHarbor` 组件以 reverse proxy 暴露 `/v2/*` distribution endpoint + `*/token` endpoint，并通过 `enable-pod-image-pull-via-connector` feature flag 控制的 `PodWebhook`（mutating admission，OCI/Harbor 共享 PodWebhook 类型，`verbs=create`）改写 Pod。用户在 Pod 上打 `connectors.cpaas.io/connector: <ns>/<connector>` annotation + `connectors.cpaas.io/proxy-inject: "true"` label，webhook 把容器 `image: harbor.example.com/team-a/app:v1` 改写为 `192.168.x.x:31567/namespaces/<ns>/connectors/harbor/team-a/app:v1`，kubelet 走 reverse proxy 拉镜像；imagePullSecret 用的是该 namespace 一个 SA token 包装的 docker-registry secret，token 校验在 reverse proxy 里完成，真正 Harbor robot 密码只存在 `connectors-system` 的 `Connector` Secret 里。flag 关闭时 webhook 直接 deny 含该 annotation 的 Pod。该路径**不需要改 kubelet / 不需要 CRI 插件**，但要求 OCI proxy 服务以 NodePort/Ingress 暴露、容器运行时配置 insecure_registries 信任 HTTP。

## 3. 平台治理 + 委派

Connectors 用三层 K8s 原生抽象实现治理：(a) `Connector` 资源三种 scope —— `kube-public` 内为 cluster-level、带 `cpaas.io/inner-namespace` 标签的 namespace group 为 project-level、普通 ns 为 namespace-level，平台管理员把"已批准的 GitHub Org / Harbor project" 物化为某个 scope 的 `Connector` CR；(b) **资源权限**（`get connectors`、`get connectorclasses`）控制"能不能看到"，**能力权限**（`connectors/proxy` subresource、`connectors/apis` subresource）控制"能不能用"，分别由 `enable-connector-proxy-permissions` / `enable-connector-apis-permissions` 两个 feature flag 启用；(c) 委派落到 ACP IAM 角色绑定上，平台预置 role 已经把 read-oriented `connectors/apis` 给到普通开发者用于 UI 选择器，而 `connectors/proxy` 通常只给经治理审核的 SA / namespace。结果是同一个 `prod-harbor` Connector，一个团队可以 "看到 + 在 UI 列 tag"，另一个团队甚至可以 push，第三个团队完全看不到——所有委派表达式都是 RBAC RoleBinding，**直接复用 ACP IAM**。

## 4. 项目级多租户

依赖 ACP 的"项目 = namespace group"模型 + Connector 的 project-level scope。项目 A 的管理员在 group namespace `project-a`（label `cpaas.io/inner-namespace: project-a`）下创建一个 `gitlab` Connector 指向自家 GitLab；项目 B 在 `project-b` 下创建另一个指向公司 GitLab。CSI driver 在挂载时按 `cpaas.io/project: <group>` label 校验请求 Pod 的 namespace 是否属于该 group，跨 group 拒绝。Proxy 侧的 SA token 校验也走 K8s RBAC，相同 Connector 名字在不同 project 下是完全独立的 CR、独立的 Secret、独立的 Proxy Service Endpoint（`c-<name>.<ns>.svc.cluster.local`），没有共享租户表。`Connector.spec.params` + `ResourceInterface` 让 UI 在 Pipeline 配置时只看到本项目可见的 Connector 列表。**强耦合于 ACP 的 namespace-group / project 概念**——非 ACP K8s 没有这个层。

## 5. 审批门控

由 `AccessPolicy` + `AccessRequest` 两个 CRD（在 `pkg/apis/connectors/v1alpha1/`）实现，需同时开启 `enable-connector-proxy-permissions` + `enable-connectors-approval`。管理员对 `prod-harbor` 创建 `AccessPolicy`，`spec.checkGrantedPermission.checks` 引用内置 ConfigMap `connectors-approvals-in-pipeline`（语义："匹配同一个 PipelineRun 里的 `ApprovalTask`"），`roleTemplate` 引用 `connectors-use-connectors-proxy-in-pod`（即"批准后给该 Pod 颁发临时 `connectors/proxy` 权限"）。运行时：promotion Task 通过 CSI 挂载 `prod-harbor` → CSI driver 检测到匹配的 policy → 自动创建 `AccessRequest` 记录该 Pod 的请求 → 等同一 PipelineRun 的 `ApprovalTask` 决策。批准则 controller 同步 RoleBinding 把 `connectors/proxy` 临时授予该 Pod 的 SA；拒绝则 CSI 只挂一个 `.error.json` 文件、不挂任何配置/token，Pod 启动后立刻失败。开发环境的 Connector 不创建 AccessPolicy，走默认放行。**强依赖 Tekton + ApprovalTask + ACP IAM**。

## 6. UI 资源选择器

由 `Connectors API`（`pkg/restapi/`，由 `cmd/api/main.go` 起的 API server）+ `ConnectorClass.spec.api.openapi` + `ResourceInterface` + 前端 Pipeline Integration 插件组成。`ConnectorClass` 在 `spec.api.openapi` 里声明 OpenAPI 3.0 schema（如 `/git/gitrefs`、`/api/v4/projects`），并用 `x-display-schema` 描述"如何把响应映射到下拉项"。`ResourceInterface`（如 `gitcoderepository` / `ociartifact`）在 `style.tekton.dev/descriptors` annotation 里用 `urn:alm:descriptor:widgets:select` + `schema:openapi:context.connectorClass.spec.api.openapi:listGitRefs` 引用该 OpenAPI operation。前端在 Pipeline 配置页选定 Connector 后，按 descriptor 调 `Connectors API`（URL 形如 `/clusters-rewrite/<cluster><connector.status.api.path>/git/gitrefs?...`），API server 在后端代用户 SA token 调 `Connectors Proxy` 拿真实 GitLab/Harbor 数据，回填下拉框；同时 `ResourceInterface.spec.attributes` 用 JS 表达式把"connector + 用户选项"算出 `url`、`revision`、`artifact-versions` 等参数，外加 `workspaces` 自动生成 CSI workspace binding。整套 UI 体验**深度耦合 ACP Tekton 前端 + Pipeline Integration descriptor 框架**，是第三方 secret store 完全没有的产品形态。

## 7. 凭据轮换 / 短期化 / 吊销

Connectors 自己**不轮换**外部工具的真实密码——真实密码长期存活在 `Connector` 引用的 K8s Secret 里、由管理员/外部流程负责轮换。Connectors 短期化的是"客户端拿到的代理凭据"：CSI 挂卷时通过 K8s TokenRequest API 为 Pod SA 签发短期 token（`token.expiration` 默认 30m，可调），写到 `context.token`；Tekton Task 结束、Pod 销毁、token 过期，client 侧凭据自动失效。Proxy 在每个请求上都重新走 TokenReview/SubjectAccessReview 校验 SA token + `connectors/proxy` 权限，所以"立即吊销"的方式是：删除/改名/调权 Pod 用的 SA、或撤销该 SA 的 `connectors/proxy` RoleBinding——下一次请求即被 reject。真实工具凭据要轮换时，管理员只需更新 `Connector` 引用的 Secret，controller reconcile 后 proxy 热重载（见第 10 项）。**不提供 Vault 那种"动态密钥引擎按需创建一次性凭据"，但通过 K8s SA token 短期化达到类似效果**。

## 8. 审计

Connectors 自身没有独立审计 sink，所有可审计事件都落在 K8s 原生轨道上：(a) `Connector` / `ConnectorClass` / `AccessPolicy` / `AccessRequest` 的 CR 变更进 K8s audit log（kube-apiserver audit policy 配置）；(b) `AccessRequest` 本身就是"谁、在哪个 PipelineRun、对哪个 Connector、什么时候发起、检查通过/拒绝"的结构化记录，可 `kubectl get accessrequest` 查询；(c) Proxy 的 HTTP access log 记录"哪个 SA token（即哪个 Pod/Workload）、什么时候、调用了 target tool 的哪个 path"，可以经 ACP 日志组件采集；(d) `ApprovalTask` 的审批人记录在 Tekton 资源里。把"谁"映射到自然人靠 ACP IAM 的 SA token → user 反查。**没有原生统一审计 dashboard**，依赖 ACP 日志/审计平台聚合。

## 9. air-gap 可安装可升级

Connectors 走 OLM 标准路径，由 `connectors-operator` 仓库提供 bundle。客户 SRE 操作面只有一个 cluster-singleton CR `ConnectorsConfig`（admission webhook 跨 ns list 强制 cluster 唯一），它声明启用哪些子组件（Core 必选，Git/GitLab/OCI/Harbor/Maven/... 可选）。operator 启动时如不存在 `ConnectorsConfig` 会用 leader-elected runnable 幂等创建默认值，然后 `ConnectorsReconciler` 把 `ConnectorsConfig` 翻译成 per-component 子 CR（`ConnectorsCore` 等），从 `cmd/kodata/<kind>/<version>/install.yaml` 加载嵌入的 manifest，经 `pkg/controllers/transformer/` 注入 namespace / 镜像 registry / 标签 / 工作负载 override，再创建 `InstallManifest` CR，由 `InstallManifestReconciler` 按 CRDs → ClusterScoped → NamespaceScoped → Workloads 四阶段 apply。所有镜像和 install.yaml 都嵌在 operator bundle 里（airgap 镜像同步走 `make dist` 推 Nexus），升级、回滚、灰度全部走 OLM 的 InstallPlan / CSV。**SRE 学习成本 = "在 OperatorHub 装个 operator + 编辑一个 CR"**，复用 ACP 现有 operator 体系，无新组件。

## 10. 热轮换不断流

凭据轮换链路：管理员更新 `Connector` 引用的 Secret → controller watch Secret 触发 `Connector` reconcile → proxy 内部 credential cache 失效并重新从 K8s API 加载新值。**正在跑的 HTTP 请求不被打断**——Connectors Proxy 是 stateless 反向代理，凭据按请求注入（forward 模式注 `Proxy-Authorization` / 后端 Basic、reverse 模式注 Bearer / Rego 模板），下一个请求自动用新凭据；Tekton Task 进程拿到的是"proxy URL + SA token"而非真实密码，所以真实密码换了 client 进程完全无感。CSI 已挂载的 token 文件按 `token.expiration` 到期才需要重新挂卷（新 Pod 自动拿新值，运行中的 Pod 在 token 有效期内继续用旧 token，过期后下次请求被 proxy reject 失败）。Connector 删除 / scope 调整 / RBAC 调整生效更快——proxy 每请求都 SubjectAccessReview，无 token 黑名单需求。**对比 Vault 的 lease + revocation 模型，Connectors 的"反向代理 + K8s SA token TTL"实现了等价的不断流热轮换，但粒度受限于 token TTL**。

## 11. 新工具 onboarding 成本

接入 Jira/Artifactory 等新工具，工程量集中在三处：(a) 定义 `ConnectorClass`（cluster-scoped CRD），声明 `spec.address`、`spec.auth.types`（用户用什么 Secret type）、`spec.proxy.ref`（用内置 HTTP proxy 还是自研 plugin proxy）、`spec.configurations`（CSI 挂载的配置文件模板，go-template + sprig）、`spec.api.openapi`（UI 选择器要的 OpenAPI schema）；如果工具走标准 Basic/Bearer + HTTP，**内置 HTTP proxy + Rego 规则**就够，整个 Connector 类型可以只用一份 YAML 完成；如果是非 HTTP 协议（如 OCI distribution）需要在 `connectors-extensions/connectors-<name>` 仓库写一个 custom plugin proxy（参考 `connectors-oci`），实现 forward + reverse 两个 listener；(b) 可选定义 `ResourceInterface` 把工具资源（issue、artifact）暴露到 Pipeline UI；(c) 在 `connectors-operator` 增加 `ConnectorsJira` CRD 类型 + embed install.yaml，让 operator 能装新组件。**最小代价是一份 ConnectorClass YAML，最大代价是新建一个 extensions 仓库 + operator 注册新类型**。

## Connectors 的核心架构哲学

Connectors 的本质选择是 **data-plane proxy 模式**而非 **secret injection 模式**：真实工具凭据始终留在集群 control plane 的一个 Secret 里，client 侧拿到的永远是"代理地址 + 短期 SA token"，所有真实凭据注入发生在 in-cluster proxy 的出栈方向。这与"把真凭据短期化后注入 client 容器 env / file"（Vault Agent Injector / CSI Secret Store 的典型用法）有三点本质差异：(1) 真凭据**永远不出 connectors-system namespace**，不在 client 进程地址空间、不会被 `env`、`ps`、core dump、日志、镜像层捕获；(2) 吊销是"撤 RBAC"而非"等 lease 过期"，proxy 每请求 SubjectAccessReview，秒级生效；(3) client 改造极小（改 `http_proxy` 或镜像地址改写），无需 SDK / sidecar / init container 配合解析 secret 文件。代价是必须为每类工具实现 protocol-aware proxy。

## Connectors 的护城河能力

与第三方独立组件难以复现、强耦合 ACP 平台的能力：(1) `connectors.cpaas.io/connector` annotation 触发 `PodWebhook` 改写 image 到 reverse proxy 地址 + kubelet 走 SA token 拉镜像——**改的是 Pod admission + 信任 insecure-registry 的运行时配置**，纯第三方 secret store 给不出"集群级 imagePullSecret-less"；(2) `ConnectorClass.spec.api.openapi` + `ResourceInterface` + Tekton 前端 descriptor 联动，让 UI 在 Pipeline 配置时按工具语义浏览 branch / tag / project，**深度绑定 ACP Tekton 前端插件**；(3) `kube-public` / namespace-group / namespace 三级 scope 直接挂 ACP IAM 角色，治理委派复用平台 RBAC；(4) `AccessPolicy` 与 Tekton `ApprovalTask` 在同一 PipelineRun 内联动审批，绑定 ACP DevOps 模块。
