
# 🧩 Local Vault Testing on Docker Desktop (Kubernetes)

This guide helps you **test HashiCorp Vault locally** using **Docker Desktop’s Kubernetes** environment.  
It automates Vault installation, initialization, unsealing, and Kubernetes authentication setup.

---

## 🧰 Prerequisites

Ensure you have the following installed on your Windows laptop:

### 🪄 Chocolatey (Windows Package Manager)
Chocolatey is used to install CLI tools easily.

```bash
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
````

### 🔧 Install Required Tools

```bash
choco install git
choco install helm
choco install vault
```

### 🐳 Docker Desktop with Kubernetes Enabled

1. Open **Docker Desktop → Settings → Kubernetes → Enable Kubernetes**
2. Wait until it shows:
   **“Kubernetes is running”**

---

## ⚙️ Switch to Docker Desktop Kubernetes Context

```bash
# List all contexts
kubectl config get-contexts

# Example output:
# CURRENT   NAME             CLUSTER
# *         arn:aws:eks...   eks-cluster
#           docker-desktop   docker-desktop

# Switch to Docker Desktop
kubectl config use-context docker-desktop

# Verify the connection
kubectl cluster-info
```

✅ Expected Output:

```
Kubernetes control plane is running at https://kubernetes.docker.internal:6443
CoreDNS is running at https://kubernetes.docker.internal:6443/api/v1/namespaces/kube-system/services/kube-dns:dns/proxy
```

---

## 🔍 Quick Test After Switching

```bash
kubectl get nodes
kubectl get namespaces
```

✅ Expected Output:

```
NAME             STATUS   ROLES           AGE   VERSION
docker-desktop   Ready    control-plane   Xd    v1.29.x
```

Default namespaces:

```
default, kube-system, kube-public, kube-node-lease
```

---

## 📦 Clone the Repository

```bash
git clone https://github.com/Harshacric945/vault-local-test.git
cd vault-local-test
```

Or open the folder in **VS Code** using the integrated Git Bash terminal.

---

## 🚀 Run the Setup Script

Make the script executable and run it:

```bash
chmod +x local-vault-test.sh
./local-vault-test.sh
```

This script will:

* Add the Helm repo for Vault
* Create the `vault` namespace
* Generate a `values.yaml` for local setup (single pod)
* Install Vault via Helm
* Initialize and unseal Vault (manually via Shamir keys)
* Enable KV engine and store/read test secrets
* Configure Kubernetes authentication
* Create test roles and policies
* Start port-forwarding to the Vault UI

Vault UI will be available at:
👉 **[http://localhost:8200](http://localhost:8200)**

---

## 🧹 Quick Fixes

If you encounter issues, run:

```bash
# 1. Uninstall existing Vault
helm uninstall vault -n vault 2>/dev/null || echo "No Vault found"

# 2. Delete namespace
kubectl delete namespace vault

# 3. Wait and verify cleanup
sleep 10
kubectl get namespace vault
# Should show: Error from server (NotFound)
```

Then re-run the script:

```bash
./local-vault-test.sh
```

---

## 🧠 Understanding the Flow

### Script Actions

```bash
# Create a test ServiceAccount
kubectl create serviceaccount vault-test-sa

# Bind Vault role to ServiceAccount
vault write auth/kubernetes/role/test-role \
    bound_service_account_names=vault-test-sa
```

✅ After script execution:

* Vault installed
* Initialized with 5 keys + root token
* Pods unsealed
* KV engine tested
* Kubernetes auth configured

---

## ⚙️ Phase 2: Kubernetes Auth Setup

Apply the Kubernetes auth setup YAML:

```bash
kubectl apply -f k8sdemo-auth-setup.yaml
```

Verify:

```bash
kubectl get sa -n vault
kubectl get sa -n default
```

---

## 🎯 Scenarios

### Scenario 1: Testing Vault Only

Run only the script:

```bash
./local-vault-test-portforward.sh
```

✅ Verifies Vault initialization, unseal, and KV engine.

---

### Scenario 2: Testing Full App Integration

1. Run the setup script (Vault installed)
2. Apply `k8sdemo-auth-setup.yaml`
3. Create Vault roles and policies for your app
4. Deploy your app with Vault Agent Injector

---

## 🏗️ Phase 3: Configure Vault for Your Apps

```bash
export VAULT_TOKEN=$(cat vault-keys.json | jq -r '.root_token')
export VAULT_ADDR="http://localhost:8200"

VAULT_AUTH_TOKEN=$(kubectl create token vault-auth -n vault)
KUBERNETES_HOST=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
KUBERNETES_CA_CERT=$(kubectl config view --raw --minify --flatten -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)

kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault write auth/kubernetes/config \
    kubernetes_host="$KUBERNETES_HOST" \
    kubernetes_ca_cert="$KUBERNETES_CA_CERT" \
    token_reviewer_jwt="$VAULT_AUTH_TOKEN"

# Create policy
kubectl exec -i -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault policy write cartservice-policy - <<EOF
path "kv/data/cart/*" {
  capabilities = ["read", "list"]
}
EOF

# Create Vault role
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault write auth/kubernetes/role/cartservice-role \
    bound_service_account_names=cartservice-sa \
    bound_service_account_namespaces=default \
    policies=cartservice-policy \
    ttl=1h

# Store test secret
kubectl exec -n vault vault-0 -- env VAULT_TOKEN=$VAULT_TOKEN vault kv put kv/cart/config \
    redis_host="redis.default.svc" \
    redis_port="6379" \
    cache_ttl="300"
```

✅ Now your app’s ServiceAccount can authenticate and fetch secrets securely.

---

## 🧩 Phase 4: Deploy Test Application

```bash
kubectl apply -f test-cartservicedep.yaml
kubectl wait --for=condition=ready pod -l app=cartservice --timeout=120s
kubectl get pods -l app=cartservice
kubectl logs -l app=cartservice -c server
```

✅ Expected Output:

```
✓ Secrets loaded from Vault!
REDIS_HOST=redis.default.svc
REDIS_PORT=6379
CACHE_TTL=300
```

---

## 🧹 Cleanup

```bash
kubectl delete -f test-cartservice.yaml
helm uninstall vault -n vault
kubectl delete namespace vault
kubectl delete -f k8sdemo-auth-setup.yaml
```

---

## 🪶 Summary

| Step              | Purpose                       | Required For          |
| ----------------- | ----------------------------- | --------------------- |
| Script            | Installs and configures Vault | Vault testing         |
| `auth-setup.yaml` | Creates ServiceAccounts       | App auth              |
| Phase 3           | Binds apps to Vault policies  | Authorization         |
| Phase 4           | Deploys test app              | End-to-end validation |

---

## 💡 Tips for Local to EKS Transition

* Verify everything locally first
* The same setup works on **EKS** with minor changes (IRSA, Helm values)
* Once confident, automate everything with **Helm + Argo CD**

---

## ✅ Quick Decision Guide

| Goal                       | Action                       |
| -------------------------- | ---------------------------- |
| Verify Vault setup only    | Run script                   |
| Test app + Vault injection | Run all phases               |
| Prepare for EKS deployment | Run all phases locally first |

---

**Author:** [Harsha Koppu](https://github.com/Harshacric945)
**License:** MIT

