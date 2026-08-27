# Déploiement sur un nouveau NAS Synology

Procédure complète pour repartir de zéro (NAS de remplacement, réinstallation
DSM, migration…).

## 1. Prérequis système (via Package Center / Entware)

- **Package Center** : installer *SSH Service* (Panneau de configuration →
  Terminal & SNMP → activer le service SSH).
- **Entware** (gestionnaire de paquets tiers, nécessaire pour `restic` et
  quelques utilitaires) : installer via le paquet communautaire SynoCommunity
  ou le script officiel Entware pour DSM.
- Une fois Entware actif :
  ```bash
  opkg update
  opkg install bash rsync msmtp gnupg
  ```
- **restic** : Entware n'a pas toujours un paquet à jour. Télécharger le
  binaire statique correspondant à l'architecture du NAS (ARM/x86_64) depuis
  <https://github.com/restic/restic/releases>, puis :
  ```bash
  chmod +x restic_*_linux_*
  mv restic_*_linux_* /opt/bin/restic
  restic version
  ```
- Vérifier que `bash`, `rsync`, `ssh`, `msmtp`, `restic` sont bien dans le
  `PATH` de l'utilisateur qui exécutera le script (pas seulement dans un
  shell interactif — vérifier aussi depuis une tâche planifiée DSM).

## 2. Récupérer le dépôt du script

```bash
cd /volume/chemin/de/ton/choix
git clone <url-du-repo> hanako-backup
cd hanako-backup
chmod +x hanako-backup.sh hanako-backup-batch.sh lib/*.sh
```

## 3. Désactiver IPv6 si nécessaire

Si l'IPv6 sortant du NAS n'est pas fonctionnel (symptôme : connexions SSH ou
mail qui bloquent indéfiniment sans erreur), désactiver IPv6 :
**Panneau de configuration → Réseau → Interface réseau → [interface] →
Modifier → décocher "Activer IPv6"**, puis redémarrer le NAS ou renouveler
la configuration réseau. Vérifier ensuite :
```bash
nslookup mail.infomaniak.ch
bash -c 'exec 3<>/dev/tcp/mail.infomaniak.ch/465 && echo TCP_OK || echo TCP_FAIL'
```

## 4. Régénérer la clé SSH pour l'authentification Infomaniak

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -t ed25519 -f ~/.ssh/infomaniak-backup -C "hanako-backup-$(hostname)"
```
- Ne jamais mettre de passphrase (le script tourne sans interaction/cron).
- Ajouter le contenu de `~/.ssh/infomaniak-backup.pub` à
  `~/.ssh/authorized_keys` **sur chaque serveur Infomaniak** concerné (via
  le Manager Infomaniak ou en te connectant une première fois au mot de
  passe pour y déposer la clé).
- Tester : `ssh -i ~/.ssh/infomaniak-backup <SSH_USER>@<SSH_HOST>` (valeurs du
  `.conf` du site) doit se connecter sans prompt.

## 5. Configurer msmtp (notifications mail)

```bash
cat > ~/.msmtprc <<'EOF'
account infomaniak
host mail.infomaniak.ch
port 465
tls on
tls_starttls off
auth on
user lionel@aboutblank.ch
passwordeval "gpg --no-tty -q -d ~/.msmtp-password.gpg"
from lionel@aboutblank.ch
EOF
chmod 600 ~/.msmtprc
```
Chiffrer le mot de passe SMTP avec le binaire GPG réellement présent sur ce
NAS (`gpg` la plupart du temps, pas forcément `gpg2` — vérifier avec
`which gpg gpg2`) :
```bash
echo -n "mot-de-passe-smtp" | gpg --batch --yes --passphrase-file ~/.gpg-passphrase -c -o ~/.msmtp-password.gpg
```
Tester : `echo -e "Subject: test\n\nCeci est un test." | timeout 15 msmtp -a infomaniak ton-adresse@exemple.ch`

## 6. Configurer l'accès SwissBackup (Swift) pour restic

- Dans le Manager Infomaniak / Public Cloud, récupérer les identifiants
  OpenStack du projet SwissBackup (idéalement le fichier RC officiel plutôt
  que de les ressaisir à la main).
- Créer `~/.restic/swift-env.sh` :
  ```bash
  mkdir -p ~/.restic && chmod 700 ~/.restic
  cat > ~/.restic/swift-env.sh <<'EOF'
  export OS_AUTH_URL="https://swiss-backup02.infomaniak.com"
  export ST_AUTH_VERSION=3
  export OS_USERNAME="SBI-XXXXX"
  export OS_PASSWORD="xxxxx"
  export OS_PROJECT_NAME="sb_project_SBI-XXXXX"
  export OS_REGION_NAME="RegionOne"
  export OS_USER_DOMAIN_NAME="Default"
  export OS_PROJECT_DOMAIN_NAME="Default"
  EOF
  chmod 600 ~/.restic/swift-env.sh
  ```
- Voir [docs/nouveau-site.md](nouveau-site.md) pour la création du mot de
  passe restic et du dépôt par site.

## 7. Copier/recréer les fichiers `.conf` des sites

Les `.conf` ne sont **jamais committés** (secrets serveur, clés). Les
recopier depuis une sauvegarde sécurisée existante (gestionnaire de mots de
passe, sauvegarde chiffrée) plutôt que de les recréer de zéro — sinon,
suivre [docs/nouveau-site.md](nouveau-site.md) pour chaque site.

## 8. Tester un run complet avant de planifier

```bash
./hanako-backup.sh configs/monsite.conf
```
Vérifier : connexion SSH par clé, dump DB, sync fichiers, copie SwissBackup,
purge de rétention (locale + SwissBackup), mail de notification reçu.

## 9. Planifier via DSM Task Scheduler

**Panneau de configuration → Tâches planifiées → Créer → Tâche déclenchée
(script défini par l'utilisateur)**, exécutée par l'utilisateur propriétaire
des clés/`.msmtprc`/`.restic` (pas `root`, sauf si tout est configuré pour
root). Commande type :
```bash
/volume/chemin/hanako-backup/hanako-backup-batch.sh /volume/chemin/hanako-backup/tasks/private.list
```
Vérifier que le `PATH` de la tâche planifiée inclut `/opt/bin` et
`/opt/sbin` (souvent absent du `PATH` par défaut d'une tâche planifiée,
contrairement à une session SSH interactive) — sinon `restic`/`msmtp`
installés via Entware ne seront pas trouvés :
```bash
export PATH="/opt/bin:/opt/sbin:$PATH"
```
à ajouter en tête du script, ou dans le champ "Utilisateur" / variables
d'environnement de la tâche planifiée selon la version de DSM.
