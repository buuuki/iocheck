#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
TARGET=""
DEVICE_OVERRIDE=""
SIZE="4G"
RUNTIME="60"
JOBS="1"
IODEPTH="32"
INFO_ONLY=0
KEEP_FILE=0
REPORT_FILE=""
FIO_EXTRA_ARGS=()

usage() {
  cat <<USAGE
Uso:
  $SCRIPT_NAME --target /ruta/montada [opciones]

Ejemplos:
  $SCRIPT_NAME --target /mnt/ssd
  $SCRIPT_NAME --target /home --size 8G --runtime 120 --jobs 4
  $SCRIPT_NAME --target /mnt/ssd --info-only

Opciones:
  -t, --target DIR       Directorio o punto de montaje donde crear el archivo de prueba.
      --device DEV       Disco fisico para informacion previa, por ejemplo /dev/nvme0n1 o /dev/sda.
  -s, --size SIZE        Tamano del archivo de prueba de fio. Por defecto: $SIZE.
  -r, --runtime SEC      Duracion de cada prueba en segundos. Por defecto: $RUNTIME.
  -j, --jobs N           Numero de jobs de fio. Por defecto: $JOBS.
  -d, --iodepth N        Profundidad de cola. Por defecto: $IODEPTH.
      --report FILE      Archivo de informe. Por defecto: ./fio-report-YYYYmmdd-HHMMSS.log.
      --keep-file        No borrar el archivo de prueba al terminar.
      --info-only        Mostrar informacion del disco y TRIM/fstrim, sin ejecutar fio.
  -h, --help             Mostrar esta ayuda.

Notas:
  - El script usa un archivo llamado .fio-disk-check-testfile dentro del target.
  - Las pruebas de escritura modifican ese archivo, no escriben sobre el bloque completo.
  - Asegurate de que el target este en el disco que quieres probar y tenga espacio libre.
USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

as_root_prefix() {
  if [[ "${EUID}" -eq 0 ]]; then
    printf ''
  elif have sudo; then
    printf 'sudo '
  else
    printf ''
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--target)
        TARGET="${2:-}"
        [[ -n "$TARGET" ]] || die "falta valor para $1"
        shift 2
        ;;
      --device)
        DEVICE_OVERRIDE="${2:-}"
        [[ -n "$DEVICE_OVERRIDE" ]] || die "falta valor para $1"
        shift 2
        ;;
      -s|--size)
        SIZE="${2:-}"
        [[ -n "$SIZE" ]] || die "falta valor para $1"
        shift 2
        ;;
      -r|--runtime)
        RUNTIME="${2:-}"
        [[ -n "$RUNTIME" ]] || die "falta valor para $1"
        shift 2
        ;;
      -j|--jobs)
        JOBS="${2:-}"
        [[ -n "$JOBS" ]] || die "falta valor para $1"
        shift 2
        ;;
      -d|--iodepth)
        IODEPTH="${2:-}"
        [[ -n "$IODEPTH" ]] || die "falta valor para $1"
        shift 2
        ;;
      --report)
        REPORT_FILE="${2:-}"
        [[ -n "$REPORT_FILE" ]] || die "falta valor para $1"
        shift 2
        ;;
      --keep-file)
        KEEP_FILE=1
        shift
        ;;
      --info-only)
        INFO_ONLY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        FIO_EXTRA_ARGS+=("$@")
        break
        ;;
      *)
        die "opcion desconocida: $1"
        ;;
    esac
  done
}

require_target() {
  [[ -n "$TARGET" ]] || die "debes indicar --target /ruta/montada"
  [[ -d "$TARGET" ]] || die "el target no existe o no es un directorio: $TARGET"
  [[ -w "$TARGET" || "$INFO_ONLY" -eq 1 ]] || die "no hay permiso de escritura en: $TARGET"
}

resolve_device() {
  local source clean_source

  source="$(findmnt -T "$TARGET" -n -o SOURCE 2>/dev/null || true)"
  [[ -n "$source" ]] || die "no se pudo determinar el dispositivo montado para: $TARGET"
  clean_source="${source%%[*}"

  if [[ "$clean_source" == /dev/* ]]; then
    PARTITION="$clean_source"
    if [[ -n "$DEVICE_OVERRIDE" ]]; then
      DISK="$DEVICE_OVERRIDE"
    else
      DISK="$(resolve_parent_disk "$clean_source")"
    fi
  else
    DISK="${DEVICE_OVERRIDE:-$clean_source}"
    PARTITION="$clean_source"
  fi

  FSTYPE="$(findmnt -T "$TARGET" -n -o FSTYPE 2>/dev/null || true)"
  MOUNTPOINT="$(findmnt -T "$TARGET" -n -o TARGET 2>/dev/null || true)"
  MOUNT_OPTIONS="$(findmnt -T "$TARGET" -n -o OPTIONS 2>/dev/null || true)"
}

resolve_parent_disk() {
  local dev current type pkname guard
  dev="$1"
  current="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"
  guard=0

  while [[ "$guard" -lt 20 ]]; do
    type="$(lsblk -no TYPE "$current" 2>/dev/null | head -n1 | tr -d ' ' || true)"
    if [[ "$type" == "disk" ]]; then
      printf '%s\n' "$current"
      return 0
    fi

    pkname="$(lsblk -no PKNAME "$current" 2>/dev/null | head -n1 | tr -d ' ' || true)"
    if [[ -z "$pkname" ]]; then
      break
    fi

    current="/dev/$pkname"
    guard=$((guard + 1))
  done

  printf '%s\n' "$dev"
}

print_section() {
  printf '\n== %s ==\n' "$1"
}

init_report() {
  if [[ -z "$REPORT_FILE" ]]; then
    REPORT_FILE="./fio-report-$(date +%Y%m%d-%H%M%S).log"
  fi

  {
    printf '# fio disk check report\n'
    printf 'Fecha: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
    printf 'Host: <redacted>\n'
    printf 'Target: <redacted>\n'
    printf 'Disco: <redacted>\n'
    printf 'Archivo de prueba: <TARGET>/.fio-disk-check-testfile\n'
    printf 'Tamano fio: %s\n' "$SIZE"
    printf 'Runtime por prueba: %ss\n' "$RUNTIME"
    printf 'Jobs: %s\n' "$JOBS"
    printf 'Iodepth: %s\n' "$IODEPTH"
    printf '\n'
  } >"$REPORT_FILE"
}

sanitize_report_stream() {
  REPORT_FILE="$REPORT_FILE" TARGET="$TARGET" DISK="$DISK" perl -pe '
    s/\Q$ENV{REPORT_FILE}\E/<REPORT>/g;
    s/\Q$ENV{TARGET}\E/<TARGET>/g if length $ENV{TARGET};
    s/\Q$ENV{DISK}\E/<DEVICE>/g if length $ENV{DISK};
  '
}

append_report_section() {
  printf '\n\n## %s\n' "$1" >>"$REPORT_FILE"
}

format_command() {
  printf '%q ' "$@"
  printf '\n'
}

print_basic_info() {
  print_section "Target"
  printf 'Target:      %s\n' "$TARGET"
  printf 'Montaje:     %s\n' "${MOUNTPOINT:-desconocido}"
  printf 'Fuente:      %s\n' "${PARTITION:-desconocida}"
  printf 'Disco:       %s\n' "${DISK:-desconocido}"
  printf 'Filesystem:  %s\n' "${FSTYPE:-desconocido}"
  printf 'Opciones:    %s\n' "${MOUNT_OPTIONS:-desconocidas}"

  print_section "lsblk"
  if [[ "$DISK" == /dev/* ]] && lsblk "$DISK" >/dev/null 2>&1; then
    lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,ROTA,TRAN,FSTYPE,MOUNTPOINTS,DISC-MAX,DISC-GRAN "$DISK"
  else
    printf 'No se pudo limitar lsblk a "%s"; se muestra la lista completa.\n' "$DISK"
    lsblk -o NAME,PATH,TYPE,SIZE,MODEL,ROTA,TRAN,FSTYPE,MOUNTPOINTS,DISC-MAX,DISC-GRAN
  fi
}

print_transport_info() {
  local base transport root_prefix
  base="$(basename "$DISK")"
  root_prefix="$(as_root_prefix)"

  if [[ "$DISK" == /dev/* ]] && ! lsblk "$DISK" >/dev/null 2>&1; then
    print_section "Informacion del dispositivo"
    printf 'No se pudo consultar "%s" como dispositivo de bloque.\n' "$DISK"
    printf 'Si el target esta sobre LUKS/LVM, revisa el arbol completo de lsblk mostrado arriba para identificar el SATA/NVMe fisico.\n'
    return 0
  fi

  transport="$(lsblk -dn -o TRAN "$DISK" 2>/dev/null | tr -d ' ' || true)"

  print_section "Informacion del dispositivo"
  printf 'Transporte detectado: %s\n' "${transport:-desconocido}"

  if [[ "$base" == nvme* ]] && have nvme; then
    printf '\n-- nvme id-ctrl --\n'
    ${root_prefix}nvme id-ctrl "$DISK" 2>/dev/null | sed -n '1,80p' || true
    printf '\n-- nvme smart-log --\n'
    ${root_prefix}nvme smart-log "$DISK" 2>/dev/null || true
  elif [[ "$transport" == "sata" || "$transport" == "ata" ]] && have hdparm; then
    printf '\n-- hdparm -I --\n'
    ${root_prefix}hdparm -I "$DISK" 2>/dev/null | sed -n '1,120p' || true
  fi

  if have smartctl; then
    printf '\n-- smartctl -i -A --\n'
    ${root_prefix}smartctl -i -A "$DISK" 2>/dev/null || true
  else
    printf '\nsmartctl no esta instalado. En Debian/Ubuntu: sudo apt install smartmontools\n'
  fi

  if [[ "$base" == nvme* ]] && ! have nvme; then
    printf 'nvme-cli no esta instalado. En Debian/Ubuntu: sudo apt install nvme-cli\n'
  fi
}

print_trim_info() {
  local disc_max fstrim_state root_prefix
  root_prefix="$(as_root_prefix)"

  print_section "TRIM / fstrim"
  if [[ "$DISK" == /dev/* ]] && ! lsblk "$DISK" >/dev/null 2>&1; then
    printf 'Soporte TRIM/discard del disco: no se pudo comprobar para "%s".\n' "$DISK"
  else
    disc_max="$(lsblk -dn -o DISC-MAX "$DISK" 2>/dev/null | tr -d ' ' || true)"
    if [[ -n "$disc_max" && "$disc_max" != "0B" && "$disc_max" != "0" ]]; then
      printf 'Soporte TRIM/discard del disco: si (DISC-MAX=%s)\n' "$disc_max"
    else
      printf 'Soporte TRIM/discard del disco: no detectado o no expuesto (DISC-MAX=%s)\n' "${disc_max:-desconocido}"
    fi
  fi

  if [[ ",$MOUNT_OPTIONS," == *",discard,"* ]]; then
    printf 'Discard online en el montaje: activado\n'
  else
    printf 'Discard online en el montaje: no activado\n'
  fi

  if have systemctl; then
    fstrim_state="$(systemctl is-enabled fstrim.timer 2>/dev/null || true)"
    printf 'fstrim.timer: %s\n' "${fstrim_state:-no detectado}"
    systemctl list-timers fstrim.timer --no-pager 2>/dev/null || true
  else
    printf 'systemctl no esta disponible; no se puede revisar fstrim.timer.\n'
  fi

  printf '\nPasos rapidos si fstrim.timer no esta activado:\n'
  printf '  1. %ssystemctl enable --now fstrim.timer\n' "$root_prefix"
  printf '  2. systemctl status fstrim.timer\n'
  printf '  3. %sfstrim -av\n' "$root_prefix"
  printf '\nAlternativa: usar opcion discard en /etc/fstab, aunque normalmente se prefiere fstrim.timer periodico.\n'
}

check_fio() {
  have fio || die "fio no esta instalado. En Debian/Ubuntu: sudo apt install fio"
}

print_space_warning() {
  print_section "Espacio disponible"
  df -h "$TARGET"
  printf '\nArchivo de prueba: %s/.fio-disk-check-testfile\n' "$TARGET"
  printf 'Tamano configurado: %s\n' "$SIZE"
}

run_fio_test() {
  local name rw bs extra=() output_file status cmd=()
  name="$1"
  rw="$2"
  bs="$3"
  shift 3
  extra=("$@")
  output_file="$(mktemp)"

  print_section "fio: $name"
  explain_fio_test "$name" "$rw" "$bs" "${extra[@]}"

  cmd=(
    fio
    --name="$name" \
    --filename="$TARGET/.fio-disk-check-testfile" \
    --size="$SIZE" \
    --time_based=1 \
    --runtime="$RUNTIME" \
    --ramp_time=5 \
    --ioengine=libaio \
    --direct=1 \
    --group_reporting=1 \
    --numjobs="$JOBS" \
    --iodepth="$IODEPTH" \
    --rw="$rw" \
    --bs="$bs" \
    "${extra[@]}" \
    "${FIO_EXTRA_ARGS[@]}"
  )

  printf 'Comando:\n  '
  format_command "${cmd[@]}"

  append_report_section "Prueba: $name"
  {
    printf 'Explicacion:\n'
    explain_fio_test "$name" "$rw" "$bs" "${extra[@]}"
    printf '\nComando:\n'
    format_command "${cmd[@]}"
    printf '\nSalida completa de fio:\n'
  } | sanitize_report_stream >>"$REPORT_FILE"

  if "${cmd[@]}" >"$output_file" 2>&1; then
    status=0
  else
    status=$?
  fi

  sanitize_report_stream <"$output_file" >>"$REPORT_FILE"
  printf '\nCodigo de salida: %s\n' "$status" >>"$REPORT_FILE"

  print_fio_summary "$output_file"
  rm -f "$output_file"

  if [[ "$status" -ne 0 ]]; then
    die "fio fallo en la prueba $name. Revisa el informe: $REPORT_FILE"
  fi
}

explain_fio_test() {
  local name rw bs mix description operation
  name="$1"
  rw="$2"
  bs="$3"
  shift 3
  mix="$(printf '%s\n' "$@" | sed -n 's/^--rwmixread=//p' | head -n1)"

  case "$rw" in
    write)
      operation="escritura secuencial"
      description="Escribe datos de forma continua para medir rendimiento sostenido de escritura."
      ;;
    read)
      operation="lectura secuencial"
      description="Lee datos de forma continua para medir rendimiento sostenido de lectura."
      ;;
    randwrite)
      operation="escritura aleatoria"
      description="Escribe bloques en posiciones aleatorias para medir IOPS y latencia de escritura."
      ;;
    randread)
      operation="lectura aleatoria"
      description="Lee bloques en posiciones aleatorias para medir IOPS y latencia de lectura."
      ;;
    randrw)
      operation="lectura/escritura aleatoria"
      description="Mezcla lecturas y escrituras aleatorias para simular carga mixta."
      ;;
    *)
      operation="$rw"
      description="Prueba fio personalizada."
      ;;
  esac

  printf 'Tipo de prueba: %s (%s)\n' "$name" "$operation"
  printf 'Descripcion: %s\n' "$description"
  printf 'Archivo de prueba: %s/.fio-disk-check-testfile\n' "$TARGET"
  printf 'Tamano del archivo/dataset: %s\n' "$SIZE"
  printf 'Tamano de bloque: %s\n' "$bs"
  printf 'Duracion: %ss + 5s de calentamiento\n' "$RUNTIME"
  printf 'Jobs: %s\n' "$JOBS"
  printf 'Iodepth: %s\n' "$IODEPTH"
  printf 'I/O directa: si (--direct=1)\n'
  if [[ -n "$mix" ]]; then
    printf 'Mezcla lectura/escritura: %s%% lectura, %s%% escritura\n' "$mix" "$((100 - mix))"
  fi
}

print_fio_summary() {
  local output_file
  output_file="$1"

  printf '\nResumen:\n'
  awk '
    /^[[:space:]]*(read|write):/ {
      gsub(/^[[:space:]]+/, "")
      print "  " $0
    }
    /^[[:space:]]*lat \([^)]*\):/ {
      gsub(/^[[:space:]]+/, "")
      print "  " $0
    }
    /^[[:space:]]*cpu[[:space:]]*:/ {
      gsub(/^[[:space:]]+/, "")
      print "  " $0
    }
    /^[[:space:]]*IO depths[[:space:]]*:/ {
      gsub(/^[[:space:]]+/, "")
      print "  " $0
    }
  ' "$output_file"
  printf 'Salida completa guardada en: %s\n' "$REPORT_FILE"
}

cleanup() {
  if [[ "$KEEP_FILE" -eq 0 && -n "$TARGET" && -f "$TARGET/.fio-disk-check-testfile" ]]; then
    rm -f "$TARGET/.fio-disk-check-testfile"
  fi
}

main() {
  parse_args "$@"
  require_target
  resolve_device

  print_basic_info
  print_transport_info
  print_trim_info

  if [[ "$INFO_ONLY" -eq 1 ]]; then
    exit 0
  fi

  check_fio
  init_report
  printf '\nInforme: %s\n' "$REPORT_FILE"
  print_space_warning

  printf '\nSe ejecutaran pruebas de escritura y lectura sobre un archivo dentro del target.\n'
  printf 'Pulsa Ctrl+C ahora si el target no es correcto.\n\n'
  sleep 5

  trap cleanup EXIT
  run_fio_test "seq_write_1m" "write" "1M"
  run_fio_test "seq_read_1m" "read" "1M"
  run_fio_test "rand_write_4k" "randwrite" "4k"
  run_fio_test "rand_read_4k" "randread" "4k"
  run_fio_test "rand_rw_4k_70read" "randrw" "4k" --rwmixread=70

  print_section "Finalizado"
  if [[ "$KEEP_FILE" -eq 1 ]]; then
    printf 'Se conserva el archivo de prueba: %s/.fio-disk-check-testfile\n' "$TARGET"
  else
    printf 'El archivo de prueba se eliminara automaticamente.\n'
  fi
  printf 'Informe completo: %s\n' "$REPORT_FILE"
}

main "$@"
