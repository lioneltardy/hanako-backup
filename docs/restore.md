# Restaurer une sauvegarde restic

```bash
source ~/.restic/swift-env.sh
export RESTIC_REPOSITORY="swift:hanako-backup:/lioneltardy.com"
export RESTIC_PASSWORD_FILE=~/.restic/lioneltardy.pass

# Lister les snapshots disponibles
restic snapshots --host lioneltardy.com

# Restaurer le plus récent en entier
restic restore latest --target /chemin/de/restauration

# Restaurer seulement un sous-dossier (ex. juste la base de données)
restic restore latest --target /chemin --include /database

# Parcourir sans tout restaurer / extraire un seul fichier
restic ls latest
restic dump latest /chemin/vers/fichier > fichier-restaure
```