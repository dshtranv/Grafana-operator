# Grafana-operator

Grafana Operator is a Kubernetes operator built to help you manage your Grafana instances and its resources in and outside of Kubernetes.

Whether you’re running one Grafana instance or many, the Grafana Operator simplifies the processes of installing, configuring, and maintaining Grafana and its resources. Additionally, it’s perfect for those who prefer to manage resources using infrastructure as code or using GitOps workflows through tools like ArgoCD and Flux CD.

[What is Grafana Operator](https://grafana.github.io/grafana-operator/docs/)

## Configure PVC-backed Prometheus

Grafana queries Thanos Querier, and Thanos Querier reads the OpenShift monitoring Prometheus data. After the Prometheus retention is extended, Grafana can query the longer history through the same datasource.

Red Hat’s supported path is to configure `cluster-monitoring-config` in `openshift-monitoring`. Persistent storage is recommended for production monitoring, and Red Hat documents `prometheusK8s.volumeClaimTemplate`, `retention`, and `retentionSize` as supported settings.

[Monitoring stack for Red Hat OpenShift 4.20](https://docs.redhat.com/en/documentation/monitoring_stack_for_red_hat_openshift/4.20/pdf/configuring_core_platform_monitoring/Monitoring_stack_for_Red_Hat_OpenShift-4.20-Configuring_core_platform_monitoring-en-US.pdf)

---

> [!WARNING]
> When you add or change PVC configuration for OpenShift monitoring, the affected StatefulSet is recreated and there is a temporary service outage for that monitoring component. Red Hat explicitly documents this behavior.

---

> [!NOTE]
> Existing short-lived metrics are not backfilled.
> If Prometheus currently uses `emptyDir`, switching to PVC starts durable retention from the moment the new pods come up.
> Each Prometheus replica stores its own copy, so `50Gi` with 2 replicas means roughly `100Gi` total backend storage.

---

### Check available StorageClasses

Check whether PVC expansion is supported:

```bash
oc get storageclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner,EXPANSION:.allowVolumeExpansion,MODE:.volumeBindingMode
```

```bash
NAME                       PROVISIONER                  EXPANSION   MODE
<storageclass-name>       <supported-csi-driver>        true        WaitForFirstConsumer
```

> [!NOTE]
> If there is already existing content under `data.config.yaml`, merge the new settings into the existing config. Do not blindly overwrite previous custom monitoring settings.

### Backup existing monitoring configuration

Check if a config already exists:

```bash
oc -n openshift-monitoring get configmap cluster-monitoring-config -o yaml
```

Save the config:

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
```

```bash
configmap/cluster-monitoring-config configured (server dry run)
configmap/user-workload-monitoring-config configured (server dry run)
```

> [!NOTE]
> If the namespace `openshift-user-workload-monitoring` does not exist yet, first apply only the core config with `enableUserWorkload: true`, then wait for the namespace and pods to appear.

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

### Rollback

Revert the ConfigMap to the previous backup:

```bash
oc apply -f monitoring-backup-YYYY-MM-DD/cluster-monitoring-config.yaml
```

If you also changed user workload monitoring:

```bash
oc apply -f monitoring-backup-YYYY-MM-DD/user-workload-monitoring-config.yaml
```

Then monitor:

```bash
watch -n 5 'oc -n openshift-monitoring get pods,pvc,statefulset'
```

>[!WARNING]
> Do not delete PVCs unless you explicitly want to delete retained metrics data.

### Sizing recommendation

For **production**, do not finalize `50Gi` blindly. Start with observed ingest rate.

Run after Prometheus is stable:

```bash
oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
  du -sh /prometheus
```

Check active series:

```bash
oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
  wget -qO- http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series
```

Rule of thumb:

```text
Required storage per replica = current daily growth × retention days × 1.2 safety factor
```

Example:

```text
5 Gi/day × 400 days × 1.2 = 2400 Gi
```

So you would use at least:

```yaml
storage: 3Ti
retentionSize: 2600GB
```

For strict enterprise long-term observability, especially if you need more than one year, many clusters, or compliance/reporting retention, **prefer remote write to an external long-term metrics backend** in addition to local PVC retention. OpenShift 4.20 also supports remote write configuration under `prometheusK8s.remoteWrite`.

## Install Grafana Operator

Option 1 (Cluster Wide):

Operator is installed globally and can watch/manage CRs across namespaces

```bash
oc apply -k operator/
```

Approve the InstallPlan:

```bash
oc -n openshift-operators get installplan

NAME                 CSV                         APPROVAL   APPROVED
<installplan_name>   grafana-operator.v5.x.x     Manual     false
```

```bash
oc -n openshift-operators patch installplan <installplan_name> \
  --type merge \
  -p '{"spec":{"approved":true}}'
```

Option 2 (Namespaced)

Operator is scoped to that namespace only

```bash
oc apply -k operator/namespaced/
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

> [!WARNING]
> When using kubectl apply -k for Kustomize, you often need a second apply because of resource ordering and CRD race conditions.
> ArgoCD avoids this by building dependency graphs, whereas CLI Kustomize applies linearly in alphabetical order without respecting resource creation readiness.

```bash
oc apply -k grafana/
```

Get the service account token:

```bash
oc get secret grafana-sa-token-secret -n grafana -o jsonpath='{.data.token}' | base64 --decode
```

Paste the token to `datasource.yaml`:

```yaml
      httpHeaderValue1: 'Bearer <token>'
```

## Apply Datasource

```bash
oc apply -f datasources/datasource.yaml
```

## Access Grafana

If Grafana was deployed by the Grafana Operator, get the route:

```bash
oc get route -n openshift-operators
```

Or, if the Grafana namespace is different:

```bash
oc get route -A | grep -i grafana
```

Get the Grafana URL:

```bash
GRAFANA_HOST=$(oc -n grafana get route -o jsonpath='{.items[0].spec.host}')
echo "https://${GRAFANA_HOST}"
```

Open the URL in a browser.

## References

- [What is Grafana Operator](https://grafana.github.io/grafana-operator/docs/)
- [Monitoring stack for Red Hat OpenShift 4.20](https://docs.redhat.com/en/documentation/monitoring_stack_for_red_hat_openshift/4.20/pdf/configuring_core_platform_monitoring/Monitoring_stack_for_Red_Hat_OpenShift-4.20-Configuring_core_platform_monitoring-en-US.pdf)
