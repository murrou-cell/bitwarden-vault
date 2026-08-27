#!/usr/bin/env bash
set -euo pipefail

PREFIX="bitwarden-vault/"

# Reserved control-field names. Everything else on an item becomes a key in
# the resulting Kubernetes Secret, so a Secret cannot carry a data key with
# one of these exact names.
#   type   - "generic" (default, Opaque) or "dockerconfigjson"
#   mode   - "create" (default, replace) or "merge" (patch in place)
#   labels - optional JSON object, applied to metadata.labels
CONTROL='["type","mode","labels"]'

# -----------------------------
# Login + unlock
# -----------------------------
if ! bw login --check >/dev/null 2>&1; then
    echo "Logging in to Bitwarden..."
    bw login --apikey
else
    echo "Already logged in, reusing session"
fi

echo "Unlocking Vault..."
SESSION=$(bw unlock "$BW_PASSWORD" --raw)

echo "Syncing vault..."
bw sync --session "$SESSION"

echo "Fetching all vault items..."
ITEMS_JSON=$(bw list items --session "$SESSION")

# =============================================================================
# apply_one <item-json>
# Handles a single vault item. Returns non-zero on failure so the caller can
# skip it without aborting the whole run. Runs in a subshell (see the loop),
# so `set -e` failures here don't kill the parent.
# =============================================================================
apply_one() {
    local ITEM="$1"

    local SECRET_NAME k8s_secret_name secret_namespace SECRET_TYPE SECRET_MODE
    SECRET_NAME=$(jq -r '.name' <<<"$ITEM")
    k8s_secret_name=$(awk -F'/' '{print $NF}' <<<"$SECRET_NAME")
    secret_namespace=$(awk -F'/' '{print $2}' <<<"$SECRET_NAME")
    SECRET_TYPE=$(jq -r 'first(.fields[]? | select(.name=="type")  | .value) // "generic"' <<<"$ITEM")
    SECRET_MODE=$(jq -r 'first(.fields[]? | select(.name=="mode")  | .value) // "create"'  <<<"$ITEM")

    echo "==============================="
    echo "SECRET NAME:     $SECRET_NAME"
    echo "K8S SECRET NAME: $k8s_secret_name"
    echo "NAMESPACE:       $secret_namespace"
    echo "TYPE:            $SECRET_TYPE"
    echo "MODE:            $SECRET_MODE"

    # never let the tool clobber Argo CD's own secret
    if [[ "$k8s_secret_name" == "argocd-secret" ]]; then
        echo "Detected argocd-secret -> forcing MERGE mode"
        SECRET_MODE="merge"
    fi

    if ! kubectl get namespace "$secret_namespace" >/dev/null 2>&1; then
        echo "Creating namespace $secret_namespace"
        kubectl create namespace "$secret_namespace"
    fi

    # optional metadata.labels (control field "labels" holding a JSON object)
    local LABELS_JSON
    LABELS_JSON=$(jq -c 'first(.fields[]? | select(.name=="labels") | .value) // "{}" | fromjson' <<<"$ITEM")

    # k8s Secret type + the data object, values base64-encoded (handles
    # multi-line, "=", quotes, anything - no line-based parsing).
    local K8S_TYPE DATA_JSON
    if [[ "$SECRET_TYPE" == "dockerconfigjson" ]]; then
        K8S_TYPE="kubernetes.io/dockerconfigjson"
        DATA_JSON=$(jq -c --argjson c "$CONTROL" '
            [.fields[] | select(.name | IN($c[]) | not)
             | {(if .name == "dockerconfigjson" then ".dockerconfigjson" else .name end):
                (.value | @base64)}]
            | add // {}' <<<"$ITEM")
    else
        K8S_TYPE="Opaque"
        DATA_JSON=$(jq -c --argjson c "$CONTROL" '
            [.fields[] | select(.name | IN($c[]) | not)
             | {(.name): (.value | @base64)}]
            | add // {}' <<<"$ITEM")
    fi

    if [[ "$DATA_JSON" == "{}" || "$DATA_JSON" == "null" ]]; then
        echo "ERROR: no data fields on $SECRET_NAME"; return 1
    fi

    # -----------------------------
    # MERGE: patch data (+labels) into the existing secret, leaving every
    # other key / label / annotation / .type untouched.
    # -----------------------------
    if [[ "$SECRET_MODE" == "merge" ]]; then
        if kubectl get secret "$k8s_secret_name" -n "$secret_namespace" >/dev/null 2>&1; then
            local patch
            patch=$(jq -nc --argjson data "$DATA_JSON" --argjson labels "$LABELS_JSON" \
                '{data:$data} + (if ($labels|length) > 0 then {metadata:{labels:$labels}} else {} end)')
            kubectl patch secret "$k8s_secret_name" -n "$secret_namespace" --type merge -p "$patch"
            echo "merge applied"
            return 0
        fi
        echo "Secret does not exist yet - creating it instead of merging"
    fi

    # -----------------------------
    # CREATE (default): apply a full manifest built from the item.
    # -----------------------------
    jq -nc \
        --arg name "$k8s_secret_name" --arg ns "$secret_namespace" --arg stype "$K8S_TYPE" \
        --argjson data "$DATA_JSON" --argjson labels "$LABELS_JSON" \
        '{apiVersion:"v1", kind:"Secret", type:$stype, data:$data,
          metadata: ({name:$name, namespace:$ns}
                     + (if ($labels|length) > 0 then {labels:$labels} else {} end))}' \
      | kubectl apply -f - >/dev/null
    echo "secret applied"
}

# -----------------------------
# Process all bitwarden-vault/* items. One bad item is logged and skipped;
# the run still processes everything else and exits 0 unless nothing worked.
# -----------------------------
failed=0
total=0
while IFS= read -r ITEM; do
    total=$((total + 1))
    if ! ( apply_one "$ITEM" ); then
        name=$(jq -r '.name' <<<"$ITEM" 2>/dev/null || echo "?")
        echo "!!! FAILED: $name - skipping, continuing with the rest"
        failed=$((failed + 1))
    fi
done < <(jq -c --arg prefix "$PREFIX" '
    .[] | select(.name | startswith($prefix))
        | select(.fields? != null and (.fields | length > 0))' <<<"$ITEMS_JSON")

echo "==============================="
echo "Done: $((total - failed))/$total secrets applied, $failed failed."
[[ "$failed" -lt "$total" ]]
