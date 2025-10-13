# infra

## Bootstrap flux 
```
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator --namespace flux-system --create-namespace
kubectl apply -f flux/clusters/{clustername}/flux-instance.yaml
```

## Add flux repo git secret
```
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

## Vault support add a token
```
---
apiVersion: v1
kind: Secret
metadata:
  name: flux-vault-token
  namespace: flux-system
stringData:
  token: 123456789
```
