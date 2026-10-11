# MariaDB: vlastní build a automatický upgrade

Build a push se spouští na MacBooku, upgrade přímo na Raspberry Pi přes SSH.
Nejdřív přenes aktuální změny tohoto repozitáře na server. Stažený SQL export
ponech mimo server a zachovej původní image `my-mariadb:1.0` v registry.

## 1. MacBook: build a push

```bash
cd /Users/filip/Sites/kubedev
bash scripts/build-mariadb.sh
```

Skript sestaví ARM64 image z `docker/mysql/Dockerfile` a publikuje ho do
`192.168.1.245:32000/my-mariadb:11.4.13`. Při dalším upgradu změň přesnou verzi
v Dockerfile i v manifestu; skripty kontrolují jejich shodu.

## 2. Raspberry Pi: celý upgrade

```bash
cd /var/kubedev/kubedev
sudo bash scripts/upgrade-mariadb.sh
```

Skript je určený pro zdejší jednouzlový MicroK8s a namespace `default`.
Potřebuje oprávnění roota kvůli kopii dat z hostPath svazku. Automaticky:

1. Zkontroluje hostitele, databázi a prostor a stáhne nový image ještě před odstávkou.
2. Uloží původní image, počty replik a seznam zapnutých CronJobů.
3. Pozastaví plánování aplikačních úloh a počká na dokončení již spuštěných úloh.
4. Vypne aplikaci a MariaDB a ověří její čisté vypnutí.
5. Uloží celý datový adresář a kontrolní součet do `/var/tmp/kubedev-mariadb/upgrade.*`.
6. Spustí `deploy-mariadb.sh`: nasadí vlastní image 11.4.13 nad stejným PVC
   s `MARIADB_AUTO_UPGRADE=1` a počká na úspěšný start.
7. Přes PHP ověří spojení s databází, její verzi a počet tabulek a obnoví původní
   počty replik i pouze původně zapnuté CronJoby.

Consumers mají dobu běhu 1000 sekund, takže jejich doběhnutí může zabrat zhruba
17 minut, případně déle při zpracování zprávy. Web během čekání zůstává dostupný.
Limit čekání je 30 minut; při překročení se skript zastaví. Potom stačí ručně
zkontrolovat web, portfolio, statistiky a běžné ukládání.

Skript nemění schéma aplikace pomocí Doctrine migrací. Zachovává stávající PVC
a na připojeném PV nastavuje `Retain`. Zálohy záměrně nemaže. Obsahují také
databázové účty; adresář je přístupný pouze rootovi a nepatří do Gitu ani do chatu.

## Chyba nebo návrat

Při chybě skript vypíše fázi, adresář uloženého stavu a přesný příkaz pro návrat.
Aplikace nebo úlohy mohou zůstat pozastavené. Nespouštěj znovu nový upgrade;
nejdřív použij vypsaný příkaz, například:

```bash
sudo bash scripts/upgrade-mariadb.sh rollback /var/tmp/kubedev-mariadb/upgrade.ABCDEFGH
```

Nahraď adresář skutečnou cestou z výstupu. Návrat je použitelný i po úspěšném
upgradu. Pokud ještě nezačalo nasazení nové verze, pouze obnoví původní provoz.
Pokud už začalo, ověří archiv, zastaví zápisy, obnoví celou kopii dat a původní
image a poté původní stav aplikace a úloh. **Zápisy vzniklé po záloze se tím vrátí.**
Datový adresář nové verze ponechá vedle původní cesty s příponou `.failed.*`.
Při chybě během obnovy lze stejný příkaz opakovat; záloha se nepřepisuje.

Pokud proces přerušíš nebo ztratíš SSH spojení, adresář najdeš příkazem
`sudo ls -lt /var/tmp/kubedev-mariadb`. Stav je v souborech `phase` a `result`.
Nový upgrade odmítne začít, dokud existuje nedokončený předchozí běh.

`deploy-mariadb.sh` zůstává dílčím nasazovacím skriptem; při běžném upgradu ho
volá hlavní skript. Build/push a provozní příkazy spouští uživatel.

## Kontroly skriptů

```bash
python3 tools/test-mariadb-upgrade.py
```

Testy používají izolované dočasné soubory a simulované MicroK8s příkazy;
nepřipojují se ke clusteru ani nic nebuildí nebo nepublikují.

## Reference

- [Upgrade mezi hlavními verzemi](https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/upgrading/platform-specific-upgrade-guides/upgrading-on-linux/upgrading-between-major-mariadb-versions)
- [Automatický upgrade a proměnné image](https://mariadb.com/docs/server/server-management/automated-mariadb-deployment-and-administration/docker-and-mariadb/mariadb-server-docker-official-image-environment-variables)
- [Pozastavení CronJobů](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/#schedule-suspension)
- [MicroK8s registry](https://canonical.com/microk8s/docs/registry-built-in)
