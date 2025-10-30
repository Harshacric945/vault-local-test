Local Vault Testing - Docker Desktop Kubernetes
Prerequisites
git bash installed on your local laptop 

helm installed on your local laptop 

choco install helm 

vault cli installed on your local laptop 

choco install vault 

Before this install chocolatey which is a windows packaged manager to install all types of tools or cli 

Docker Desktop with Kubernetes enabled

Open Docker Desktop → Settings → Kubernetes → Enable Kubernetes
Wait for it to show "Kubernetes is running"

You need to switch to Docker Desktop's local Kubernetes context.
'''bash
# List all contexts
kubectl config get-contexts

# You'll see something like:
# CURRENT   NAME             CLUSTER
# *         arn:aws:eks...   eks-cluster    ← Currently active (broken)
#           docker-desktop   docker-desktop ← Local K8s

# Switch to docker-desktop
kubectl config use-context docker-desktop

# Verify
kubectl cluster-info
```

**Should now show:**
```
Kubernetes control plane is running at https://kubernetes.docker.internal:6443
CoreDNS is running at https://kubernetes.docker.internal:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
'''

Quick Test After Switching
bash'''
Should work now
kubectl get nodes

# Expected output:
# NAME             STATUS   ROLES           AGE   VERSION
# docker-desktop   Ready    control-plane   Xd    v1.29.x

# Check namespaces
kubectl get namespaces

# Should show default K8s namespaces:
# default, kube-system, kube-public, kube-node-lease
'''
clone the git repository from github in your local laptop or you can fork in your own account and then clone it 

git clone https://github.com/Harshacric945/vault-local-test.git

cd vault-local-test or open this folder through Microsoft VS code with git bash as a terminal to execute the .sh scripts as they wont be executed in cmd or ps1

ls

chmod +x local-vault-test.sh -Make the script executable or modify the permissions to give executable permissions for the file 

./local-vault-test.sh  -> execute the script 

This script does everything from adding helm repo for vault , creating namescape for vault , creating values.yaml for vault with one pod only bcz rn we only have one node so for local testing its okay , installing vault , initilaizing , unsealing the vault pod manually by shamir keys method , testing basic operations like enabling kv pair engine , storing and reading secret , enabling kubernetes authorization and configuring kubernetes authentication , crating k8s roles for test and vault policies and finally setting up port forward too 

Now u can access the vault UI at localhost:8200 


If u encounter any issues quick fixes 

 1. Uninstall any existing Vault
helm uninstall vault -n vault 2>/dev/null || echo "No Vault found"

# 2. Delete the namespace (this cleans everything)
kubectl delete namespace vault

# 3. Wait a few seconds for cleanup
sleep 10

# 4. Verify namespace is gone
kubectl get namespace vault
# Should show: Error from server (NotFound): namespaces "vault" not found

# 5. Now run the script again
./local-vault-test.sh

Understanding the Flow
What the script does:
bash# This creates a TEST ServiceAccount
kubectl create serviceaccount vault-test-sa

# This creates a Vault role bound to that SA
vault write auth/kubernetes/role/test-role \
    bound_service_account_names=vault-test-sa  # ← Only binds to vault-test-sa

    At this point:

Vault is installed ✅
Initialized with 5 keys + root token ✅
All 3 pods unsealed ✅
Basic features tested ✅

Phase 2: Apply Kubernetes Auth Setup
bash# Apply the auth setup YAML
kubectl apply -f vault-kubernetes-auth-SETUP.yaml

# Verify ServiceAccounts created
kubectl get sa -n vault
# Should show: vault-auth

kubectl get sa -n default
# Should show: cartservice-sa, checkoutservice-sa, etc.


Two Scenarios:
Scenario 1: Just Testing Vault Features (Script alone is enough)
If you just want to verify:

Vault initializes correctly
Unsealing works
KV secrets work
Kubernetes auth mechanism works

Then: Run the script alone. No need for auth-setup.yaml.
bash./local-vault-test-portforward.sh
# This proves Vault itself is working!

Scenario 2: Testing Full App Deployment (Need auth-setup.yaml)
If you want to deploy your actual cartservice and have it pull secrets from Vault, you need:

Run the script first (sets up Vault)
Apply auth-setup.yaml (creates app ServiceAccounts)
Create roles for your apps (bind cartservice-sa to Vault)
Deploy your app (cartservice uses Vault Agent Injector)

At this point:

vault-auth SA exists (Vault can review tokens) ✅
cartservice-sa exists (your app can authenticate) ✅

Phase 3: Configure Vault for Your Apps
bash# Set Vault address and token
export VAULT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')
export VAULT_ADDR="http://localhost:8200"

# Get vault-auth SA token
VAULT_AUTH_TOKEN=$(kubectl create token vault-auth -n vault)

# Get Kubernetes info
KUBERNETES_HOST=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
KUBERNETES_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

# Reconfigure Kubernetes auth with vault-auth SA
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault write auth/kubernetes/config \
    kubernetes_host="$KUBERNETES_HOST" \
    kubernetes_ca_cert="$KUBERNETES_CA_CERT" \
    token_reviewer_jwt="$VAULT_AUTH_TOKEN"

echo "✓ Kubernetes auth reconfigured with vault-auth SA"

# Create policy for cartservice
kubectl exec -i -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault policy write cartservice-policy - <<EOF
path "kv/data/cart/*" {
  capabilities = ["read", "list"]
}
EOF

echo "✓ Policy created for cartservice"

# Create Vault role for cartservice
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault write auth/kubernetes/role/cartservice-role \
    bound_service_account_names=cartservice-sa \
    bound_service_account_namespaces=default \
    policies=cartservice-policy \
    ttl=1h

echo "✓ Vault role created for cartservice"

# Store test secret for cartservice
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault kv put kv/cart/config \
    redis_host="redis.default.svc" \
    redis_port="6379" \
    cache_ttl="300"

echo "✓ Secrets stored for cartservice"

At this point:

Kubernetes auth uses vault-auth SA ✅
cartservice-sa can authenticate to Vault ✅
Policy allows cartservice to read secrets ✅


Phase 4: Deploy Test Application

kubectl apply -f test-cartservicedep.yaml

# Wait for pod
kubectl wait --for=condition=ready pod -l app=cartservice --timeout=120s

# Check if it worked
kubectl get pods -l app=cartservice

# Should show: cartservice-xxx   2/2   Running
#              ^ app + vault-agent sidecar

# Check logs - should show secrets loaded
kubectl logs -l app=cartservice -c server

# Expected output:
# =========================================
# ✓ Secrets loaded from Vault!
# =========================================
# REDIS_HOST=redis.default.svc
# REDIS_PORT=6379
# CACHE_TTL=300
# =========================================

If you see this, everything is working perfectly! ✅

Cleanup (When Done)
bash# Delete test deployment
kubectl delete -f test-cartservice.yaml

# Stop port-forward (use PID from script output)
kill <PORT_FORWARD_PID>

# Or just Ctrl+C in the terminal running port-forward

# Delete Vault
helm uninstall vault -n vault
kubectl delete namespace vault

# Delete ServiceAccounts
kubectl delete -f vault-kubernetes-auth-SETUP.yaml


Summary: What Each Step Does
StepWhat It DoesRequired ForScriptInstalls Vault, tests basic featuresTesting Vault itselfauth-setup.yamlCreates ServiceAccounts for appsApp authenticationPhase 3 commandsLinks apps to Vault policiesApp authorizationPhase 4 deploymentDeploys app with Vault injectionEnd-to-end test

Quick Decision Guide
Want to just verify Vault works?
→ Run script only ✅
Want to test full app deployment with Vault?
→ Run all phases (1-5) ✅
Deploying to EKS later?
→ Test all phases locally first, then you'll know exactly what to expect on EKS ✅



