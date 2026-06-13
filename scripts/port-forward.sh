#!/usr/bin/env bash
# =============================================================================
#  iptables Port-Forwarding Manager  (TCP/UDP, DNAT + MASQUERADE)
#  مناسب برای فوروارد کردن ترافیک از سرور ایران به سرور خارجی (مثلاً 3x-ui)
#  Author: ChatGPT for user  |  License: MIT
# =============================================================================
#  امکانات:
#   1) فعال‌سازی IP Forwarding در کرنل (به‌صورت دائمی)
#   2) اضافه‌کردن قانون فوروارد یک پورت / رنج پورت  (TCP / UDP / هردو)
#   3) نمایش قوانین فعلی (NAT)
#   4) حذف یک قانون
#   5) پاک‌کردن کامل قوانین NAT
#   6) ذخیره‌ی دائمی قوانین (iptables-persistent یا netfilter-persistent)
#   7) تست اتصال به سرور مقصد
# =============================================================================

set -o pipefail

# ----------------------------- رنگ‌ها و لاگ‌ها -------------------------------
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'
CYAN=$'\e[36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

info()    { echo "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo "${GREEN}[ OK ]${RESET}  $*"; }
warn()    { echo "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo "${RED}[ERR ]${RESET}  $*" >&2; }
hr()      { echo "${BLUE}--------------------------------------------------------------${RESET}"; }

# ----------------------------- بررسی نیازمندی‌ها -----------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        err "این اسکریپت باید با دسترسی root اجرا شود.  مثال:  sudo bash $0"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_FAMILY="${ID_LIKE:-$ID}"
    else
        OS_ID="unknown"; OS_FAMILY="unknown"
    fi
}

install_pkg() {
    local pkg="$1"
    info "در حال نصب بسته‌ی ${pkg} ..."
    case "$OS_ID" in
        ubuntu|debian)
            DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" </dev/null
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then dnf install -y "$pkg"; else yum install -y "$pkg"; fi
            ;;
        *)
            err "توزیع لینوکس ناشناخته است ($OS_ID). لطفاً $pkg را دستی نصب کنید."
            return 1
            ;;
    esac
}

ensure_iptables() {
    if ! command -v iptables >/dev/null 2>&1; then
        warn "iptables نصب نیست. در حال نصب..."
        install_pkg iptables || { err "نصب iptables ناموفق بود."; exit 1; }
    fi
}

ensure_persistent() {
    case "$OS_ID" in
        ubuntu|debian)
            if ! dpkg -l | grep -q iptables-persistent; then
                info "نصب iptables-persistent برای ذخیره‌ی دائمی قوانین..."
                echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
                echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
                DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent </dev/null
            fi
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if ! command -v iptables-save >/dev/null 2>&1; then
                install_pkg iptables-services || true
            fi
            systemctl enable iptables >/dev/null 2>&1 || true
            ;;
    esac
}

# ----------------------------- توابع اصلی ------------------------------------
enable_ip_forward() {
    info "فعال‌سازی IP Forwarding ..."
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    if ! grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1' /etc/sysctl.conf; then
        # اگر خط هست ولی کامنت/صفر است، جایگزین کن؛ وگرنه اضافه کن
        if grep -qE '^\s*#?\s*net\.ipv4\.ip_forward' /etc/sysctl.conf; then
            sed -i 's|^\s*#\?\s*net\.ipv4\.ip_forward.*|net.ipv4.ip_forward=1|' /etc/sysctl.conf
        else
            echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
        fi
    fi
    sysctl -p >/dev/null
    ok "IP Forwarding فعال شد."
}

save_rules() {
    info "در حال ذخیره‌ی دائمی قوانین ..."
    case "$OS_ID" in
        ubuntu|debian)
            mkdir -p /etc/iptables
            iptables-save  > /etc/iptables/rules.v4
            ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
            if command -v netfilter-persistent >/dev/null 2>&1; then
                netfilter-persistent save >/dev/null 2>&1 || true
            fi
            ;;
        centos|rhel|rocky|almalinux|fedora)
            service iptables save >/dev/null 2>&1 || iptables-save > /etc/sysconfig/iptables
            ;;
        *)
            iptables-save > /root/iptables.rules
            warn "قوانین در /root/iptables.rules ذخیره شد (به‌صورت دستی restore کنید)."
            ;;
    esac
    ok "قوانین ذخیره شد."
}

validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.; read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do (( p>=0 && p<=255 )) || return 1; done
    return 0
}

validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1 && p<=65535 ))
}

ask() {
    # ask "متن سوال" "مقدار پیش‌فرض"
    local prompt="$1" default="$2" answer
    if [[ -n "$default" ]]; then
        read -r -p "${BOLD}${prompt}${RESET} [${YELLOW}${default}${RESET}]: " answer
        echo "${answer:-$default}"
    else
        read -r -p "${BOLD}${prompt}${RESET}: " answer
        echo "$answer"
    fi
}

add_forward_rule() {
    hr
    echo "${BOLD}افزودن قانون پورت فورواردینگ${RESET}"
    hr

    # آی‌پی مقصد
    local DEST_IP
    while :; do
        DEST_IP=$(ask "آی‌پی سرور مقصد (سرور خارجی - 3x-ui)" "")
        if validate_ip "$DEST_IP"; then break
        else err "آی‌پی نامعتبر است. دوباره وارد کنید."; fi
    done

    # نوع ورودی پورت
    echo
    echo "نحوه‌ی وارد کردن پورت‌ها:"
    echo "  1) یک پورت        (مثلاً 443)"
    echo "  2) چند پورت جدا با کاما (مثلاً 443,2053,8443)"
    echo "  3) رنج پورت        (مثلاً 10000:20000)"
    local MODE
    MODE=$(ask "انتخاب شما (1/2/3)" "1")

    local PORTS_INPUT
    case "$MODE" in
        1) PORTS_INPUT=$(ask "پورت" "443") ;;
        2) PORTS_INPUT=$(ask "پورت‌ها (جدا با کاما)" "443,2053,8443") ;;
        3) PORTS_INPUT=$(ask "رنج پورت  (start:end)" "10000:20000") ;;
        *) err "انتخاب نامعتبر"; return 1 ;;
    esac

    # آیا پورت مقصد در سرور خارجی همان است؟
    local DPORT_REMOTE
    DPORT_REMOTE=$(ask "پورت روی سرور مقصد همان پورت ورودی باشد؟ (y/n)" "y")

    local REMOTE_PORT=""
    if [[ "${DPORT_REMOTE,,}" == "n" ]]; then
        if [[ "$MODE" != "1" ]]; then
            warn "تغییر پورت مقصد فقط در حالت تک‌پورت پشتیبانی می‌شود. از همان پورت ورودی استفاده می‌کنیم."
        else
            while :; do
                REMOTE_PORT=$(ask "پورت روی سرور مقصد" "$PORTS_INPUT")
                validate_port "$REMOTE_PORT" && break || err "پورت نامعتبر"
            done
        fi
    fi

    # پروتکل
    echo
    echo "پروتکل:"
    echo "  1) TCP"
    echo "  2) UDP"
    echo "  3) هردو (TCP + UDP)"
    local PROTO_CHOICE
    PROTO_CHOICE=$(ask "انتخاب شما (1/2/3)" "3")
    local PROTOS=()
    case "$PROTO_CHOICE" in
        1) PROTOS=(tcp) ;;
        2) PROTOS=(udp) ;;
        3) PROTOS=(tcp udp) ;;
        *) err "انتخاب نامعتبر"; return 1 ;;
    esac

    # تشخیص اینترفیس خروجی
    local OUT_IF
    OUT_IF=$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    OUT_IF=${OUT_IF:-eth0}
    info "اینترفیس خروجی تشخیص داده شد: ${BOLD}${OUT_IF}${RESET}"

    enable_ip_forward

    # ساخت لیست پورت‌ها برای DNAT
    local DNAT_PORTSPEC=""
    case "$MODE" in
        1) DNAT_PORTSPEC="$PORTS_INPUT" ;;
        2) DNAT_PORTSPEC="$PORTS_INPUT" ;;   # multiport
        3) DNAT_PORTSPEC="$PORTS_INPUT" ;;   # range با ":"
    esac

    hr
    info "اعمال قوانین iptables ..."
    for proto in "${PROTOS[@]}"; do
        if [[ "$MODE" == "2" ]]; then
            # multiport DNAT  (نمی‌توان رنج با کاما ترکیب کرد)
            iptables -t nat -A PREROUTING -p "$proto" -m multiport --dports "$DNAT_PORTSPEC" \
                     -j DNAT --to-destination "$DEST_IP"
            iptables -t nat -A POSTROUTING -p "$proto" -d "$DEST_IP" -m multiport --dports "$DNAT_PORTSPEC" \
                     -j MASQUERADE
        elif [[ "$MODE" == "3" ]]; then
            # رنج پورت
            local START END
            START="${DNAT_PORTSPEC%:*}"; END="${DNAT_PORTSPEC#*:}"
            iptables -t nat -A PREROUTING -p "$proto" --dport "${START}:${END}" \
                     -j DNAT --to-destination "$DEST_IP"
            iptables -t nat -A POSTROUTING -p "$proto" -d "$DEST_IP" --dport "${START}:${END}" \
                     -j MASQUERADE
        else
            # تک پورت
            local TO_DEST="$DEST_IP"
            [[ -n "$REMOTE_PORT" ]] && TO_DEST="${DEST_IP}:${REMOTE_PORT}"
            iptables -t nat -A PREROUTING -p "$proto" --dport "$DNAT_PORTSPEC" \
                     -j DNAT --to-destination "$TO_DEST"
            local POST_DPORT="${REMOTE_PORT:-$DNAT_PORTSPEC}"
            iptables -t nat -A POSTROUTING -p "$proto" -d "$DEST_IP" --dport "$POST_DPORT" \
                     -j MASQUERADE
        fi
        ok "قانون $proto برای پورت(های) ${DNAT_PORTSPEC} -> ${DEST_IP} اضافه شد."
    done

    # اطمینان از POSTROUTING عمومی (MASQUERADE برای ترافیک خروجی روی اینترفیس)
    if ! iptables -t nat -C POSTROUTING -o "$OUT_IF" -j MASQUERADE 2>/dev/null; then
        iptables -t nat -A POSTROUTING -o "$OUT_IF" -j MASQUERADE
        ok "MASQUERADE روی اینترفیس $OUT_IF فعال شد."
    fi

    save_rules
    hr
    ok "تمام شد. حالا کاربران با اتصال به  ${BOLD}IP_THIS_SERVER:${DNAT_PORTSPEC}${RESET} به سرور مقصد می‌رسند."
    warn "نکته: چون از MASQUERADE استفاده می‌کنیم، سرور مقصد آی‌پی واقعی کاربر را نمی‌بیند و آی‌پی این سرور ایران را می‌بیند."
}

list_rules() {
    hr
    echo "${BOLD}قوانین جدول NAT (PREROUTING / POSTROUTING):${RESET}"
    hr
    echo "${BOLD}PREROUTING:${RESET}"
    iptables -t nat -L PREROUTING -n -v --line-numbers
    echo
    echo "${BOLD}POSTROUTING:${RESET}"
    iptables -t nat -L POSTROUTING -n -v --line-numbers
    hr
    echo "وضعیت IP Forwarding: $(sysctl -n net.ipv4.ip_forward)"
}

delete_rule() {
    list_rules
    hr
    local CHAIN NUM
    CHAIN=$(ask "نام زنجیره برای حذف (PREROUTING/POSTROUTING)" "PREROUTING")
    NUM=$(ask "شماره خط قانون (line-number)" "")
    if [[ -z "$NUM" ]]; then err "شماره وارد نشد."; return 1; fi
    iptables -t nat -D "$CHAIN" "$NUM" && ok "قانون حذف شد." || err "حذف ناموفق بود."
    save_rules
}

flush_all() {
    local CONFIRM
    CONFIRM=$(ask "آیا مطمئنید که همه‌ی قوانین NAT پاک شوند؟ (yes/no)" "no")
    if [[ "${CONFIRM,,}" == "yes" ]]; then
        iptables -t nat -F
        iptables -t nat -X 2>/dev/null || true
        ok "همه‌ی قوانین NAT پاک شدند."
        save_rules
    else
        info "لغو شد."
    fi
}

test_dest() {
    local IP PORT
    IP=$(ask "آی‌پی سرور مقصد برای تست" "")
    PORT=$(ask "پورت برای تست" "443")
    if ! validate_ip "$IP" || ! validate_port "$PORT"; then
        err "ورودی نامعتبر"; return 1
    fi
    info "تست اتصال TCP به ${IP}:${PORT} ..."
    if command -v nc >/dev/null 2>&1; then
        if timeout 5 nc -zv "$IP" "$PORT" 2>&1; then ok "اتصال برقرار شد."; else err "ناموفق."; fi
    else
        if timeout 5 bash -c "</dev/tcp/$IP/$PORT" 2>/dev/null; then ok "اتصال برقرار شد."; else err "ناموفق."; fi
    fi
}

show_summary() {
    local THIS_IP
    THIS_IP=$(ip -4 addr show scope global 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n1)
    hr
    echo "${BOLD}${GREEN} iptables Port-Forward Manager ${RESET}"
    echo "${BOLD} آی‌پی این سرور:${RESET} ${YELLOW}${THIS_IP:-?}${RESET}"
    echo "${BOLD} IP Forwarding:${RESET} $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
    echo "${BOLD} OS:${RESET} ${OS_ID}"
    hr
}

main_menu() {
    while :; do
        show_summary
        echo " 1) افزودن قانون فوروارد جدید"
        echo " 2) نمایش قوانین فعلی"
        echo " 3) حذف یک قانون"
        echo " 4) پاک‌کردن همه‌ی قوانین NAT"
        echo " 5) تست اتصال به سرور مقصد"
        echo " 6) ذخیره‌ی دستی قوانین"
        echo " 0) خروج"
        hr
        local CH
        CH=$(ask "انتخاب شما" "1")
        case "$CH" in
            1) add_forward_rule ;;
            2) list_rules ;;
            3) delete_rule ;;
            4) flush_all ;;
            5) test_dest ;;
            6) save_rules ;;
            0) info "خداحافظ!"; exit 0 ;;
            *) err "گزینه‌ی نامعتبر" ;;
        esac
        echo; read -r -p "$(echo -e ${CYAN}برای ادامه Enter بزنید...${RESET})" _
    done
}

# ----------------------------- اجرای اصلی -----------------------------------
require_root
detect_os
ensure_iptables
ensure_persistent
main_menu
