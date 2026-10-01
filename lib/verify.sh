#!/usr/bin/env bash
# ============================================================
#  lib/verify.sh — vérifications de cohérence sur le dump DB et les
#  fichiers rapatriés (taille, chute anormale vs le snapshot précédent,
#  présence de fichiers clés). Ce ne sont que des heuristiques : elles ne
#  garantissent pas qu'une restauration fonctionnerait réellement (pour
#  ça, voir docs/restore.md et tester "à la main" de temps en temps).
#  Sourcé UNIQUEMENT par hanako-backup.sh.
# ============================================================

# file_size_bytes <fichier> — portable GNU/BSD (macOS et Synology/Entware).
file_size_bytes() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0
}

# dump_is_complete <fichier> — un dump mysqldump/wp-cli valide se termine
# par "UNLOCK TABLES;". Un dump tronqué (coupure réseau pendant le rapatriement,
# export interrompu côté serveur…) ne l'aura pas. Signal utile mais pas une
# garantie absolue (dépend du moteur d'export utilisé côté serveur).
dump_is_complete() {
  tail -n 20 "$1" 2>/dev/null | grep -qi "unlock tables"
}

# previous_dump_size <snapshot_precedent> — taille en octets du dump SQL du
# snapshot précédent, 0 si absent.
previous_dump_size() {
  local prev="$1" f
  [[ -n "$prev" && -d "$prev/database" ]] || { echo 0; return; }
  for f in "$prev"/database/*.sql; do
    [[ -f "$f" ]] && { file_size_bytes "$f"; return; }
  done
  echo 0
}

# previous_files_count <snapshot_precedent> — 0 si absent.
previous_files_count() {
  local prev="$1"
  [[ -n "$prev" && -d "$prev/files" ]] || { echo 0; return; }
  find "$prev/files" -type f | wc -l | tr -d ' '
}

# dir_size_bytes <dossier> — somme des tailles logiques des fichiers (pas
# l'usage disque réel : avec --link-dest, deux snapshots partagent les mêmes
# blocs via hardlinks, "du" sous-compterait donc le poids réel du contenu).
dir_size_bytes() {
  local dir="$1"
  if stat -f%z /dev/null >/dev/null 2>&1; then
    find "$dir" -type f -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END{print s+0}'
  else
    find "$dir" -type f -exec stat -c%s {} + 2>/dev/null | awk '{s+=$1} END{print s+0}'
  fi
}

# human_size <octets> — affichage lisible (Ko/Mo/Go…), sans dépendance à
# numfmt (absent de certains environnements BSD/busybox).
human_size() {
  awk -v b="${1:-0}" 'BEGIN{
    split("o Ko Mo Go To", u, " ");
    i=1; while (b>=1024 && i<5){b/=1024; i++}
    printf "%.1f%s", b, u[i]
  }'
}

# pct_drop <ancien> <nouveau> — pourcentage de baisse (0 si pas de baisse).
pct_drop() {
  local old="$1" new="$2"
  [[ "$old" -gt 0 ]] || { echo 0; return; }
  (( new >= old )) && { echo 0; return; }
  echo $(( (old - new) * 100 / old ))
}

# write_snapshot_status <snapshot_path> <status> <db_bytes> <files_bytes> <nfiles>
#                        <warnings_csv> <restic_check> <restic_bytes> <restic_nfiles>
# Petit fichier clé=valeur (pas de JSON : reste lisible/parsable en bash pur,
# y compris sur l'ash/busybox d'un Synology). Base du rapport consolidé
# multi-sites (voir hanako-check.sh).
write_snapshot_status() {
  local snapshot_path="$1" status="$2" db_bytes="$3" files_bytes="$4" nfiles="$5" \
        warnings="$6" restic_check="$7" restic_bytes="${8:-0}" restic_nfiles="${9:-0}"
  {
    echo "STATUS=$status"
    echo "TIMESTAMP=$(basename "$snapshot_path")"
    echo "DB_SIZE_BYTES=$db_bytes"
    echo "FILES_SIZE_BYTES=$files_bytes"
    echo "NFILES=$nfiles"
    echo "WARNINGS=$warnings"
    echo "RESTIC_CHECK=$restic_check"
    echo "RESTIC_SIZE_BYTES=$restic_bytes"
    echo "RESTIC_NFILES=$restic_nfiles"
  } > "$snapshot_path/status.txt"
}
