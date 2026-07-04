# vyos-deploy

Playbooks Ansible pour déployer et maintenir des containers Podman sur un
routeur **VyOS** : la stack proxy (Squid + c-icap + ClamAV), **Suricata**
en mode IPS inline (NFQUEUE), **BIND9** (DNS split-horizon) et **HAProxy**
(reverse-proxy TLS). Complète les images Docker hardened `FROM scratch`
publiées séparément :
[squid-hardened](https://github.com/jbsky/squid-hardened),
[suricata-hardened](https://github.com/jbsky/suricata-hardened) et
[bind9-hardened](https://github.com/jbsky/bind9-hardened).

Chaque service a son propre playbook autonome à la racine
(`<service>-deploy.yaml`) avec ses fichiers sous
`etc/{squid,c-icap,clamav,suricata,bind,haproxy}/`.

| Playbook | Déploie |
|----------|---------|
| `proxy-deploy.yaml` | Squid (SSL Bump) + c-icap/squidclamav + ClamAV |
| `suricata-deploy.yaml` | Suricata IPS inline (NFQUEUE) + mise à jour des règles |
| `bind-deploy.yaml` | BIND9 (zones, split-horizon, TSIG pour ACME DNS-01) |
| `haproxy-deploy.yaml` | HAProxy (reverse-proxy TLS vers Traefik/K3s) |

## Ce repo ne fournit aucun inventaire

`hosts: vyos` référence un **groupe** Ansible, pas un hostname fixe — à
définir dans *ton propre* inventaire :

```ini
[vyos]
vyos.home.arpa
```

```yaml
# host_vars/vyos.home.arpa/main.yaml
ansible_host: 192.168.1.1
ansible_user: mon_user
ansible_become: true
ansible_become_method: sudo
```

## Pointer vers ta propre config

Chaque playbook lit ses fichiers via des variables dédiées, qui valent par
défaut l'exemple bundlé dans `etc/`. Si tu gères déjà tes vraies configs
ailleurs, surcharge-les depuis ton inventaire :

```yaml
# group_vars/vyos.yaml (dans ton projet)
squid_conf: /chemin/vers/ta/vraie/conf/squid
cicap_conf: /chemin/vers/ta/vraie/conf/c-icap
clam_conf: /chemin/vers/ta/vraie/conf/clamav
suricata_conf: /chemin/vers/ta/vraie/conf/suricata
bind_conf: /chemin/vers/ta/vraie/conf/bind
haproxy_conf: /chemin/vers/ta/vraie/conf/haproxy
```

ou en ligne de commande : `-e squid_conf=... --tags config`.

## Tester avant d'appliquer

Les tâches de déploiement utilisent `ansible.builtin.copy`, qui supporte
nativement `--check`/`--diff` — toujours utile avant d'appliquer pour de
vrai :

```bash
ansible-playbook proxy-deploy.yaml --check --diff --tags config
```

## Tester les configs elles-mêmes (docker compose)

Un `docker-compose.yml` permet de faire tourner les configs d'exemple
localement, hors VyOS, pour vérifier qu'elles sont réellement valides
(pas juste que le YAML Ansible est correct) :

```bash
./test/generate-test-certs.sh   # certs/cles jetables, jamais committes
docker compose up -d
dig @127.0.0.1 -p 5353 example.com
curl -x http://127.0.0.1:3128 http://example.org/
curl -k https://127.0.0.1:8443 --resolve example.com:8443:127.0.0.1
```

ClamAV tentera de télécharger de vraies signatures virales au démarrage
(freshclam) — normal que ça échoue sans accès internet direct dans un
environnement de test isolé, pas bloquant pour valider la config.

Le CI GitHub Actions (`.github/workflows/validate-configs.yml`) automatise
une version plus légère de ces mêmes vérifications à chaque push touchant
`etc/**` : `named-checkconf`, `suricata -T`, `squid -k parse`,
`haproxy -c` — le mode "config-check" natif de chaque démon, rapide et
sans dépendance réseau externe.

## Utilisation en submodule Git (recommandé)

```bash
cd mon-projet-ansible/
git submodule add https://github.com/jbsky/vyos-deploy.git external/vyos-deploy
git submodule update --init --recursive
```

Ajoute le groupe `[vyos]` dans ton propre inventaire (voir ci-dessus), puis :

```bash
ansible-playbook external/vyos-deploy/proxy-deploy.yaml -i inventories/production
ansible-playbook external/vyos-deploy/suricata-deploy.yaml -i inventories/production
ansible-playbook external/vyos-deploy/bind-deploy.yaml -i inventories/production
ansible-playbook external/vyos-deploy/haproxy-deploy.yaml -i inventories/production
```

`git submodule update --remote` pour récupérer les mises à jour des playbooks.

## Ou en clone direct

```bash
git clone https://github.com/jbsky/vyos-deploy.git
cd vyos-deploy
mkdir -p inventories/production/host_vars/vyos.home.arpa
# cree hosts + host_vars/vyos.home.arpa/main.yaml comme ci-dessus
ansible-playbook proxy-deploy.yaml -i inventories/production
```

---

## proxy-deploy.yaml — Squid + c-icap + ClamAV

Déploie `squid.conf`+`nobump_domains.acl` → `squid/conf/`,
`c-icap.conf`+`squidclamav.conf` → `c-icap/`, `clamd.conf`+`freshclam.conf`
→ `clamav/conf/` (sous `/config/containers/`), redémarre dans l'ordre
clamav → c-icap → squid, puis vérifie la connectivité HTTP/HTTPS.

**Prérequis** : accès SSH+sudo au VyOS, les 3 containers déjà définis dans
`config.boot` avec les images `jbsky/*-hardened` et des volumes montés en
conséquence (`squid-conf` → `/etc/squid`, `c-icap` → `/etc/c-icap`,
`clamav-conf`/`clamav-db` → `/etc/clamav`/`/var/lib/clamav`). Le container
ClamAV a deux volumes séparés `clamav/conf` et `clamav/db` — ce playbook ne
gère que `clamav/conf`, la base virale reste gérée par freshclam. Certs
SSL-bump : voir Secrets ci-dessous.

**Secrets** : le tag `certs`/`squid_certs` a besoin de
`vault_squid_bump_pem` et `vault_squid_dhparam_pem` (PEM de la CA de bump
et des paramètres DH), non fournis dans ce repo. À passer via `-e` :

```bash
ansible-playbook proxy-deploy.yaml --tags certs \
  -e @~/secrets/squid-certs-vault.yaml --ask-vault-pass
```

Le reste (`config`, `service`, `check`) ne nécessite aucun secret.

```bash
ansible-playbook proxy-deploy.yaml                       # tout deployer
ansible-playbook proxy-deploy.yaml --tags squid_config   # conf squid seule
ansible-playbook proxy-deploy.yaml --tags check          # verifier
```

Tags : `config`, `certs`, `service`, `check`, `squid_config`, `squid_certs`,
`icap_config`, `clamav_config`.

**Adapter à ton réseau** : `squid.conf` contient des ACL et IPs d'exemple
(`home_assistant`, `iot_device2`, `192.168.x.x`) à remplacer par ta propre
topologie. `nobump_domains.acl` liste des domaines bancaires/santé français
à ne jamais SSL-bumper — vérifie qu'elle couvre tes usages sensibles.

---

## suricata-deploy.yaml — Suricata IPS inline

Déploie la config Suricata (`suricata.yaml`, `disable.conf`, `modify.conf`,
etc.) + `rules/local.rules` + le script `suricata-update.sh` (task
scheduler VyOS, mise à jour quotidienne des règles), redémarre le
container et vérifie son état via `show container`. Le fichier
`suricata.rules` (généré par `suricata-update`) n'est volontairement pas
géré ici.

**Prérequis** : accès SSH+sudo, container `suricata` déjà défini en mode
NFQUEUE inline (`allow-host-networks`, capabilities `net-admin`+`sys-nice`).
Aucun secret requis.

```bash
ansible-playbook suricata-deploy.yaml                       # tout deployer
ansible-playbook suricata-deploy.yaml --tags config,script  # conf + script
ansible-playbook suricata-deploy.yaml --tags check          # verifier
```

Tags : `config`, `script`, `service`, `check`.

**Gotcha `--suricata-version`** : `suricata-update.sh` renomme
temporairement `/usr/bin/suricata` pour contourner les file capabilities
(`NET_ADMIN`) à l'exécution. `suricata-update` détecte normalement la
version du moteur en exécutant ce binaire — sans lui, il retombe sur son
défaut caché (`6.0.0`) et télécharge le mauvais ruleset ET Open. Le script
passe donc `--suricata-version` explicitement, dérivé du tag de l'image.

**Adapter à ton réseau** : `suricata.yaml` utilise déjà des `HOME_NET`
génériques (`192.168.0.0/16`, `10.0.0.0/8`, `172.16.0.0/12`).
`rules/local.rules` contient des règles de test triviales à remplacer par
les tiennes.

---

## bind-deploy.yaml — BIND9 (DNS split-horizon)

Déploie la config BIND9 (`named.conf*`, zones) vers
`/config/containers/bind9/`, valide la syntaxe localement
(`named-checkconf`) avant tout transfert, redémarre le container.

L'exemple bundlé (`etc/bind/`) montre un pattern **split-horizon
simplifié à 2 vues** (`local` pour le LAN interne, `internet` pour les
requêtes publiques) sur un domaine `example.com` factice — y compris le
bloc `update-policy { grant tsig-key ... }` qui autorise les mises à jour
TSIG-signées des enregistrements `_acme-challenge` (indispensable pour de
l'émission de certificats Let's Encrypt en DNS-01/wildcard). Le vrai setup
de production va plus loin : une vue distincte par sous-réseau permet de
répondre différemment selon le VLAN d'origine — duplique le bloc `view` de
l'exemple autant de fois que nécessaire pour reproduire ça chez toi.

**`rndc.key`/`tsig.key` ne sont jamais fournis ni committés** (exclus
explicitement du rsync par le playbook) — génère les tiens localement
(`tsig-keygen`, `rndc-confgen`) et dépose-les dans ta copie de
`inventories/production/` ou directement sur le VyOS, jamais dans ce repo.

**Prérequis** : accès SSH+sudo, container `bind9` déjà défini dans
`config.boot` avec l'image `jbsky/bind9-hardened`, capability
`net-bind-service`.

```bash
ansible-playbook bind-deploy.yaml                    # tout deployer
ansible-playbook bind-deploy.yaml --tags config      # conf seule
ansible-playbook bind-deploy.yaml --tags check       # verifier
```

Tags : `config`, `service`, `check`.

**Gotcha réseau** : pas de test DNS contre l'IP de bridge podman du
container — elle n'est joignable ni depuis VyOS lui-même ni depuis le
reste du LAN (`No route to host`, confirmé empiriquement ; BIND9 n'a
d'ailleurs aucun port publié dans `config.boot`, contrairement à Squid ou
HAProxy). Le tag `check` vérifie donc l'état du container via
`show container`, pas une vraie requête DNS.

## haproxy-deploy.yaml — HAProxy (reverse-proxy TLS)

Déploie `haproxy.cfg` + `WWW.crt_list` vers `/config/containers/haproxy/`,
redémarre le container, vérifie la connectivité HTTPS.

L'exemple bundlé (`etc/haproxy/`) montre le pattern ACL par sous-domaine
(`var(txn.txnhost)` + `use_backend`) routant vers un backend Traefik/K3s,
avec 2 domaines d'exemple (`example.com`, `app1.example.com`) — adapte les
ACL et les IPs de backend à ta topologie.

**Prérequis** : accès SSH+sudo, container `haproxy` déjà défini dans
`config.boot` avec les ports `80`/`443` publiés. Les certificats Let's
Encrypt (`WWW/*.pem`) sont gérés séparément (rôle certbot ou équivalent) et
ne sont pas déployés par ce playbook.

```bash
ansible-playbook haproxy-deploy.yaml                 # tout deployer
ansible-playbook haproxy-deploy.yaml --tags config   # conf seule
ansible-playbook haproxy-deploy.yaml --tags check    # verifier
```

Tags : `config`, `service`, `check`.

**Workflow nouveau domaine** : génère le cert (DNS-01 via BIND9 par
exemple, voir `bind-deploy.yaml` ci-dessus) et synchronise le PEM dans
`WWW/` **avant** de déployer une `WWW.crt_list` qui le référence — HAProxy
refuse de démarrer si un PEM listé est absent, ce qui casserait tous les
domaines déjà en place, pas seulement le nouveau.

---

## Article associé

Ce repo accompagne un article détaillant l'architecture complète (Squid +
c-icap + ClamAV + Suricata + orchestration Ansible) sur
[jbsky.fr](https://jbsky.fr/).
