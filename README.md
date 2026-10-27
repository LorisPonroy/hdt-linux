# hdt-linux

Installe [Hearthstone Deck Tracker](https://hsreplay.net/downloads/) (HDT) sous Linux,
quand Hearthstone est lancé via **Battle.net ajouté à Steam comme jeu non-Steam**
(Proton).

```sh
./install.sh
```

puis, dans Steam : clic droit sur Battle.net → **Propriétés** → **Général** →
**Options de lancement** :

```
STEAM_COMPAT_LAUNCHER_SERVICE=proton /home/<toi>/.local/bin/bnet-hdt-wrapper.sh %command%
```

(`install.sh` affiche la ligne exacte à copier.) HDT s'ouvre alors tout seul à chaque
lancement de Hearthstone.

## Prérequis

- Steam **natif** (pas la version Flatpak).
- Battle.net ajouté à Steam comme jeu non-Steam, avec Proton (testé avec Proton 11.0),
  installé et lancé au moins une fois. Hearthstone installé depuis Battle.net.
- `curl`, `7z` (p7zip), `sha256sum`, `tar`.
- Battle.net, Hearthstone et HDT **fermés** pendant l'installation.

## Ce que fait `install.sh`

Chaque étape est sautée si elle est déjà faite : le script peut être relancé sans risque.

1. **Détection** : dossier Steam, préfixe Proton qui contient `Battle.net.exe`, version
   de Proton utilisée par ce préfixe, Steam Linux Runtime associé.
2. **.NET Framework 4.8** de Microsoft à la place de wine-mono (le préfixe est sauvegardé
   avant, dans `compatdata/<id>/hdt-linux-backup-<date>/`).
3. **HDT**, avec son installeur officiel (dernière version sur GitHub).
4. **Scripts** dans `~/.local/bin` (modifiable avec `--bin-dir`) :

| Script | Rôle |
|---|---|
| `bnet-hdt-wrapper.sh` | À mettre dans les options de lancement de Battle.net. Lance Battle.net, puis HDT à chaque démarrage de Hearthstone. Journal : `~/.cache/bnet-hdt-wrapper.log` |
| `launch-hdt.sh` | Met HDT à jour puis le lance. Utilisable à la main. |
| `hdt-update.sh` | Met HDT à jour avec le paquet complet. |
| `hdt-common.sh`, `hdt-linux.conf` | Fonctions et chemins partagés (`hdt-linux.conf` est généré). |

Options : `./install.sh --help` (`--compatdata`, `--appid`, `--proton`, `--bin-dir`,
`--no-backup`).

## Pourquoi tout ça

Chaque point ci-dessous a cassé HDT avant d'être contourné.

**HDT doit être dans le préfixe de Battle.net.** Il lit la mémoire de Hearthstone, ce
qui ne marche qu'entre programmes du même préfixe Wine.

**… et dans le même environnement que Battle.net.** Steam lance Battle.net dans un
conteneur (Steam Linux Runtime). Un HDT lancé à côté avec `proton run` partage le même
`wineserver` sans être dans le conteneur. Résultat : HDT se fige, ou Proton attend
indéfiniment ce `wineserver` étranger. La variable `STEAM_COMPAT_LAUNCHER_SERVICE=proton`
fait démarrer un service dans le conteneur, et `steam-runtime-launch-client` y lance HDT.
Pour un jeu non-Steam, ce service s'appelle `com.steampowered.App0` (et non l'id du
préfixe) : les scripts le cherchent par `--list` et vérifient son `WINEPREFIX`.

**wine-mono ne suffit pas.** HDT démarre sous wine-mono, mais HearthMirror (le module
C++/CLI qui lit la mémoire du jeu) plante dès que Hearthstone tourne
(`Native Crash Reporting … HearthMirror.Reflection:GetAccountId`). Il faut le vrai .NET.
Or `winetricks dotnet48` échoue sous Proton :
- Proton remplace des DLL du préfixe par des liens vers ses propres fichiers en lecture
  seule (`diasymreader.dll`, `mscoree.dll`…) : l'installeur Microsoft ne peut pas écrire
  à travers (erreur 5, puis 1603). Le script supprime ces liens et lance l'installeur
  avec le `wine` de Proton directement, car `proton run` les recréerait.
- L'installeur 4.8 ne fournit pas `mscoree.dll` (Windows l'a déjà) : le script le prend
  dans le paquet officiel .NET 4.0.
- La clé de registre `InstallRoot`, supprimée avec wine-mono, doit être recréée.

**Les mises à jour intégrées de HDT plantent Proton.** HDT se met à jour par petits
correctifs (« deltas ») appliqués avec `msdelta.dll`, que Wine n'implémente pas
(`unimplemented function msdelta.dll.ApplyDeltaW, aborting`). `hdt-update.sh` installe à
la place le paquet complet de la dernière version, avant chaque lancement. La
vérification toutes les 20 minutes de HDT est coupée (`CheckForUpdates` dans
`config.xml`).

## Dépannage

- **HDT ne s'ouvre pas avec Hearthstone** : regarde `~/.cache/bnet-hdt-wrapper.log`, et
  vérifie dans Steam que les options de lancement de Battle.net ont bien été enregistrées.
- **HDT plante à nouveau après une mise à jour de Proton** : une mise à jour majeure peut
  retirer `mscoree.dll`. Ferme tout et relance `./install.sh`, qui ne refait que ce qui
  manque.
- **Lancer HDT sans Battle.net** : `launch-hdt.sh` fonctionne aussi seul, mais ferme-le
  avant d'ouvrir Battle.net (sinon Battle.net reste bloqué au démarrage).
- Tant que HDT est ouvert, Steam considère Battle.net comme lancé.
- Journaux de HDT : `<préfixe>/drive_c/users/steamuser/AppData/Roaming/HearthstoneDeckTracker/Logs/`.

## Désinstallation

```sh
./uninstall.sh          # retire les scripts de ~/.local/bin
```

puis remets `%command%` dans les options de lancement de Battle.net. HDT et .NET restent
dans le préfixe. Pour revenir à l'état d'avant, Battle.net fermé, restaure la sauvegarde :

```sh
cd ~/.local/share/Steam/steamapps/compatdata/<id>
cp hdt-linux-backup-<date>/*.reg pfx/
rm -rf pfx/drive_c/windows && tar -C pfx/drive_c -xf hdt-linux-backup-<date>/windows.tar
```
