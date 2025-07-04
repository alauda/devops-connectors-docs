---
sourceSHA: 726575cedb938a5ca8bad3a82b491f45494064e5b3b7d69376f82e5769f48c22
---

# InstallManifest Resource Update

For resources already deployed to the cluster, the controller needs to observe changes to these resources and update the associated managed resources to meet installation expectations.

## Existing Issues

### Issue 1: How Should the Controller Watch the Resource List

As the resources to be deployed by InstallManifest are user-defined, it is not possible to determine the list of resources to be observed prior to configuration.

- Observing Only Some Resources

> Currently, most operators such as Knative and Tekton exhibit this behavior.
>
> **Issue**: Certain resources that are not within the observation scope can be inadvertently modified by other users, causing instances to run in an unexpected state. When adding observed resources, an analysis must be done in advance to determine which parts are permissible for user modification and which modifications need to be corrected in a timely manner.
> **Advantage**: Fewer observed resources result in simpler overall logic.

- Dynamically Adding Resources Recorded in InstallManifest spec.manifests as Observables.

> This approach is employed by chart operators.
>
> **Issue**: The number of resources of interest increases, necessitating a unified logical filtering of the resources managed by the deployment spec.manifests.
> **Advantage**: All resources can be deployed as intended.

Observing all resources adds complexity but allows all resources to operate as expected.

### Issue 2: Multiple Controllers Managing a Resource Simultaneously

There are cases where deployed resources are managed by multiple controllers, leading to:

1. Updating resources within one controller may overwrite fields managed by other controllers.
2. Modifications from other controllers can trigger unnecessary reconciliation.

Solutions:

- Calculate the hash value of the management fields of the expected installation resources and compare it with the hash value of the resources upon installation to determine if any changes have occurred.

Since only the management resources are calculated, this approach avoids influence from fields managed by other managers.

> **Issue**: If the installation resource has been modified by other users, the hash value on the resource will not change, resulting in the resource operating in an unexpected state.

- By explicitly specifying the YAML path of the observed resources, only the relevant path parts are compared during reconciliation, avoiding influence from other controllers.

> **Issue**: With numerous resource types, it is impossible to enumerate all paths. Processing can only be performed on a limited set of resources.

- Update resources via server-side apply. During creation, the manager fields of the resource will record the controller-managed fields. Using server-side apply will only update the managed fields.

> **Issues**:
>
> 1. Manager fields may be updated by other users, resulting in conflicts (forced updates can be employed to overwrite).
> 2. The applied object must contain all management fields.

By updating resources using server-side apply, it is possible to only update the fields that need management, and there is no need to manage which fields should be updated manually. When non-managed fields trigger an update, it will initiate an update, but it will not affect the resource.
