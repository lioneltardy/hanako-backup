# hanako-backup — Sauvegarde automatique WordPress / Infomaniak

Version 1.0.0 — 2026.08.28

Sauvegarde incrémentale (fichiers + base) avec hardlinks locaux, copie
offsite déduplicatée vers SwissBackup (Swift) via `restic`, et rétention
automatique (30 quotidiens + 12 hebdo + 6 mensuels par défaut, synchronisée
entre le NAS et SwissBackup).

## Procédures

- [Déploiement sur un nouveau NAS Synology](docs/deploiement-nas.md)
- [Mise en place d'une nouvelle sauvegarde (nouveau site)](docs/nouveau-site.md)
– [Restauration depuis SwissBackup](docs/restore.md)

## Prérequis

- `ssh`, `rsync`, `curl` (déjà présents sous macOS/Linux ; sur un NAS
  Synology voir [docs/deploiement-nas.md](docs/deploiement-nas.md))
- WP-CLI disponible côté serveur (commande configurable via `WP_CLI_CMD` :
  `wp`, `wp-cli`, `php wp-cli.phar`…)
- **Authentification SSH par clé** (recommandé sur NAS/cron, sans
  interaction) : renseigne `SSH_KEY="/chemin/vers/infomaniak-backup"` dans
  la config du site (clé privée ; la clé publique correspondante doit être
  ajoutée à `~/.ssh/authorized_keys` sur le serveur distant). Sans
  `SSH_KEY`, le mot de passe est demandé **une seule fois** au démarrage,
  puis réutilisé pour toute la session grâce au multiplexage SSH
  (ControlMaster).

```bash
cp exemple.conf configs/monsite.conf   # puis édite configs/monsite.conf
chmod +x hanako-backup.sh hanako-backup-batch.sh lib/*.sh
```

Ajoute `*.conf` à ton `.gitignore` — ces fichiers contiennent des chemins
serveur, clés, mots de passe, jamais dans un dépôt.

---

### Usage

```bash
./hanako-backup.sh configs/monsite.conf
```

Plusieurs sites d'un coup :
```bash
./hanako-backup-batch.sh tasks/ma-liste.txt
```
(un `.conf` par ligne — résolu automatiquement dans `configs/`, cf.
`tasks/exemple.list`).

Chaque run : connexion SSH → dump DB → rsync incrémental des fichiers
(hardlinks via `--link-dest` sur les fichiers inchangés) → copie offsite
SwissBackup (si activée) → purge de rétention (locale + SwissBackup) →
notification mail.

### Notification mail

Via `msmtp` (voir `MAIL_TO` / `MSMTP_ACCOUNT` dans la config du site).
`lib/notify.sh` cherche `msmtp` dans plusieurs emplacements courants
(`/opt/bin`, `/usr/local/bin`…) — utile sur NAS où le `PATH` d'une tâche
planifiée diffère du `PATH` d'une session SSH interactive — et enveloppe
l'envoi dans un `timeout 20` pour ne jamais bloquer tout le script si le
serveur SMTP ne répond pas.

### Copie offsite SwissBackup (restic) & rétention

Activable par site via `RESTIC_ENABLE="true"` dans le `.conf` (voir
`exemple.conf` pour la liste complète des variables `RESTIC_*` et
`SWIFT_ENV_FILE`). Après chaque sauvegarde locale réussie :
1. `restic backup` pousse le snapshot vers SwissBackup (déduplication au
   niveau bloc — pas de recopie intégrale à chaque run, contrairement à un
   simple miroir de type CloudSync).
2. `restic forget --prune` applique la rétention (30 quotidiens / 12
   hebdomadaires / 6 mensuels par défaut, ajustable via `RESTIC_KEEP_*`).
3. La même politique de rétention est appliquée **localement** sur le NAS
   (`prune_local_snapshots` dans `lib/snapshot.sh`) — NAS et SwissBackup
   restent en copie conforme, sans lien physique entre les deux purges (la
   suppression d'un snapshot local ne supprime jamais son équivalent
   offsite, et inversement).

Restauration depuis SwissBackup — voir
[docs/nouveau-site.md](docs/nouveau-site.md) §6, ou en résumé :
```bash
source ~/.restic/swift-env.sh
export RESTIC_REPOSITORY="swift:hanako-backup:/monsite"
export RESTIC_PASSWORD_FILE=~/.restic/monsite.pass
restic snapshots --host monsite
restic restore latest --target /chemin/de/restauration
```

### Restauration manuelle depuis le NAS

Chaque snapshot est déposé dans `LOCAL_BACKUP_DIR/<SITE_NAME>/<horodatage>/`
(`files/` + `database/`). Restauration manuelle :
```bash
# Fichiers
rsync -az LOCAL_BACKUP_DIR/monsite/<stamp>/files/ $SSH_USER@$SSH_HOST:$REMOTE_WP_PATH/
# Base
ssh $SSH_USER@$SSH_HOST "cd CHEMIN && wp db import -" \
  < LOCAL_BACKUP_DIR/monsite/<stamp>/database/*.sql
```