#!/usr/bin/env bash
# ============================================================
#  lib/restic.sh — copie déduplicatée du snapshot local vers SwissBackup
#  (Swift) via restic, avec la MÊME politique de rétention que le NAS
#  (cf. prune_local_snapshots dans lib/snapshot.sh) — SwissBackup reste
#  ainsi une copie conforme du disque, pas un simple miroir "latest".
#
#  Config attendue dans le .conf du site :
#    RESTIC_ENABLE="true"
#    RESTIC_REPOSITORY="swift:container:/chemin"
#    RESTIC_PASSWORD_FILE="/chemin/vers/mot-de-passe-repo"
#    SWIFT_ENV_FILE="/chemin/vers/env-swift.sh"   (exporte OS_*/ST_* pour restic)
#    RESTIC_KEEP_DAILY / RESTIC_KEEP_WEEKLY / RESTIC_KEEP_MONTHLY (optionnels)
#
#  Sourcé UNIQUEMENT par hanako-backup.sh.
# ============================================================

# restic_backup_snapshot <chemin_local_du_snapshot> <keep_daily> <keep_weekly> <keep_monthly>
restic_backup_snapshot() {
  local snapshot_path="$1" keep_daily="$2" keep_weekly="$3" keep_monthly="$4"

  if ! command -v restic >/dev/null 2>&1; then
    err "restic introuvable — copie SwissBackup ignorée."
    return 1
  fi

  : "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY manque dans la config}"
  : "${RESTIC_PASSWORD_FILE:?RESTIC_PASSWORD_FILE manque dans la config}"
  export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

  # Identifiants Swift (OS_*/ST_*) — dans un fichier séparé, jamais committé,
  # pour ne pas dupliquer un secret partagé entre plusieurs sites dans chaque .conf.
  if [[ -n "${SWIFT_ENV_FILE:-}" ]]; then
    if [[ ! -f "$SWIFT_ENV_FILE" ]]; then
      err "SWIFT_ENV_FILE introuvable : $SWIFT_ENV_FILE"
      return 1
    fi
    # shellcheck source=/dev/null
    source "$SWIFT_ENV_FILE"
  fi

  # Initialise le dépôt au premier passage — idempotent, l'échec (dépôt déjà
  # initialisé) est normal et ignoré.
  if ! restic snapshots --host "$SITE_NAME" >/dev/null 2>&1; then
    log "Initialisation du dépôt restic (première utilisation)…"
    restic init >/dev/null 2>&1 || true
  fi

  log "Copie déduplicatée vers SwissBackup (restic)…"
  # --group-by host,tags : le chemin absolu sauvegardé change à chaque run
  # ($SNAPSHOTPATH contient l'horodatage), donc le regroupement par défaut
  # (host,paths) ne trouve jamais de parent (nécessite restic >= 0.14).
  #
  # Chemins relatifs (cd + "files"/"database" au lieu du chemin absolu) :
  # le nom du dossier daté disparaît alors de l'arborescence enregistrée par
  # restic, qui ne compare que "files/…" — condition nécessaire pour que la
  # détection de changement par métadonnées reconnaisse un fichier inchangé
  # d'un run à l'autre.
  #
  # --ignore-ctime : chaque run recrée les hardlinks (--link-dest) des
  # fichiers inchangés dans le nouveau dossier daté, ce qui met à jour leur
  # ctime (changement de metadata : nombre de liens) même sans modification
  # réelle du contenu. Sans cette option, restic rescannerait donc quand
  # même tout à chaque fois ; mtime + inode + taille suffisent ici puisque
  # rsync préserve fidèlement le mtime distant.
  if ! (cd "$snapshot_path" && restic backup --tag "$SITE_NAME" --host "$SITE_NAME" \
        --group-by host,tags --ignore-ctime files database); then
    err "Échec de la copie restic vers SwissBackup."
    return 1
  fi
  ok "Copie SwissBackup effectuée."

  log "Purge SwissBackup (rétention ${keep_daily}j / ${keep_weekly}sem / ${keep_monthly}mois)…"
  if restic forget --prune \
        --tag "$SITE_NAME" --host "$SITE_NAME" --group-by host,tags \
        --keep-daily "$keep_daily" \
        --keep-weekly "$keep_weekly" \
        --keep-monthly "$keep_monthly" >/dev/null 2>&1; then
    ok "Rétention SwissBackup appliquée."
  else
    warn "La purge restic a échoué — à vérifier manuellement (restic forget --prune)."
    return 1
  fi
}
