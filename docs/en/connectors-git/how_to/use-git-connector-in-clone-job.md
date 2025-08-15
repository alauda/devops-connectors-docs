---
weight: 10
title: Using Git Connector in Clone Tasks
sourceSHA: 56d028298ef479eb259a14390017d149b51b96421f5a57697b5c2bbb4e082c93
---

## Feature Overview

The Git Connector allows ordinary users to perform code cloning operations without directly handling credentials. With the connector, credential information is centrally managed by an administrator and is automatically injected into the cloning process when needed, enhancing security and convenience.

## Use Cases

- Multiple teams share code repository access rights without sharing credentials.
- Secure access to private code repositories is needed in DevOps pipelines.
- Environments require centralized management of code repository access permissions.
- Avoid hardcoding or embedding Git credentials directly in Kubernetes workloads.

## Prerequisites

Before using the feature, ensure:

- The Connectors Core component is deployed in the environment.
- The Connectors Git component is deployed in the environment.
- You have permissions to create Kubernetes resources (Namespace, Secret, Connector, etc.).

## Steps

Follow these steps to use the Git Connector to complete code cloning:

1. Create a Namespace

    ```shell
    kubectl create ns connectors-git-demo
    ```

2. Create Git Connector and its credentials

    ```shell
    cat <<EOF | kubectl apply -f -
    kind: Secret
    apiVersion: v1
    metadata:
      name: test-secret
      namespace: connectors-git-demo
    type: kubernetes.io/basic-auth
    stringData:
      username: username # Replace with your Git Server username
      password: password # Replace with your Git Server password
    ---
    apiVersion: connectors.alauda.io/v1alpha1
    kind: Connector
    metadata:
      name: test-connector
      namespace: connectors-git-demo
    spec:
      connectorClassName: git
      address: https://github.com # Replace with your Git Server address
      auth:
        name: basicAuth
        secretRef:
          name: test-secret
        params:
        - name: repository
          value: AlaudaDevops/connectors-git.git # Replace with the path to the repository accessible by the current credentials
    EOF
    ```

3. Create a clone job using the connector

    ```shell
    cat <<EOF | kubectl apply -f -
    apiVersion: batch/v1
    kind: Job
    metadata:
      name: git-clone
      namespace: connectors-git-demo
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
          - name: git
            image: bitnami/git:2.47.1
            imagePullPolicy: IfNotPresent
            command:
            - "git"
            args: [ "clone", "--progress", "https://github.com/AlaudaDevops/connectors-git.git", "/tmp/demo" ] # Change to your repository address
            volumeMounts:
            - name: gitconfig
              mountPath: /root/
          volumes:
          - name: gitconfig
            csi:
              readOnly: true
              driver: connectors-csi
              volumeAttributes:
                connector.name: "test-connector"
                configuration.names: "gitconfig"
    EOF
    ```

4. View the clone job execution result

    ```shell
    kubectl logs -f job/git-clone -n connectors-git-demo
    ```

Parameter descriptions are as follows:

| **Parameter**         | **Description**                               |
| --------------------- | --------------------------------------------- |
| connector.name        | Specifies the name of the connector to use   |
| configuration.names   | Specifies the type of configuration file to generate; gitconfig indicates generating a Git configuration file |
| mountPath             | Specifies the mount path for the configuration file; for Git operations, it should be mounted to the /root/ directory |

## Operation Result

After successful configuration, the clone job will be able to complete the cloning of the code repository without directly using credentials. You can verify whether the cloning operation was successful by checking the logs.

## Working Principle

To better understand the working principle of the Git Connector, we can create a long-running Pod to inspect the generated configuration:

```shell
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: pod-git-clone
  namespace: connectors-git-demo
spec:
  restartPolicy: Never
  containers:
  - name: git
    image: bitnami/git:2.47.1
    imagePullPolicy: IfNotPresent
    command:
    - "sleep"
    args: [ "3600" ]
    volumeMounts:
    - name: gitconfig
      mountPath: /root/
  volumes:
  - name: gitconfig
    csi:
      readOnly: true
      driver: connectors-csi
      volumeAttributes:
        connector.name: "test-connector"
        configuration.names: "gitconfig"
EOF
```

Use the following command to view the contents of the generated configuration file:

```shell
kubectl exec -it pod-git-clone -n connectors-git-demo -- cat /root/.gitconfig
```

Example of the generated configuration file:

    [http]
        extraHeader = Authorization: Basic OmV5Smhixxxxxxxxx==
    [url "http://connectors-proxy-service.connectors-system.svc/namespaces/default/connectors/test-connector"]
        insteadOf = https://github.com

During the Git clone process:

1. The original Git repository address is automatically replaced by the `connectors-proxy` service address.
2. The system automatically injects authentication information for the proxy request (this information will expire after 30 minutes).
3. The `connectors-proxy` automatically completes the injection of credential information on the server side to perform the clone operation.
