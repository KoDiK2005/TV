#!/usr/bin/env bash
# Оптимизация Android TV (Haier DVB2K, Android TV 11) через ADB без root.
# Все изменения обратимы: пакеты отключаются (pm disable-user), а не удаляются.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LISTS="$ROOT/packages"
STATE_DIR="$ROOT/state"
ADB="${ADB:-adb}"
STOCK_LAUNCHER="com.google.android.tvlauncher"
ALT_LAUNCHERS=(com.spocky.projengmenu me.efesser.flauncher com.wolf.firelauncher)

usage() {
  cat <<'EOF'
Использование: tv-optimize.sh <команда> [аргументы]

  connect <IP>        подключиться к ТВ по сети (порт 5555)
  info                модель, версия Android, свободная память
  scan                что установлено из списков + сторонние и подозрительные пакеты
  debloat             отключить пакеты из packages/safe.txt (с подтверждением)
  optional            по одному спросить про пакеты из packages/optional.txt
  disable <пакет>     отключить конкретный пакет (например, найденный через scan)
  perf                ускорить анимации (0.5x) и очистить кэш приложений
  dns [хост|off]      Private DNS для блокировки рекламы (по умолчанию dns.adguard-dns.com)
  launcher            перейти на альтернативный лаунчер (Projectivy / FLauncher / Wolf)
  restore             вернуть всё как было

Если подключено несколько устройств, задайте ANDROID_SERIAL=<IP>:5555.
EOF
}

die() { echo "Ошибка: $*" >&2; exit 1; }

adb_sh() { "$ADB" shell "$@" | tr -d '\r'; }

require_device() {
  command -v "$ADB" >/dev/null || die "adb не найден. Установите Android platform-tools."
  "$ADB" get-state >/dev/null 2>&1 || die "ТВ не подключён. Выполните: $0 connect <IP телевизора>"
}

serial() { "$ADB" get-serialno | tr -d '\r' | tr ':/' '__'; }
state_file() { echo "$STATE_DIR/disabled-$(serial).txt"; }

# Читает список пакетов: убирает комментарии и пустые строки.
read_list() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' "$1" | grep -v '^$' || true; }

# Комментарий к пакету из файла списка (для подсказок).
describe() { grep -h "^$1[[:space:]]" "$LISTS"/*.txt 2>/dev/null | sed -n 's/.*#[[:space:]]*//p' | head -n1; }

is_protected() {
  local pkg="$1" rule
  while read -r rule; do
    if [[ "$rule" == *'*' ]]; then
      [[ "$pkg" == "${rule%\*}"* ]] && return 0
    else
      [[ "$pkg" == "$rule" ]] && return 0
    fi
  done < <(read_list "$LISTS/never.txt")
  return 1
}

installed()  { adb_sh pm list packages    | sed 's/^package://'; }
enabled()    { adb_sh pm list packages -e | sed 's/^package://'; }
disabled()   { adb_sh pm list packages -d | sed 's/^package://'; }
third_party(){ adb_sh pm list packages -3 | sed 's/^package://'; }

confirm() {
  local answer
  read -r -p "$1 [y/N] " answer </dev/tty || return 1
  [[ "$answer" =~ ^[YyДд]$ ]]
}

disable_pkg() {
  local pkg="$1" force="${2:-}"
  if is_protected "$pkg" && [[ "$force" != "--force" ]]; then
    echo "  пропущен (защищён, см. packages/never.txt): $pkg"
    return 0
  fi
  if adb_sh pm disable-user --user 0 "$pkg" | grep -q 'disabled'; then
    echo "  отключён: $pkg"
    mkdir -p "$STATE_DIR"
    local sf; sf="$(state_file)"
    grep -qxF "$pkg" "$sf" 2>/dev/null || echo "$pkg" >> "$sf"
  else
    echo "  не удалось отключить: $pkg"
  fi
}

cmd_connect() {
  [[ $# -ge 1 ]] || die "укажите IP телевизора: $0 connect 192.168.1.50"
  local target="$1"
  [[ "$target" == *:* ]] || target="$target:5555"
  "$ADB" connect "$target"
  echo "Если на ТВ появился запрос «Разрешить отладку по USB?» — отметьте «Всегда» и нажмите OK,"
  echo "затем снова выполните команду connect."
}

cmd_info() {
  require_device
  echo "Модель:   $(adb_sh getprop ro.product.model)"
  echo "Android:  $(adb_sh getprop ro.build.version.release)"
  echo "Чипсет:   $(adb_sh getprop ro.board.platform)"
  adb_sh cat /proc/meminfo | grep -E '^(MemTotal|MemAvailable):' | sed 's/^/Память:   /'
  echo "Лаунчер:  $(adb_sh cmd package resolve-activity --brief -c android.intent.category.HOME -a android.intent.action.MAIN | tail -n1)"
}

cmd_scan() {
  require_device
  local all on list pkg
  all="$(installed)"; on="$(enabled)"
  for list in safe optional; do
    echo "== packages/$list.txt =="
    while read -r pkg; do
      if ! grep -qxF "$pkg" <<<"$all"; then continue; fi
      if grep -qxF "$pkg" <<<"$on"; then status="ВКЛ "; else status="выкл"; fi
      printf '  [%s] %-42s %s\n' "$status" "$pkg" "$(describe "$pkg")"
    done < <(read_list "$LISTS/$list.txt")
  done
  echo "== Установленные вами приложения =="
  third_party | sort | sed 's/^/  /'
  echo "== Системные пакеты, похожие на рекламу/рекомендации/магазины производителя =="
  echo "   (проверьте название в интернете, прежде чем отключать: $0 disable <пакет>)"
  grep -iE 'haier|ads|advert|promo|recommend|ott|store|market|launcher|weather|tvcloud|dataservice' <<<"$all" \
    | grep -vxFf <(read_list "$LISTS/safe.txt"; read_list "$LISTS/optional.txt") \
    | sort | sed 's/^/  /' || true
}

cmd_debloat() {
  require_device
  local on pkg targets=()
  on="$(enabled)"
  while read -r pkg; do
    grep -qxF "$pkg" <<<"$on" && targets+=("$pkg")
  done < <(read_list "$LISTS/safe.txt")
  [[ ${#targets[@]} -gt 0 ]] || { echo "Нечего отключать — всё из safe.txt уже отключено или не установлено."; return; }
  echo "Будут отключены:"
  for pkg in "${targets[@]}"; do printf '  %-42s %s\n' "$pkg" "$(describe "$pkg")"; done
  confirm "Продолжить?" || { echo "Отменено."; return; }
  for pkg in "${targets[@]}"; do disable_pkg "$pkg"; done
}

cmd_optional() {
  require_device
  local all on pkg
  all="$(installed)"; on="$(enabled)"
  while read -r pkg; do
    grep -qxF "$pkg" <<<"$all" || continue
    grep -qxF "$pkg" <<<"$on" || continue
    if confirm "Отключить $pkg ($(describe "$pkg"))?"; then disable_pkg "$pkg"; fi
  done < <(read_list "$LISTS/optional.txt")
}

cmd_disable() {
  require_device
  [[ $# -ge 1 ]] || die "укажите пакет: $0 disable com.example.app"
  grep -qxF "$1" <<<"$(installed)" || die "пакет $1 не установлен"
  if is_protected "$1"; then
    echo "Пакет $1 в списке защищённых. Отключение может сломать эфир, пульт или загрузку ТВ."
    confirm "Всё равно отключить? (вернуть: $0 restore)" || return 0
    disable_pkg "$1" --force
  else
    disable_pkg "$1"
  fi
}

cmd_perf() {
  require_device
  local key
  for key in window_animation_scale transition_animation_scale animator_duration_scale; do
    adb_sh settings put global "$key" 0.5
  done
  echo "Анимации ускорены в 2 раза."
  adb_sh pm trim-caches 999G >/dev/null || true
  echo "Кэш приложений очищен."
  adb_sh cat /proc/meminfo | grep '^MemAvailable:' | sed 's/^/Свободно: /'
}

cmd_dns() {
  require_device
  local host="${1:-dns.adguard-dns.com}"
  if [[ "$host" == "off" ]]; then
    adb_sh settings put global private_dns_mode off
    adb_sh settings delete global private_dns_specifier >/dev/null || true
    echo "Private DNS выключен."
  else
    adb_sh settings put global private_dns_mode hostname
    adb_sh settings put global private_dns_specifier "$host"
    echo "Private DNS: $host. Реклама внутри многих приложений и баннеры будут блокироваться."
    echo "Если пропадёт интернет — выполните: $0 dns off"
  fi
}

cmd_launcher() {
  require_device
  local all alt="" pkg
  all="$(installed)"
  for pkg in "${ALT_LAUNCHERS[@]}"; do
    if grep -qxF "$pkg" <<<"$all"; then alt="$pkg"; break; fi
  done
  [[ -n "$alt" ]] || die "сначала установите из Play Маркета Projectivy Launcher или FLauncher, затем повторите."
  echo "Найден лаунчер: $alt"
  echo "Стандартный лаунчер ($STOCK_LAUNCHER) с рекламными рядами будет отключён, кнопка Home откроет $alt."
  confirm "Продолжить?" || { echo "Отменено."; return; }
  disable_pkg "$STOCK_LAUNCHER" --force
  adb_sh am start -a android.intent.action.MAIN -c android.intent.category.HOME >/dev/null || true
  echo "Если на ТВ появится выбор лаунчера — выберите $alt и «Всегда»."
}

cmd_restore() {
  require_device
  local off pkg sf
  off="$(disabled)"; sf="$(state_file)"
  confirm "Включить обратно все отключённые этим скриптом пакеты и сбросить настройки?" || return 0
  while read -r pkg; do
    grep -qxF "$pkg" <<<"$off" || continue
    adb_sh pm enable --user 0 "$pkg" >/dev/null && echo "  включён: $pkg"
  done < <(
    read_list "$LISTS/safe.txt"; read_list "$LISTS/optional.txt"
    echo "$STOCK_LAUNCHER"
    [[ -f "$sf" ]] && cat "$sf"
  )
  rm -f "$sf"
  local key
  for key in window_animation_scale transition_animation_scale animator_duration_scale; do
    adb_sh settings put global "$key" 1
  done
  adb_sh settings put global private_dns_mode off
  echo "Готово. Перезагрузите ТВ: $ADB reboot"
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    connect)  cmd_connect "$@" ;;
    info)     cmd_info ;;
    scan)     cmd_scan ;;
    debloat)  cmd_debloat ;;
    optional) cmd_optional ;;
    disable)  cmd_disable "$@" ;;
    perf)     cmd_perf ;;
    dns)      cmd_dns "$@" ;;
    launcher) cmd_launcher ;;
    restore)  cmd_restore ;;
    ""|-h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
