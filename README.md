Local Vault Testing - Docker Desktop Kubernetes
Prerequisites

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
bash# Should work now
kubectl get nodes

# Expected output:
# NAME             STATUS   ROLES           AGE   VERSION
# docker-desktop   Ready    control-plane   Xd    v1.29.x

# Check namespaces
kubectl get namespaces

# Should show default K8s namespaces:
# default, kube-system, kube-public, kube-node-lease
