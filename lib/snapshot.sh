#!/usr/bin/env bash
# ============================================================
#  lib/snapshot.sh — sauvegarde incrémentale par hardlinks (rsync --link-dest)
#  Sourcé UNIQUEMENT par hanako-backup.sh. rsync_pull() de lib/utils.sh reste
#  inchangé et disponible pour d'autres usages (ex. rapatriement du dump SQL).
# ============================================================

# rsync_pull_snapshot <remote_src> <local_dst> [options rsync...]
# Même mécanique que rsync_pull(), avec pour seule différence l'appelant
# qui lui passe --link-dest=<snapshot précédent> pour créer des hardlinks
# sur les fichiers inchangés au lieu de les recopier.
rsync_pull_snapshot() {
  local remote_src="$1" local_dst="$2"; shift 2
  "$RSYNC_BIN" -a ${RSYNC_PROGRESS_OPT:+$RSYNC_PROGRESS_OPT} "$@" \
    -e "ssh ${SSH_OPTS[*]}" \
    "${SSH_TARGET}:${remote_src}" "${local_dst}"
}

# previous_snapshot_dir <dossier_du_site> <horodatage_en_cours>
# Renvoie le chemin du snapshot le plus récent (hors celui en cours de
# création), à utiliser comme référence --link-dest. Chaîne vide si
# c'est le premier snapshot du site.
previous_snapshot_dir() {
  local site_root="$1" current_stamp="$2" prev=""
  local d
  for d in "$site_root"/*/; do
    d="${d%/}"
    [[ "$(basename "$d")" == "$current_stamp" ]] && continue
    [[ -d "$d/files" ]] || continue
    prev="$d"   # le tri lexicographique du glob = tri chronologique (YYYYmmdd-HHMMSS)
  done
  echo "$prev"
}

# --- Rétention locale (grandfather-father-son, façon `restic forget`) -----
# Pas d'associative arrays ici (bash 3.2 livré par défaut sur macOS n'en a
# pas) : recherche linéaire dans des tableaux indexés, largement suffisant
# vu le nombre de snapshots en jeu.

# Convertit un stamp "YYYYmmdd-HHMMSS" en epoch, portable GNU/BSD.
_stamp_to_epoch() {
  local stamp="$1"
  local y="${stamp:0:4}" mo="${stamp:4:2}" d="${stamp:6:2}"
  local h="${stamp:9:2}" mi="${stamp:11:2}" s="${stamp:13:2}"
  date -j -f "%Y-%m-%d %H:%M:%S" "${y}-${mo}-${d} ${h}:${mi}:${s}" +%s 2>/dev/null && return 0
  date -d "${y}-${mo}-${d} ${h}:${mi}:${s}" +%s 2>/dev/null
}

# Formatte un epoch selon $1, portable GNU/BSD.
_epoch_fmt() {
  local fmt="$1" epoch="$2"
  date -j -f %s "$epoch" "+$fmt" 2>/dev/null && return 0
  date -u -d "@$epoch" "+$fmt" 2>/dev/null
}

# prune_local_snapshots <dossier_du_site> <keep_daily> <keep_weekly> <keep_monthly>
# Conserve, par ordre décroissant de récence, le dernier snapshot de chacun
# des N derniers jours / semaines ISO / mois distincts ayant une sauvegarde
# (union des trois fenêtres), supprime le reste. Affiche le nombre supprimé.
prune_local_snapshots() {
  local site_root="$1" keep_daily="${2:-0}" keep_weekly="${3:-0}" keep_monthly="${4:-0}"
  local d base
  local -a dirs=()
  for d in "$site_root"/*/; do
    d="${d%/}"
    base="$(basename "$d")"
    [[ "$base" =~ ^[0-9]{8}-[0-9]{6}$ ]] || continue
    dirs+=("$base")
  done
  if [[ ${#dirs[@]} -eq 0 ]]; then echo 0; return 0; fi

  # Tri décroissant (le plus récent d'abord) — le format se trie lexicographiquement.
  local sorted
  sorted="$(printf '%s\n' "${dirs[@]}" | sort -r)"

  local -a keep_list=() seen_days=() seen_weeks=() seen_months=()
  local kept_daily=0 kept_weekly=0 kept_monthly=0
  local stamp epoch day week month matched found item

  while IFS= read -r stamp; do
    [[ -z "$stamp" ]] && continue
    epoch="$(_stamp_to_epoch "$stamp")" || continue
    day="$(_epoch_fmt "%Y%m%d" "$epoch")"
    week="$(_epoch_fmt "%G-%V" "$epoch")"
    month="$(_epoch_fmt "%Y%m" "$epoch")"
    matched=0

    if (( kept_daily < keep_daily )); then
      found=0
      for item in "${seen_days[@]:-}"; do [[ "$item" == "$day" ]] && found=1 && break; done
      if [[ "$found" -eq 0 ]]; then seen_days+=("$day"); kept_daily=$((kept_daily+1)); matched=1; fi
    fi
    if (( kept_weekly < keep_weekly )); then
      found=0
      for item in "${seen_weeks[@]:-}"; do [[ "$item" == "$week" ]] && found=1 && break; done
      if [[ "$found" -eq 0 ]]; then seen_weeks+=("$week"); kept_weekly=$((kept_weekly+1)); matched=1; fi
    fi
    if (( kept_monthly < keep_monthly )); then
      found=0
      for item in "${seen_months[@]:-}"; do [[ "$item" == "$month" ]] && found=1 && break; done
      if [[ "$found" -eq 0 ]]; then seen_months+=("$month"); kept_monthly=$((kept_monthly+1)); matched=1; fi
    fi

    [[ "$matched" -eq 1 ]] && keep_list+=("$stamp")
  done <<< "$sorted"

  local removed=0
  while IFS= read -r stamp; do
    [[ -z "$stamp" ]] && continue
    found=0
    for item in "${keep_list[@]:-}"; do [[ "$item" == "$stamp" ]] && found=1 && break; done
    if [[ "$found" -eq 0 ]]; then
      rm -rf "${site_root:?}/$stamp"
      removed=$((removed+1))
    fi
  done <<< "$sorted"

  echo "$removed"
}
