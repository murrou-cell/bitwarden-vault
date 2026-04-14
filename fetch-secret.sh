#!/usr/bin/env bash
set -euo pipefail

PREFIX="bitwarden-vault/"

# -----------------------------
# Login
# -----------------------------
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

# -----------------------------
# Helper: build JSON for patch
# -----------------------------
build_patch_json() {
  local json="{}"

  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    json=$(echo "$json" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
  done <<< "$1"

  echo "$json"
}

# -----------------------------
# Process items
# -----------------------------
echo "$ITEMS_JSON" | jq -c --arg prefix "$PREFIX" '
  .[]
  | select(.name | startswith($prefix))
  | select(.fields? != null and (.fields | length > 0))
' | while IFS= read -r ITEM; do

    SECRET_NAME=$(echo "$ITEM" | jq -r '.name')
    SECRET_TYPE=$(echo "$ITEM" | jq -r '.fields[]? | select(.name=="type") | .value // "generic"')
    SECRET_MODE=$(echo "$ITEM" | jq -r '.fields[]? | select(.name=="mode") | .value // "create"')

    k8s_secret_name=$(echo "$SECRET_NAME" | awk -F'/' '{print $NF}')
    secret_namespace=$(echo "$SECRET_NAME" | awk -F'/' '{print $2}')

    echo "==============================="
    echo "SECRET NAME: $SECRET_NAME"
    echo "K8S SECRET NAME: $k8s_secret_name"
    echo "NAMESPACE: $secret_namespace"
    echo "TYPE: $SECRET_TYPE"
    echo "MODE: $SECRET_MODE"

    # Ensure namespace exists
    if ! kubectl get namespace "$secret_namespace" >/dev/null 2>&1; then
        echo "Creating namespace $secret_namespace"
        kubectl create namespace "$secret_namespace"
    fi

    # -----------------------------
    # Docker config secret
    # -----------------------------
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

    # -----------------------------
    # Generic secret processing
    # -----------------------------
    secret_data=$(echo "$ITEM" | jq -r '
      .fields[]
      | select(.name != "type" and .name != "mode")
      | "\(.name)=\(.value)"
    ')

    # FORCE safety: never overwrite argocd-secret
    if [[ "$k8s_secret_name" == "argocd-secret" ]]; then
        echo "Detected argocd-secret → forcing MERGE mode"
        SECRET_MODE="merge"
    fi

    # -----------------------------
    # MERGE mode (safe patch)
    # -----------------------------
    if [[ "$SECRET_MODE" == "merge" ]]; then
        echo "Merging into secret: $k8s_secret_name"

        patch_json=$(build_patch_json "$secret_data")

        # Try patch first
        if kubectl get secret "$k8s_secret_name" -n "$secret_namespace" >/dev/null 2>&1; then
            kubectl patch secret "$k8s_secret_name" \
              -n "$secret_namespace" \
              --type merge \
              -p "{\"stringData\": $patch_json}"
        else
            echo "Secret does not exist, creating..."
            kubectl create secret generic "$k8s_secret_name" \
              -n "$secret_namespace" \
              --from-literal="$(echo "$secret_data" | tr '\n' ' ')" \
              --dry-run=client -o yaml \
            | kubectl apply -f - >/dev/null
        fi

        echo "merge applied"
        continue
    fi

    # -----------------------------
    # CREATE mode (default overwrite)
    # -----------------------------
    echo "Creating/replacing secret: $k8s_secret_name"

    kubectl_args=()
    while IFS= read -r line; do
        key="${line%%=*}"
        value="${line#*=}"
        kubectl_args+=(--from-literal="$key=$value")
    done <<< "$secret_data"

    kubectl create secret generic "$k8s_secret_name" \
      "${kubectl_args[@]}" \
      -n "$secret_namespace" \
      --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null

    echo "secret applied"

done