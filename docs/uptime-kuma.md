Uptime Kuma https://github.com/louislam/uptime-kuma
-----

script: `./scripts/deploy-uptime-kuma.sh`

1. Vytvorit namespace
```shell
kubectl apply -f namespace/namespace/uptime-kuma-namespace.yaml)
```

2. Vyvoreni volumes (z `/volumes`)

```shell
microk8s kubectl apply -f uptime-kuma-pv.yaml
microk8s kubectl apply -f uptime-kuma-pvc.yaml
```

3. Nasazeni (z `/deployment` a `/services`)
```shell
microk8s kubectl apply -f deployment/uptime-kuma-deployment.yaml
microk8s kubectl apply -f services/uptime-kuma-service.yaml
```
