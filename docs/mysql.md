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
