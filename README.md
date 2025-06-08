# infra

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
