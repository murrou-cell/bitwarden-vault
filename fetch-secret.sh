#!/usr/bin/env bash
set -euo pipefail

PREFIX="bitwarden-vault/"

# Check if already logged in
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
    echo "==============================="
    echo "SECRET NAME: $SECRET_NAME"

    k8s_secret_name=$(echo "$SECRET_NAME" | awk -F'/' '{print $NF}')
    secret_namespace=$(echo "$SECRET_NAME" | awk -F'/' '{print $2}')
    secret_data=$(echo "$ITEM" | jq -r '.fields[] | "\(.name)=\(.value)"')

    echo "K8S SECRET NAME: $k8s_secret_name"

    echo "SECRET NAMESPACE: $secret_namespace"

    echo "SECRET DATA:*HIDDEN FOR SECURITY*"

    # Create or update secret with all fields
    kubectl create secret generic "$k8s_secret_name" \
    $(echo "$secret_data" | sed 's/^/--from-literal=/') \
    -n "$secret_namespace" --dry-run=client -o yaml \
    | kubectl apply -f - >/dev/null

    
    echo "==============================="
done