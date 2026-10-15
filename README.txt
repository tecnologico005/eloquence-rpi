Eloquence V6.1 para Raspberry Pi OS + speech-dispatcher
=======================================================

Contenido
  install.sh   instalador completo (dependencias, compilación, instalación,
               descarga de las librerías de Eloquence, configuración)
  src/         código fuente (Mudb0y/eloquence con el port para Raspberry Pi OS
               y la librería de módulos de speech-dispatcher incluida)

Uso
  unzip eloquence-rpi.zip
  cd eloquence-rpi
  ./install.sh              (si no es ejecutable:  bash install.sh)

Necesita: Raspberry Pi OS (Debian) de 64 bits (arm64) o 32 bits (armhf),
conexión a Internet y sudo. Tarda unos minutos.

Opciones
  --set-default       Eloquence pasa a ser el módulo por defecto
  --no-audio-config   no toca la salida de audio de speech-dispatcher
  --skip-setup        no descarga el firmware (luego: sudo eloquence-setup)
  --uninstall         elimina todo
  --dry-run           muestra lo que haría sin ejecutar nada

Después de instalar
  spd-say -o eloquence "Hola"
  eloquence -t "Hello" -o /tmp/t.wav && aplay /tmp/t.wav
  Ajustes de voz/velocidad: /etc/speech-dispatcher/modules/eloquence.conf

Si algo falla
  - Registro del puente: ${XDG_RUNTIME_DIR:-/tmp}/eci-bridge.log
  - Raspberry Pi 5: si el cargador rechaza las librerías ("not page-aligned"),
    añade  kernel=kernel8.img  a /boot/firmware/config.txt y reinicia.
  - Alternativa con emulación:  ECI_BRIDGE_MODE=qemu  (requiere qemu-user).

Licencias
  El código de Mudb0y/eloquence es GPL-3.0 (src/LICENSE). src/spd/vendor/
  contiene ficheros de speech-dispatcher 0.12.0 sin modificar (BSD y LGPL,
  ver src/spd/vendor/README). Las librerías de Eloquence NO se incluyen: las
  descarga eloquence-setup del firmware público LevelStar Icon.
