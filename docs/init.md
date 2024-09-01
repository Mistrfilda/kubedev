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
```

