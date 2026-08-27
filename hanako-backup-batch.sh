#!/usr/bin/env bash
# ============================================================
#  hanako-backup-batch.sh — Lance hanako-backup.sh pour une série
#  de sites listés dans un fichier de tâches (un site .conf par ligne).
#
#  Usage : ./hanako-backup-batch.sh tasks/ma-liste.txt
#
#  Chaque ligne peut être :
#    monsite.conf            (résolu dans configs/)
#    configs/monsite.conf    (chemin explicite)
#  Les lignes vides et celles commençant par # sont ignorées.
#
#  Le mot de passe/clé SSH de chaque site est géré par hanako-backup.sh
#  lui-même (clé SSH via SSH_KEY si définie dans le .conf, sinon prompt
#  SSH classique) — rien à faire de plus ici.
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKLIST="${1:-}"

if [[ -z "$TASKLIST" || ! -f "$TASKLIST" ]]; then
  echo "Usage : $0 chemin/vers/liste.txt" >&2
  exit 1
fi

FAILED=()
COUNT=0

# Lu entièrement en amont : sinon ssh (lancé par hanako-backup.sh)
# hériterait du fd 0 encore branché sur ce fichier et en consommerait le
# reste, ce qui arrêtait la boucle après la première tâche.
# (mapfile n'existe pas sur le bash 3.2 livré par défaut sur macOS.)
LINES=()
while IFS= read -r line || [[ -n "$line" ]]; do
  LINES+=("$line")
done < "$TASKLIST"

for line in "${LINES[@]}"; do
  # Ignore lignes vides et commentaires
  line="${line%%#*}"
  line="$(echo "$line" | xargs)"
  [[ -z "$line" ]] && continue

  conf="$line"
  [[ "$conf" != */* ]] && conf="configs/$conf"
  [[ "$conf" != *.conf ]] && conf="${conf}.conf"
  [[ "$conf" != /* ]] && conf="$SCRIPT_DIR/$conf"

  if [[ ! -f "$conf" ]]; then
    echo "✗ Config introuvable : $conf" >&2
    FAILED+=("$line")
    continue
  fi

  if ! "$SCRIPT_DIR/hanako-backup.sh" "$conf" < /dev/null; then
    FAILED+=("$line")
  fi
done

echo
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "✗ Échec(s) : ${FAILED[*]}" >&2
  exit 1
fi
echo "✓ ${COUNT} sauvegarde(s) terminée(s) sans échec."
