# Migrace z NGINX Ingress na Traefik

### 1. Vypnutí NGINX Ingress

```bash 
microk8s disable ingress
```

### 2. Zapnutí Traefik

```bash 
microk8s enable traefik
``` 

### 3. Zapnutí MetalLB (pro LoadBalancer support)
```bash 
microk8s enable metallb:192.168.1.245-192.168.1.245
```

```bash 
kubectl apply -f ingress/my-portfolio-tracker-traefik-ingress.yaml
```

### 4. Smazání starého NGINX Ingress
```bash 
kubectl delete ingress nginx-ingress
``` 

### 5. Změna nginx-service na ClusterIP
Upraveno `services/my-portfolio-tracker-nginx-service.yaml`:
- Změna z `type: LoadBalancer` na `type: ClusterIP`
- Traefik Ingress se postará o routing, nepotřebujeme LoadBalancer


```bash 
kubectl apply -f services/my-portfolio-tracker-nginx-service.yaml
```

### 6Změna uptime-kuma služby na NodePort
Upraveno `services/uptime-kuma-service.yaml`:
- Změna z `type: LoadBalancer` na `type: NodePort`
- Důvod: Uvolnit IP adresu 192.168.1.245 pro Traefik

```bash 
kubectl apply -f services/uptime-kuma-service.yaml
``` 

### 7Restart MetalLB (pokud IP zůstává pending)
```bash 
kubectl rollout restart deployment controller -n metallb-system kubectl rollout restart daemonset speaker -n metallb-system
```

## Verifikace

### Zkontrolovat Traefik pod
```bash 
kubectl get pods -n traefik
```

Očekávaný výstup: `Running`

### Zkontrolovat Traefik službu
```bash 
kubectl get svc -n traefik traefik
```

Očekávaný výstup: `EXTERNAL-IP: 192.168.1.245`

### Zkontrolovat Ingress
```bash 
kubectl get ingress
```

Očekávaný výstup: `traefik-ingress` s CLASS `traefik`

### Test funkčnosti
```bash 
curl -H "Host: my-new-portfolio-tracker.internal" http://192.168.1.245
```

Nebo v prohlížeči:
```
http://my-new-portfolio-tracker.internal
``` 

## Traefik vs NGINX Ingress - Rozdíly

| Parametr | NGINX Ingress | Traefik |
|----------|---------------|---------|
| ingressClassName | `public` | `traefik` |
| Annotations | `nginx.ingress.kubernetes.io/*` | `traefik.ingress.kubernetes.io/*` |
| Rewrite | `nginx.ingress.kubernetes.io/rewrite-target` | Většinou není potřeba |

## Přístup k Uptime Kuma po migraci

Uptime Kuma nyní běží na NodePort. Zjištění portu:
```bash 
kubectl get svc -n uptime-kuma uptime-kuma-tcp
```

Přístup:
```
http://192.168.1.245:
``` 

## Troubleshooting

### Traefik služba má status "pending"
Zkontroluj MetalLB:
```

bash kubectl get pods -n metallb-system kubectl logs -n metallb-system deployment/controller```

### Ingress nefunguje
Zkontroluj, že ingressClassName je `traefik`:
```

bash kubectl get ingress -o yaml``` 

### Port forwarding problémy
MicroK8s Traefik standardně běží na portech:
- HTTP: 8000 (nebo 80 s LoadBalancer)
- HTTPS: 8443 (nebo 443 s LoadBalancer)

Zjištění NodePort:
```bash 
kubectl get svc -n traefik traefik
```

## Budoucí vylepšení

- [ ] Nastavit HTTPS s cert-manager
- [ ] Přidat Traefik middleware (rate limiting, auth)
- [ ] Přidat Traefik dashboard
- [ ] Monitorovat Traefik s Prometheus

## Poznámky

- MetalLB přiděluje IP adresy službám, ne porty
- Každá LoadBalancer služba potřebuje vlastní IP z poolu
- Traefik v MicroK8s používá standardně porty 8000/8443, s MetalLB může používat 80/443
-
