#!/bin/bash
# ========================================
# Local Vault Test Script (Single Node)
# Perfect for Docker Desktop (1 replica only)
# ========================================

set -e

echo "========================================="
echo "LOCAL VAULT TESTING (SINGLE NODE)"
echo "========================================="
echo ""

# Check kubectl works
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: kubectl not working"
    exit 1
fi

echo "✓ Kubernetes is running"

# Clean up any existing Vault
echo ""
echo "Cleaning up existing Vault installation..."
helm uninstall vault -n vault 2>/dev/null || true
kubectl delete namespace vault 2>/dev/null || true
sleep 10

# Install Vault
echo ""
echo "Step 1: Installing Vault (single replica)..."
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
helm repo update

kubectl create namespace vault

cat > /tmp/vault-local-single.yaml <<EOF
global:
  enabled: true
  tlsDisable: true

injector:
  enabled: true
  replicas: 1

server:
  # Use standalone mode for single node
  standalone:
    enabled: true
    config: |
      ui = true
      
      listener "tcp" {
        tls_disable = 1
        address = "[::]:8200"
        cluster_address = "[::]:8201"
      }
      
      storage "file" {
        path = "/vault/data"
      }
  
  readinessProbe:
    enabled: true
    path: "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
    initialDelaySeconds: 10
    periodSeconds: 5
  
  livenessProbe:
    enabled: true
    path: "/v1/sys/health?standbyok=true"
    initialDelaySeconds: 30
    periodSeconds: 5
  
  resources:
    requests:
      memory: 128Mi
      cpu: 100m
    limits:
      memory: 256Mi
      cpu: 200m
  
  dataStorage:
    enabled: true
    size: 1Gi
    storageClass: "hostpath"
  
  service:
    enabled: true
    type: ClusterIP

ui:
  enabled: true
  serviceType: ClusterIP
EOF

helm install vault hashicorp/vault -f /tmp/vault-local-single.yaml -n vault

echo "✓ Vault installed"

# Wait for pod
echo ""
echo "Step 2: Waiting for vault-0 to start..."
sleep 20

kubectl wait --for=condition=ready pod/vault-0 -n vault --timeout=120s || {
    echo "ERROR: vault-0 not ready"
    kubectl get pods -n vault
    kubectl describe pod vault-0 -n vault
    exit 1
}

echo "✓ vault-0 is running (sealed)"

# Initialize Vault
echo ""
echo "Step 3: Initializing Vault..."
kubectl exec -n vault vault-0 -- vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json > vault-keys.json

echo "✓ Vault initialized"

# Display keys
echo ""
echo "========================================="
echo "VAULT KEYS (SAVE THESE!)"
echo "========================================="
cat vault-keys.json | jq -r '.unseal_keys_b64[]' | nl -w 1 -s'. '
echo ""
echo "Root Token:"
cat vault-keys.json | jq -r '.root_token'
echo "========================================="
echo ""

# Extract keys
KEY1=$(cat vault-keys.json | jq -r '.unseal_keys_b64[0]')
KEY2=$(cat vault-keys.json | jq -r '.unseal_keys_b64[1]')
KEY3=$(cat vault-keys.json | jq -r '.unseal_keys_b64[2]')
VAULT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')

# Unseal vault-0
echo "Step 4: Unsealing vault-0..."
kubectl exec -n vault vault-0 -- vault operator unseal $KEY1 >/dev/null
echo "  ✓ Key 1/3"
kubectl exec -n vault vault-0 -- vault operator unseal $KEY2 >/dev/null
echo "  ✓ Key 2/3"
kubectl exec -n vault vault-0 -- vault operator unseal $KEY3 >/dev/null
echo "  ✓ Key 3/3 - vault-0 unsealed!"

echo ""
kubectl get pods -n vault

# Test basic operations
echo ""
echo "Step 5: Testing Vault operations..."

# Enable KV
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault secrets enable -path=kv kv-v2 2>/dev/null || echo "  KV already enabled"

# Store secret
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault kv put kv/test/demo \
    username="testuser" \
    password="testpass123" \
    environment="local"
echo "  ✓ Secret stored"

# Read secret
echo ""
echo "Reading secret back:"
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault kv get kv/test/demo

# Enable Kubernetes auth
echo ""
echo "Step 6: Configuring Kubernetes auth..."
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault auth enable kubernetes 2>/dev/null || echo "  Already enabled"

KUBERNETES_HOST=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
KUBERNETES_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

kubectl create serviceaccount vault-test-sa -n default 2>/dev/null || true
SA_TOKEN=$(kubectl create token vault-test-sa -n default)

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault write auth/kubernetes/config \
    kubernetes_host="$KUBERNETES_HOST" \
    kubernetes_ca_cert="$KUBERNETES_CA_CERT" \
    token_reviewer_jwt="$SA_TOKEN" 2>/dev/null

echo "  ✓ Kubernetes auth configured"

# Create policy
kubectl exec -i -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault policy write test-policy - <<EOF
path "kv/data/test/*" {
  capabilities = ["read", "list"]
}
EOF
echo "  ✓ Policy created"

# Create role
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault write auth/kubernetes/role/test-role \
    bound_service_account_names=vault-test-sa \
    bound_service_account_namespaces=default \
    policies=test-policy \
    ttl=1h 2>/dev/null
echo "  ✓ Role created"

# Setup port-forward
echo ""
echo "Step 7: Setting up port-forward..."
kubectl port-forward -n vault svc/vault 8200:8200 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
sleep 3

# Final status
echo ""
echo "========================================="
echo "✓ VAULT TEST COMPLETE!"
echo "========================================="
echo ""
echo "Vault Status:"
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault status
echo ""
echo "Access Vault UI:"
echo "  URL: http://localhost:8200"
echo "  Token: $VAULT_TOKEN"
echo ""
echo "Files created:"
echo "  vault-keys.json - BACKUP THIS FILE!"
echo ""
echo "Port-forward PID: $PORT_FORWARD_PID"
echo "To stop port-forward: kill $PORT_FORWARD_PID"
echo ""
echo "To cleanup:"
echo "  kill $PORT_FORWARD_PID"
echo "  helm uninstall vault -n vault"
echo "  kubectl delete namespace vault"
echo ""
echo "What was tested:"
echo "  ✓ Vault installation (single node)"
echo "  ✓ Initialization (5 keys + root token)"
echo "  ✓ Unsealing vault-0"
echo "  ✓ KV secrets engine"
echo "  ✓ Storing and reading secrets"
echo "  ✓ Kubernetes authentication"
echo "  ✓ Policy creation"
echo "  ✓ Role creation"
echo ""
echo "Next steps:"
echo "  1. Apply: kubectl apply -f vault-kubernetes-auth-SETUP.yaml"
echo "  2. Configure app roles (see guide)"
echo "  3. Deploy test app"
echo ""
echo "Port-forward is running in background..."
echo "Keep this terminal open to access Vault UI"
echo "========================================="