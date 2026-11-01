Valkey
-----

One Valkey instance provides shared application cache and Nette sessions for My Portfolio Tracker.
It runs in the dedicated `valkey` namespace behind an internal `ClusterIP` service.
The image is pinned to Valkey 9.0.7 Alpine and its multi-platform digest.

The in-cluster connection URI for Contributte Redis / Predis is:

```text
tcp://valkey.valkey.svc.cluster.local:6379
```

The application must enable its Redis cache storage and session handler separately.
These manifests do not change PHP configuration; localhost can keep file storage.

Resource budget
-----

| Setting                | Initial value                           |
|------------------------|-----------------------------------------|
| Replicas               | 1                                       |
| CPU request / limit    | 25m / 250m                              |
| Memory request / limit | 64Mi / 128Mi                            |
| Valkey `maxmemory`     | 64mb (64 MiB)                           |
| Eviction policy        | `allkeys-lru`                           |
| Disk persistence       | Disabled: no RDB snapshots, AOF, or PVC |

The container memory limit leaves room above `maxmemory` for allocator overhead and client buffers.
These are starting limits for a small cache; monitor memory, evictions, and CPU throttling before increasing them.
The small disk-backed `emptyDir` supplies a writable working directory, not persistent storage.

Cache and sessions share the instance and its eviction policy. Sessions can be evicted under memory pressure.
A PHP application deployment preserves unexpired keys while Valkey remains running. A Valkey process restart
or pod replacement clears all keys, including sessions. Application TTLs and login expiration still apply.
The `Recreate` deployment strategy avoids routing clients to two independent caches during a Valkey update;
that update causes a brief cache outage and starts with an empty dataset.

Access
-----

There is no public ingress, NodePort, or password authentication. The NetworkPolicy allows TCP 6379 from
pods in the `default` namespace, where the PHP deployment, CronJobs, and queue consumers currently run.
This requires a network-policy-capable CNI such as MicroK8s' default Calico. If the application moves
to another namespace, update the policy before moving its clients.

Deploy
-----

Run from the checkout on the MicroK8s host:

```shell
bash scripts/deploy-valkey.sh
```

The script resolves manifest paths relative to itself, applies only the Valkey resources, waits for readiness,
and checks `PING`. It does not restart the PHP application or modify any other workloads.

Verify the rollout and inspect memory usage:

```shell
microk8s kubectl --namespace valkey get pods,service,networkpolicy
microk8s kubectl --namespace valkey exec deployment/valkey -- valkey-cli ping
microk8s kubectl --namespace valkey exec deployment/valkey -- valkey-cli INFO memory
microk8s kubectl --namespace valkey exec deployment/valkey -- valkey-cli INFO stats
```

For an optional connection check from the application's namespace, start a disposable client pod:

```shell
microk8s kubectl --namespace default run valkey-check --rm -i --restart=Never \
    --image=valkey/valkey:9.0.7-alpine@sha256:2d04268dfa26ab31cfa3fdc538866e76438b2d00e41db41b8cb86d780ac5a416 \
    --command -- valkey-cli -h valkey.valkey.svc.cluster.local ping
```

The expected result is `PONG`.

References: [Valkey release](https://valkey.io/download/),
[memory limits and eviction](https://valkey.io/topics/lru-cache/),
[Kubernetes NetworkPolicy](https://kubernetes.io/docs/concepts/services-networking/network-policies/).
