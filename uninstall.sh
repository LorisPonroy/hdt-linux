#!/usr/bin/env bash
# Retire les scripts installés par install.sh.
# HDT et .NET restent dans le préfixe de Battle.net (voir le README pour revenir
# en arrière avec la sauvegarde faite par install.sh).
set -euo pipefail

BIN_DIR="${1:-$HOME/.local/bin}"

for f in hdt-common.sh hdt-update.sh launch-hdt.sh bnet-hdt-wrapper.sh hdt-linux.conf; do
    rm -fv "$BIN_DIR/$f"
done

cat <<EOF

Pense à retirer l'option de lancement de Battle.net dans Steam
(Propriétés > Général > Options de lancement) : remets simplement %command%
EOF
