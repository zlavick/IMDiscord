#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# IMDiscord - MinGW-w64 cross build that runs on Linux.
#
# Same no-CRT story as build.bat: everything is compiled with -nostdlib-ish
# link flags (no mingw CRT startup), the only runtime is customcrt + Win32.
#
#   ./build.sh            release build
#   ./build.sh debug      debug build (-O0, IMD_DEBUG)
#   ./build.sh clean      wipe obj/bin
# ---------------------------------------------------------------------------
set -u
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/src"
OBJ="$ROOT/obj-linux"
BIN="$ROOT/bin/linux"

CROSS=${CROSS:-x86_64-w64-mingw32}
CC=${CC:-$CROSS-gcc}
CXX=${CXX:-$CROSS-g++}
WINDRES=${WINDRES:-$CROSS-windres}

if [ "${1:-}" = "clean" ]; then
    rm -rf "$OBJ" "$BIN"
    echo "[build] cleaned"
    exit 0
fi

CONFIG=release
[ "${1:-}" = "debug" ] && CONFIG=debug

for t in "$CC" "$CXX" "$WINDRES"; do
    command -v "$t" >/dev/null || { echo "[build] $t not found - install mingw-w64"; exit 1; }
done

mkdir -p "$OBJ" "$BIN"

# ---- apply compatibility patches -----------------------------------------
# Any source changes needed to build under MinGW-w64 live in patches/*.patch
# so the MSVC path in build.bat stays untouched.
shopt -s nullglob
for p in "$ROOT"/patches/*.patch; do
    if (cd "$ROOT" && git apply --check "$p") >/dev/null 2>&1; then
        (cd "$ROOT" && git apply "$p") && echo "[build] applied $(basename "$p")"
    elif patch -p1 -N -r - --dry-run -d "$ROOT" <"$p" >/dev/null 2>&1; then
        patch -p1 -N -r - -d "$ROOT" <"$p" >/dev/null && echo "[build] applied $(basename "$p")"
    else
        echo "[build] $(basename "$p"): already applied or does not apply cleanly, skipping"
    fi
done
shopt -u nullglob

INCLUDES="-I$SRC -I$SRC/system/pch -I$SRC/system/alghoritms -I$SRC/system/io -I$SRC/system/manipulators -I$SRC/libs -I$SRC/libs/customcrt -I$SRC/libs/imgui -I$SRC/libs/stb -I$SRC/libs/opus/include -I$SRC/libs/libwebp -I$SRC/libs/speexdsp -I$SRC/libs/tlse -I$SRC/libs/miniz -I$SRC/libs/zstd -I$BIN"

COMMON_C="-std=c11 -fno-strict-aliasing -fno-builtin-memcpy -fno-builtin-memmove -fno-builtin-memset -fno-builtin-memcmp -fno-builtin-bzero"
COMMON="-fno-strict-aliasing -fno-builtin-memcpy -fno-builtin-memmove -fno-builtin-memset -fno-builtin-memcmp -fno-builtin-bzero -fno-exceptions -fno-rtti -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-stack-protector -fno-threadsafe-statics -std=c++17 -DUNICODE -D_UNICODE -DWIN32_LEAN_AND_MEAN -DNOMINMAX -D_CRT_SECURE_NO_WARNINGS -DIMD_WINDOWS=1 -Wall -Wno-unused-variable -Wno-unused-but-set-variable -Wno-parentheses -Wno-sign-compare -Wno-format -Wno-multichar -Wno-attributes -Wno-unknown-pragmas"

CXXFLAGS="$COMMON"
CFLAGS_C="$COMMON_C"

if [ "$CONFIG" = "debug" ]; then
    CXXFLAGS="$CXXFLAGS -g -O0 -DIMD_DEBUG=1"
    CFLAGS_C="$CFLAGS_C -g -O0 -DIMD_DEBUG=1"
    OPT="-g -O0 -DIMD_DEBUG=1"
else
    CXXFLAGS="$CXXFLAGS -O2 -DNDEBUG"
    CFLAGS_C="$CFLAGS_C -O2 -DNDEBUG"
    OPT="-O2 -DNDEBUG"
fi

objects=()

compile() { # compile <out.obj> <compiler> <flags...> -- <source>
    local out="$1" comp="$2"; shift 2
    local flags="" srcs=() a
    for a in "$@"; do
        if [ "$a" = "--" ]; then continue; fi
        case "$a" in *.c|*.cpp|*.cc) srcs+=("$a");; *) flags="$flags $a";; esac
    done
    echo "[build] $(basename "${srcs[0]}")"
    # shellcheck disable=SC2086
    $comp $flags -c -o "$out" "${srcs[@]}" || exit 1
    objects+=("$out")
}

# ---- "precompiled header" --------------------------------------------------
# GCC's textual PCH (.gch) is tied to the exact command line that produced it,
# which makes it a liability here; -include pch.h gives the same single-source
# truth without the fragility.
PCHINC="-include $SRC/system/pch/pch.h"

# ---- tlse (C, amalgamated, no PCH) ------------------------------------------
compile "$OBJ/tlse.o" "$CC" $OPT -DNO_CRT_STDIO_INLINE -DTLS_AMALGAMATION -DTLS_FORWARD_SECRECY -DTLS_SRTP -DARGTYPE=4 -DLTC_NO_ASM -D_CRT_SECURE_NO_WARNINGS -I"$SRC/libs/tlse" -w -- "$SRC/libs/tlse/tlse.c"

# ---- miniz ------------------------------------------------------------------
for f in miniz miniz_tdef miniz_tinfl miniz_zip; do
    compile "$OBJ/$f.o" "$CC" $OPT -DNO_CRT_STDIO_INLINE -I"$SRC/libs/miniz" -include "$SRC/libs/miniz/miniz_cfg.h" -w -- "$SRC/libs/miniz/$f.c"
done

# ---- zstd -------------------------------------------------------------------
compile "$OBJ/zstd.o" "$CC" $OPT -DNDEBUG -DNO_CRT_STDIO_INLINE -I"$SRC/libs/zstd" -w -- "$SRC/libs/zstd/zstd.c"

# ---- no-intrinsics math aliases ----------------------------------------------
compile "$OBJ/customcrt_mathalias.o" "$CXX" $OPT -I"$SRC/libs/customcrt" -- "$SRC/libs/customcrt/customcrt_mathalias.cpp"

# ---- translation units --------------------------------------------------------
i=0
while IFS= read -r f; do
    b=$(basename "$f")
    case "$b" in
        pch.cpp|imgui_demo.cpp|customcrt_mathalias.cpp|buffer.cpp|jitter.cpp|scal.cpp|smallft.cpp) continue;;
    esac
    case "$f" in
        */libwebp/enc/*|*/libwebp/mux/*|*/libwebp/sharpyuv/*) continue;;
    esac
    extra=""
    case "$f" in */speexdsp/*) extra="-DHAVE_CONFIG_H";; esac
    i=$((i+1))
    compile "$OBJ/u${i}_$b.o" "$CXX" $CXXFLAGS $extra $INCLUDES $PCHINC -- "$f"
done < <(find "$SRC" -name '*.cpp' | sort)

# ---- opus ---------------------------------------------------------------------
OPUSSRC="$SRC/libs/opus/source"
OPUSINC="-I$OPUSSRC -I$OPUSSRC/include -I$OPUSSRC/celt -I$OPUSSRC/silk -I$OPUSSRC/silk/fixed -I$SRC/libs/opus"
while IFS= read -r f; do
    b=$(basename "$f")
    case "$f" in */x86/*|*/arm/*|*/mips/*|*/tests/*|*/float/*) continue;; esac
    case "$b" in opus_demo.c|opus_compare.c|repacketizer_demo.c|opus_custom_demo.c|opus_custom.c|debug.c) continue;; esac
    i=$((i+1))
    compile "$OBJ/u${i}_$b.o" "$CC" $OPT -DNO_CRT_STDIO_INLINE -include "$SRC/libs/opus/opus_build_config.h" $OPUSINC -w -- "$f"
done < <(find "$OPUSSRC" -name '*.c' | sort)

# ---- app icon -----------------------------------------------------------------
echo "[build] app.rc"
$WINDRES --define UNICODE -i "$ROOT/app.rc" -o "$OBJ/app.res" || exit 1

# ---- link ---------------------------------------------------------------------
echo "[build] linking"
LIBS="-lkernel32 -luser32 -lgdi32 -lshell32 -lole32 -loleaut32 -ladvapi32 -lcomdlg32 -lws2_32 -ldwmapi -limm32 -lcrypt32 -lavrt -lwinmm -lmfplat -lmfuuid -lmmdevapi -liphlpapi -lntdll"

LDFLAGS="-static -nostartfiles -Wl,--entry,im_entry -Wl,-subsystem,windows -Wl,--stack,0x200000 -Wl,--dynamicbase -Wl,--nxcompat"
if [ "$CONFIG" = "debug" ]; then LDFLAGS="$LDFLAGS -g"; fi

# The tree ships rnnoise only as an MSVC .lib, which ld cannot read. The
# matching sources are compiled in via patches/0002 when building for MinGW.
if [ -f "$SRC/libs/rnnoise/src/rnnoise_data.c" ]; then
    i=$((i+1))
    compile "$OBJ/u${i}_rnnoise_data.o" "$CC" $OPT -I"$SRC/libs/rnnoise/include" -I"$SRC/libs/rnnoise/src" -w -- "$SRC/libs/rnnoise/src/rnnoise_data.c"
    i=$((i+1))
    compile "$OBJ/u${i}_rnnoise.o" "$CC" $OPT -I"$SRC/libs/rnnoise/include" -I"$SRC/libs/rnnoise/src" -w -- "$SRC/libs/rnnoise/src/rnnoise.c"
fi

# shellcheck disable=SC2086
$CXX $LDFLAGS -o "$BIN/IMDiscord.exe" "${objects[@]}" "$OBJ/app.res" $LIBS || exit 1

echo
echo "[build] ok -> $BIN/IMDiscord.exe"
