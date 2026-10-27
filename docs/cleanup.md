# Údržba místa na Raspberry Pi

Server: `filip@192.168.1.245`, repozitář: `/var/kubedev/kubedev`.
Na Pi používej aktuální verzi repozitáře po commitu a `git pull`.

## Registry: ruční úklid

Na Pi pod uživatelem `filip`:

```bash
cd /var/kubedev/kubedev

# 1. Náhled: vypíše, co ponechá a co smaže. Nic nemění.
./scripts/cleanup-registry-images.sh

# 2. Po kontrole náhledu: smaže staré verze a uvolní místo.
./scripts/cleanup-registry-images.sh --apply --garbage-collect

# 3. Kontrola výsledku.
df -h /
/snap/bin/microk8s kubectl -n container-registry get pods
```

Skript maže staré verze pouze z `my-portfolio-tracker-nginx` a
`my-portfolio-tracker-php`. Ponechává 5 nejnovějších číselných verzí,
verze používané aktuálními workloady a všechny nečíselné tagy.
Verze mimo retenci už nemusí být dostupné pro rollback.

Úklid má dva kroky: smazání manifestů odstraní odkazy na staré images;
**garbage collection potom fyzicky smaže nepoužívaná data z disku**.
Samotné `--apply` místo neuvolní, pro běžnou údržbu používej oba přepínače.
Skript sám dočasně zapne read-only, restartuje registry a obnoví zápis.
Spouštěj ho mimo build/push/deploy; při restartu mohou krátce selhat i pully.
Registry se zatím automaticky neuklízí. Úklid spouštěj po větším počtu deployů
nebo když její velikost roste.

Dne 27. 10. 2026 tento postup odstranil 59 tagů / 47 manifestů a následně
5 884 nepoužívaných datových objektů. Registry klesla z asi 109 na 8,3 GiB.

## Lokální cache containerd

Je oddělená od registry. Při uvedeném úklidu se nemazala a zabírala asi 59 GiB.
Spravuje ji kubelet; aktuálně spouští úklid při zaplnění disku nad 85 %.
Není součástí běžného postupu výše. Soubory v `/var/snap` nemaž ručně.

## Databázové zálohy

Stahování běží ve 03:00 přes `/var/vps-backups/download_backup.sh`.
Retence ve Filipově crontabu běží ve 04:00 a ponechává posledních 30 dní
plus jednu zálohu za každý z 12 posledních dostupných měsíců.
Řádek pro spouštění přímo z repozitáře je v
[`maintenance/vps-backup-retention.cron`](../maintenance/vps-backup-retention.cron).

Ruční kontrola a případný úklid na Pi:

```bash
python3 /var/kubedev/kubedev/scripts/cleanup-vps-backups.py
# Pouze pokud chceš náhled provést:
python3 /var/kubedev/kubedev/scripts/cleanup-vps-backups.py --apply
```
