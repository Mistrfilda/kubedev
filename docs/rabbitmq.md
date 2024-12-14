RabbitMQ
-----

1. Vybuildit docker container ze slozky docker/rabbitmq
```shell
docker build -t my-rabbitmq-image:1.0 .
```

2. Tag v registry
```shell
docker tag my-rabbitmq-image:1.0 192.168.1.245:32000/my-rabbitmq-image:1.0
```

3. Push
```shell
docker push 192.168.1.245:32000/my-rabbitmq-image:1.0
```
