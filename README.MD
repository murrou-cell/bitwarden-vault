# Bitwarden-vault

This integration creates a cron job that fetches secrets from your Bitwarden vault and stores them in Kubernetes secrets. It retrieves only the additional custom fields defined in each Bitwarden item and translates them into Kubernetes secret key-value pairs.

## Secret Naming Convention

Secrets to be synchronized must follow this naming pattern:


```bash
bitwarden-vault/<namespace>/<secretname>
```

## Item fields

Every custom field on the item becomes a key in the resulting Kubernetes
Secret. Field **values are base64-encoded as-is**, so multi-line values
(private keys, cookie jars, PEM bundles) and values containing `=`, spaces
or quotes are all handled.

Four field names are reserved as controls (a Secret therefore cannot have a
data key with one of these exact names):

| field    | values | meaning |
|----------|--------|---------|
| `type`   | `generic` (default) / `dockerconfigjson` | `dockerconfigjson` produces a `kubernetes.io/dockerconfigjson` Secret; put the raw `{"auths":...}` JSON in a field named `dockerconfigjson`. |
| `mode`   | `create` (default) / `merge` | `create` applies a full manifest (replaces the Secret, drops keys/labels not re-specified). `merge` patches only the listed keys (and `labels`) into an existing Secret, leaving everything else — other keys, `.type`, annotations, labels — untouched. Use `merge` for any Secret that must keep a label it doesn't declare here (e.g. an Argo CD `repository` Secret). `argocd-secret` is always forced to `merge`. |
| `labels` | JSON object | applied to `metadata.labels`. |
| `replicate` | `all` / comma-separated namespaces | also write the Secret into those namespaces (`all` = every Active namespace except `kube-*`). An explicit `bitwarden-vault/<ns>/<same-name>` item wins over a replica. Replicas are not pruned if the field is removed. Needs `list` on namespaces. |

One bad item is logged (`!!! FAILED: …`) and skipped; the run still processes
everything else. The job only fails if *nothing* synced.

> **Do not run `bw` against this deployment's PVC while a sync job is running**
> (e.g. a debug pod mounting the same `bitwarden-vault-pvc`). The Bitwarden
> CLI's `data.json` is not safe for concurrent access — the sync job's session
> gets clobbered and it falls back to an interactive password prompt. Suspend
> the CronJob first (`kubectl patch cronjob … -p '{"spec":{"suspend":true}}'`).

## Prerequisites

Create the required secret before deployment in your Kubernetes cluster:

```bash
kubectl create secret generic bw-credentials \
    --from-literal=BW_CLIENTID=<your-client-id> \
    --from-literal=BW_CLIENTSECRET=<your-client-secret> \
    --from-literal=BW_PASSWORD=<your-master-password> \
    --namespace bitwarden-vault
```

**Note:** Replace the placeholder values with your actual Bitwarden credentials.

**Disclaimer:** This project is not affiliated with, endorsed by, or connected to Bitwarden in any way.