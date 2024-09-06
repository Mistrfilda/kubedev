My portfolio tracker zprovozneni
-----

1. My-portfolio-tracker jiz pouziva docker containery
2. Build
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
kubectl apply -f php-service.yml
kubectl apply -f nginx-service.yml
```

