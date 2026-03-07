#!/bin/bash
# deploy.sh — Deploy OpenClaw skills and cron jobs to the cluster
#
# Usage: ssh into the control-plane node (192.168.1.191) and run:
#   bash /path/to/deploy.sh
#
# Prerequisites:
#   - kubectl configured with access to the k3s cluster
#   - OpenClaw running in the "ai" namespace with PVC "openclaw-pvc"
#
set -euo pipefail

NAMESPACE="ai"
DEPLOYMENT="openclaw"
PVC="openclaw-pvc"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== OpenClaw Skills Deployer ==="

# ── 0. YouTube API Credentials (optional) ────────────────────────────
echo ""
echo "[0/3] YouTube API Credentials (for youtube-dj-sets skill)"
echo "     Leave blank to skip - can be added later"
echo ""

read -sp "YouTube Transcript API key: " YOUTUBE_TRANSCRIPT_API_KEY
echo ""

if [ -n "$YOUTUBE_TRANSCRIPT_API_KEY" ]; then
  echo "Get YouTube Data API credentials from: https://console.cloud.google.com/apis/credentials"
  read -p "YouTube Data API Client ID: " YOUTUBE_CLIENT_ID
  read -sp "YouTube Data API Client Secret: " YOUTUBE_CLIENT_SECRET
  echo ""
  
  # Update the openclaw-env-secret with YouTube credentials
  echo ""
  echo "  Updating openclaw-env-secret with YouTube credentials..."
  
  # Get existing secret data
  EXISTING_GATEWAY_TOKEN=$(kubectl get secret openclaw-env-secret -n "$NAMESPACE" -o jsonpath='{.data.OPENCLAW_GATEWAY_TOKEN}' 2>/dev/null | base64 -d || echo "")
  EXISTING_OPENROUTER_KEY=$(kubectl get secret openclaw-env-secret -n "$NAMESPACE" -o jsonpath='{.data.OPENROUTER_API_KEY}' 2>/dev/null | base64 -d || echo "")
  
  kubectl create secret generic openclaw-env-secret \
    --namespace "$NAMESPACE" \
    --from-literal=OPENCLAW_GATEWAY_TOKEN="${EXISTING_GATEWAY_TOKEN}" \
    --from-literal=OPENROUTER_API_KEY="${EXISTING_OPENROUTER_KEY}" \
    --from-literal=YOUTUBE_TRANSCRIPT_API_KEY="$YOUTUBE_TRANSCRIPT_API_KEY" \
    --from-literal=YOUTUBE_CLIENT_ID="$YOUTUBE_CLIENT_ID" \
    --from-literal=YOUTUBE_CLIENT_SECRET="$YOUTUBE_CLIENT_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
  
  echo "  Secret updated."
fi

# ── 1. Copy skill files into the running pod ─────────────────────────
echo ""
echo "[1/4] Deploying skills..."

POD=$(kubectl get pod -n "$NAMESPACE" -l app="$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$POD" ]; then
  echo "ERROR: No running OpenClaw pod found in namespace $NAMESPACE"
  exit 1
fi

# Deploy each skill directory
for skill_dir in "$SCRIPT_DIR"/*/; do
  skill_name=$(basename "$skill_dir")
  if [ -f "$skill_dir/SKILL.md" ]; then
    echo "  → $skill_name"
    kubectl exec -n "$NAMESPACE" "$POD" -c openclaw -- mkdir -p "/home/node/.openclaw/skills/$skill_name"
    kubectl cp "$skill_dir/SKILL.md" "$NAMESPACE/$POD:/home/node/.openclaw/skills/$skill_name/SKILL.md" -c openclaw

    # Copy companion scripts (e.g. youtube_dj_sets.py) into the workspace
    for script in "$skill_dir"/*.py; do
      [ -f "$script" ] || continue
      echo "    → $(basename "$script") → workspace/"
      kubectl cp "$script" "$NAMESPACE/$POD:/home/node/.openclaw/workspace/$(basename "$script")" -c openclaw
    done
  fi
done

echo "  Skills deployed."

# ── 2. Deploy cron jobs (requires gateway stop/start) ────────────────
echo ""
echo "[2/4] Deploying cron jobs..."

if [ -f "$SCRIPT_DIR/cron_jobs.json" ]; then
  echo "  Scaling down deployment to safely write cron jobs..."
  kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=0
  sleep 5

  # Wait for pod to terminate
  kubectl wait --for=delete pod -l app="$DEPLOYMENT" -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

  # Base64-encode the cron jobs file
  B64=$(base64 -w0 "$SCRIPT_DIR/cron_jobs.json")

  # Write via a temporary pod that mounts the PVC
  kubectl run openclaw-cron-editor --rm --restart=Never -n "$NAMESPACE" \
    --attach=true \
    --image=busybox \
    --overrides="{\"spec\":{\"containers\":[{\"name\":\"editor\",\"image\":\"busybox\",\"command\":[\"sh\",\"-c\",\"echo $B64 | base64 -d > /data/cron/jobs.json && echo WRITTEN\"],\"volumeMounts\":[{\"name\":\"data\",\"mountPath\":\"/data\"}]}],\"volumes\":[{\"name\":\"data\",\"persistentVolumeClaim\":{\"claimName\":\"$PVC\"}}],\"restartPolicy\":\"Never\"}}" 2>&1

  echo "  Scaling deployment back up..."
  kubectl scale deployment "$DEPLOYMENT" -n "$NAMESPACE" --replicas=1
  kubectl wait --for=condition=ready pod -l app="$DEPLOYMENT" -n "$NAMESPACE" --timeout=120s
  echo "  Cron jobs deployed."
else
  echo "  No cron_jobs.json found, skipping."
fi

# ── 3. Restart deployment to pick up new env vars ───────────────────
if [ -n "$YOUTUBE_TRANSCRIPT_API_KEY" ]; then
  echo ""
  echo "[3/4] Restarting OpenClaw to pick up new credentials..."
  kubectl rollout restart deployment/$DEPLOYMENT -n $NAMESPACE
  kubectl rollout status deployment/$DEPLOYMENT -n $NAMESPACE --timeout=120s
fi

# ── 4. Verify ────────────────────────────────────────────────────────
echo ""
echo "[4/4] Verification..."

POD=$(kubectl get pod -n "$NAMESPACE" -l app="$DEPLOYMENT" -o jsonpath='{.items[0].metadata.name}')

echo ""
echo "  Skills on disk:"
kubectl exec -n "$NAMESPACE" "$POD" -c openclaw -- ls /home/node/.openclaw/skills/ 2>/dev/null || echo "  (none)"

echo ""
echo "  Cron jobs:"
kubectl exec -n "$NAMESPACE" "$POD" -c openclaw -- cat /home/node/.openclaw/cron/jobs.json 2>/dev/null || echo "  (none)"

echo ""
echo "=== Done ==="
