#!/usr/bin/env bash
# ============================================================
#  hanako-check.sh — Rapport de santé consolidé de plusieurs sites, basé sur
#  le fichier status.txt écrit par hanako-backup.sh à la fin de CHAQUE run
#  (STATUS, taille du dump, nb de fichiers, avertissements), complété ici par
#  une vérification d'intégrité restic FORCÉE à chaque exécution (restic
#  check --read-data-subset) pour les sites avec RESTIC_ENABLE=true — c'est
#  le seul contrôle qui n'est pas qu'une relecture de faits déjà enregistrés.
#
#  Usage : ./hanako-check.sh tasks/ma-liste.txt
#    (même format de liste que hanako-backup-batch.sh : un .conf par ligne)
#  Destinataire du rapport : à régler ci-dessous (DIGEST_MAIL_TO), pas en
#  argument — ce script est pensé pour être planifié (cron), pas pour
#  changer de destinataire d'un lancement à l'autre.
#
#  MAX_AGE_HOURS (défaut 36h) : au-delà, le dernier snapshot d'un site est
#  signalé "pas vu depuis longtemps" même si son propre statut était OK —
#  seul moyen ici de détecter un site dont le backup a cessé de tourner
#  (cron arrêté, config cassée…) puisqu'aucun run récent n'a alors pu
#  envoyer la moindre alerte.
# ============================================================
set -uo pipefail

# --- Destinataire du rapport (laisser vide pour n'afficher que sur stdout) ---
DIGEST_MAIL_TO="lionel@aboutblank.ch"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/utils.sh"
source "$SCRIPT_DIR/lib/notify.sh"
source "$SCRIPT_DIR/lib/verify.sh"
source "$SCRIPT_DIR/lib/restic.sh"

TASKLIST="${1:-}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-36}"

if [[ -z "$TASKLIST" || ! -f "$TASKLIST" ]]; then
  echo "Usage : $0 chemin/vers/liste.txt" >&2
  exit 1
fi

LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  LINES+=("$line")
done < "$TASKLIST"

REPORT="Rapport de santé hanako-backup — $(date '+%Y-%m-%d %H:%M')\n\n"
ANY_ISSUE=0
NOW_EPOCH="$(date +%s)"

# Lignes du tableau, un tableau indexé par colonne (pas d'associatif : bash
# 3.2 livré par défaut sur macOS n'en a pas).
declare -a ROW_SITE=() ROW_STATUT=() ROW_AGE=() ROW_DB=() ROW_FICHIERS=() \
           ROW_RESTIC=() ROW_RESTIC_CHECK=() ROW_DETAIL=() ROW_ISSUE=()

# check_site <conf> — tout en sous-shell pour isoler les variables d'un
# .conf à l'autre ; imprime une seule ligne pipe-délimitée sur stdout :
# KIND|site|détail|statut|age_h|db_bytes|nfiles|files_bytes|restic_nfiles|restic_bytes|restic_check
check_site() {
  local conf="$1"
  (
    SITE_NAME=""; LOCAL_BACKUP_DIR=""
    # shellcheck source=/dev/null
    source "$conf"
    : "${SITE_NAME:?}"; : "${LOCAL_BACKUP_DIR:?}"

    SITEPATH="$LOCAL_BACKUP_DIR/$SITE_NAME"
    if [[ ! -d "$SITEPATH" ]]; then
      echo "ISSUE|${SITE_NAME}|Aucun snapshot trouvé (${SITEPATH} absent).|N/A|-|0|0|-1|-1|-1|n/a"
      exit 0
    fi

    LATEST=""
    for d in "$SITEPATH"/*/; do
      d="${d%/}"
      [[ "$(basename "$d")" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
      LATEST="$d"   # tri lexicographique du glob = tri chronologique
    done
    if [[ -z "$LATEST" ]]; then
      echo "ISSUE|${SITE_NAME}|Aucun snapshot daté trouvé dans ${SITEPATH}.|N/A|-|0|0|-1|-1|-1|n/a"
      exit 0
    fi

    STAMP="$(basename "$LATEST")"
    SNAP_EPOCH="$(date -j -f "%Y%m%d-%H%M%S" "$STAMP" +%s 2>/dev/null || date -d "${STAMP:0:8} ${STAMP:9:2}:${STAMP:11:2}:${STAMP:13:2}" +%s 2>/dev/null)"
    AGE_H=$(( (NOW_EPOCH - SNAP_EPOCH) / 3600 ))

    STATUS_FILE="$LATEST/status.txt"
    if [[ ! -f "$STATUS_FILE" ]]; then
      echo "ISSUE|${SITE_NAME}|Dernier snapshot (${STAMP}, il y a ${AGE_H}h) sans fichier status.txt (ancienne version du script ?).|N/A|${AGE_H}|0|0|-1|-1|-1|n/a"
      exit 0
    fi

    # Valeurs par défaut : -1 = champ absent d'un status.txt écrit par une
    # version antérieure du script (ex. FILES_SIZE_BYTES ajouté après coup),
    # à distinguer d'un 0 qui serait une vraie valeur.
    STATUS=""; DB_SIZE_BYTES=0; FILES_SIZE_BYTES=-1; NFILES=0
    RESTIC_SIZE_BYTES=-1; RESTIC_NFILES=-1; WARNINGS=""
    # shellcheck source=/dev/null
    source "$STATUS_FILE"

    # Vérification d'intégrité restic FORCÉE ici (pas dans hanako-backup.sh) :
    # systématique, indépendante du succès du run de backup du jour.
    RESTIC_ENABLE="${RESTIC_ENABLE:-false}"
    RESTIC_CHECK_SUBSET="${RESTIC_CHECK_SUBSET:-5%}"
    restic_check="n/a"
    restic_age_h=""
    if [[ "$RESTIC_ENABLE" == "true" ]]; then
      if ! command -v restic >/dev/null 2>&1; then
        restic_check="restic_absent"
      elif [[ -z "${RESTIC_REPOSITORY:-}" || -z "${RESTIC_PASSWORD_FILE:-}" ]]; then
        restic_check="config_manquante"
      elif [[ -n "${SWIFT_ENV_FILE:-}" && ! -f "$SWIFT_ENV_FILE" ]]; then
        restic_check="swift_env_absent"
      else
        export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE
        [[ -n "${SWIFT_ENV_FILE:-}" ]] && source "$SWIFT_ENV_FILE"
        # tail -n1 : restic_check_repo imprime aussi des messages log/ok/err
        # avant son résultat final, on ne garde que la dernière ligne.
        restic_check="$(restic_check_repo 2>/dev/null | tail -n1)"
        # Âge du dernier snapshot restic : les chiffres "restic" du tableau
        # (fichiers/poids) ne sont PAS un cumul entre snapshots, mais s'ils
        # ne correspondent pas au snapshot local d'aujourd'hui, c'est que la
        # copie SwissBackup est périmée (restic_backup_snapshot a échoué
        # silencieusement un jour donné) — pas un bug de calcul.
        RESTIC_SNAP_EPOCH="$(restic_latest_snapshot_epoch 2>/dev/null)"
        if [[ -n "$RESTIC_SNAP_EPOCH" ]]; then
          restic_age_h=$(( (NOW_EPOCH - RESTIC_SNAP_EPOCH) / 3600 ))
        fi
      fi
    fi

    issue=""
    [[ "$STATUS" != "OK" ]] && issue="statut ${STATUS}"
    if [[ -n "${WARNINGS:-}" ]]; then
      [[ -n "$issue" ]] && issue+=", "
      issue+="avertissements: ${WARNINGS}"
    fi
    if [[ "$AGE_H" -ge "$MAX_AGE_HOURS" ]]; then
      [[ -n "$issue" ]] && issue+=", "
      issue+="pas de snapshot récent (${AGE_H}h > ${MAX_AGE_HOURS}h — cron arrêté ?)"
    fi
    if [[ "$restic_check" == "fail" ]]; then
      [[ -n "$issue" ]] && issue+=", "
      issue+="vérification restic en échec"
    fi
    if [[ -n "$restic_age_h" && "$restic_age_h" -ge "$MAX_AGE_HOURS" ]]; then
      [[ -n "$issue" ]] && issue+=", "
      issue+="copie SwissBackup périmée (dernier snapshot restic il y a ${restic_age_h}h)"
    fi

    kind="OK"; [[ -n "$issue" ]] && kind="ISSUE"
    [[ -z "$issue" ]] && issue="—"
    echo "${kind}|${SITE_NAME}|${issue}|${STATUS}|${AGE_H}|${DB_SIZE_BYTES}|${NFILES}|${FILES_SIZE_BYTES}|${RESTIC_NFILES}|${RESTIC_SIZE_BYTES}|${restic_check}"
  )
}

for line in "${LINES[@]}"; do
  line="${line%%#*}"
  line="$(echo "$line" | xargs)"
  [[ -z "$line" ]] && continue

  conf="$line"
  [[ "$conf" != */* ]] && conf="configs/$conf"
  [[ "$conf" != *.conf ]] && conf="${conf}.conf"
  [[ "$conf" != /* ]] && conf="$SCRIPT_DIR/$conf"

  if [[ ! -f "$conf" ]]; then
    err "Config introuvable : $conf"
    ROW_SITE+=("$line"); ROW_STATUT+=("N/A"); ROW_AGE+=("-"); ROW_DB+=("—")
    ROW_FICHIERS+=("—"); ROW_RESTIC+=("—"); ROW_RESTIC_CHECK+=("n/a")
    ROW_DETAIL+=("config introuvable (${conf})"); ROW_ISSUE+=(1)
    ANY_ISSUE=1
    continue
  fi

  result="$(check_site "$conf")"
  IFS='|' read -r kind name detail status age_h db_bytes nfiles files_bytes restic_nfiles restic_bytes restic_check <<< "$result"

  if [[ "$files_bytes" -eq -1 ]]; then
    fichiers_local="${nfiles} (poids n/a — relancer un backup)"
  else
    fichiers_local="${nfiles} ($(human_size "$files_bytes"))"
  fi
  if [[ "$restic_nfiles" -eq -1 || "$restic_bytes" -eq -1 ]]; then
    fichiers_restic="n/a (ancien format)"
  elif [[ "$restic_nfiles" -gt 0 || "$restic_bytes" -gt 0 ]]; then
    fichiers_restic="${restic_nfiles} ($(human_size "$restic_bytes"))"
  else
    fichiers_restic="—"
  fi

  ROW_SITE+=("$name"); ROW_STATUT+=("${status:-N/A}"); ROW_AGE+=("${age_h}h")
  ROW_DB+=("$(human_size "$db_bytes")"); ROW_FICHIERS+=("$fichiers_local")
  ROW_RESTIC+=("$fichiers_restic"); ROW_RESTIC_CHECK+=("$restic_check")
  ROW_DETAIL+=("$detail")

  if [[ "$kind" == "ISSUE" ]]; then
    err "${name} : ${detail}"
    ROW_ISSUE+=(1)
    ANY_ISSUE=1
  else
    ok "${name} : ${detail}"
    ROW_ISSUE+=(0)
  fi
done

# --- Tableau terminal ----------------------------------------
TERM_TABLE="$(printf '%-16s %-9s %-6s %-10s %-20s %-20s %-10s %s\n' \
  "SITE" "STATUT" "AGE" "DB" "FICHIERS (local)" "FICHIERS (restic)" "RESTIC" "DETAIL")"
for i in "${!ROW_SITE[@]}"; do
  TERM_TABLE+="$(printf '\n%-16s %-9s %-6s %-10s %-20s %-20s %-10s %s' \
    "${ROW_SITE[$i]}" "${ROW_STATUT[$i]}" "${ROW_AGE[$i]}" "${ROW_DB[$i]}" \
    "${ROW_FICHIERS[$i]}" "${ROW_RESTIC[$i]}" "${ROW_RESTIC_CHECK[$i]}" "${ROW_DETAIL[$i]}")"
done
echo
echo -e "$TERM_TABLE"
REPORT+="$TERM_TABLE\n"

# --- Tableau HTML (mail) --------------------------------------
HTML_REPORT="<p>Rapport de santé hanako-backup — $(date '+%Y-%m-%d %H:%M')</p>"
HTML_REPORT+="<table border=\"1\" cellspacing=\"0\" cellpadding=\"6\" style=\"border-collapse:collapse;font-family:sans-serif;font-size:13px\">"
HTML_REPORT+="<tr style=\"background:#333;color:#fff\"><th>Site</th><th>Statut</th><th>Âge</th><th>DB</th><th>Fichiers (local)</th><th>Fichiers (restic)</th><th>Restic check</th><th>Détail</th></tr>"
for i in "${!ROW_SITE[@]}"; do
  if [[ "${ROW_ISSUE[$i]}" -eq 1 ]]; then
    row_style="background:#fde2e2"
  else
    row_style="background:#e6f6e6"
  fi
  HTML_REPORT+="<tr style=\"${row_style}\"><td>${ROW_SITE[$i]}</td><td>${ROW_STATUT[$i]}</td><td>${ROW_AGE[$i]}</td><td>${ROW_DB[$i]}</td><td>${ROW_FICHIERS[$i]}</td><td>${ROW_RESTIC[$i]}</td><td>${ROW_RESTIC_CHECK[$i]}</td><td>${ROW_DETAIL[$i]}</td></tr>"
done
HTML_REPORT+="</table>"

if [[ -n "$DIGEST_MAIL_TO" ]]; then
  MAIL_TO="$DIGEST_MAIL_TO"
  subject="hanako-check — $([[ "$ANY_ISSUE" -eq 1 ]] && echo 'A VERIFIER' || echo 'OK')"
  notify_mail "$subject" "$HTML_REPORT" "text/html; charset=UTF-8"
fi

[[ "$ANY_ISSUE" -eq 1 ]] && exit 1
exit 0
