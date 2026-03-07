#!/bin/bash
# OpenEBS LocalPV (hostpath) Installation for K3s on Raspberry Pi 4 Cluster
# Uses kubectl apply - no Helm required
# Lightweight local storage: data lives on each node under /var/openebs/local/
#

set -e

OPENEBS_OPERATOR_URL="https://openebs.github.io/charts/openebs-operator-lite.yaml"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== OpenEBS LocalPV Installation ==="
echo ""

# Pre-flight: check kubectl access
if ! kubectl get nodes &>/dev/null; then
  echo "ERROR: Cannot connect to Kubernetes cluster. Check your kubeconfig."
  exit 1
fi

# Step 1: Apply the OpenEBS operator (creates openebs namespace + localpv-provisioner)
echo "[1/3] Applying OpenEBS operator (lite)..."
kubectl apply -f "$OPENEBS_OPERATOR_URL"

# Step 2: Wait for the provisioner deployment
echo ""
echo "[2/3] Waiting for openebs-localpv-provisioner to be ready (up to 3 min)..."
# Wait for namespace to appear first
for i in $(seq 1 20); do
  kubectl get namespace openebs &>/dev/null && break
  sleep 3
done
kubectl -n openebs wait --for=condition=available deployment/openebs-localpv-provisioner \
  --timeout=180s

# The lite operator does NOT auto-create the openebs-hostpath StorageClass — do it here
if ! kubectl get storageclass openebs-hostpath &>/dev/null; then
  echo ""
  echo "  Creating openebs-hostpath StorageClass..."
  kubectl apply -f - <<'SCEOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: openebs-hostpath
  annotations:
    openebs.io/cas-type: local
    cas.openebs.io/config: |
      - name: StorageType
        value: hostpath
      - name: BasePath
        value: /var/openebs/local/
provisioner: openebs.io/local
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
SCEOF
fi

echo ""
echo "[3/3] Verifying StorageClasses..."
kubectl get storageclass

# Step 3: Apply optional custom StorageClass config (basePath override, etc.)
if [ -f "${SCRIPT_DIR}/openebs-localpv.yaml" ]; then
  echo ""
  echo "Applying openebs-localpv.yaml (custom StorageClass settings)..."
  kubectl apply -f "${SCRIPT_DIR}/openebs-localpv.yaml"
else
  echo "  (openebs-localpv.yaml not found, using defaults)"
fi

echo ""
echo "============================================"
echo "  OpenEBS LocalPV Installation Complete"
echo "============================================"
echo ""
echo "Default storage class: openebs-hostpath"
echo "  Data path: /var/openebs/local/<pvc-name>/ on each node"
echo ""
echo "Verify: kubectl get pods -n openebs"
echo "        kubectl get storageclass"
