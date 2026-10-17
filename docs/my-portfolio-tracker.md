My portfolio tracker zprovozneni
-----

Restart
----
```
kubectl rollout restart deployment nginx-deployment
kubectl rollout restart deployment php-deployment
microk8s kubectl rollout restart statefulset mariadb
```


Instalace
-----


1. My-portfolio-tracker jiz pouziva docker containery
2. Vytvoreni volumes z `volumes`

```shell
microk8s kubectl apply -f my-portfolio-tracker-pv.yaml
microk8s kubectl apply -f my-portfolio-tracker-pvc.yaml
microk8s kubectl apply -f my-portfolio-tracker-log-pvc.yaml
microk8s kubectl apply -f my-portfolio-tracker-puppeter-pvc.yaml
microk8s kubectl apply -f my-portfolio-tracker-gemini-pvc.yaml
microk8s kubectl apply -f my-portfolio-tracker-oauth-pvc.yaml
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


OAuth klíče
-----

`my-pt-oauth-pvc` připojuje 1 GiB z `microk8s-hostpath` do PHP podu na `/var/resources/oauth`. Init container nastaví vlastníka `www-data` a práva adresáře `0700`; existující klíče nepřepisuje. Oba PHP image tagy v deploymentu aktualizuje stávající `deploy-update-k8s-versions.sh` z repozitáře aplikace.

Nasazovaný image aplikace musí obsahovat výchozí cestu `resources/oauth` v `api.oauth.keysDirectory`. Před přechodem ze staré cesty `var/oauth` přenes existující klíče na PVC se zachováním obsahu a práv. Generování nových klíčů je určené pouze pro prázdné úložiště; nahrazení klíčů zneplatní dosavadní tokeny a rozpracovaná přihlášení.

Z kořene tohoto repozitáře aplikuj manifesty v tomto pořadí (na clusteru lze použít `microk8s kubectl`):

```bash
kubectl -n default apply -f volumes/my-portfolio-tracker-oauth-pvc.yaml
kubectl -n default apply -f deployment/my-portfolio-tracker-php-deployment.yaml
kubectl -n default rollout status deployment/php-deployment
```

Deploy skript `scripts/deploy-my-portfolio-tracker.sh` aplikuje PVC automaticky před deploymentem. PVC může čekat ve stavu `Pending`, dokud ho nezačne používat pod (`WaitForFirstConsumer`).

Pro nové prázdné úložiště po prvním nasazení jednou spusť:

```bash
kubectl -n default exec deployment/php-deployment -c php-container -- \
    su -s /bin/sh www-data -c 'cd /var && bin/console oauth:keys:generate'
```

Klíče se vytvoří s právy `0600`. Další nasazení je ponechají na PVC, příkaz záměrně odmítá existující klíče přepsat. Již registrované OAuth klienty není potřeba vytvářet znovu.

Stav a oprávnění lze zkontrolovat bez výpisu obsahu klíčů:

```bash
kubectl -n default get pvc my-pt-oauth-pvc
kubectl -n default exec deployment/php-deployment -c php-container -- \
    ls -ld /var/resources/oauth /var/resources/oauth/private.key /var/resources/oauth/public.key /var/resources/oauth/encryption.key
```

Klíče zálohuj odděleně a PVC nemaž při běžném nasazení. Použitá storage class má reclaim policy `Delete`; odstranění PVC může smazat jeho data. [MicroK8s hostpath storage](https://canonical.com/microk8s/docs/addon-hostpath-storage) ukládá data na konkrétním uzlu a nenahrazuje zálohu.
