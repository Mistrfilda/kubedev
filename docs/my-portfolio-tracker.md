My portfolio tracker zprovozneni
-----

Restart
----
```
kubectl rollout restart deployment nginx-deployment
kubectl rollout restart deployment php-deployment
```


Instalace
-----

1. My-portfolio-tracker jiz pouziva docker containery
2. Vytvoreni volumes z `volumes`

```shell
microk8s kubectl apply -f my-portfolio-tracker-pv.yaml
microk8s kubectl apply -f my-portfolio-tracker-pvc.yaml
microk8s kubectl apply -f my-portfolio-tracker-log-pvc.yaml
```

3. Build
```shell
 docker-compose build
``` 
3. Tag
```shell
docker tag my-portfolio-tracker-php 192.168.1.245:32000/my-portfolio-tracker-php:1.0
docker tag my-portfolio-tracker-nginx 192.168.1.245:32000/my-portfolio-tracker-nginx:1.0
```

4. Push
```shell
docker push 192.168.1.245:32000/my-portfolio-tracker-php:1.0
docker push 192.168.1.245:32000/my-portfolio-tracker-nginx:1.0   
```

5. Nasadit sluzby
```shell
kubectl apply -f my-portfolio-tracker-php-service.yaml
kubectl apply -f my-portfolio-tracker-nginx-service.yaml
```

6. Nasadit deployment z `/deployment`
```shell
kubectl apply -f my-portfolio-tracker-nginx-deployment.yaml
kubectl apply -f my-portfolio-tracker-php-deployment.yaml
```

7. Nasadit cronjobs z `cronjobs`
```shell
kubectl apply -f my-portfolio-tracker-cronjobs.yaml
```

8. Nasadit konfiguraci pro ingress z `ingress`
```shell
kubectl apply -f my-portfolio-tracker-nginx-ingress.yaml
```
