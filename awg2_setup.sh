#!/bin/sh
# =============================================================================
# RouteRich AX3000 (OpenWrt) — AmneziaWG 2.0 + podkop Setup Script
# =============================================================================
# Использование:
#   sh <(wget -O - https://your-host/routerich-awg2-setup.sh) /path/to/vpn.conf
#
# Или в два шага:
#   wget -O /tmp/setup.sh https://your-host/routerich-awg2-setup.sh
#   sh /tmp/setup.sh /tmp/vpn.conf
#
# Что делает скрипт:
#   1. Устанавливает пакеты AmneziaWG 2.0
#   2. Создаёт UCI-интерфейс awg1
#   3. Настраивает зону файрвола
#   4. Добавляет NTP-сервер
#   5. Устанавливает podkop (маршрутизация)
#
# Требования:
#   OpenWrt >= 24.10.3 (для AWG 2.0)
#   Платформа: mediatek/filogic (RouteRich AX3000)
#   Минимум 20MB свободного места (для sing-box / podkop)
# =============================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$1"; }
log_warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$1"; }

echo ""
echo "============================================================"
echo "  RouteRich AX3000 — AmneziaWG 2.0 + podkop Setup"
echo "============================================================"
echo ""

# =============================================================================
# Проверка аргумента — путь к конфигу
# =============================================================================
CONF_FILE="$1"

if [ -z "$CONF_FILE" ]; then
    log_error "Укажите путь к конфигу AWG:"
    echo ""
    echo "  sh setup.sh /path/to/vpn.conf"
    echo ""
    exit 1
fi

if [ ! -f "$CONF_FILE" ]; then
    log_error "Файл не найден: $CONF_FILE"
    exit 1
fi

log_info "Читаю конфиг: $CONF_FILE"

# =============================================================================
# Парсинг конфига
# Поддерживается AWG 1.0 и AWG 2.0 (H1-H4 в формате "number-number")
# =============================================================================
PRIVATE_KEY=$(grep -i   "^PrivateKey"           "$CONF_FILE" | awk '{print $3}')
ADDRESS=$(grep -i       "^Address"              "$CONF_FILE" | awk '{print $3}')
DNS=$(grep -i           "^DNS"                  "$CONF_FILE" | awk '{print $3}')
PUBLIC_KEY=$(grep -i    "^PublicKey"            "$CONF_FILE" | awk '{print $3}')
PRESHARED_KEY=$(grep -i "^PresharedKey"         "$CONF_FILE" | awk '{print $3}')
ENDPOINT=$(grep -i      "^Endpoint"             "$CONF_FILE" | awk '{print $3}')
KEEPALIVE=$(grep -i     "^PersistentKeepalive"  "$CONF_FILE" | awk '{print $3}')

JC=$(grep -i   "^Jc\b"   "$CONF_FILE" | awk '{print $3}')
JMIN=$(grep -i "^Jmin\b" "$CONF_FILE" | awk '{print $3}')
JMAX=$(grep -i "^Jmax\b" "$CONF_FILE" | awk '{print $3}')
S1=$(grep -i   "^S1\b"   "$CONF_FILE" | awk '{print $3}')
S2=$(grep -i   "^S2\b"   "$CONF_FILE" | awk '{print $3}')
H1=$(grep -i   "^H1\b"   "$CONF_FILE" | awk '{print $3}')
H2=$(grep -i   "^H2\b"   "$CONF_FILE" | awk '{print $3}')
H3=$(grep -i   "^H3\b"   "$CONF_FILE" | awk '{print $3}')
H4=$(grep -i   "^H4\b"   "$CONF_FILE" | awk '{print $3}')

# AWG 2.0 дополнительные поля
S3=$(grep -i   "^S3\b"   "$CONF_FILE" | awk '{print $3}')
S4=$(grep -i   "^S4\b"   "$CONF_FILE" | awk '{print $3}')
I1=$(grep -i   "^I1\b"   "$CONF_FILE" | awk '{print $3}')
I2=$(grep -i   "^I2\b"   "$CONF_FILE" | awk '{print $3}')
I3=$(grep -i   "^I3\b"   "$CONF_FILE" | awk '{print $3}')
I4=$(grep -i   "^I4\b"   "$CONF_FILE" | awk '{print $3}')
I5=$(grep -i   "^I5\b"   "$CONF_FILE" | awk '{print $3}')

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$ENDPOINT" ]; then
    log_error "Конфиг неполный. Должны быть: PrivateKey, PublicKey, Endpoint"
    exit 1
fi

# Определяем версию AWG по формату H1 или наличию новых полей
if [ -n "$H1" ] && echo "$H1" | grep -q "-"; then
    AWG_VER="2.0"
elif [ -n "$S3" ] || [ -n "$I1" ]; then
    AWG_VER="2.0"
else
    AWG_VER="1.0"
fi

ENDPOINT_HOST=$(echo "$ENDPOINT" | cut -d: -f1)
ENDPOINT_PORT=$(echo "$ENDPOINT" | cut -d: -f2)
TUNNEL_IP=$(echo "$ADDRESS" | cut -d/ -f1)

AWG_IFACE="awg1"
NTP_SERVER="194.190.168.1"

# Определяем версию OpenWrt
OPENWRT_VERSION=$(ubus call system board 2>/dev/null | jsonfilter -e '@.release.version' 2>/dev/null)
if [ -z "$OPENWRT_VERSION" ]; then
    OPENWRT_VERSION=$(grep "DISTRIB_RELEASE=" /etc/openwrt_release | cut -d"'" -f2 | cut -d'.' -f1-3)
fi

# =============================================================================
# Подтверждение параметров
# =============================================================================
echo ""
log_info "Параметры установки:"
echo "  AWG версия : $AWG_VER"
echo "  OpenWrt    : $OPENWRT_VERSION"
echo "  Интерфейс  : $AWG_IFACE"
echo "  Endpoint   : $ENDPOINT_HOST:$ENDPOINT_PORT"
echo "  Tunnel IP  : $TUNNEL_IP"
echo "  NTP        : $NTP_SERVER"
echo "  Маршрутиз. : podkop"
[ -n "$JC" ] && echo "  Jc/Jmin/Jmax/S1/S2 : $JC/$JMIN/$JMAX/$S1/$S2"
[ -n "$H1" ] && echo "  H1-H4      : $H1 / $H2 / $H3 / $H4"
[ -n "$S3" ] && echo "  S3/S4      : $S3 / $S4"
[ -n "$I1" ] && echo "  I1-I5      : $I1 / $I2 / $I3 / $I4 / $I5"
echo ""

printf "Продолжить установку? (y/n): "
read -r CONFIRM
[ "$CONFIRM" != "y" ] && { log_warn "Отменено."; exit 0; }
echo ""

# =============================================================================
# ШАГ 1: Установка пакетов AmneziaWG
# =============================================================================
log_info "=== ШАГ 1: Установка пакетов AmneziaWG ==="

if opkg list-installed 2>/dev/null | grep -q "kmod-amneziawg"; then
    log_info "kmod-amneziawg уже установлен, пропускаю"
else
    log_info "Устанавливаю пакеты AWG $AWG_VER..."
    # Отвечаем "n" на вопрос о языковом пакете и "n" на вопрос о настройке
    # интерфейса — интерфейс настраиваем сами в шаге 2
    printf "n\nn\n" | sh <(wget -4 -O - \
        https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh) \
        2>&1 | grep -vE "^$" || true
    log_info "Пакеты AWG установлены"
fi

if ! opkg list-installed 2>/dev/null | grep -q "luci-proto-amneziawg"; then
    log_warn "luci-proto-amneziawg не найден — возможно OpenWrt < 24.10.3 или установка не удалась"
fi

# =============================================================================
# ШАГ 2: Создание UCI-интерфейса AWG
# =============================================================================
log_info "=== ШАГ 2: Создание VPN интерфейса (AWG $AWG_VER) ==="

uci delete network.$AWG_IFACE        2>/dev/null || true
uci delete network.${AWG_IFACE}_peer 2>/dev/null || true

uci set network.$AWG_IFACE=interface
uci set network.$AWG_IFACE.proto=amneziawg
uci set network.$AWG_IFACE.addresses="$ADDRESS"
uci set network.$AWG_IFACE.private_key="$PRIVATE_KEY"

# DNS не прописываем — podkop управляет DNS самостоятельно

# Обфускация (awg_* префикс — требование luci-proto-amneziawg)
[ -n "$JC"   ] && uci set network.$AWG_IFACE.awg_jc="$JC"
[ -n "$JMIN" ] && uci set network.$AWG_IFACE.awg_jmin="$JMIN"
[ -n "$JMAX" ] && uci set network.$AWG_IFACE.awg_jmax="$JMAX"
[ -n "$S1"   ] && uci set network.$AWG_IFACE.awg_s1="$S1"
[ -n "$S2"   ] && uci set network.$AWG_IFACE.awg_s2="$S2"

# H1-H4: UCI принимает формат "number-number" как обычную строку
[ -n "$H1"   ] && uci set network.$AWG_IFACE.awg_h1="$H1"
[ -n "$H2"   ] && uci set network.$AWG_IFACE.awg_h2="$H2"
[ -n "$H3"   ] && uci set network.$AWG_IFACE.awg_h3="$H3"
[ -n "$H4"   ] && uci set network.$AWG_IFACE.awg_h4="$H4"

# AWG 2.0 дополнительные поля
[ -n "$S3"   ] && uci set network.$AWG_IFACE.awg_s3="$S3"
[ -n "$S4"   ] && uci set network.$AWG_IFACE.awg_s4="$S4"
[ -n "$I1"   ] && uci set network.$AWG_IFACE.awg_i1="$I1"
[ -n "$I2"   ] && uci set network.$AWG_IFACE.awg_i2="$I2"
[ -n "$I3"   ] && uci set network.$AWG_IFACE.awg_i3="$I3"
[ -n "$I4"   ] && uci set network.$AWG_IFACE.awg_i4="$I4"
[ -n "$I5"   ] && uci set network.$AWG_IFACE.awg_i5="$I5"

# Peer
# route_allowed_ips=0 — маршрутами управляет podkop, не AWG
uci set network.${AWG_IFACE}_peer=amneziawg_${AWG_IFACE}
uci set network.${AWG_IFACE}_peer.public_key="$PUBLIC_KEY"
uci set network.${AWG_IFACE}_peer.endpoint_host="$ENDPOINT_HOST"
uci set network.${AWG_IFACE}_peer.endpoint_port="$ENDPOINT_PORT"
uci set network.${AWG_IFACE}_peer.allowed_ips="0.0.0.0/0"
uci set network.${AWG_IFACE}_peer.route_allowed_ips="0"
uci set network.${AWG_IFACE}_peer.persistent_keepalive="${KEEPALIVE:-25}"
[ -n "$PRESHARED_KEY" ] && uci set network.${AWG_IFACE}_peer.preshared_key="$PRESHARED_KEY"

uci commit network
log_info "Интерфейс $AWG_IFACE создан"

# =============================================================================
# ШАГ 3: Файрвол
# Зона нужна для корректной работы podkop с AWG-интерфейсом.
# =============================================================================
log_info "=== ШАГ 3: Настройка файрвола ==="

uci delete firewall.awg_zone   2>/dev/null || true
uci delete firewall.lan_to_awg 2>/dev/null || true

uci set firewall.awg_zone=zone
uci set firewall.awg_zone.name=awg
uci set firewall.awg_zone.network="$AWG_IFACE"
uci set firewall.awg_zone.input=REJECT
uci set firewall.awg_zone.output=ACCEPT
uci set firewall.awg_zone.forward=REJECT
uci set firewall.awg_zone.masq=1
uci set firewall.awg_zone.mtu_fix=1
uci set firewall.awg_zone.family=ipv4

uci set firewall.lan_to_awg=forwarding
uci set firewall.lan_to_awg.src=lan
uci set firewall.lan_to_awg.dest=awg
uci set firewall.lan_to_awg.family=ipv4

uci commit firewall
log_info "Файрвол настроен"

# =============================================================================
# ШАГ 4: NTP
# Важно для корректного старта AWG-туннеля после перезагрузки
# =============================================================================
log_info "=== ШАГ 4: NTP ==="

uci add_list system.ntp.server="$NTP_SERVER" 2>/dev/null || true
uci commit system
log_info "NTP сервер добавлен: $NTP_SERVER"

# =============================================================================
# ШАГ 5: Установка podkop
# podkop берёт на себя всю маршрутизацию: обход блокировок по доменам/IP,
# DNS через туннель для заблокированных ресурсов.
# После установки настраивается через LuCI: Services → Podkop
# =============================================================================
log_info "=== ШАГ 5: Установка podkop ==="

if opkg list-installed 2>/dev/null | grep -q "^podkop "; then
    log_info "podkop уже установлен, пропускаю"
else
    # Проверяем свободное место (нужно ~20MB для sing-box)
    FREE_MB=$(df /overlay 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}')
    if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt 20 ]; then
        log_warn "Мало свободного места: ${FREE_MB}MB (нужно ~20MB для podkop + sing-box)"
        printf "Продолжить установку podkop? (y/n): "
        read -r PODKOP_CONFIRM
    else
        PODKOP_CONFIRM="y"
    fi

    if [ "$PODKOP_CONFIRM" = "y" ]; then
        log_info "Устанавливаю podkop (~1-2 минуты)..."
        sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh) \
            2>&1 | grep -vE "^$" || true

        if opkg list-installed 2>/dev/null | grep -q "^podkop "; then
            log_info "podkop установлен успешно"
        else
            log_warn "podkop не удалось установить — настройте маршрутизацию вручную"
        fi
    else
        log_warn "Установка podkop пропущена. Настройте маршрутизацию вручную."
    fi
fi

# =============================================================================
# Применяем сетевые настройки
# =============================================================================
log_info "Применяю настройки сети и файрвола..."
/etc/init.d/network reload  2>/dev/null || true
/etc/init.d/firewall reload 2>/dev/null || true

# =============================================================================
# Итог
# =============================================================================
echo ""
echo "============================================================"
log_info "Установка завершена!"
echo ""
echo "  AWG версия : $AWG_VER"
echo "  Интерфейс  : $AWG_IFACE"
echo "  Endpoint   : $ENDPOINT_HOST:$ENDPOINT_PORT"
echo "  Tunnel IP  : $TUNNEL_IP"
echo "  NTP        : $NTP_SERVER"
echo ""
log_warn "Следующие шаги:"
echo ""
echo "  1. Перезагрузите роутер:"
echo "     reboot"
echo ""
echo "  2. После перезагрузки проверьте туннель:"
echo "     amneziawg show"
echo ""
echo "  3. Настройте podkop через LuCI:"
echo "     Services → Podkop"
echo "     Tunnel interface: $AWG_IFACE"
echo "============================================================"