#!/usr/bin/env bash
set -euo pipefail

PREFIX="bitwarden-vault/"

# Login
if ! bw login --check >/dev/null 2>&1; then
    echo "Logging in to Bitwarden..."
    bw login --apikey
else
    echo "Already logged in, reusing session"
fi

echo "Unlocking Vault..."
SESSION=$(bw unlock "$BW_PASSWORD" --raw)

echo "Fetching all vault items..."
ITEMS_JSON=$(bw list items --session "$SESSION")

echo "$ITEMS_JSON" | jq -c --arg prefix "$PREFIX" '
  .[]
  | select(.name | startswith($prefix))
  | select(.fields? != null and (.fields | length > 0))
' | while IFS= read -r ITEM; do
    SECRET_NAME=$(echo "$ITEM" | jq -r '.name')
    SECRET_TYPE=$(echo "$ITEM" | jq -r '.fields[]? | select(.name=="type") | .value // "generic"')

    k8s_secret_name=$(echo "$SECRET_NAME" | awk -F'/' '{print $NF}')
    secret_namespace=$(echo "$SECRET_NAME" | awk -F'/' '{print $2}')

    echo "==============================="
    echo "SECRET NAME: $SECRET_NAME"
    echo "K8S SECRET NAME: $k8s_secret_name"
    echo "NAMESPACE: $secret_namespace"
    echo "TYPE: $SECRET_TYPE"

    # Ensure namespace exists
    if ! kubectl get namespace "$secret_namespace" >/dev/null 2>&1; then
        echo "Creating namespace $secret_namespace"
        kubectl create namespace "$secret_namespace"
    fi

    # ---- dockerconfigjson secret ----
    if [[ "$SECRET_TYPE" == "dockerconfigjson" ]]; then
        DOCKER_JSON=$(echo "$ITEM" | jq -r '
          .fields[] | select(.name=="dockerconfigjson") | .value
        ')

        if [[ -z "$DOCKER_JSON" ]]; then
            echo "ERROR: dockerconfigjson field missing for $SECRET_NAME"
            continue
        fi

        kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $k8s_secret_name
  namespace: $secret_namespace
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(echo -n "$DOCKER_JSON" | base64 | tr -d '\n')
EOF

        echo "dockerconfigjson secret applied"
        continue
    fi

  # ---- generic secret ----
  secret_data=$(echo "$ITEM" | jq -r '
    .fields[]
    | select(.name != "type")
    | "\(.name)=\(.value|@sh)"
  ')

  # Build kubectl arguments safely
  kubectl_args=()
  while IFS= read -r line; do
      # Remove surrounding single quotes added by @sh
      line="${line#\'}"
      line="${line%\'}"
      kubectl_args+=(--from-literal="$line")
  done <<< "$secret_data"

  kubectl create secret generic "$k8s_secret_name" \
    "${kubectl_args[@]}" \
    -n "$secret_namespace" \
    --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null
done
