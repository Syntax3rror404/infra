# infra

## 1. Add flux repo git secret
kubectl create ns flux-system
kubectl apply -f git.yaml
```
# git.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: flux-system
  namespace: flux-system
stringData:
  password: "ghp_123456789"
  username: "git"
```

## 2. Vault support add a token (if desired)
kubectl apply -f vault-token.yaml
```
# vault-token.yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: flux-vault-token
  namespace: flux-system
stringData:
  token: 123456789
```

## 3. Create cluster flux files from base
Create config file for cluster inside flux/clusters/yourclustername

## 4. Bootstrap flux 
```
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator --namespace flux-system --create-namespace
kubectl apply -f flux/clusters/{clustername}/flux-instance.yaml
```

