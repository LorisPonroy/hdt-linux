#!/usr/bin/env bash
# Lance Battle.net depuis Steam, puis HDT automatiquement à chaque démarrage
# de Hearthstone, dans le même conteneur que le jeu.
#
# Options de lancement de Battle.net dans Steam :
#   STEAM_COMPAT_LAUNCHER_SERVICE=proton /chemin/vers/bnet-hdt-wrapper.sh %command%
#
# Journal : ~/.cache/bnet-hdt-wrapper.log
DIR="$(dirname "$(readlink -f "$0")")"
source "$DIR/hdt-common.sh"

# Sans ce service, impossible d'entrer dans le conteneur de Battle.net
export STEAM_COMPAT_LAUNCHER_SERVICE="${STEAM_COMPAT_LAUNCHER_SERVICE:-proton}"

LOG="$HOME/.cache/bnet-hdt-wrapper.log"
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

"$@" &
main=$!

# Surveillance : HDT est lancé une fois par session de Hearthstone.
# Si tu fermes HDT pendant la partie, il n'est pas relancé.
watch_hearthstone() {
    local pid last_pid=""
    # Évite les avertissements LD_PRELOAD de Steam à chaque commande du journal
    unset LD_PRELOAD
    while kill -0 "$main" 2>/dev/null; do
        pid="$(hs_pid || true)"
        if [ -n "$pid" ] && [ "$pid" != "$last_pid" ]; then
            last_pid="$pid"
            if hdt_running; then
                hdt_log "Hearthstone démarré, HDT déjà ouvert."
            else
                hdt_log "Hearthstone démarré, lancement de HDT."
                HDT_CONTAINER_ONLY=1 "$DIR/launch-hdt.sh" &
            fi
        fi
        sleep 5
    done
}
watch_hearthstone >> "$LOG" 2>&1 &
watcher=$!

wait "$main"
rc=$?
kill "$watcher" 2>/dev/null
exit "$rc"
