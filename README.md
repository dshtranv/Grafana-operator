# Grafana-operator

## Deploy the resources

```bash
oc apply -k grafana/
```

## Get the token

```bash
oc get secret grafana-sa-token-secret -n grafana -o jsonpath='{.data.token}' | base64 --decode
```

## Paste the token to datasource.yaml

```yaml
      httpHeaderValue1: 'Bearer <token>'
```

## Apply datasource.yaml

```bash
oc apply -f datasource.yaml
```
