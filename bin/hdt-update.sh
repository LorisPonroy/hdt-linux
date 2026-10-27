#!/usr/bin/env bash
# Met HDT à jour avec le paquet complet de la dernière version.
# La mise à jour intégrée de HDT utilise des « deltas » qui font planter Proton
# (fonction msdelta.dll.ApplyDeltaW absente), d'où ce script.
# Usage : hdt-update.sh            (ne fait rien si HDT est déjà à jour)
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/hdt-common.sh"

if hdt_running; then
    hdt_log "HDT est ouvert : mise à jour reportée au prochain lancement."
    exit 0
fi

current="$(basename "$(hdt_latest_dir)")"
current="${current#app-}"

if ! latest="$(curl -fsS --max-time 10 https://api.github.com/repos/HearthSim/HDT-Releases/releases/latest \
        | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)" || [ -z "$latest" ]; then
    hdt_log "Impossible de vérifier les mises à jour (pas de réseau ?)."
    exit 0
fi

if [ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n 1)" = "$current" ]; then
    hdt_log "HDT $current est à jour."
    exit 0
fi

hdt_log "Mise à jour de HDT : $current -> $latest"

# Dossier de travail dans le préfixe, pour que Update.exe y accède en C:\
STAGE="$PREFIX/drive_c/users/steamuser/Temp/hdt-update"
STAGE_WIN='C:\users\steamuser\Temp\hdt-update'
rm -rf "$STAGE"
mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT

base="https://github.com/HearthSim/HDT-Releases/releases/download/v$latest"
pkg="HearthstoneDeckTracker-$latest-full.nupkg"

# Fichier RELEASES réduit au seul paquet complet : Squirrel n'utilisera pas de delta
curl -fsSL --max-time 30 "$base/RELEASES" \
    | sed '1s/^\xEF\xBB\xBF//' | tr -d '\r' | grep " $pkg " > "$STAGE/RELEASES" || {
    hdt_log "Paquet complet $pkg introuvable dans la publication v$latest."
    exit 1
}
read -r sha1 _ size < "$STAGE/RELEASES"

hdt_log "Téléchargement de $pkg ($((size / 1024 / 1024)) Mo)..."
curl -fL --max-time 600 --progress-bar -o "$STAGE/$pkg" "$base/$pkg"

got="$(sha1sum "$STAGE/$pkg" | cut -d' ' -f1)"
if [ "${got,,}" != "${sha1,,}" ]; then
    hdt_log "Empreinte incorrecte pour $pkg, mise à jour annulée."
    exit 1
fi

# Les deltas éventuellement téléchargés par HDT lui-même ne servent à rien
rm -f "$HDT_ROOT"/packages/*-delta.nupkg

run_in_prefix "$HDT_ROOT_WIN\\Update.exe" "--update=$STAGE_WIN"

if [ -f "$HDT_ROOT/app-$latest/HearthstoneDeckTracker.exe" ]; then
    hdt_log "HDT mis à jour en $latest."
else
    hdt_log "La mise à jour a échoué (voir $HDT_ROOT/SquirrelSetup.log)."
    exit 1
fi
