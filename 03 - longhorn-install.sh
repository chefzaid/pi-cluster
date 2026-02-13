#!/bin/bash
# Longhorn Installation Script for K3s on Raspberry Pi 4 Cluster
# Uses kubectl apply (no Helm required)
# Optimized settings for 4-node Pi4 cluster

set -e

LONGHORN_VERSION="v1.11.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Longhorn ${LONGHORN_VERSION} Installation (kubectl, no Helm) ==="
echo ""

# Pre-flight: check kubectl access
if ! kubectl get nodes &>/dev/null; then
  echo "ERROR: Cannot connect to Kubernetes cluster. Check your kubeconfig."
  exit 1
fi

# Step 1: Install Longhorn using the official manifest
echo "[1/4] Applying Longhorn ${LONGHORN_VERSION} manifest..."
kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/${LONGHORN_VERSION}/deploy/longhorn.yaml"

# Step 2: Wait for Longhorn manager to be ready
echo ""
echo "[2/4] Waiting for Longhorn manager pods to be ready (up to 5 min)..."
kubectl -n longhorn-system wait --for=condition=ready pod -l app=longhorn-manager --timeout=300s

# Step 3: Apply Pi4-optimized settings
echo ""
echo "[3/4] Applying Pi4-optimized settings..."
if [ -f "${SCRIPT_DIR}/04 - longhorn-pi4-settings.yaml" ]; then
  kubectl apply -f "${SCRIPT_DIR}/04 - longhorn-pi4-settings.yaml"
elif [ -f "${SCRIPT_DIR}/longhorn-pi4-settings.yaml" ]; then
  kubectl apply -f "${SCRIPT_DIR}/longhorn-pi4-settings.yaml"
else
  echo "  WARNING: longhorn-pi4-settings.yaml not found, skipping"
fi

# Step 4: Apply ingress for dashboard access
echo ""
echo "[4/4] Applying Longhorn dashboard ingress..."
if [ -f "${SCRIPT_DIR}/05 - longhorn-ingress.yaml" ]; then
  kubectl apply -f "${SCRIPT_DIR}/05 - longhorn-ingress.yaml"
elif [ -f "${SCRIPT_DIR}/longhorn-ingress.yaml" ]; then
  kubectl apply -f "${SCRIPT_DIR}/longhorn-ingress.yaml"
else
  echo "  WARNING: longhorn-ingress.yaml not found, skipping"
fi

# Wait for UI
echo ""
echo "Waiting for Longhorn UI pods to be ready..."
kubectl -n longhorn-system wait --for=condition=ready pod -l app=longhorn-ui --timeout=120s

echo ""
echo "============================================"
echo "  Longhorn ${LONGHORN_VERSION} Installation Complete"
echo "============================================"
echo ""
echo "Pi4 optimizations applied:"
echo "  - 2 replicas per volume (suits 4-node cluster)"
echo "  - 5% guaranteed instance manager CPU"
echo "  - 1 concurrent rebuild/backup per node"
echo "  - Fast replica rebuild enabled"
echo "  - Soft anti-affinity for replica scheduling"
echo "  - 15% minimum available storage threshold"
echo ""
echo "Dashboard:"
echo "  ClusterIP: $(kubectl -n longhorn-system get svc longhorn-frontend -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo 'pending')"
echo "  Ingress:   http://longhorn.local"
echo ""
echo "Verify: kubectl -n longhorn-system get pods"
