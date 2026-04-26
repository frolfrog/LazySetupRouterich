#!/bin/sh
# =============================================================================
# RouteRich AX3000 (OpenWrt) — AmneziaWG 2.0 + podkop Setup Script
# =============================================================================
# Использование:
#   wget -O /tmp/setup.sh https://your-host/routerich-awg2-setup.sh
#   sh /tmp/setup.sh /tmp/vpn.conf
#
# Что делает скрипт:
#   1. Устанавливает пакеты AmneziaWG 2.0 (kmod + tools + luci-proto)
#   2. Создаёт UCI-интерфейс awg1
#   3. Настраивает зону файрвола (IPv4)
#   4. Добавляет NTP-сервер
#   5. Устанавливает podkop (маршрутизация и DNS)
#
# Требования:
#   OpenWrt >= 24.10.3 (для AWG 2.0)
#   Платформа: mediatek/filogic (RouteRich AX3000)
#   ~20MB свободного места (sing-box / podkop)
#
# Примечания:
#   - IPv6 не настраивается (инфраструктура IPv4-only)
#   - После скрипта трафик через туннель не пойдёт сам по себе —
#     нужно настроить podkop через LuCI: Services → Podkop
#   - Если провайдер блокирует высокие UDP-порты, порт на сервере
#     нужно менять там (docker-compose на VPS), а не в конфиге клиента
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
    echo "  sh /tmp/setup.sh /tmp/vpn.conf"
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
#
# Простые однословные значения: awk '{print $3}'
# Многословные значения (I1-I5 — бинарные блобы вида "<b 0x...>"):
#   sed берёт всё после "FieldName = "
# =============================================================================
parse_simple() { grep -i "^${1}\b" "$CONF_FILE" | awk '{print $3}'; }
parse_full()   { grep -i "^${1}\b" "$CONF_FILE" | sed "s/^[^=]*= *//"; }

PRIVATE_KEY=$(parse_simple "PrivateKey")
ADDRESS=$(parse_simple "Address")
DNS=$(parse_simple "DNS")
PUBLIC_KEY=$(parse_simple "PublicKey")
PRESHARED_KEY=$(parse_simple "PresharedKey")
ENDPOINT=$(parse_simple "Endpoint")
KEEPALIVE=$(parse_simple "PersistentKeepalive")

JC=$(parse_simple "Jc")
JMIN=$(parse_simple "Jmin")
JMAX=$(parse_simple "Jmax")
S1=$(parse_simple "S1")
S2=$(parse_simple "S2")
H1=$(parse_simple "H1")
H2=$(parse_simple "H2")
H3=$(parse_simple "H3")
H4=$(parse_simple "H4")

# AWG 2.0: S3/S4 — простые числа, I1-I5 — могут быть бинарными блобами
S3=$(parse_simple "S3")
S4=$(parse_simple "S4")
I1=$(parse_full "I1")
I2=$(parse_full "I2")
I3=$(parse_full "I3")
I4=$(parse_full "I4")
I5=$(parse_full "I5")

if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] || [ -z "$ENDPOINT" ]; then
    log_error "Конфиг неполный. Должны быть: PrivateKey, PublicKey, Endpoint"
    exit 1
fi

# Определяем версию AWG по формату H1 или наличию полей AWG 2.0
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

# Версия OpenWrt
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
echo "  Маршрутиз. : podkop (настраивается после перезагрузки)"
[ -n "$JC" ] && echo "  Jc/Jmin/Jmax/S1/S2 : $JC/$JMIN/$JMAX/$S1/$S2"
[ -n "$H1" ] && echo "  H1-H4      : $H1 / $H2 / $H3 / $H4"
[ -n "$S3" ] && echo "  S3/S4      : $S3 / $S4"
[ -n "$I1" ] && echo "  I1         : $(echo "$I1" | cut -c1-40)..."
echo ""

printf "Продолжить установку? (y/n): "
read -r CONFIRM
[ "$CONFIRM" != "y" ] && { log_warn "Отменено."; exit 0; }
echo ""

# =============================================================================
# ШАГ 1: Установка пакетов AmneziaWG
#
# sh <(wget ...) не работает в BusyBox ash — используем временный файл.
# Скрипт Shchipunov сам определяет платформу и скачивает нужные .ipk
# из релизов GitHub под mediatek/filogic / aarch64_cortex-a53 / 24.10.x
# =============================================================================
log_info "=== ШАГ 1: Установка пакетов AmneziaWG ==="

AWG_NEED_INSTALL=0
opkg list-installed 2>/dev/null | grep -q "kmod-amneziawg"      || AWG_NEED_INSTALL=1
opkg list-installed 2>/dev/null | grep -q "amneziawg-tools"      || AWG_NEED_INSTALL=1
opkg list-installed 2>/dev/null | grep -q "luci-proto-amneziawg" || AWG_NEED_INSTALL=1

if [ "$AWG_NEED_INSTALL" = "0" ]; then
    log_info "Все пакеты AWG уже установлены, пропускаю"
else
    log_info "Устанавливаю пакеты AWG $AWG_VER..."
    wget -4 -O /tmp/amneziawg-install.sh \
        https://raw.githubusercontent.com/Slava-Shchipunov/awg-openwrt/refs/heads/master/amneziawg-install.sh

    if [ ! -s /tmp/amneziawg-install.sh ]; then
        log_error "Не удалось скачать amneziawg-install.sh"
        exit 1
    fi

    # n — пропустить языковой пакет
    # n — пропустить настройку интерфейса (делаем сами в шаге 2)
    printf "n\nn\n" | sh /tmp/amneziawg-install.sh 2>&1 | grep -vE "^$" || true
    rm -f /tmp/amneziawg-install.sh

    # Проверяем что все три пакета установились
    MISSING=""
    opkg list-installed 2>/dev/null | grep -q "kmod-amneziawg"      || MISSING="$MISSING kmod-amneziawg"
    opkg list-installed 2>/dev/null | grep -q "amneziawg-tools"      || MISSING="$MISSING amneziawg-tools"
    opkg list-installed 2>/dev/null | grep -q "luci-proto-amneziawg" || MISSING="$MISSING luci-proto-amneziawg"

    if [ -n "$MISSING" ]; then
        log_error "Не установились пакеты:$MISSING"
        log_error "Проверьте интернет и версию OpenWrt (нужна >= 24.10.3)"
        exit 1
    fi

    log_info "Все пакеты AWG установлены"
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
# ШАГ 3: Файрвол (IPv4)
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
# =============================================================================
log_info "=== ШАГ 4: NTP ==="

uci add_list system.ntp.server="$NTP_SERVER" 2>/dev/null || true
uci commit system
log_info "NTP сервер добавлен: $NTP_SERVER"

# =============================================================================
# ШАГ 5: Установка podkop
# =============================================================================
log_info "=== ШАГ 5: Установка podkop ==="

if opkg list-installed 2>/dev/null | grep -q "^podkop "; then
    log_info "podkop уже установлен, пропускаю"
else
    FREE_MB=$(df /overlay 2>/dev/null | awk 'NR==2{printf "%d", $4/1024}')
    if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt 20 ]; then
        log_warn "Мало свободного места: ${FREE_MB}MB (нужно ~20MB для podkop + sing-box)"
        printf "Продолжить установку podkop? (y/n): "
        read -r PODKOP_CONFIRM
    else
        PODKOP_CONFIRM="y"
    fi

    if [ "$PODKOP_CONFIRM" = "y" ]; then
        log_info "Скачиваю и устанавливаю podkop (~1-2 минуты)..."
        wget -O /tmp/podkop-install.sh \
            https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh

        if [ ! -s /tmp/podkop-install.sh ]; then
            log_error "Не удалось скачать podkop install.sh"
        else
            sh /tmp/podkop-install.sh 2>&1 | grep -vE "^$" || true
            rm -f /tmp/podkop-install.sh

            if opkg list-installed 2>/dev/null | grep -q "^podkop "; then
                log_info "podkop установлен успешно"
            else
                log_warn "podkop не удалось установить — настройте маршрутизацию вручную"
            fi
        fi
    else
        log_warn "Установка podkop пропущена."
    fi
fi

# =============================================================================
# Применяем настройки
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
echo "  2. Проверьте туннель (handshake должен быть < 2 минут):"
echo "     amneziawg show"
echo ""
echo "  3. Настройте podkop через LuCI:"
echo "     Services → Podkop"
echo "     Tunnel interface: $AWG_IFACE"
echo ""
log_warn "  Трафик через туннель не пойдёт без настройки podkop!"
echo "============================================================"