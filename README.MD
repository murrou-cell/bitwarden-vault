# Bitwarden-vault

This integration creates a cron job that fetches secrets from your Bitwarden vault and stores them in Kubernetes secrets. It retrieves only the additional custom fields defined in each Bitwarden item and translates them into Kubernetes secret key-value pairs.

## Secret Naming Convention

Secrets to be synchronized must follow this naming pattern:


```bash
bitwarden-vault/<namespace>/<secretname>
```

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