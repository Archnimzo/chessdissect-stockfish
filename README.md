# chessdissect-stockfish

Binarios de [Stockfish](https://github.com/official-stockfish/Stockfish) para Android arm64 que usa la app ChessDissect, junto con el código fuente y el script exactos para reproducirlos.

## Qué se compila

- Stockfish en la etiqueta `sf_19` (commit `edb0d9db6731067ec50ce619ff372b463bc4dd5d`)
- Android NDK r28c, `COMP=ndk` (API 29, es decir, Android 10 o superior)
- Dos variantes:
  - `libstockfish_armv8.so` (`ARCH=armv8`)
  - `libstockfish_armv8_dotprod.so` (`ARCH=armv8-dotprod`, para CPU con `asimddp`)
- Sin red NNUE embebida (`-DNNUE_EMBEDDING_OFF`): la red se publica aparte en la misma Release y la app la descarga una vez
- Segmentos ELF alineados a 16 KB (`-Wl,-z,max-page-size=16384`); la compilación falla si no lo están
- Objetivo `build` de make, no `profile-build`: al compilar en cruz no se puede ejecutar el binario para PGO

Aunque se llaman `lib*.so` para poder empaquetarlos en `jniLibs`, son ejecutables: la app los lanza como proceso aparte y se comunica con ellos por UCI.

## Releases

Cada Release contiene:

| Archivo | Contenido |
|---|---|
| `libstockfish_armv8.so`, `libstockfish_armv8_dotprod.so` | Binarios |
| `nn-*.nnue` | Red NNUE por defecto de esa versión de Stockfish |
| `stockfish-sf_19-src.tar.gz` | Código fuente exacto que se compiló |
| `build.sh`, `build.yml` | Script y workflow de compilación |
| `BUILDINFO.txt` | Versiones del NDK y del compilador, y opciones usadas |
| `SHA256SUMS` | Sumas SHA256 de todo lo anterior |

## Cómo se genera

El workflow `.github/workflows/build.yml` se lanza a mano (Actions → *Compilar Stockfish para Android* → *Run workflow*) con una etiqueta de Release, por ejemplo `sf19-r1`.

Para reproducirlo en local, en Linux x86_64 o WSL:

```sh
curl -fLO https://dl.google.com/android/repository/android-ndk-r28c-linux.zip
unzip -q android-ndk-r28c-linux.zip
ANDROID_NDK_HOME="$PWD/android-ndk-r28c" ./build.sh
```

El resultado queda en `dist/`.

## Licencia

Stockfish se distribuye bajo la GNU General Public License v3.0; ver [COPYING](COPYING). Los scripts de este repositorio se publican bajo la misma licencia.
