#!/usr/bin/env bash
# Installe Hearthstone Deck Tracker (HDT) dans le préfixe Proton de Battle.net,
# lancé depuis Steam comme jeu non-Steam.
#
# Étapes (chacune est sautée si elle est déjà faite, le script peut être relancé) :
#   1. trouve Steam, le préfixe de Battle.net, Proton et le Steam Linux Runtime ;
#   2. remplace wine-mono par le vrai .NET Framework 4.8 de Microsoft
#      (HearthMirror, le module de HDT qui lit la mémoire du jeu, plante sous Mono) ;
#   3. installe HDT ;
#   4. installe les scripts de lancement et de mise à jour.
#
# Usage : ./install.sh [options]   (voir --help)
set -euo pipefail

SRC_DIR="$(dirname "$(readlink -f "$0")")"

BIN_DIR="$HOME/.local/bin"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/hdt-linux"
COMPAT=""
PROTON_DIR=""
DO_BACKUP=1

# Installeurs officiels de Microsoft (mêmes adresses et empreintes que winetricks)
NDP48_URL="https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe"
NDP48_SHA256="95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53"
NDP40_URL="https://download.microsoft.com/download/9/5/A/95A9616B-7A37-4AF6-BC36-D6EA96C8DAAE/dotNetFx40_Full_x86_x64.exe"
NDP40_SHA256="65e064258f2e418816b304f646ff9e87af101e4c9552ab064bb74d281c38659f"

usage() {
    cat <<EOF
Usage : $0 [options]

  --compatdata DIR   dossier compatdata du préfixe à utiliser
                     (par défaut : celui qui contient Battle.net.exe)
  --appid ID         même chose, en donnant l'identifiant du dossier compatdata
  --proton DIR       dossier de Proton (par défaut : celui du préfixe)
  --bin-dir DIR      où installer les scripts (par défaut : ~/.local/bin)
  --no-backup        ne pas sauvegarder le préfixe avant d'installer .NET
  -h, --help         affiche cette aide
EOF
}

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --compatdata) COMPAT="$(readlink -f "$2")"; shift 2 ;;
        --appid)      APPID_ARG="$2"; shift 2 ;;
        --proton)     PROTON_DIR="$(readlink -f "$2")"; shift 2 ;;
        --bin-dir)    BIN_DIR="$2"; shift 2 ;;
        --no-backup)  DO_BACKUP=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage; die "Option inconnue : $1" ;;
    esac
done

# ---------------------------------------------------------------- détection

for cmd in curl 7z sha256sum sha1sum pgrep tar; do
    command -v "$cmd" >/dev/null || die "Commande manquante : $cmd"
done

find_steam() {
    local d
    for d in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root"; do
        if [ -d "$d/steamapps" ]; then readlink -f "$d"; return 0; fi
    done
    if [ -d "$HOME/.var/app/com.valvesoftware.Steam" ]; then
        die "Steam en Flatpak n'est pas pris en charge (seul Steam natif l'est)."
    fi
    die "Steam introuvable."
}

# Bibliothèques Steam (dossiers contenant steamapps/)
steam_libraries() {
    echo "$STEAM"
    sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' \
        "$STEAM/steamapps/libraryfolders.vdf" 2>/dev/null
}

find_bnet_compat() {
    local lib d found=()
    while IFS= read -r lib; do
        for d in "$lib"/steamapps/compatdata/*/; do
            [ -f "$d/pfx/drive_c/Program Files (x86)/Battle.net/Battle.net.exe" ] \
                && found+=("$(readlink -f "$d")")
        done
    done < <(steam_libraries | sort -u)
    # dédoublonne (bibliothèques listées deux fois)
    mapfile -t found < <(printf '%s\n' "${found[@]}" | sort -u | sed '/^$/d')
    case "${#found[@]}" in
        0) die "Aucun préfixe Proton ne contient Battle.net. Ajoute Battle.net à Steam
    comme jeu non-Steam avec Proton, installe-le et lance-le une fois." ;;
        1) echo "${found[0]}" ;;
        *) warn "Plusieurs préfixes contiennent Battle.net :"
           printf '      %s\n' "${found[@]}" >&2
           die "Choisis-en un avec --compatdata DIR." ;;
    esac
}

# Proton utilisé par le préfixe : 2e ligne de config_info = <proton>/files/share/fonts/
find_proton() {
    local fonts dir
    fonts="$(sed -n 2p "$COMPAT/config_info" 2>/dev/null || true)"
    dir="${fonts%/files/share/fonts/}"
    [ -n "$fonts" ] && [ -x "$dir/proton" ] || \
        die "Version de Proton du préfixe introuvable : indique-la avec --proton DIR."
    readlink -f "$dir"
}

# Client du service de lancement, fourni par le Steam Linux Runtime que Proton exige
find_launch_client() {
    local tool_id lib dir client
    tool_id="$(sed -n 's/.*"require_tool_appid"[[:space:]]*"\([0-9]*\)".*/\1/p' \
        "$PROTON_DIR/toolmanifest.vdf" 2>/dev/null)"
    if [ -n "$tool_id" ]; then
        while IFS= read -r lib; do
            dir="$(sed -n 's/.*"installdir"[[:space:]]*"\(.*\)".*/\1/p' \
                "$lib/steamapps/appmanifest_$tool_id.acf" 2>/dev/null)"
            client="$lib/steamapps/common/$dir/pressure-vessel/bin/steam-runtime-launch-client"
            if [ -n "$dir" ] && [ -x "$client" ]; then echo "$client"; return 0; fi
        done < <(steam_libraries | sort -u)
    fi
    # repli : n'importe quel Steam Linux Runtime installé
    client="$(ls -d "$STEAM"/steamapps/common/SteamLinuxRuntime_*/pressure-vessel/bin/steam-runtime-launch-client \
        2>/dev/null | sort -V | tail -n 1)"
    [ -n "$client" ] || die "Steam Linux Runtime introuvable (lance Battle.net une fois depuis Steam)."
    echo "$client"
}

STEAM="$(find_steam)"
if [ -n "${APPID_ARG:-}" ]; then
    COMPAT="$(readlink -f "$STEAM/steamapps/compatdata/$APPID_ARG")"
fi
[ -n "$COMPAT" ] || COMPAT="$(find_bnet_compat)"
[ -d "$COMPAT/pfx/drive_c" ] || die "Préfixe invalide : $COMPAT/pfx"
[ -n "$PROTON_DIR" ] || PROTON_DIR="$(find_proton)"
LAUNCH_CLIENT="$(find_launch_client)"

PREFIX="$COMPAT/pfx"
WIN="$PREFIX/drive_c/windows"
HDT_ROOT="$PREFIX/drive_c/users/steamuser/AppData/Local/HearthstoneDeckTracker"

log "Configuration détectée"
info "Steam        : $STEAM"
info "Préfixe      : $PREFIX"
info "Proton       : $PROTON_DIR"
info "Runtime      : $LAUNCH_CLIENT"
info "Scripts dans : $BIN_DIR"

# Wine de Proton, utilisé directement : « proton run » recréerait à chaque
# lancement des liens vers ses propres DLL, que l'installeur .NET ne peut pas écraser.
export WINEPREFIX="$PREFIX"
export WINEDEBUG="-all"
WINE="$PROTON_DIR/files/bin/wine"
WINESERVER="$PROTON_DIR/files/bin/wineserver"
[ -x "$WINE" ] || die "Wine introuvable dans $PROTON_DIR/files/bin"

# Le préfixe ne doit pas être utilisé pendant l'installation
prefix_in_use() {
    local p
    for p in $(pgrep -x wineserver || true); do
        tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null \
            | grep -q -x -E "WINEPREFIX=(/var)?${PREFIX#/var}/?" && return 0
    done
    return 1
}
if prefix_in_use; then
    die "Le préfixe est en cours d'utilisation : quitte Battle.net, Hearthstone et HDT, puis relance."
fi

wine_wait() { "$WINESERVER" -w; }

download() {  # download URL SHA256 -> affiche le chemin du fichier
    local url="$1" sha="$2" file
    file="$CACHE_DIR/$(basename "$url")"
    mkdir -p "$CACHE_DIR"
    if [ ! -f "$file" ] || [ "$(sha256sum "$file" | cut -d' ' -f1)" != "$sha" ]; then
        info "Téléchargement de $(basename "$url")..." >&2
        curl -fL --progress-bar -o "$file.part" "$url"
        [ "$(sha256sum "$file.part" | cut -d' ' -f1)" = "$sha" ] \
            || die "Empreinte incorrecte pour $(basename "$url")"
        mv "$file.part" "$file"
    fi
    echo "$file"
}

# ---------------------------------------------------------------- .NET 4.8

is_mono() { grep -q -a -E 'Mono Common Language Infrastructure|WINE_MONO_OVERRIDES' "$1" 2>/dev/null; }

reg_has() {  # reg_has FICHIER MOTIF
    grep -q -a -F "$2" "$PREFIX/$1"
}

dotnet_runtime_ok() {
    local f="$WIN/Microsoft.NET/Framework64/v4.0.30319"
    [ -f "$f/clr.dll" ] && [ -f "$f/mscorlib.dll" ] && ! is_mono "$f/mscorlib.dll" \
        && [ -f "$WIN/Microsoft.NET/Framework/v4.0.30319/clr.dll" ]
}

mscoree_ok() {
    local f
    for f in "$WIN/system32/mscoree.dll" "$WIN/syswow64/mscoree.dll"; do
        [ -f "$f" ] && [ ! -L "$f" ] && ! is_mono "$f" || return 1
    done
}

dotnet_config_ok() {
    reg_has user.reg '"mscoree"="native"' \
        && reg_has system.reg '"InstallRoot"="C:\\windows\\Microsoft.NET\\Framework64\\"' \
        && reg_has system.reg '"InstallRoot"="C:\\windows\\Microsoft.NET\\Framework\\"'
}

backup_prefix() {
    local dest
    [ "$DO_BACKUP" = 1 ] || return 0
    dest="$COMPAT/hdt-linux-backup-$(date +%Y%m%d-%H%M%S)"
    log "Sauvegarde du préfixe dans $dest"
    mkdir -p "$dest"
    cp -a "$PREFIX"/*.reg "$dest/"
    tar -C "$PREFIX/drive_c" -cf "$dest/windows.tar" windows
}

remove_wine_mono() {
    local desc uuid
    info "Retrait de wine-mono..."
    for desc in 'Wine Mono Windows Support' 'Wine Mono Runtime' 'Wine Mono'; do
        uuid="$("$WINE" uninstaller --list 2>/dev/null | grep -a "$desc" | cut -f1 -d'|' || true)"
        [ -n "$uuid" ] && "$WINE" uninstaller --remove "$uuid" >/dev/null 2>&1 || true
    done
    "$WINE" reg delete 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v3.5' /f >/dev/null 2>&1 || true
    "$WINE" reg delete 'HKLM\Software\Microsoft\NET Framework Setup\NDP\v4' /f >/dev/null 2>&1 || true
    wine_wait
}

# Liens symboliques vers les DLL de Proton : l'installeur ne peut pas écrire à travers
remove_proton_links() {
    local f
    find "$WIN/Microsoft.NET" -type l -lname '*/files/lib/wine/*' -delete 2>/dev/null || true
    for f in "$WIN/system32/mscoree.dll" "$WIN/syswow64/mscoree.dll"; do
        if [ -L "$f" ] || is_mono "$f"; then rm -f "$f"; fi
    done
}

install_dotnet48() {
    local ndp48 rc
    ndp48="$(download "$NDP48_URL" "$NDP48_SHA256")"
    remove_wine_mono
    remove_proton_links
    info "Installation de .NET Framework 4.8 (quelques minutes)..."
    "$WINE" winecfg -v win7 >/dev/null 2>&1
    wine_wait
    rc=0
    WINEDLLOVERRIDES="fusion=b" "$WINE" "$ndp48" /q /norestart >/dev/null 2>&1 || rc=$?
    wine_wait
    # 3010 = installé, redémarrage demandé (sans objet sous Wine)
    if [ "$rc" != 0 ] && [ "$rc" != 3010 ]; then
        die "L'installeur .NET 4.8 a échoué (code $rc). Journaux : $PREFIX/drive_c/users/steamuser/AppData/Local/Temp/"
    fi
    dotnet_runtime_ok || die ".NET 4.8 semble absent après l'installation."
}

# mscoree.dll (le lanceur de .NET) n'est pas fourni par l'installeur 4.8 :
# Windows l'a déjà. On le prend dans le paquet officiel .NET 4.0.
install_mscoree() {
    local ndp40 tmp
    ndp40="$(download "$NDP40_URL" "$NDP40_SHA256")"
    tmp="$(mktemp -d)"
    info "Installation de mscoree.dll..."
    7z e -y -o"$tmp" "$ndp40" netfx_Core.mzz >/dev/null
    7z e -y -o"$tmp" "$tmp/netfx_Core.mzz" _003_mscoree_dll_amd64 _003_mscoree_dll_x86 >/dev/null 2>&1 || true
    [ -f "$tmp/_003_mscoree_dll_amd64" ] && [ -f "$tmp/_003_mscoree_dll_x86" ] \
        || { rm -rf "$tmp"; die "Extraction de mscoree.dll impossible."; }
    rm -f "$WIN/system32/mscoree.dll" "$WIN/syswow64/mscoree.dll"
    cp "$tmp/_003_mscoree_dll_amd64" "$WIN/system32/mscoree.dll"
    cp "$tmp/_003_mscoree_dll_x86" "$WIN/syswow64/mscoree.dll"
    rm -rf "$tmp"
}

configure_dotnet() {
    info "Configuration de Wine pour .NET..."
    "$WINE" reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree /d native /f >/dev/null 2>&1
    "$WINE" reg add 'HKLM\Software\Microsoft\.NETFramework' /v InstallRoot \
        /d 'C:\windows\Microsoft.NET\Framework64\' /f /reg:64 >/dev/null 2>&1
    "$WINE" reg add 'HKLM\Software\Microsoft\.NETFramework' /v InstallRoot \
        /d 'C:\windows\Microsoft.NET\Framework\' /f /reg:32 >/dev/null 2>&1
    "$WINE" winecfg -v win10 >/dev/null 2>&1
    wine_wait
}

log "Étape 1/3 : .NET Framework 4.8"
if dotnet_runtime_ok && mscoree_ok && dotnet_config_ok; then
    info "Déjà installé."
else
    backup_prefix
    dotnet_runtime_ok || install_dotnet48
    mscoree_ok || install_mscoree
    configure_dotnet
    mscoree_ok && dotnet_config_ok || die "La configuration de .NET a échoué."
    info ".NET 4.8 installé."
fi

# ---------------------------------------------------------------- HDT

hdt_installed() { ls "$HDT_ROOT"/app-*/HearthstoneDeckTracker.exe >/dev/null 2>&1; }

install_hdt() {
    local url setup i
    url="$(curl -fsS --max-time 15 https://api.github.com/repos/HearthSim/HDT-Releases/releases/latest \
        | sed -n 's/.*"browser_download_url": *"\([^"]*HDT-Installer\.exe\)".*/\1/p' | head -n 1)"
    [ -n "$url" ] || die "Impossible de trouver l'installeur de HDT sur GitHub."
    mkdir -p "$CACHE_DIR"
    setup="$CACHE_DIR/HDT-Installer.exe"
    info "Téléchargement de l'installeur HDT..."
    curl -fL --progress-bar -o "$setup" "$url"

    info "Installation de HDT..."
    # L'installeur ouvre HDT à la fin : on attend l'installation puis on le referme
    "$WINE" "$setup" --silent >/dev/null 2>&1 &
    for i in $(seq 120); do hdt_installed && break; sleep 2; done
    hdt_installed || { "$WINESERVER" -k; die "L'installation de HDT a échoué."; }
    for i in $(seq 30); do
        pgrep -f '^[A-Za-z]:\\.*\\HearthstoneDeckTracker\.exe' >/dev/null && break
        sleep 2
    done
    sleep 10
    "$WINE" taskkill /im HearthstoneDeckTracker.exe >/dev/null 2>&1 || true
    timeout 30 "$WINESERVER" -w || { "$WINESERVER" -k 2>/dev/null || true; wine_wait; }
}

log "Étape 2/3 : Hearthstone Deck Tracker"
if hdt_installed; then
    info "Déjà installé ($(basename "$(ls -d "$HDT_ROOT"/app-* | sort -V | tail -n 1)")), mises à jour gérées par hdt-update.sh."
else
    install_hdt
    info "HDT installé."
fi

# ---------------------------------------------------------------- scripts

log "Étape 3/3 : scripts de lancement"
mkdir -p "$BIN_DIR"
# Remplacement par renommage : un script en cours d'exécution n'est pas perturbé
for f in hdt-common.sh hdt-update.sh launch-hdt.sh bnet-hdt-wrapper.sh; do
    install -m 755 "$SRC_DIR/bin/$f" "$BIN_DIR/.$f.new"
    mv -f "$BIN_DIR/.$f.new" "$BIN_DIR/$f"
done
cat > "$BIN_DIR/hdt-linux.conf" <<EOF
# Généré par hdt-linux/install.sh le $(date '+%Y-%m-%d %H:%M')
STEAM="$STEAM"
COMPAT="$COMPAT"
PROTON_DIR="$PROTON_DIR"
LAUNCH_CLIENT="$LAUNCH_CLIENT"
EOF
info "Scripts installés dans $BIN_DIR"

# Mises à jour périodiques de HDT désactivées (gérées par hdt-update.sh)
(source "$BIN_DIR/hdt-common.sh" && hdt_disable_periodic_updates) || true

log "Terminé"
cat <<EOF

Dernière étape, dans Steam : clic droit sur Battle.net > Propriétés > Général >
Options de lancement, remplace le contenu par :

    STEAM_COMPAT_LAUNCHER_SERVICE=proton $(readlink -f "$BIN_DIR")/bnet-hdt-wrapper.sh %command%

HDT s'ouvrira alors tout seul à chaque lancement de Hearthstone.
Pour lancer HDT à la main : $BIN_DIR/launch-hdt.sh
EOF
