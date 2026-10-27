# Réglages et fonctions partagés par les scripts HDT (à charger avec « source »).
#
# HDT doit tourner dans le préfixe Proton de Battle.net (raccourci Steam
# non-Steam), car il lit la mémoire de Hearthstone. Steam lance Battle.net dans
# un conteneur (Steam Linux Runtime). Pour que HDT tourne dans le même
# environnement, on passe par le « service de lancement » de ce conteneur,
# actif quand Battle.net est lancé avec STEAM_COMPAT_LAUNCHER_SERVICE=proton.

HDT_LINUX_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
HDT_LINUX_CONF="$HDT_LINUX_DIR/hdt-linux.conf"

if [ ! -f "$HDT_LINUX_CONF" ]; then
    echo "[HDT] Configuration absente : $HDT_LINUX_CONF (relance install.sh)" >&2
    exit 1
fi
# Définit STEAM, COMPAT, PROTON_DIR, LAUNCH_CLIENT
source "$HDT_LINUX_CONF"

PREFIX="$COMPAT/pfx"
PROTON="$PROTON_DIR/proton"
HDT_ROOT="$PREFIX/drive_c/users/steamuser/AppData/Local/HearthstoneDeckTracker"
HDT_ROOT_WIN='C:\users\steamuser\AppData\Local\HearthstoneDeckTracker'
HDT_CONFIG="$PREFIX/drive_c/users/steamuser/AppData/Roaming/HearthstoneDeckTracker/config.xml"
BUS=""   # nom du service de lancement, trouvé par find_bus

hdt_log() { echo "[HDT $(date +%H:%M:%S)] $*" >&2; }

# Dossier app-X.Y.Z le plus récent (chemin Linux)
hdt_latest_dir() { ls -d "$HDT_ROOT"/app-* 2>/dev/null | sort -V | tail -n 1; }

# Vrai si le processus PID tourne dans notre préfixe
in_prefix() {
    tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null \
        | grep -q -E "^WINEPREFIX=.*/$(basename "$COMPAT")/pfx/?\$"
}

# Processus Windows de notre préfixe uniquement (ligne de commande
# « C:\...\nom.exe »), pour ne pas confondre avec un terminal dont la commande
# contient ce nom, ni avec un autre jeu Proton.
win_proc() {
    local p
    for p in $(pgrep -f "^[A-Za-z]:\\\\.*\\\\$1( |\$)"); do
        if in_prefix "$p"; then echo "$p"; return 0; fi
    done
    return 0
}

hdt_running()  { [ -n "$(win_proc 'HearthstoneDeckTracker\.exe')" ]; }
hs_pid()       { win_proc 'Hearthstone\.exe'; }
bnet_running() { [ -n "$(win_proc 'Battle\.net\.exe')" ] || [ -n "$(hs_pid)" ]; }

# Trouve le service du conteneur qui utilise notre préfixe (remplit BUS).
# Il s'appelle « com.steampowered.App<id> » ; pour un raccourci non-Steam,
# Steam utilise l'id 0, d'où la vérification par WINEPREFIX.
find_bus() {
    local name suffix
    suffix="$(basename "$COMPAT")/pfx"
    [ -x "$LAUNCH_CLIENT" ] || return 1
    for name in $("$LAUNCH_CLIENT" --list 2>/dev/null \
            | sed -n 's/^--bus-name=\(com\.steampowered\.App[0-9]*\)$/\1/p'); do
        if "$LAUNCH_CLIENT" --bus-name="$name" -- \
                sh -c 'case "$WINEPREFIX" in */"$1"|*/"$1"/) exit 0;; esac; exit 1' sh "$suffix" \
                >/dev/null 2>&1; then
            BUS="$name"
            return 0
        fi
    done
    BUS=""
    return 1
}

bnet_service_up() { find_bus; }

# Exécute un programme Windows dans le préfixe et attend sa fin :
#  - dans le conteneur de Battle.net s'il tourne ;
#  - sinon directement avec Proton (Battle.net doit alors être fermé).
# Avec HDT_CONTAINER_ONLY=1, attend le conteneur au plus 60 s et ne lance
# jamais hors de celui-ci.
run_in_prefix() {
    if [ "${HDT_CONTAINER_ONLY:-0}" = 1 ]; then
        local i
        for i in $(seq 30); do bnet_service_up && break; sleep 2; done
    fi
    if bnet_service_up; then
        "$LAUNCH_CLIENT" --bus-name="$BUS" -- wine "$@"
    elif [ "${HDT_CONTAINER_ONLY:-0}" = 1 ]; then
        hdt_log "Le conteneur de Battle.net ne répond pas : HDT n'est pas lancé."
        return 1
    elif bnet_running; then
        hdt_log "Battle.net tourne sans le service de lancement : ajoute"
        hdt_log "STEAM_COMPAT_LAUNCHER_SERVICE=proton dans ses options de lancement Steam."
        return 1
    else
        STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM" \
        STEAM_COMPAT_DATA_PATH="$COMPAT" \
        STEAM_COMPAT_APP_ID="$(basename "$COMPAT")" \
        WINEPREFIX="$PREFIX" \
            "$PROTON" run "$@"
    fi
}

# Coupe la vérification des mises à jour de HDT toutes les 20 min : elle
# passerait par des « deltas » qui font planter Proton. hdt-update.sh s'en
# charge avant chaque lancement. (La vérification au démarrage reste active.)
hdt_disable_periodic_updates() {
    [ -f "$HDT_CONFIG" ] && ! hdt_running || return 0
    sed -i 's#<CheckForUpdates>true</CheckForUpdates>#<CheckForUpdates>false</CheckForUpdates>#' "$HDT_CONFIG"
}
