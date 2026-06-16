# PoC-3 Run Log

Namespace: `devops-valult-invest`
Vault: dev-mode, root token `root`, Kubernetes Auth bound role `git-reader`
to SA `default` reading `secret/git/test`.

## Environment verification

```
$ kubectl get crd | grep -i approval
approvaltasks.openshift-pipelines.org      ...
manualapprovalgates.operator.tekton.dev    ...

$ kubectl -n tekton-pipelines get pods | grep approval
manual-approval-gate-controller-86b6cb47cc-d2tkf     1/1   Running
manual-approval-gate-webhook-6674d775f7-ts2lx        1/1   Running

$ kubectl -n devops-valult-invest exec vault-... -- vault kv get secret/git/test
data: { token: ghp_FAKE_PAT_for_demo_only_12345 }
```

## Deployment

```
$ kubectl apply -f oss-approximation.yaml
configmap/vault-approval-decisions created
role.rbac.authorization.k8s.io/vault-approval-bus created
rolebinding.rbac.authorization.k8s.io/vault-approval-bus created
task.tekton.dev/vault-request-secret created
task.tekton.dev/vault-bridge-approval created
task.tekton.dev/vault-fetch-and-use-secret created
pipeline.tekton.dev/vault-pipeline-dev created
pipeline.tekton.dev/vault-pipeline-prod created
```

Images: pinned to `hub-mirrors.alauda.cn/...` after first run failed pulling
from public docker.io (cluster is air-gap-leaning; mirror is mandatory).

## Scenario 1 — dev profile, no approval

```
$ kubectl create -f <PipelineRun vault-pipeline-dev>
pipelinerun.tekton.dev/vault-dev-2fb6g created

$ kubectl -n devops-valult-invest get pipelinerun vault-dev-2fb6g
NAME              SUCCEEDED   REASON      DURATION
vault-dev-2fb6g   True        Succeeded   105s

$ kubectl logs vault-dev-2fb6g-fetch-pod --all-containers | tail -5
[gate] require-approval=false → bypass (dev profile)
[vault] exchanging SA token for Vault token via Kubernetes Auth
[vault] reading secret/git/test
[use] obtained credential prefix=ghp...
[done] secret consumed in this step only; not exported
```

**Result**: dev pipeline reads Vault without any approval — matches the
"default-allow" half of the spec.

## Scenario 2 — prod profile, approve

```
$ kubectl create -f <PipelineRun vault-pipeline-prod>
pipelinerun.tekton.dev/vault-prod-approve-f26cb created

# At t≈14s the ApprovalTask CustomRun appears, ConfigMap entry stays "pending":
$ kubectl get cm vault-approval-decisions -o jsonpath='{.data.req-prod-approve}'
pending

# Approver (logged in as `admin`) flips ApprovalTask input → "approve":
$ kubectl -n devops-valult-invest patch approvaltask vault-prod-approve-f26cb-approve \
    --type=merge -p '{"spec":{"approvers":[{"name":"admin","input":"approve","type":"User"}]}}'
approvaltask.openshift-pipelines.org/vault-prod-approve-f26cb-approve patched

$ kubectl get customrun vault-prod-approve-f26cb-approve
NAME                               SUCCEEDED   REASON      DURATION
vault-prod-approve-f26cb-approve   True        Succeeded   90s
```

Bridge task picked up the terminal status and patched the bus:

```
$ kubectl logs vault-prod-approve-f26cb-bridge-pod --all-containers
[bridge] watching CustomRun/vault-prod-approve-f26cb-approve for terminal status
[bridge] approved (reason=Succeeded) — writing approved
configmap/vault-approval-decisions patched
```

Fetch task then proceeded:

```
$ kubectl logs vault-prod-approve-f26cb-fetch-pod --all-containers | tail -10
[gate] polling ConfigMap bus for req-prod-approve
[gate] state=approved
[gate] proceed
[vault] exchanging SA token for Vault token via Kubernetes Auth
[vault] reading secret/git/test
[use] obtained credential prefix=ghp...
[done] secret consumed in this step only; not exported
```

```
$ kubectl get pipelinerun vault-prod-approve-f26cb
NAME                       SUCCEEDED   REASON      DURATION
vault-prod-approve-f26cb   True        Succeeded   7m33s
```

**Result**: approve path works end-to-end — secret read happens **only**
after the human approval is reflected on the bus.

## Scenario 3 — prod profile, reject

```
$ kubectl create -f <PipelineRun vault-pipeline-prod>  # request-id req-prod-reject
pipelinerun.tekton.dev/vault-prod-reject-t7plv created

$ kubectl patch approvaltask vault-prod-reject-t7plv-approve \
    --type=merge -p '{"spec":{"approvers":[{"name":"admin","input":"reject","type":"User"}]}}'
approvaltask.openshift-pipelines.org/vault-prod-reject-t7plv-approve patched

$ kubectl get customrun vault-prod-reject-t7plv-approve
NAME                              SUCCEEDED   REASON   DURATION
vault-prod-reject-t7plv-approve   False       Failed   8s

$ kubectl get pipelinerun vault-prod-reject-t7plv
NAME                      SUCCEEDED   REASON   DURATION
vault-prod-reject-t7plv   False       Failed   27s

$ kubectl get taskrun -l tekton.dev/pipelineRun=vault-prod-reject-t7plv
NAME                              SUCCEEDED   REASON      DURATION
vault-prod-reject-t7plv-request   True        Succeeded   16s
# bridge + fetch never ran — Tekton short-circuited downstream tasks
```

**Result**: reject path correctly prevents the Vault read. Secret was
never fetched (no `vault-prod-reject-t7plv-fetch` TaskRun exists).

## Two findings worth recording

1. **`runAfter` short-circuit**. Because `fetch` declares
   `runAfter: [bridge]` and the gate task fails on reject, the bridge
   never gets a chance to write `rejected` into the ConfigMap. This is
   **fine for the happy/sad path**, but it means the ConfigMap-as-bus is
   only loosely coupled to Tekton's own status — the real authority is
   still the ApprovalTask CustomRun status. The ConfigMap helps when the
   "fetch" agent runs **outside** Tekton (e.g. a sidecar in a deployment
   that polls the bus), which is the more general use case being
   modelled.

2. **ApprovalTask validation webhook ties approvers to platform users**.
   `manual-approval-gate-webhook` rejects patches from any user not
   present in `spec.approvers[].name`. That is a strong guarantee — but
   it also means the **approver list inside the Pipeline definition** is
   the IAM-binding mechanism. In production this likely needs to be
   generated from an external group → user resolution, because typing
   user IDs into pipeline YAML defeats the point of group-based RBAC.
