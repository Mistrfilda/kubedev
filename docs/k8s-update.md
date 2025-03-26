K8S update
------

1. update apt
```
sudo apt-get update
sudo apt-get upgrade
```

2. Zjisteni aktualni verze microk8s https://microk8s.io/docs/release-notes
3. Snap refresh `sudo snap refresh`
4. Update microk8s na posledni verzi
```
sudo snap refresh microk8s --channel=<CURRENT_VERSION>/stable
```
napr. tedy
```
sudo snap refresh microk8s --channel=1.32/stable
```
