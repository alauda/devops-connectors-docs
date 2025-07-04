---
sourceSHA: 9b87d2c1ca4dc028986ab7377c84cf5b41bb8ca765e29e4ded715dfee7beb004
---

# Operator Solution Design

## Design Goals

To implement an operator for deploying applications based on YAML. The operator will facilitate actions such as deploying, modifying, deleting, and upgrading applications through YAML.

## Operator Ecosystem

### Operator Scaffolding

- operator-sdk: Provides tools for building, testing, and packaging operators using OLM (Operator Lifecycle Manager).
  - Offers tools for building, testing, and packaging the operator.
  - Supports managing operators through OLM.
  - Provides examples and templates to help developers get started quickly.

- kubebuilder:
  - Quickly creates Kubernetes APIs and controllers.
  - Supports Custom Resource Definitions (CRDs).
  - Supplies code generation tools to simplify the development process.
  - Integrates testing frameworks, making it easier to test operator functionalities.

### Operator Implementation Methods

- Deploy applications by loading YAML from a specified location (knative, tekton).
  > Deployment resources can be adjusted based on configuration, and multiple resources can be executed sequentially. Management of multiple resources is possible.
  > For complex process control, corresponding logic needs to be implemented separately and an additional abstraction based on deployment objects is required.

- Deploy applications from a fixed location YAML (secret-sci-driver).
  > No adjustments are needed for local YAML files; the operator can directly instantiate objects without requiring an additional abstraction for deployment orchestration.
  > It is not possible to make detailed adjustments to the YAML, and multi-instance management is not supported.

- Deploy applications by rendering Helm charts (tool-operator, gitlab-operator).
  > More complex deployment control can be achieved using Helm; different renderings can be applied through Helm values at deployment time. It can handle deployments of non-cloud-native applications.
  > This introduces maintenance costs for charts as well as issues with release status management. An additional abstraction based on deployment objects is required to provide user management entry points (e.g., GitLab deployment requires user management entry points without an additional abstraction).

- Directly implement the rendering of Kubernetes resource code within the operator code to complete application deployment (prometheus-operator).
  > Allows for more precise deployment control by dynamically adjusting based on deployment statuses of different components.
  > However, orchestration for every resource requires coding, resulting in a larger workload.

## Bundle Packaging Approach

- Generate projects using kubebuilder, which can reuse pkg sharemain code to manage deployed application resources.
- Add OLM packaging configurations to the project created by kubebuilder, enabling direct publication as an operator.
- Use a separate script to place the deployment YAML files into the operator image's kodata/\<application>/ directory.
- The Operator controller reads the YAML from kodata/\<application>/ in the operator image for deployment and modification.

## Operator Processing Workflow

Two new resources will be added:

- Connectors Controller: Defines the deployment object and namespace resource.
- InstallManifest: Records the deployed objects and manages the Kubernetes resources as cluster resources.

![Connectors Controller](/connectors-operator/controller.drawio.svg)

1. Create connector resources, defining match rules and operational options for the Transformer.
2. The operator loads the local YAML files for the Connector deployment.
3. Based on the Connector definition, create a Transformer to adjust the YAML file.
4. Fetch the ConfigMap associated with the Connector. If it does not exist, create it (record the operator version and manifests hash in the InstallManifest). If it exists, proceed to the sub-process.
   - If it exists, compare the recorded operator version in the InstallManifest to see if they are the same; if not, delete the InstallManifest and all existing resources to recreate them.
   - If the operator version is the same, use hash calculations to check for changes; if changes exist, update the resources.
5. Create or update resources based on the information recorded in the InstallManifest. Set the ownerReference of associated resources to the InstallManifest.
6. Update the state of the connector resource, reflecting the deployment results on the connector resource.

### InstallManifest

![InstallManifest Controller](/connectors-operator/controller.drawio.svg)

### Installation

1. Perform the default ownerRef injection operation (except for CRD, namespace, PVC) to facilitate automatic cleanup after deleting the InstallManifest.
2. Ensure CRD resources are installed in the cluster.
3. Ensure cluster-level resources are installed in the cluster.
4. Ensure namespace resources are installed in the cluster.
5. Ensure deployment resources are installed in the cluster and ready (if not ready, return an error and wait for the next reconcile).
6. Ensure StatefulSet resources are installed in the cluster and ready (if not ready, return an error and wait for the next reconcile).

### Update

After confirming that the resources are installed in the cluster, check if they need to be updated. There are two methods for this check.

Method One: Compare the hash recorded in the annotations cpaas.io/last-applied-hash with the hash of the new version resource to determine if an update is needed.

This method applies to resources whose modifications do not affect the deployment object. Users can temporarily adjust certain configurations through editing. Most resources currently use this method.

Method Two: The controller maintains specific paths for managing resources; when a resource changes, only the data managed by the controller is compared. Updates will occur only if corresponding data changes.

Deployment and StatefulSet only observe changes in labels, annotations, and specifications to determine if an update is needed.

### Uninstall

During uninstallation, the `spec.manifests` will be updated to delete resources and remove Finalizers. Additionally, since ownerRefs have been set for each resource that needs deletion upon creation, Kubernetes' garbage collection mechanism will also clean up associated resources.

Setting ownerReference will exclude certain resources that do not need to be cleaned up during uninstallation: CRD, Namespace, PVC.

#### Data Structure

```yaml
apiVersion: v1alpha1
kind: InstallManifest
metadata:
  name: example-install-manifest-deployment
annotations:
  cpaas.io/manifestsHash: "1234567890" # manifests hash value
labels:
  cpaas.io/connectorVersion: "v0.0.1" # connector version
  cpaas.io/connector: "example-connector" # connector name
spec:
  manifests:
    - kind: "Deployment"
      apiVersion: "v1"
      namespace: "default"
      name: "example-deployment"
      spec:
        template:
          metadata:
            labels:
              app: example
    - kind: "Service"
      apiVersion: "v1"
      namespace: "default"
      name: "example-service"
      spec:
        selector:
          app: example
status:
  Conditions:
    - type: Ready
      status: True
      reason: Ready
  connectorVersion: "v0.0.1"
---
apiVersion: v1alpha1
kind: InstallManifest
metadata:
  name: example-install-manifest-static
annotations:
  cpaas.io/last-applied-hash: "1234567890" # manifests hash value
labels:
  cpaas.io/release-version: "v0.0.1" # connector version
  cpaas.io/connector-name: "example-connector" # connector name
  cpaas.io/connector-namespace: "default"
spec:
  manifests:
    - kind: "Deployment"
      apiVersion: "v1"
      namespace: "default"
      name: "example-deployment"
      spec:
        template:
          metadata:
            labels:
              app: example
    - kind: "Service"
      apiVersion: "v1"
      namespace: "default"
      name: "example-service"
      spec:
        selector:
          app: example
status:
  Conditions:
    - type: Ready
      status: True
      reason: Ready
  connectorVersion: "v0.0.1"
```

#### InstallManifest Conditions

| Type                 | Description      |
| -------------------- | ---------------- |
| Ready                | Resource is ready           |
| CrdInstalled         | CRD installation successful         |
| ClustersScoped       | Cluster-scoped resource installation successful      |
| NamespaceScoped      | Namespace-scoped resource installation successful    |
| DeploymentsAvailable | Workload installation successful         |
| StatefulSetReady     | StatefulSet installation successful |

### Connector

```yaml
apiVersion: v1alpha1
kind: Connector
metadata:
  name: example-connector
  namespace: default
spec:
  manifestType: "Metadata" # The type of resources recorded by InstallManifest, supporting two values: Metadata (only records Meta information) and All (records full information). Default is Metadata
  additionalManifests: "https://example.com/manifests.yaml" # Specifies additional manifests file, which can be an external URL or a local file path
  labels: # Global labels
    app: example
  annotations: # Global annotations
    description: "An example connector"
  registry: "registry.example.com" # Specifies the registry address for deploying resources
  workloads: # Workload configurations, currently only supporting Deployment and StatefulSet
    - name: example-deployment # Workload name
      replicas: 1 # Number of workload replicas
      selector: # Workload selector
        matchLabels:
          app: example
      template: # Workload template
        metadata:
          labels:
            app: example
        spec:
          containers:
            - name: example-container
              image: example-image
              resources:
                requests:
                  cpu: 100m
                  memory: 128Mi
status:
  Conditions:
    - type: Ready
      status: True
      reason: Ready
      lastTransitionTime: 2024-11-13T05:32:50Z
    - type: WorkloadAvailable
      status: True
      lastTransitionTime: 2024-11-13T05:32:50Z
    - type: InstallSucceeded
      status: True
      lastTransitionTime: 2024-11-13T05:32:50Z
    - type: TransformersSucceeded
      status: True
      lastTransitionTime: 2024-11-13T05:32:50Z
```

#### Connector YAML Modification Notes

The default deployment of resources for the Connector is in the connector's namespace. Users can modify the deployment resources through the `global`, `workloads`, and `additionalManifests` configurations.

When multiple modification operations are defined in the connector, the application order is as follows:

Use global configuration -> Use workloads -> Use additionalManifests

#### Connector Conditions

| Type                  | Description |
| --------------------- | ----------- |
| Ready                 | Resource is ready      |
| TransformersSucceeded | Transformer execution succeeded     |
| InstallSucceeded      | Installation successful        |
| WorkloadAvailable     | Workload is available      |

### YAML File Loading and Modification

[Manifestival](https://github.com/manifestival/manifestival) provides a complete set of functionalities for loading, modifying, filtering, applying, and deleting YAML files.
