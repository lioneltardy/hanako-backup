#!/usr/bin/env bash
# ============================================================
#  lib/notify.sh — notification mail de fin de sauvegarde (via msmtp)
#  Sourcé UNIQUEMENT par hanako-backup.sh.
#
#  macOS n'a pas de MTA local fonctionnel par défaut : msmtp est un client
#  SMTP minimal qui se configure avec n'importe quel fournisseur (y compris
#  une adresse Infomaniak). Installation : brew install msmtp
#  Config une fois pour toutes dans ~/.msmtprc (voir doc msmtp), puis
#  définir MAIL_TO (et MSMTP_ACCOUNT si tu as plusieurs comptes) dans le
#  fichier .conf du site.
# ============================================================

# notify_mail <sujet> <corps>
notify_mail() {
  local subject="$1" body="$2"

  [[ -n "${MAIL_TO:-}" ]] || return 0   # pas de MAIL_TO configuré = notif désactivée

  # command -v seul dépend du PATH du contexte d'exécution (cron/NAS ont
  # souvent un PATH minimal qui n'inclut pas /opt/bin, /usr/local/bin…) —
  # on cherche donc aussi dans les emplacements d'install courants.
  local msmtp_bin="" candidate
  for candidate in msmtp /opt/bin/msmtp /usr/local/bin/msmtp /usr/bin/msmtp; do
    if command -v "$candidate" >/dev/null 2>&1; then
      msmtp_bin="$candidate"
      break
    fi
  done

  if [[ -z "$msmtp_bin" ]]; then
    warn "msmtp introuvable (PATH actuel : $PATH) — notification mail ignorée."
    return 1
  fi

  local account_opt=()
  [[ -n "${MSMTP_ACCOUNT:-}" ]] && account_opt=(-a "$MSMTP_ACCOUNT")

  # timeout évite qu'un envoi qui bloque (SMTP injoignable, port filtré…)
  # ne fasse jamais se terminer le script de sauvegarde.
  local run_cmd=("$msmtp_bin")
  command -v timeout >/dev/null 2>&1 && run_cmd=(timeout 20 "$msmtp_bin")

  {
    echo "Subject: ${subject}"
    echo "To: ${MAIL_TO}"
    echo
    echo -e "$body"
  } | "${run_cmd[@]}" "${account_opt[@]+"${account_opt[@]}"}" "$MAIL_TO"
}