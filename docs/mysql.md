MYSQL setup
-----

1. Vytvoreni dockerfile (viz `docker/mysql`)
2. Build
```shell
cd docker/mysql
docker build -t my-mariadb:1.0 .
```
3. Tag v registry
```shell
 docker tag my-mariadb:1.0 192.168.1.245:32000/my-mariadb:1.0
```

4. Push
```shell
docker push 192.168.1.245:32000/my-mariadb:1.0
```

5. Vyvoreni volumes (z `/volumes`)

```shell
microk8s kubectl apply -f mariadb-pv.yaml
microk8s kubectl apply -f mariadb-pvc.yaml
```

6. Nasazeni (z `/deployment` a `/services`)
```shell
   microk8s kubectl apply -f mariadb-deployment.yaml
   microk8s kubectl apply -f mariadb-service.yaml
```
