# Cleanup MicroK8s disk space

There are two separate image stores:

1. the built-in Docker Registry on port `32000`;
2. the local containerd cache used by running Kubernetes workloads.

Cleaning one does not clean the other.

## Built-in Registry

The retention script works both from a workstation with the `microk8s`
`kubectl` context and directly on the Raspberry Pi:

```bash
./scripts/cleanup-registry-images.sh
```

The default invocation is a read-only preview. It only handles:

- `my-portfolio-tracker-nginx`;
- `my-portfolio-tracker-php`.

For each repository it keeps:

- the five numerically newest tags;
- tags referenced by Deployments, StatefulSets, DaemonSets, CronJobs and
  currently active Pods;
- every non-numeric tag.

Historical ReplicaSets and completed Jobs are intentionally not protected.
Consequently, a Kubernetes rollback older than the retained window may no
longer be able to pull its image.

Dependencies:

- `bash`;
- `curl`;
- `jq`;
- either `kubectl`, `microk8s kubectl`, or `/snap/bin/microk8s kubectl`.

Delete the manifests shown by the preview:

```bash
./scripts/cleanup-registry-images.sh --apply
```

Deleting manifests does not immediately release disk space. Run deletion and
garbage collection together during a maintenance window:

```bash
./scripts/cleanup-registry-images.sh --apply --garbage-collect
```

Garbage collection temporarily switches the Registry to read-only mode,
restarts its Pod, performs the cleanup and restores read-write mode. Image
pushes are rejected while it is read-only and the single Registry Pod restarts
can also briefly interrupt pulls, so use a maintenance window.

The defaults can be overridden:

```bash
./scripts/cleanup-registry-images.sh \
    --registry-url http://192.168.1.245:32000 \
    --keep 5
```

Use `--verbose` to include every selected tag and manifest digest in the
preview.

## Local containerd cache

This is independent from Registry retention. To remove images no longer used
by containers on the MicroK8s node:

```bash
sudo microk8s ctr images prune --all
```
