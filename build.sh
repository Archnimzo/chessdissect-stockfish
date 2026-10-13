#!/usr/bin/env bash
# Compila Stockfish para Android arm64 (armv8 y armv8-dotprod) sin red NNUE
# embebida y con segmentos ELF alineados a 16 KB.
#
# Uso:
#   ANDROID_NDK_HOME=/ruta/al/android-ndk-r28c ./build.sh
#
# Variables opcionales:
#   SF_TAG, SF_COMMIT       etiqueta y commit esperados de Stockfish
#   EXPECTED_NDK_REVISION   Pkg.Revision exigido al NDK (vacío = no comprobar)
#   NDK_ARCHIVE_URL, NDK_ARCHIVE_SHA256
#                           origen y suma del zip del NDK, solo para BUILDINFO.txt
#   OUT_DIR                 carpeta de salida (por defecto ./dist)
#   WORK_DIR                carpeta de trabajo (por defecto ./work)
#   JOBS                    trabajos paralelos de make (por defecto nproc)
#
# Requiere un host Linux x86_64 (o WSL) con bash, git, make, gzip y sha256sum.

set -euo pipefail

SF_TAG="${SF_TAG:-sf_19}"
SF_COMMIT="${SF_COMMIT:-edb0d9db6731067ec50ce619ff372b463bc4dd5d}"
SF_REPO="${SF_REPO:-https://github.com/official-stockfish/Stockfish.git}"
EXPECTED_NDK_REVISION="${EXPECTED_NDK_REVISION:-}"
PAGE_SIZE=16384

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/dist}"
WORK_DIR="${WORK_DIR:-$ROOT/work}"
JOBS="${JOBS:-$(nproc)}"

EXTRACXXFLAGS="-DNNUE_EMBEDDING_OFF"
EXTRALDFLAGS="-Wl,-z,max-page-size=$PAGE_SIZE"

# ARCH de Stockfish -> nombre del binario (debe ser lib*.so para empaquetarlo en jniLibs)
ARCHES=(armv8 armv8-dotprod)
declare -A LIB_NAME=(
  [armv8]=libstockfish_armv8.so
  [armv8-dotprod]=libstockfish_armv8_dotprod.so
)

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }

# --- NDK -------------------------------------------------------------------
[[ -n "${ANDROID_NDK_HOME:-}" ]] || die "define ANDROID_NDK_HOME"
[[ -f "$ANDROID_NDK_HOME/source.properties" ]] || die "no parece un NDK: $ANDROID_NDK_HOME"
NDK_REVISION="$(sed -n 's/^Pkg\.Revision *= *//p' "$ANDROID_NDK_HOME/source.properties" | tr -d '\r')"
log "NDK $NDK_REVISION en $ANDROID_NDK_HOME"
if [[ -n "$EXPECTED_NDK_REVISION" && "$NDK_REVISION" != "$EXPECTED_NDK_REVISION" ]]; then
  die "se esperaba el NDK $EXPECTED_NDK_REVISION y se encontró $NDK_REVISION"
fi
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
[[ -d "$NDK_BIN" ]] || die "no existe $NDK_BIN (¿host distinto de linux-x86_64?)"
export PATH="$NDK_BIN:$PATH"
READELF="$NDK_BIN/llvm-readelf"
STRIP="$NDK_BIN/llvm-strip"

# --- Código fuente -----------------------------------------------------------
SRC="$WORK_DIR/Stockfish"
rm -rf "$SRC"
mkdir -p "$WORK_DIR"
log "Clonando $SF_TAG"
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$SF_TAG" "$SF_REPO" "$SRC"
HEAD_COMMIT="$(git -C "$SRC" rev-parse 'HEAD^{commit}')"
[[ "$HEAD_COMMIT" == "$SF_COMMIT" ]] || die "$SF_TAG apunta a $HEAD_COMMIT, se esperaba $SF_COMMIT"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Tarball del código fuente exacto que se compila (obligación de la GPL-3.0).
# git archive usa la fecha del commit y gzip -n omite la marca de tiempo: sale reproducible.
SRC_TARBALL="stockfish-$SF_TAG-src.tar.gz"
git -C "$SRC" archive --format=tar --prefix="Stockfish-$SF_TAG/" HEAD | gzip -n -9 > "$OUT_DIR/$SRC_TARBALL"

# --- Comprobaciones del binario ------------------------------------------------
check_elf() {
  local file="$1" machine aligns a dec
  machine="$("$READELF" -h "$file" | sed -n 's/^ *Machine: *//p')"
  [[ "$machine" == "AArch64" ]] || die "$file: máquina '$machine', se esperaba AArch64"

  aligns="$("$READELF" -lW "$file" | awk '$1 == "LOAD" { print $NF }')"
  [[ -n "$aligns" ]] || die "$file: sin segmentos LOAD"
  for a in $aligns; do
    dec=$((a))
    if (( dec < PAGE_SIZE || dec % PAGE_SIZE != 0 )); then
      die "$file: segmento LOAD con alineación $a; se exige múltiplo de $PAGE_SIZE (16 KB)"
    fi
  done
  log "$(basename "$file"): AArch64, LOAD alineados a $(echo $aligns | tr ' ' ',')"
}

# --- Compilación ---------------------------------------------------------------
for arch in "${ARCHES[@]}"; do
  log "Compilando ARCH=$arch"
  make -C "$SRC/src" objclean
  # 'build' (no 'profile-build'): al compilar en cruz no se puede ejecutar el binario para PGO.
  # El objetivo 'build' depende de 'net', que descarga y verifica la red por defecto.
  make -C "$SRC/src" -j"$JOBS" build \
    ARCH="$arch" COMP=ndk \
    EXTRACXXFLAGS="$EXTRACXXFLAGS" \
    EXTRALDFLAGS="$EXTRALDFLAGS"
  out="$OUT_DIR/${LIB_NAME[$arch]}"
  "$STRIP" -o "$out" "$SRC/src/stockfish"
  check_elf "$out"
done

# --- Redes NNUE (no van embebidas; la app las descarga una vez) ------------------
mapfile -t NETS < <(grep -oE 'nn-[0-9a-f]{12}\.nnue' "$SRC/src/evaluate.h" | sort -u)
(( ${#NETS[@]} > 0 )) || die "no se encontró el nombre de la red en evaluate.h"
for net in "${NETS[@]}"; do
  [[ -f "$SRC/src/$net" ]] || die "falta la red $net (¿falló net.sh?)"
  # El nombre lleva los 12 primeros dígitos de su SHA256: se comprueba.
  expected="${net#nn-}"; expected="${expected%.nnue}"
  actual="$(sha256sum "$SRC/src/$net" | cut -c1-12)"
  [[ "$actual" == "$expected" ]] || die "$net: SHA256 empieza por $actual"
  cp "$SRC/src/$net" "$OUT_DIR/"
done

# --- Script y workflow, para que la Release sea autosuficiente --------------------
cp "$ROOT/build.sh" "$OUT_DIR/"
if [[ -f "$ROOT/.github/workflows/build.yml" ]]; then
  cp "$ROOT/.github/workflows/build.yml" "$OUT_DIR/"
fi

# --- Información de compilación y sumas ----------------------------------------
{
  echo "stockfish_tag=$SF_TAG"
  echo "stockfish_commit=$SF_COMMIT"
  echo "ndk_revision=$NDK_REVISION"
  if [[ -n "${NDK_ARCHIVE_URL:-}" ]]; then echo "ndk_archive=$NDK_ARCHIVE_URL"; fi
  if [[ -n "${NDK_ARCHIVE_SHA256:-}" ]]; then echo "ndk_archive_sha256=$NDK_ARCHIVE_SHA256"; fi
  echo "android_api=29 (aarch64-linux-android29-clang++)"
  echo "arches=${ARCHES[*]}"
  echo "make_target=build"
  echo "extracxxflags=$EXTRACXXFLAGS"
  echo "extraldflags=$EXTRALDFLAGS"
  echo "nets=${NETS[*]}"
  echo "clang=$("$NDK_BIN/clang++" --version | head -1)"
} > "$OUT_DIR/BUILDINFO.txt"

(cd "$OUT_DIR" && sha256sum -- * | grep -v ' SHA256SUMS$' > SHA256SUMS)

log "Listo. Contenido de $OUT_DIR:"
ls -l "$OUT_DIR"
cat "$OUT_DIR/SHA256SUMS"
