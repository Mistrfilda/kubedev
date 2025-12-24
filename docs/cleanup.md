Cleanup microk8s diskspace
------

```
microk8s ctr images prune --all
microk8s stop
microk8s start
```
