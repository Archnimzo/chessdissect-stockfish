#!/usr/bin/env bash
# Reúne el código fuente correspondiente de Stockfish.js (el motor WebAssembly
# que ChessDissect distribuye sin modificar) para publicarlo en una Release de
# este repositorio, de modo que no dependa solo del repositorio original.
#
# Uso:
#   ./mirror-stockfish-js.sh
#
# Variables opcionales:
#   SFJS_VERSION   versión de Stockfish.js (etiqueta v<versión> y paquete npm)
#   SFJS_COMMIT    commit que debe tener esa etiqueta
#   SFJS_NET       red NNUE embebida en los .wasm lite
#   OUT_DIR        carpeta de salida (por defecto ./dist-sfjs)
#   WORK_DIR       carpeta de trabajo (por defecto ./work-sfjs)
#
# Requiere bash, git, curl, tar, gzip y sha256sum.

set -euo pipefail

SFJS_VERSION="${SFJS_VERSION:-18.0.8}"
SFJS_COMMIT="${SFJS_COMMIT:-93c994592dcf3b4b21052ab925e9b534df9c0918}"
SFJS_REPO="${SFJS_REPO:-https://github.com/nmrugg/stockfish.js.git}"
SFJS_NET="${SFJS_NET:-nn-9067e33176e8}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist-sfjs}"
WORK_DIR="${WORK_DIR:-$ROOT/work-sfjs}"
MAJOR="${SFJS_VERSION%%.*}"

rm -rf "$OUT_DIR" "$WORK_DIR"
mkdir -p "$OUT_DIR" "$WORK_DIR"

echo "== Código fuente: $SFJS_REPO v$SFJS_VERSION"
git clone --quiet --depth 1 --branch "v$SFJS_VERSION" "$SFJS_REPO" "$WORK_DIR/stockfish.js"
commit="$(git -C "$WORK_DIR/stockfish.js" rev-parse HEAD)"
if [[ "$commit" != "$SFJS_COMMIT" ]]; then
  echo "La etiqueta v$SFJS_VERSION apunta a $commit, no a $SFJS_COMMIT" >&2
  exit 1
fi
if [[ -f "$WORK_DIR/stockfish.js/.gitmodules" ]]; then
  echo "El repositorio usa submódulos: git archive no los incluiría" >&2
  exit 1
fi
src_tar="stockfish.js-$SFJS_VERSION-src.tar.gz"
git -C "$WORK_DIR/stockfish.js" archive --format=tar --prefix="stockfish.js-$SFJS_VERSION/" HEAD \
  | gzip -9n > "$OUT_DIR/$src_tar"

echo "== Paquete npm stockfish@$SFJS_VERSION (los archivos que se distribuyen)"
npm_tgz="stockfish-$SFJS_VERSION.tgz"
curl -fsSL --retry 3 -o "$OUT_DIR/$npm_tgz" "https://registry.npmjs.org/stockfish/-/$npm_tgz"
expected_sha1="$(curl -fsSL --retry 3 "https://registry.npmjs.org/stockfish/$SFJS_VERSION" \
  | grep -o '"shasum" *: *"[0-9a-f]*"' | head -1 | grep -o '[0-9a-f]\{40\}')"
actual_sha1="$(sha1sum < "$OUT_DIR/$npm_tgz" | cut -d" " -f1)"
if [[ -z "$expected_sha1" || "$expected_sha1" != "$actual_sha1" ]]; then
  echo "El SHA1 del paquete npm ($actual_sha1) no coincide con el del registro ($expected_sha1)" >&2
  exit 1
fi

echo "== Red NNUE $SFJS_NET"
curl -fsSL --retry 3 -o "$OUT_DIR/$SFJS_NET.nnue" \
  "https://tests.stockfishchess.org/api/nn/$SFJS_NET.nnue"
# El nombre de una red de Stockfish son los 12 primeros caracteres de su SHA256.
net_sha="$(sha256sum < "$OUT_DIR/$SFJS_NET.nnue" | cut -d' ' -f1)"
if [[ "nn-${net_sha:0:12}" != "$SFJS_NET" ]]; then
  echo "La red descargada (SHA256 $net_sha) no es $SFJS_NET" >&2
  exit 1
fi

cp "$ROOT/mirror-stockfish-js.sh" "$OUT_DIR/"
cp "$ROOT/.github/workflows/mirror-stockfish-js.yml" "$OUT_DIR/"

emscripten="$(grep -o 'expectedEmscripten = "[^"]*"' "$WORK_DIR/stockfish.js/build.js" | cut -d'"' -f2)"
cat > "$OUT_DIR/SOURCE.txt" <<EOF
Stockfish.js $SFJS_VERSION
Repositorio:  $SFJS_REPO
Etiqueta:     v$SFJS_VERSION
Commit:       $SFJS_COMMIT
Emscripten:   $emscripten (el que exige build.js)
Red NNUE:     $SFJS_NET.nnue (CC0, embebida en los .wasm lite)

Archivos que distribuye ChessDissect, sin modificar, sacados de $npm_tgz:
  package/bin/stockfish-$MAJOR-lite.js           -> engine/mt/stockfish.js
  package/bin/stockfish-$MAJOR-lite.wasm         -> engine/mt/stockfish.wasm
  package/bin/stockfish-$MAJOR-lite-single.js    -> engine/st/stockfish.js
  package/bin/stockfish-$MAJOR-lite-single.wasm  -> engine/st/stockfish.wasm

Para compilarlos: descomprimir $src_tar, instalar Emscripten $emscripten
(emsdk install $emscripten && emsdk activate $emscripten) y seguir el
README de Stockfish.js (./build.js --help).
EOF

(cd "$OUT_DIR" && sha256sum -- * > SHA256SUMS)
echo "== Listo en $OUT_DIR"
cat "$OUT_DIR/SHA256SUMS"
