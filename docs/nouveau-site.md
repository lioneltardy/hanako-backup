# Mise en place d'une nouvelle sauvegarde (nouveau site)

Procédure pour ajouter un nouveau site WordPress au périmètre de sauvegarde.

## 1. Créer le fichier de config du site

```bash
cp exemple.conf configs/monsite.conf
```
Remplir dans `configs/monsite.conf` :
- `SITE_NAME`, `SSH_USER`, `SSH_HOST`, `SSH_PORT`
- `SSH_KEY` — réutiliser la clé existante (`$HOME/.ssh/infomaniak-backup`) si
  le site est chez le même hébergeur/compte ; sinon en générer une nouvelle
  (voir [docs/deploiement-nas.md](deploiement-nas.md) §4) et l'ajouter aux
  `authorized_keys` du nouveau serveur. (https://www.infomaniak.com/fr/support/faq/2054/se-connecter-avec-cle-ssh)
- `REMOTE_WP_PATH`, `WP_CLI_CMD`
- `LOCAL_BACKUP_DIR` (généralement le même dossier racine que les autres
  sites — un sous-dossier `SITE_NAME` y sera créé automatiquement)
- `MAIL_TO` (et `MSMTP_ACCOUNT` si plusieurs comptes msmtp existent)

Ne jamais committer ce fichier (`*.conf` doit être dans `.gitignore`).

## 2. Tester la connexion SSH seule, avant tout le reste

```bash
ssh -i ~/.ssh/infomaniak-backup <SSH_USER>@<SSH_HOST>
```
Doit se connecter sans prompt de mot de passe. Si ce n'est pas le cas,
ajouter la clé publique correspondante aux `authorized_keys` du serveur
distant avant d'aller plus loin.

## 3. Configurer restic / SwissBackup pour ce site

- Générer un mot de passe dédié (un par site — ne jamais réutiliser le
  même mot de passe restic pour deux dépôts) :
  ```bash
  mkdir -p ~/.restic
  openssl rand -base64 32 > ~/.restic/monsite.pass
  chmod 600 ~/.restic/monsite.pass
  ```
  **Sauvegarder ce mot de passe immédiatement** dans un gestionnaire de
  mots de passe (Proton Pass, Bitwarden…) — sans lui, le contenu chiffré
  sur SwissBackup est définitivement irrécupérable, même par Infomaniak.
- Dans `configs/monsite.conf`, ajouter/adapter :
  ```bash
  RESTIC_ENABLE="true"
  RESTIC_REPOSITORY="swift:hanako-backup:/monsite"
  RESTIC_PASSWORD_FILE="$HOME/.restic/monsite.pass"
  SWIFT_ENV_FILE="$HOME/.restic/swift-env.sh"   # déjà partagé entre tous les sites
  RESTIC_KEEP_DAILY=30
  RESTIC_KEEP_WEEKLY=12
  RESTIC_KEEP_MONTHLY=6
  ```
- Initialiser le dépôt une première fois (sinon `hanako-backup.sh` le fait
  automatiquement au premier run, mais autant vérifier séparément) :
  ```bash
  source ~/.restic/swift-env.sh
  export RESTIC_REPOSITORY="swift:hanako-backup:/monsite"
  export RESTIC_PASSWORD_FILE=~/.restic/monsite.pass
  restic init
  ```

## 4. Premier run manuel (jamais planifié directement en aveugle)

```bash
./hanako-backup.sh configs/monsite.conf
```
Vérifier dans la sortie :
- connexion SSH & détection WP-CLI OK
- dump DB rapatrié
- fichiers synchronisés (nombre de fichiers cohérent, pas 0)
- copie SwissBackup effectuée + rétention appliquée (si `RESTIC_ENABLE=true`)
- mail de notification reçu (sujet "OK — Sauvegarde monsite")

## 5. Ajouter le site aux sauvegardes groupées

Ajouter une ligne dans `tasks/private.list` (ou la liste de tâches
utilisée) :
```
monsite.conf
```
(résolu automatiquement dans `configs/` par `hanako-backup-batch.sh`).

## 6. Vérification finale de restauration (à ne pas sauter)

Une sauvegarde jamais testée en restauration n'est pas une sauvegarde.
Faire au moins une fois :
```bash
source ~/.restic/swift-env.sh
export RESTIC_REPOSITORY="swift:hanako-backup:/monsite"
export RESTIC_PASSWORD_FILE=~/.restic/monsite.pass
restic snapshots --host monsite
restic restore latest --target /tmp/restore-test-monsite
```
et vérifier que les fichiers/dump SQL restaurés sont cohérents.
