#!/usr/bin/env bash
# install.sh -- Eloquence V6.1 para Raspberry Pi OS (arm64 / armhf) + speech-dispatcher
#
# Hace todo el proceso:
#   1. instala las dependencias (y habilita armhf en sistemas de 64 bits)
#   2. compila el puente, el shim libeci.so, el CLI y el módulo sd_eloquence
#   3. lo instala en el sistema
#   4. descarga y parchea las librerías de Eloquence (eloquence-setup)
#   5. deja speech-dispatcher listo y prueba que habla
#
# Uso:  ./install.sh [opciones]      (pedirá sudo cuando haga falta)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"
SPD_CONF=/etc/speech-dispatcher/speechd.conf

SET_DEFAULT=0
AUDIO_CONF=auto        # auto | no
SKIP_SETUP=0
UNINSTALL=0
DRY=0

usage() {
    cat <<'EOF'
Uso: ./install.sh [opciones]

  --set-default       Hace de Eloquence el módulo por defecto de speech-dispatcher
  --no-audio-config   No toca la salida de audio de speech-dispatcher
                      (por defecto, si no hay PulseAudio/PipeWire, se usa ALSA)
  --skip-setup        No ejecuta eloquence-setup (no descarga el firmware)
  --uninstall         Elimina todo lo instalado por este script
  --dry-run           Muestra lo que haría sin ejecutar nada
  -h, --help          Esta ayuda

Variables útiles:
  ECI_BRIDGE_MODE=qemu   Fuerza el modo con emulación en lugar del nativo
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --set-default)     SET_DEFAULT=1 ;;
        --no-audio-config) AUDIO_CONF=no ;;
        --skip-setup)      SKIP_SETUP=1 ;;
        --uninstall)       UNINSTALL=1 ;;
        --dry-run)         DRY=1 ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "Opción desconocida: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------- utilidades

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mAviso:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY" = 1 ]; then printf '+ %s\n' "$*"; else "$@"; fi
}

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "Hace falta ejecutarlo como root o tener sudo instalado."
    SUDO="sudo"
fi
priv() { run $SUDO "$@"; }

# Ejecuta un comando como el usuario que lanzó el script (no como root)
as_user() {
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
        runuser -u "$SUDO_USER" -- "$@"
    else
        "$@"
    fi
}

# Sustituye o añade "CLAVE valor" en un fichero de configuración (con copia de seguridad)
set_conf_opt() {
    local f="$1" k="$2" v="$3"
    [ -f "$f" ] || { warn "No existe $f; no se puede ajustar $k"; return 0; }
    [ -f "$f.eloquence.bak" ] || priv cp -a "$f" "$f.eloquence.bak"
    if grep -Eq "^[[:space:]]*$k[[:space:]]" "$f"; then
        priv sed -i -E "s|^[[:space:]]*$k[[:space:]].*|$k $v|" "$f"
    elif grep -Eq "^[[:space:]]*#[[:space:]]*$k[[:space:]]" "$f"; then
        priv sed -i -E "0,/^[[:space:]]*#[[:space:]]*$k[[:space:]].*/s||$k $v|" "$f"
    elif [ "$DRY" = 1 ]; then
        echo "+ echo '$k $v' >> $f"
    else
        echo "$k $v" | $SUDO tee -a "$f" >/dev/null
    fi
}

# ------------------------------------------------------------ comprobaciones

# ELOQ_FORCE_ARCH solo existe para poder probar el script fuera de una Pi
DEB_ARCH="${ELOQ_FORCE_ARCH:-$(dpkg --print-architecture 2>/dev/null || true)}"

command -v apt-get >/dev/null 2>&1 || die "Este instalador es para Raspberry Pi OS / Debian (no encuentro apt-get)."
case "$DEB_ARCH" in
    arm64|armhf) ;;
    *) die "Arquitectura '$DEB_ARCH' no soportada: este instalador es para Raspberry Pi OS arm64 o armhf." ;;
esac

# Directorios de speech-dispatcher según la distribución
SPDMODDIR=/usr/lib/speech-dispatcher-modules
for d in /usr/lib/speech-dispatcher-modules /usr/libexec/speech-dispatcher-modules; do
    if [ -d "$d" ]; then SPDMODDIR="$d"; break; fi
done

# ----------------------------------------------------------------- desinstalar

if [ "$UNINSTALL" = 1 ]; then
    say "Desinstalando Eloquence"
    if [ -x /usr/bin/eloquence-setup ]; then priv /usr/bin/eloquence-setup --uninstall || true; fi
    MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
    priv rm -f /usr/bin/eloquence /usr/bin/eloquence-setup \
        "/usr/lib/$MULTIARCH/libeci.so" \
        "$SPDMODDIR/sd_eloquence" \
        /etc/speech-dispatcher/modules/eloquence.conf \
        /usr/share/man/man1/eloquence.1
    priv rm -rf /usr/share/eloquence
    for f in "$SPD_CONF"; do
        if [ -f "$f.eloquence.bak" ]; then
            echo "Hay una copia de seguridad de $f hecha por este instalador: $f.eloquence.bak"
            echo "Restáurala a mano si quieres deshacer los cambios de configuración."
        fi
    done
    priv ldconfig || true
    as_user pkill -x speech-dispatch 2>/dev/null || true
    echo "Hecho."
    exit 0
fi

[ -f "$SRC/Makefile" ] || die "No encuentro el código fuente en $SRC (¿has descomprimido todo el zip?)."

# ---------------------------------------------------------------- 1. paquetes

say "1/5 Instalando dependencias ($DEB_ARCH)"

PKGS=(build-essential pkg-config libspeechd-dev libglib2.0-dev speech-dispatcher
      curl unzip ca-certificates python3 python3-venv python3-dev liblzo2-dev
      kmod alsa-utils)

if [ "$DEB_ARCH" = arm64 ]; then
    # El puente es un programa ARM de 32 bits: hace falta armhf
    if ! dpkg --print-foreign-architectures | grep -qx armhf; then
        echo "Habilitando la arquitectura armhf..."
        priv dpkg --add-architecture armhf
    fi
    priv env DEBIAN_FRONTEND=noninteractive apt-get update
    # libc6-dev-armhf-cross lleva las cabeceras de C del compilador cruzado; en Debian
    # solo es "Recommends" de gcc-arm-linux-gnueabihf, y aquí no se instalan recomendados
    PKGS+=(gcc-arm-linux-gnueabihf libc6-dev-armhf-cross libc6:armhf libstdc++6:armhf)
else
    priv env DEBIAN_FRONTEND=noninteractive apt-get update
fi

priv env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PKGS[@]}"

# ----------------------------------------------------------------- 2. compilar

say "2/5 Compilando"

# Comprobación previa: el compilador del puente (32 bits ARM) debe poder compilar
# un programa que use las mismas cabeceras que el puente.
preflight_cc() {
    local cc="$1" t
    t="$(mktemp -d /tmp/eloquence-cc.XXXXXX)"
    printf '#include <stdio.h>\n#include <stdint.h>\n#include <dlfcn.h>\n#include <pthread.h>\n#include <sys/socket.h>\nint main(void){return 0;}\n' > "$t/t.c"
    if ! "$cc" -o "$t/t" "$t/t.c" -ldl -lpthread 2> "$t/err"; then
        cat "$t/err" >&2
        rm -rf "$t"
        die "El compilador '$cc' no puede compilar programas C (faltan cabeceras o librerías de desarrollo). Revisa la salida de arriba."
    fi
    rm -rf "$t"
}
if [ "$DRY" != 1 ]; then
    if [ "$DEB_ARCH" = arm64 ]; then preflight_cc arm-linux-gnueabihf-gcc; else preflight_cc gcc; fi
fi

BUILD_DIR="$(mktemp -d /tmp/eloquence-build.XXXXXX)"
cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

if [ "$DRY" = 1 ]; then
    echo "+ cp -a $SRC/. $BUILD_DIR/"
    echo "+ make -C $BUILD_DIR -j$(nproc 2>/dev/null || echo 2) all sd_eloquence"
else
    cp -a "$SRC"/. "$BUILD_DIR"/
    make -C "$BUILD_DIR" clean >/dev/null 2>&1 || true
    if ! make -C "$BUILD_DIR" -j"$(nproc)" all sd_eloquence; then
        warn "La compilación en paralelo falló; repito en serie para ver el primer error..."
        make -C "$BUILD_DIR" all sd_eloquence
    fi
    for f in build/eci-bridge build/libeci.so build/eloquence build/sd_eloquence; do
        [ -f "$BUILD_DIR/$f" ] || die "La compilación no produjo $f"
    done
fi

# ---------------------------------------------------------------- 3. instalar

say "3/5 Instalando"

# No pisar la configuración del módulo si ya existe (conserva tus ajustes)
KEEP_CONF=""
if [ "$DRY" != 1 ] && [ -f /etc/speech-dispatcher/modules/eloquence.conf ]; then
    KEEP_CONF="$(mktemp)"
    cp /etc/speech-dispatcher/modules/eloquence.conf "$KEEP_CONF"
fi

priv make -C "$BUILD_DIR" install SPDMODDIR="$SPDMODDIR"
priv ldconfig

if [ -n "$KEEP_CONF" ]; then
    $SUDO cp "$KEEP_CONF" /etc/speech-dispatcher/modules/eloquence.conf
    rm -f "$KEEP_CONF"
    echo "Se ha conservado tu /etc/speech-dispatcher/modules/eloquence.conf existente."
fi

# ------------------------------------------------------------------ 4. firmware

if [ "$SKIP_SETUP" = 1 ]; then
    say "4/5 eloquence-setup omitido (--skip-setup)"
    echo "Ejecútalo después con:  sudo eloquence-setup"
else
    say "4/5 Descargando y parcheando las librerías de Eloquence (eloquence-setup)"
    priv /usr/bin/eloquence-setup
fi

# ------------------------------------------------------- 5. speech-dispatcher

say "5/5 Configurando speech-dispatcher"

if [ -f "$SPD_CONF" ]; then
    if [ "$SET_DEFAULT" = 1 ]; then
        set_conf_opt "$SPD_CONF" DefaultModule eloquence
        echo "Eloquence es ahora el módulo por defecto."
    fi
    if [ "$AUDIO_CONF" = auto ]; then
        if command -v pipewire-pulse >/dev/null 2>&1 || command -v pulseaudio >/dev/null 2>&1; then
            echo "Se ha detectado un servidor de sonido (PulseAudio/PipeWire): no se toca la salida de audio."
        else
            echo "No hay PulseAudio ni PipeWire: speech-dispatcher usará ALSA directamente."
            set_conf_opt "$SPD_CONF" AudioOutputMethod '"alsa"'
        fi
    fi
else
    warn "No existe $SPD_CONF; se omite la configuración de speech-dispatcher."
fi

# Reiniciar speech-dispatcher del usuario para que detecte el nuevo módulo
as_user pkill -x speech-dispatch 2>/dev/null || true

# ------------------------------------------------------------------ pruebas

if [ "$DRY" = 1 ]; then
    say "Simulación terminada (--dry-run): no se ha ejecutado nada"
    exit 0
fi

say "Comprobando"
OK=1
if [ "$SKIP_SETUP" = 1 ]; then
    echo "Pruebas omitidas: falta ejecutar eloquence-setup."
    OK=2
else
    TESTWAV="$(mktemp /tmp/eloquence-test.XXXXXX.wav)"
    chmod 666 "$TESTWAV"
    if as_user eloquence -t "Eloquence is installed." -o "$TESTWAV" \
        && [ "$(stat -c %s "$TESTWAV")" -gt 2000 ]; then
        echo "Síntesis directa: OK ($(stat -c %s "$TESTWAV") bytes de audio)"
    else
        OK=0
        warn "La síntesis directa falló. Mira el registro del puente:"
        warn "  /usr/share/eloquence/eci-bridge.log  o  \${XDG_RUNTIME_DIR:-/tmp}/eci-bridge.log"
    fi
    rm -f "$TESTWAV"
    # El puente de la prueba queda en segundo plano: se cierra para no dejarlo huérfano
    as_user pkill -x eci-bridge 2>/dev/null || true

    if command -v spd-say >/dev/null 2>&1; then
        if as_user spd-say -O 2>/dev/null | grep -qw eloquence; then
            echo "speech-dispatcher ve el módulo 'eloquence': OK"
        else
            OK=0
            warn "speech-dispatcher no lista el módulo 'eloquence' (prueba: spd-say -O)."
        fi
    fi
fi

cat <<EOF

----------------------------------------------------------------------
$( [ "$OK" = 1 ] && echo "Instalación completada." || { [ "$OK" = 2 ] && echo "Instalación completada (falta eloquence-setup)." || echo "Instalación terminada con avisos (ver arriba)."; } )

Probar con voz:
    spd-say -o eloquence "Hola, esto es Eloquence"
Probar solo la síntesis:
    eloquence -t "Hello world" -o /tmp/t.wav && aplay /tmp/t.wav
Configuración del módulo (voz, velocidad, tono):
    /etc/speech-dispatcher/modules/eloquence.conf
Hacerlo el módulo por defecto:
    ./install.sh --set-default    (o: DefaultModule eloquence en $SPD_CONF)
Desinstalar:
    ./install.sh --uninstall
----------------------------------------------------------------------
EOF
