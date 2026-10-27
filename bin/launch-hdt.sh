#!/usr/bin/env bash
# Met HDT à jour si besoin, puis le lance dans le préfixe de Battle.net :
#  - si Battle.net tourne (lancé avec STEAM_COMPAT_LAUNCHER_SERVICE=proton),
#    HDT est lancé dans son conteneur, donc dans le même environnement ;
#  - sinon HDT est lancé seul avec Proton (ferme-le avant d'ouvrir Battle.net).
set -euo pipefail
DIR="$(dirname "$(readlink -f "$0")")"
source "$DIR/hdt-common.sh"

if hdt_running; then
    hdt_log "HDT est déjà ouvert."
    exit 0
fi

"$DIR/hdt-update.sh" || hdt_log "Mise à jour impossible, lancement de la version installée."
hdt_disable_periodic_updates

app="$(hdt_latest_dir)"
if [ ! -f "$app/HearthstoneDeckTracker.exe" ]; then
    hdt_log "Exécutable HDT introuvable dans $HDT_ROOT"
    exit 1
fi

hdt_log "Lancement de HDT $(basename "$app" | sed 's/^app-//')"
run_in_prefix "$HDT_ROOT_WIN\\$(basename "$app")\\HearthstoneDeckTracker.exe"
