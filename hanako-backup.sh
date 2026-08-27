#!/usr/bin/env bash
# ============================================================
#  hanako-backup.sh — Sauvegarde incrémentale d'un site WordPress hébergé
#  chez Infomaniak (dump DB + fichiers, hardlinks sur les fichiers inchangés).
#
#  Usage : ./hanako-backup.sh chemin/vers/monsite.conf
#
#  Authentification SSH par clé (NAS/cron, sans interaction) :
#    Dans le .conf du site : SSH_KEY="/chemin/vers/infomaniak-backup"
#    (clé privée ; la clé publique correspondante — infomaniak-backup.pub —
#    doit être déposée dans ~/.ssh/authorized_keys du serveur distant).
#    Sans SSH_KEY, ssh retombe sur le mot de passe, demandé une seule fois.
#
#  Plusieurs sauvegardes d'un coup :
#    ./hanako-backup-batch.sh tasks/ma-liste.txt
#    (liste d'un site .conf par ligne, cf. tasks/exemple.list)
#
#  Copie offsite déduplicatée (SwissBackup / Swift) + rétention (NAS et
#  SwissBackup en copie conforme, 30 quotidiens + 12 hebdo + 6 mensuels par
#  défaut) : voir RESTIC_ENABLE et RESTIC_* dans le .conf du site.
# ============================================================
set -uo pipefail

# Les tâches planifiées DSM tournent avec un PATH minimal (contrairement à une
# session SSH interactive) : on complète avec les emplacements usuels de restic
# sur Synology (Entware, /usr/local, package manuel) pour éviter un faux
# "restic introuvable" au lancement via le planificateur de tâches.
export PATH="/opt/bin:/opt/sbin:/usr/local/bin:/usr/local/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/snapshot.sh"
source "$SCRIPT_DIR/lib/notify.sh"
source "$SCRIPT_DIR/lib/restic.sh"

# --- Chargement de la config ---------------------------------
CONF="${1:-}"
if [[ -z "$CONF" || ! -f "$CONF" ]]; then
  err "Usage : $0 chemin/vers/site.conf"; exit 1
fi
# Exclusions rsync additionnelles au site, en plus de celles codées en dur
# ci-dessous. Valeur par défaut vide, écrasable dans le .conf avec :
#   EXTRA_RSYNC_EXCLUDES=('uploads/gros-dossier/' '*.zip')
declare -a EXTRA_RSYNC_EXCLUDES=()
# shellcheck source=/dev/null
source "$CONF"

: "${SITE_NAME:?manque dans la config}"
: "${SSH_USER:?manque dans la config}"
: "${SSH_HOST:?manque dans la config}"
: "${REMOTE_WP_PATH:?manque dans la config}"
: "${LOCAL_BACKUP_DIR:?manque dans la config}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY="${SSH_KEY:-}"
WP_CLI_CMD="${WP_CLI_CMD:-wp}"
RESTIC_ENABLE="${RESTIC_ENABLE:-false}"
RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-30}"
RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-12}"
RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-6}"

STAMP="$(date +%Y%m%d-%H%M%S)"

SITEPATH="$LOCAL_BACKUP_DIR/$SITE_NAME"
SNAPSHOTPATH="$SITEPATH/$STAMP"
FILESPATH="$SNAPSHOTPATH/files"
DBPATH="$SNAPSHOTPATH/database"

mkdir -p "$SITEPATH" "$SNAPSHOTPATH" "$FILESPATH" "$DBPATH"

# Snapshot précédent, utilisé comme référence --link-dest pour les hardlinks
PREV_SNAPSHOT="$(previous_snapshot_dir "$SITEPATH" "$STAMP")"

STATUS="OK"
REPORT="Sauvegarde ${SITE_NAME} — $(date '+%Y-%m-%d %H:%M')\n\n"

# Nettoyage complet à la sortie : connexion SSH + notification mail,
# que le run se termine bien ou mal.
cleanup() {
  ssh_close_master
  local subject
  if [[ "$STATUS" == "OK" ]]; then
    subject="hanako-backup — OK - ${SITE_NAME}"
  else
    subject="hanako-backup — ECHEC — ${SITE_NAME}"
  fi
  notify_mail "$subject" "$REPORT"
}
trap cleanup EXIT

echo -e "${C_BOLD}════════════════════════════════════════════════${C_RESET}"
echo -e "${C_BOLD}  Sauvegarde : ${SITE_NAME}${C_RESET}"
echo -e "${C_BOLD}  $(date '+%Y-%m-%d %H:%M')${C_RESET}"
echo -e "${C_BOLD}════════════════════════════════════════════════${C_RESET}"

# --- Pré-vol ----------------------------------------------
phase "Connexion & vérifications"
if ! ssh_open_master "$SSH_USER" "$SSH_HOST" "$SSH_PORT" "$SSH_KEY"; then
  STATUS="FAIL"; REPORT+="Connexion SSH impossible.\n"
  exit 1
fi
detect_rsync

log "Test WP-CLI sur le serveur (commande : ${WP_CLI_CMD})…"
if ! wpr core version >/dev/null 2>&1; then
  err "WP-CLI introuvable ou WordPress non détecté."
  err "Vérifie WP_CLI_CMD ('${WP_CLI_CMD}') et REMOTE_WP_PATH dans la config."
  STATUS="FAIL"; REPORT+="WP-CLI introuvable (vérifier WP_CLI_CMD / REMOTE_WP_PATH).\n"
  exit 1
fi
CURRENT_WP="$(wpr core version 2>/dev/null)"
ok "WordPress $CURRENT_WP détecté."
REPORT+="WordPress : ${CURRENT_WP}\n"
if [[ -n "$PREV_SNAPSHOT" ]]; then
  log "Snapshot de référence pour les hardlinks : $(basename "$PREV_SNAPSHOT")"
  REPORT+="Snapshot de référence : $(basename "$PREV_SNAPSHOT")\n"
else
  log "Aucun snapshot précédent — sauvegarde complète."
  REPORT+="Premier snapshot pour ce site.\n"
fi
REPORT+="\n"

# --- Sauvegarde -------------------------------------------
phase "Sauvegarde"

REMOTE_DUMP="/tmp/hanako-backup-${SITE_NAME}-${STAMP}.sql"
log "Export de la base de données (côté serveur)…"
if wpr db export "$REMOTE_DUMP" >/dev/null 2>&1; then
  ok "Dump créé sur le serveur."
else
  err "Échec de l'export DB. Abandon."
  STATUS="FAIL"; REPORT+="Échec de l'export de la base de données.\n"
  exit 1
fi

log "Rapatriement du dump SQL…"
LOCAL_DUMP="$DBPATH/$SITE_NAME-$STAMP.sql"
if rsync_pull "$REMOTE_DUMP" "$LOCAL_DUMP"; then
  DBSIZE=$(du -h "$LOCAL_DUMP" | cut -f1)
  ok "Dump SQL rapatrié ($DBSIZE) — un seul fichier."
  REPORT+="Base de données : ${DBSIZE}\n"
  remote "rm -f '$REMOTE_DUMP'" && log "Temporaire distant nettoyé."
else
  err "Échec du rapatriement du dump. Abandon."
  STATUS="FAIL"; REPORT+="Échec du rapatriement du dump SQL.\n"
  remote "rm -f '$REMOTE_DUMP'" 2>/dev/null
  exit 1
fi

log "Récupération des fichiers du site (rsync, incrémental)…"
LINK_DEST_OPT=()
[[ -n "$PREV_SNAPSHOT" ]] && LINK_DEST_OPT=(--link-dest="$PREV_SNAPSHOT/files")

EXTRA_EXCLUDE_OPTS=()
for pattern in "${EXTRA_RSYNC_EXCLUDES[@]+"${EXTRA_RSYNC_EXCLUDES[@]}"}"; do
  EXTRA_EXCLUDE_OPTS+=(--exclude "$pattern")
done
if [[ "${#EXTRA_RSYNC_EXCLUDES[@]}" -gt 0 ]]; then
  log "Exclusions supplémentaires du site : ${EXTRA_RSYNC_EXCLUDES[*]}"
fi

if rsync_pull_snapshot "$REMOTE_WP_PATH/" "$FILESPATH" \
      "${LINK_DEST_OPT[@]+"${LINK_DEST_OPT[@]}"}" \
      --exclude 'matomo/' \
      --exclude 'wp-content/cache/' \
      --exclude 'wp-content/*cache*/' \
      --exclude 'wp-content/uploads/cache/' \
      --exclude '*/backup/' \
      --exclude '*/backups/' \
      --exclude '*backup*/' \
      --exclude 'wp-content/uploads/backup*/' \
      "${EXTRA_EXCLUDE_OPTS[@]+"${EXTRA_EXCLUDE_OPTS[@]}"}" ; then
  NFILES=$(find "$FILESPATH" -type f | wc -l)
  if [[ "$NFILES" -eq 0 ]]; then
    err "rsync n'a récupéré AUCUN fichier. Vérifie REMOTE_WP_PATH et les droits."
    STATUS="FAIL"; REPORT+="Aucun fichier récupéré — vérifier REMOTE_WP_PATH.\n"
  else
    ok "Fichiers synchronisés ($NFILES fichiers, caches & backups exclus)."
    REPORT+="Fichiers : ${NFILES} (snapshot ${STAMP})\n"
  fi
else
  err "rsync a échoué."
  STATUS="FAIL"; REPORT+="Échec de la synchronisation des fichiers.\n"
fi

# --- Copie offsite (SwissBackup) + rétention -----------------
# Uniquement si la sauvegarde locale a réussi : pas question de propager
# une copie partielle/en échec, ni de purger l'historique local sur la foi
# d'un snapshot boiteux.
if [[ "$STATUS" == "OK" ]]; then
  if [[ "$RESTIC_ENABLE" == "true" ]]; then
    phase "Copie déduplicatée SwissBackup"
    if restic_backup_snapshot "$SNAPSHOTPATH" "$RESTIC_KEEP_DAILY" "$RESTIC_KEEP_WEEKLY" "$RESTIC_KEEP_MONTHLY"; then
      REPORT+="SwissBackup : copie + rétention appliquées (${RESTIC_KEEP_DAILY}j/${RESTIC_KEEP_WEEKLY}sem/${RESTIC_KEEP_MONTHLY}mois).\n"
    else
      REPORT+="SwissBackup : échec de la copie ou de la purge (voir logs).\n"
    fi
  fi

  phase "Rétention locale"
  REMOVED="$(prune_local_snapshots "$SITEPATH" "$RESTIC_KEEP_DAILY" "$RESTIC_KEEP_WEEKLY" "$RESTIC_KEEP_MONTHLY")"
  if [[ "$REMOVED" -gt 0 ]]; then
    ok "Rétention locale : ${REMOVED} ancien(s) snapshot(s) supprimé(s)."
    REPORT+="Rétention locale : ${REMOVED} snapshot(s) supprimé(s).\n"
  else
    log "Rétention locale : rien à supprimer."
  fi
fi

if [[ "$STATUS" == "OK" ]]; then
  ok "Sauvegarde terminée."
else
  err "Sauvegarde terminée avec des erreurs."
fi