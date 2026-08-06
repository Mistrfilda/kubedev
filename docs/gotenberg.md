Gotenberg
-----

Gotenberg provides Chromium-based HTML screenshots for internal applications in the cluster. It is deployed in the dedicated `gotenberg` namespace and is intentionally exposed only through a `ClusterIP` service.

The in-cluster endpoint is:

```text
http://gotenberg.gotenberg.svc.cluster.local:3000
```

Deploy from `/var/kubedev/kubedev`:

```shell
bash scripts/deploy-gotenberg.sh
```

Verify the rollout and health endpoint:

```shell
microk8s kubectl --namespace gotenberg get pods,service
microk8s kubectl --namespace gotenberg port-forward service/gotenberg 3000:3000
curl http://127.0.0.1:3000/health
```
