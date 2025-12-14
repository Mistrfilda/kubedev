Raspberry PI 5 mk8s init
-----

Prvotni setup
------

Otevrit

```shell
sudo nano /boot/firmware/cmdline.txt
```

A pridat 

```shell
cgroup_enable=memory cgroup_memory=1
```


Instalace
-----

```shell
sudo snap install microk8s --classic --channel=1.30
sudo usermod -a -G microk8s filip
sudo chown -R filip ~/.kube
sudo reboot 
microk8s enable dns dashboard storage
microk8s enable registry prometheus dashboard
microk8s enable traefik
```

Docker registry
----
Pridani lokalniho registry do docker daemona. Lokalne mam ORBstack, tudiz jit pres `settings > docker` a pridat 
```
{
  "insecure-registries" : [
    "192.168.1.245:32000"
  ]
}
```

Pridani do mk8s na raspberry pi 

```
sudo mkdir -p /var/snap/microk8s/current/args/certs.d/192.168.1.245:32000
sudo touch /var/snap/microk8s/current/args/certs.d/192.168.1.245:32000/hosts.toml
```

Then, edit the file we just created and make sure the contents are as follows:

`sudo nano /var/snap/microk8s/current/args/certs.d/192.168.1.245:32000/hosts.toml`

```
# /var/snap/microk8s/current/args/certs.d/192.168.1.245:32000/hosts.toml
server = "http://192.168.1.245:32000"

[host."http://192.168.1.245:32000"]
capabilities = ["pull", "resolve"]
```

a pote

```
microk8s stop
microk8s start
```

Dashboard
----

Zjisteni tokenu
```
microk8s kubectl create token default
```

Prepnout se do `services`
```
microk8s kubectl apply -f dashboard.yaml
```
