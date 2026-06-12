# Grafana-operator

## Configure PVC-backed Prometheus

Grafana queries Thanos Querier, and Thanos Querier reads the OpenShift monitoring Prometheus data. After the Prometheus retention is extended, Grafana can query the longer history through the same datasource.

Red Hat’s supported path is to configure `cluster-monitoring-config` in `openshift-monitoring`. Persistent storage is recommended for production monitoring, and Red Hat documents `prometheusK8s.volumeClaimTemplate`, `retention`, and `retentionSize` as supported settings.

> [!WARNING]
> When you add or change PVC configuration for OpenShift monitoring, the affected StatefulSet is recreated and there is a temporary service outage for that monitoring component. Red Hat explicitly documents this behavior.
> [!NOTE]
> Existing short-lived metrics are not backfilled.
> If Prometheus currently uses `emptyDir`, switching to PVC starts durable retention from the moment the new pods come up.
> Each Prometheus replica stores its own copy, so 50Gi with 2 replicas means roughly 100Gi total backend storage.

### Check available StorageClasses

Check whether PVC expansion is supported:

```bash
oc get storageclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,EXPANSION:.allowVolumeExpansion,MODE:.volumeBindingMode

NAME                       PROVISIONER                  EXPANSION   MODE
<storageclass-name>       <supported-csi-driver>        true        WaitForFirstConsumer
```

> [!NOTE]
> If there is already existing content under data.config.yaml, merge the new settings into the existing config. Do not blindly overwrite previous custom monitoring settings.

### Backup existing monitoring configuration

Check if a config already exists:

```bash
oc -n openshift-monitoring get configmap cluster-monitoring-config -o yaml
```

```bash
# Cluster workload
oc -n openshift-monitoring get configmap cluster-monitoring-config -o yaml \
  > cluster-monitoring-config-$(date +%F).yaml 2>/dev/null || true

# Optional: User workload
oc -n openshift-user-workload-monitoring get configmap user-workload-monitoring-config -o yaml \
  > monitoring-backup-$(date +%F)/user-workload-monitoring-config.yaml 2>/dev/null || true
```

### Create cluster-monitoring-config.yaml

This is the main required file for OpenShift core platform metrics:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true

    prometheusK8s:
      retention: 400d
      retentionSize: 45GB
      volumeClaimTemplate:
        spec:
          storageClassName: <storageclass-name>
          volumeMode: Filesystem
          accessModes:
          - ReadWriteOnce
          resources:
            requests:
              storage: 50Ti

    alertmanagerMain:
      volumeClaimTemplate:
        spec:
          storageClassName: <storageclass-name>
          volumeMode: Filesystem
          accessModes:
          - ReadWriteOnce
          resources:
            requests:
              storage: 20Gi
```

> [!NOTE]
> Replace `<storageclass-name>`.
> prometheusK8s.retention: `400d` keeps data for slightly more than one year.
> retentionSize: `45Gi` prevents Prometheus from filling the full `50Gi` PVC.
> Alertmanager PVC is not required for metrics history, but it is recommended for production HA. Red Hat recommends persistent storage for Prometheus and Alertmanager in multi-node clusters.

### Optional: user workload monitoring retention

Use this only if you also need application/user workload metrics retained for one year.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: user-workload-monitoring-config
  namespace: openshift-user-workload-monitoring
data:
  config.yaml: |
    prometheus:
      retention: 400d
      retentionSize: 45GB
      volumeClaimTemplate:
        spec:
          storageClassName: <storageclass-name>
          volumeMode: Filesystem
          accessModes:
          - ReadWriteOnce
          resources:
            requests:
              storage: 50Ti

    thanosRuler:
      retention: 400d
      volumeClaimTemplate:
        spec:
          storageClassName: <storageclass-name>
          volumeMode: Filesystem
          accessModes:
          - ReadWriteOnce
          resources:
            requests:
              storage: 30Gi

    alertmanager:
      volumeClaimTemplate:
        spec:
          storageClassName: <storageclass-name>
          volumeMode: Filesystem
          accessModes:
          - ReadWriteOnce
          resources:
            requests:
              storage: 20Gi
```

Red Hat documents the user workload monitoring components under `user-workload-monitoring-config`, including `prometheus`, `thanosRuler`, and `alertmanager`. It also states that persistent storage is recommended for production and required for HA in multi-node clusters.

### Replace the StorageClass placeholder

```bash
STORAGECLASS="gp3-csi"

sed -i "s/<storageclass-name>/${STORAGECLASS}/g" prometheus/*.yaml

grep -R "storageClassName" .
```

### Dry-run validation

```bash
oc apply -f prometheus/*.yaml --dry-run=server

configmap/cluster-monitoring-config configured (server dry run)
configmap/user-workload-monitoring-config configured (server dry run)
```

> [!NOTE]
> If the namespace openshift-user-workload-monitoring does not exist yet, first apply only the core config with `enableUserWorkload: true`, then wait for the namespace and pods to appear.

### Apply the configuration

```bash
oc apply -f prometheus/*.yaml
```

Monitor the rollout:

```bash
watch -n 5 'oc -n openshift-monitoring get pods,pvc,statefulset'
```

For user workload monitoring:

```bash
watch -n 5 'oc -n openshift-user-workload-monitoring get pods,pvc,statefulset'
```

Expected PVCs for core monitoring:

```bash
prometheus-k8s-db-prometheus-k8s-0
prometheus-k8s-db-prometheus-k8s-1
alertmanager-main-db-alertmanager-main-0
alertmanager-main-db-alertmanager-main-1
alertmanager-main-db-alertmanager-main-2
```

Check the Prometheus pod volume mounts:

```bash
oc -n openshift-monitoring describe pod prometheus-k8s-0 | egrep -A5 "Mounts|prometheus-k8s-db"
```

Validate retention flags:

```bash
oc -n openshift-monitoring get statefulset prometheus-k8s -o yaml | \
  egrep -- '--storage.tsdb.retention|--storage.tsdb.retention.size|--storage.tsdb.path'

--storage.tsdb.retention.time=400d
--storage.tsdb.retention.size=45GB
--storage.tsdb.path=/prometheus
```

### Validate Thanos Querier and Grafana path

Check Thanos Querier:

```bash
oc -n openshift-monitoring get pods -l app.kubernetes.io/name=thanos-query
oc -n openshift-monitoring get svc thanos-querier
```

> [!NOTE]
>Port should include 9091.

Test from inside the Grafana namespace:

```bash
oc -n grafana run thanos-test \
  --rm -i --restart=Never \
  --image=registry.redhat.io/ubi9/ubi-minimal \
  --command -- sh -c '
    microdnf install -y curl ca-certificates >/dev/null 2>&1 || true
    curl -k -s https://thanos-querier.openshift-monitoring.svc.cluster.local:9091/-/ready
  '

OK
```

## Install Grafana Operator

```bash
oc apply -k operator/
```

Approve the InstallPlan:

```bash
oc -n grafana get installplan

NAME                 CSV                         APPROVAL   APPROVED
<installplan_name>   grafana-operator.v5.x.x     Manual     false
```

```bash
oc -n grafana patch installplan <installplan_name> \
  --type merge \
  -p '{"spec":{"approved":true}}'
```

## Deploy the grafana resources

```bash
oc apply -k grafana/
```

Get the token:

```bash
oc get secret grafana-sa-token-secret -n grafana -o jsonpath='{.data.token}' | base64 --decode
```

Paste the token to datasource.yaml:

```yaml
      httpHeaderValue1: 'Bearer <token>'
```

## Apply datasource.yaml

```bash
oc apply -f datasources/datasource.yaml
```

## References

[Monitoring stack for Red Hat OpenShift 4.20](https://docs.redhat.com/en/documentation/monitoring_stack_for_red_hat_openshift/4.20/pdf/configuring_core_platform_monitoring/Monitoring_stack_for_Red_Hat_OpenShift-4.20-Configuring_core_platform_monitoring-en-US.pdf)
