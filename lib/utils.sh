#!/usr/bin/env bash
# ============================================================
#  lib/utils.sh — fonctions partagées
# ============================================================

# Couleurs
C_RESET='\033[0m'; C_BOLD='\033[1m'
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
C_BLUE='\033[34m'; C_CYAN='\033[36m'

log()      { echo -e "${C_CYAN}›${C_RESET} $*"; }
ok()       { echo -e "${C_GREEN}✓${C_RESET} $*"; }
warn()     { echo -e "${C_YELLOW}!${C_RESET} $*"; }
err()      { echo -e "${C_RED}✗${C_RESET} $*" >&2; }
phase()    { echo -e "\n${C_BOLD}${C_BLUE}━━━ $* ━━━${C_RESET}"; }

# --- Multiplexage SSH (ControlMaster) ------------------------
SSH_TARGET=""
SSH_CTRL_DIR=""
SSH_CTRL_PATH=""
SSH_OPTS=()
# Mémorisés pour pouvoir rouvrir la connexion si elle meurt.
_SSH_USER=""; _SSH_HOST=""; _SSH_PORT=""; _SSH_KEY=""

ssh_open_master() {
  local user="$1" host="$2" port="${3:-22}" key="${4:-}"
  _SSH_USER="$user"; _SSH_HOST="$host"; _SSH_PORT="$port"; _SSH_KEY="$key"
  SSH_TARGET="${user}@${host}"
  # Socket réutilisée même après reconnexion : on ne recrée pas le dossier
  # si on rouvre (sinon on perdrait le chemin).
  if [[ -z "$SSH_CTRL_DIR" || ! -d "$SSH_CTRL_DIR" ]]; then
    SSH_CTRL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hanako-backup-ssh.XXXXXX")"
    SSH_CTRL_PATH="${SSH_CTRL_DIR}/ctrl.sock"
  fi
  SSH_OPTS=(
    -4
    -o "ConnectTimeout=15"           # échoue vite plutôt que de bloquer indéfiniment
    -o "ConnectionAttempts=1"
    -o "StrictHostKeyChecking=accept-new"  # jamais de prompt interactif invisible
    -o "ControlMaster=auto"
    -o "ControlPath=${SSH_CTRL_PATH}"
    -o "ControlPersist=4h"          # la socket survit jusqu'à 4h d'inactivité
    -o "ServerAliveInterval=60"     # ping toutes les 60s pour ne pas être coupé
    -o "ServerAliveCountMax=10"     # tolère 10 pings ratés avant d'abandonner
    -p "${port}"
  )
  # Si SSH_KEY pointe vers une clé privée (config du site), on l'utilise en
  # authentification par clé, sans prompt interactif — indispensable pour un
  # NAS/cron. IdentitiesOnly force l'usage de cette clé (pas de fallback vers
  # l'agent) et BatchMode fait échouer proprement plutôt que d'attendre un
  # mot de passe qui ne viendra jamais.
  if [[ -n "$key" ]]; then
    if [[ ! -f "$key" ]]; then
      err "Clé SSH introuvable : $key"
      return 1
    fi
    SSH_OPTS+=(-i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o PasswordAuthentication=no)
    log "Ouverture de la connexion SSH (clé : $(basename "$key"))…"
  else
    log "Ouverture de la connexion SSH (mot de passe demandé une seule fois)…"
  fi
  if ssh "${SSH_OPTS[@]}" -M -N -f "${SSH_TARGET}"; then
    ok "Connexion SSH maître établie — réutilisée pour toute la session."
    return 0
  fi
  err "Impossible d'établir la connexion SSH maître."
  return 1
}

ssh_close_master() {
  if [[ -n "$SSH_CTRL_PATH" && -S "$SSH_CTRL_PATH" ]]; then
    ssh "${SSH_OPTS[@]}" -O exit "${SSH_TARGET}" 2>/dev/null
  fi
  [[ -n "$SSH_CTRL_DIR" && -d "$SSH_CTRL_DIR" ]] && rm -rf "$SSH_CTRL_DIR"
}

remote() {
  ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "$@"
}

wpr() {
  local cmd arg
  cmd="cd '$REMOTE_WP_PATH' && ${WP_CLI_CMD}"
  for arg in "$@"; do
    cmd+=" $(printf '%q' "$arg")"
  done
  remote "$cmd"
}

# --- Détection d'un rsync capable de --info=progress2 --------
# macOS livre openrsync par défaut, qui ne supporte pas --info=progress2 :
# on retombe alors sur --progress, qui imprime nom + stats sur deux lignes
# PAR FICHIER (illisible sur un gros site). On cherche donc d'abord un
# rsync GNU (typiquement installé via `brew install rsync`), qui affiche
# une seule ligne mise à jour en continu pour tout le transfert.
#
# La progression (\r) n'a de sens que sur un vrai terminal : un outil de
# reporting/cron qui capture stdout dans un fichier de log convertit
# chaque \r en \n, ce qui transforme une ligne qui se met à jour en place
# en des centaines de lignes. On ne l'active donc que si stdout est un tty.
RSYNC_BIN=""
RSYNC_PROGRESS_OPT=""
detect_rsync() {
  local candidates=()
  if command -v brew >/dev/null 2>&1; then
    local brew_rsync
    brew_rsync="$(brew --prefix rsync 2>/dev/null)/bin/rsync"
    [[ -x "$brew_rsync" ]] && candidates+=("$brew_rsync")
  fi
  candidates+=("/opt/homebrew/bin/rsync" "/usr/local/bin/rsync" "rsync")

  local c
  for c in "${candidates[@]}"; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" --info=progress2 --version >/dev/null 2>&1; then
      RSYNC_BIN="$c"
      [[ -t 1 ]] && RSYNC_PROGRESS_OPT="--info=progress2"
      break
    fi
  done

  if [[ -z "$RSYNC_BIN" ]]; then
    RSYNC_BIN="rsync"
    if rsync --progress --version >/dev/null 2>&1; then
      if [[ -t 1 ]]; then
        RSYNC_PROGRESS_OPT="--progress"
        warn "rsync système sans --info=progress2 (openrsync) — progression sur deux lignes."
        warn "Pour une ligne unique : brew install rsync"
      fi
    else
      [[ -t 1 ]] && warn "Option de progression rsync indéterminée — copie sans barre."
    fi
  fi

  if [[ -z "$RSYNC_PROGRESS_OPT" && ! -t 1 ]]; then
    log "Sortie non-interactive détectée (cron/NAS) — progression rsync désactivée pour un log lisible."
  fi
}

rsync_pull() {
  local remote_src="$1" local_dst="$2"; shift 2
  "$RSYNC_BIN" -az ${RSYNC_PROGRESS_OPT:+$RSYNC_PROGRESS_OPT} "$@" \
    -e "ssh ${SSH_OPTS[*]}" \
    "${SSH_TARGET}:${remote_src}" "${local_dst}"
}