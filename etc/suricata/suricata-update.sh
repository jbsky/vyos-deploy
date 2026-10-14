#!/bin/bash
# =====================================================================
#  suricata-update.sh — VyOS task-scheduler script
#  Strategy: stop suricata → update rules (ephemeral) → start suricata
#  Traffic continues via --queue-bypass during the stop window (~30s)
# =====================================================================
set -euo pipefail

LOGFILE="/var/log/suricata-update.log"
TAG="suricata-update"
RULES_DIR="/config/containers/suricata/rules"
CONFIG_DIR="/config/containers/suricata/etc"
RULES_FILE="$RULES_DIR/suricata.rules"

log() {
    local level="$1"; shift
    logger -t "$TAG" -p "user.${level}" "$*"
    echo "$(date '+%F %T') [$level] $*" | sudo tee -a "$LOGFILE" >/dev/null
}

# Un point de branchement pour une sonde : ce script tourne au planificateur,
# donc son echec est MUET par nature. Le homelab d'origine definit ici une
# fonction `push <up|down> <message>` qui pousse vers un moniteur externe -- le
# silence d'un script qui ne tourne plus devient alors un rouge, lui aussi.
# Sans sonde, la coquille ci-dessous ne fait rien et le journal reste la seule
# trace : y brancher votre supervision.
push() {  # <up|down> <message>
    :
}

# L'image est celle du conteneur EN SERVICE, lue avant l'arret (VyOS
# supprime le conteneur a l'arret). Une valeur ecrite ici en dur
# (8.0.5) a survecu a la purge de son tag sur Docker Hub : chaque passage
# echouait sur "manifest unknown" et les regles sont restees figees du
# 2026-09-01 au 2026-10-03, sans autre signal que ce journal.
# APRES log() et push() : la sortie ci-dessous les appelle, et une fonction
# appelee avant sa definition rend 127 -- le journal et la sonde restaient
# muets sur la seule panne que ce garde est la pour signaler.
IMAGE=$(sudo podman inspect suricata --format '{{.ImageName}}' 2>/dev/null || true)
if [ -z "$IMAGE" ]; then
    log error "conteneur suricata introuvable, image inconnue"
    push down "conteneur suricata introuvable"
    exit 1
fi
# Tag <version>.<revision> (8.0.7.4) : suricata-update n'attend que x.y.z.
SURICATA_VERSION=$(echo "${IMAGE##*:}" | cut -d. -f1-3)

log info "=== Mise à jour des règles Suricata ==="

# Save current rules timestamp for comparison
OLD_MTIME=$(stat -c %Y "$RULES_FILE" 2>/dev/null || echo 0)

# 1. Stop suricata (--queue-bypass keeps traffic flowing)
log info "Arrêt de Suricata (bypass actif)..."
sudo systemctl stop vyos-container-suricata.service || true

# 2. Update rules in ephemeral container
#    --network host: Internet access (safe: NFQUEUE queues are empty, no caps)
#    --user root: to rename suricata binary (file caps prevent exec without NET_ADMIN)
#    Note: suricata-update exits non-zero due to reload-command needing /bin/sh
#          (absent in FROM scratch). Rules are written BEFORE that error. We verify
#          success via file timestamp, not exit code.
#    --suricata-version REQUIRED: renaming the suricata binary above (to bypass
#          file caps) means suricata-update can't auto-detect the engine version
#          by executing it. Without this flag it silently falls back to its own
#          hardcoded default (6.0.0!) and fetches the ET Open ruleset built for
#          that ancient version instead of what's actually running. Confirmed via
#          /var/log/suricata-update.log: "Using default Suricata version of
#          6.0.0" / "Fetching .../suricata-6.0.0/emerging.rules.tar.gz" on every
#          run before this fix.
log info "Téléchargement des règles..."

UPDATE_ARGS="update -f --no-test --suricata-version $SURICATA_VERSION --suricata-conf /etc/suricata/suricata.yaml --output /var/lib/suricata/rules"
[ -f "$CONFIG_DIR/disable.conf" ] && UPDATE_ARGS="$UPDATE_ARGS --disable-conf /etc/suricata/disable.conf"
[ -f "$CONFIG_DIR/modify.conf" ] && UPDATE_ARGS="$UPDATE_ARGS --modify-conf /etc/suricata/modify.conf"

#    --read-only=false: conteneur de maintenance, pas un service -- il renomme
#          un binaire de l'image. Sans ce drapeau, le read_only global de
#          containers.conf.d (rootfs en lecture seule des services) le ferait
#          echouer en EROFS.
sudo podman run --rm --read-only=false --user root --network host --memory 1g \
    -v "$RULES_DIR":/var/lib/suricata/rules \
    -v "$CONFIG_DIR":/etc/suricata:ro \
    --entrypoint python3 "$IMAGE" \
    -c "
import os, sys
os.rename('/usr/bin/suricata', '/usr/bin/suricata.bak')
os.execvp('suricata-update', ['suricata-update'] + sys.argv[1].split())
" "$UPDATE_ARGS" 2>&1 | sudo tee -a "$LOGFILE" || true

# Verify rules were actually updated (timestamp changed)
NEW_MTIME=$(stat -c %Y "$RULES_FILE" 2>/dev/null || echo 0)
if [ "$NEW_MTIME" -le "$OLD_MTIME" ]; then
    log error "Rules non mises à jour (fichier inchangé). Redémarrage anciennes règles."
    sudo systemctl start vyos-container-suricata.service
    push down "regles non mises a jour"
    exit 2
fi

# 3. Start with new rules
log info "Démarrage Suricata..."
START_TS=$(date '+%F %T')
sudo systemctl start vyos-container-suricata.service || { log error "Échec start!"; push down "echec du demarrage"; exit 3; }

# 4. Verify : en marche, ET aucune regle refusee au chargement. Le bilan
#    « N rules successfully loaded, M rules failed » arrive ~15 s apres le
#    demarrage (52 000 regles) ; on l'attend jusqu'a 2 min.
# `|| true` OBLIGATOIRE : une affectation prend le code de la substitution,
# `grep` sans correspondance rend 1, `pipefail` le propage et `set -e` tuait
# le script au PREMIER tour -- la boucle de 2 min n'a jamais servi. Le bilan
# arrive ~4 s apres le demarrage et le 1er sondage tombe a 5 s : chaque nuit
# la course etait gagnee d'une seconde, le 2026-10-14 a 09:39:05 elle a ete
# perdue d'une fraction de seconde et le job de montee d'image est sorti en 1,
# regles a jour et suricata en marche.
BILAN=""
for _ in $(seq 1 24); do
    sleep 5
    BILAN=$(sudo journalctl --since "$START_TS" --no-pager CONTAINER_NAME=suricata 2>/dev/null \
            | grep -o '[0-9]* rules successfully loaded, [0-9]* rules failed' | tail -1 || true)
    [ -n "$BILAN" ] && break
done
if ! sudo podman ps --format '{{.Names}}' | grep -qx suricata; then
    log error "Suricata non démarré!"
    push down "suricata non demarre"
    exit 4
fi
DROPS=$(grep -c '^drop ' "$RULES_FILE" 2>/dev/null || echo 0)
ALERTS=$(grep -c '^alert ' "$RULES_FILE" 2>/dev/null || echo 0)
if [ -z "$BILAN" ]; then
    log error "Bilan de chargement des regles introuvable dans le journal."
    push down "bilan de chargement introuvable"
    exit 5
fi
ECHECS=$(echo "$BILAN" | sed -E 's/.* ([0-9]+) rules failed/\1/')
if [ "$ECHECS" -gt 0 ]; then
    log error "$BILAN -- des regles sont refusees (journal : CONTAINER_NAME=suricata)."
    push down "$ECHECS regles refusees"
    exit 6
fi
log info "OK. $BILAN. Rules: $DROPS drop, $ALERTS alert."
push up "$DROPS drop, $ALERTS alert"
