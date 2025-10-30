#!/bin/sh
# shellcheck shell=dash

REPO="https://api.github.com/repos/itdoginfo/podkop/releases/latest"
DOWNLOAD_DIR="/tmp/podkop"
COUNT=3

# Cached flag to switch between ipk or apk package managers
PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

msg() {
    printf "\033[32;1m%s\033[0m\n" "$1"
}

pkg_is_installed () {
    local pkg_name="$1"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed | grep -q "$pkg_name"
    else
        opkg list-installed | grep -q "$pkg_name"
    fi
}

pkg_remove() {
    local pkg_name="$1"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk del "$pkg_name"
    else
        opkg remove --force-depends "$pkg_name"
    fi
}

pkg_list_update() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk update
    else
        opkg update
    fi
}

pkg_install() {
    local pkg_file="$1"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$pkg_file"
    else
        opkg install "$pkg_file"
    fi
}

update_config() {
    printf "\033[48;5;196m\033[1m╔══════════════════════════════════════════════════════════════════════╗\033[0m\n"
    printf "\033[48;5;196m\033[1m║ ! Обнаружена старая версия podkop.                                   ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Если продолжите обновление, потребуется настроить Podkop заново.     ║\033[0m\n"
    printf "\033[48;5;196m\033[1m║ Старая конфигурация будет сохранена в /etc/config/podkop-070         ║\033[0m\n"
    printf "\033[48;5;196m\033[1m╚══════════════════════════════════════════════════════════════════════╝\033[0m\n"
    msg "Продолжить? (yes/no)"
    while true; do
        read -r CONFIG_UPDATE
        case $CONFIG_UPDATE in
            yes|y|Y)
                mv /etc/config/podkop /etc/config/podkop-070 2>/dev/null
                wget -O /etc/config/podkop https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/podkop/files/etc/config/podkop
                msg "Конфиг Podkop сброшен. Старая версия сохранена в /etc/config/podkop-070"
                break
                ;;
            *)
                msg "Выход"
                exit 1
                ;;
        esac
    done
}

check_system() {
    MODEL=$(cat /tmp/sysinfo/model)
    msg "Router model: $MODEL"

    openwrt_version=$(grep DISTRIB_RELEASE /etc/openwrt_release | cut -d"'" -f2 | cut -d'.' -f1)
    if [ "$openwrt_version" = "23" ]; then
        msg "OpenWrt 23.05 не поддерживается начиная с podkop 0.5.0"
        exit 1
    fi

    AVAILABLE_SPACE=$(df /overlay | awk 'NR==2 {print $4}')
    REQUIRED_SPACE=15360
    if [ "$AVAILABLE_SPACE" -lt "$REQUIRED_SPACE" ]; then
        msg "Недостаточно места на флеше"
        exit 1
    fi

    if ! nslookup google.com >/dev/null 2>&1; then
        msg "DNS не работает"
        exit 1
    fi
}

check_podkop_version() {
    if command -v podkop >/dev/null 2>&1; then
        version=$(/usr/bin/podkop show_version 2>/dev/null | sed 's/^v//')
        [ -z "$version" ] && { update_config; return; }

        major=$(echo "$version" | cut -d. -f1)
        minor=$(echo "$version" | cut -d. -f2)
        patch=$(echo "$version" | cut -d. -f3)

        if [ "$major" -lt 1 ] && [ "$minor" -lt 7 ]; then
            update_config
        fi
    fi
}

sing_box_check() {
    if ! pkg_is_installed "^sing-box"; then
        return
    fi
    sing_box_version=$(sing-box version | head -n1 | awk '{print $3}')
    required_version="1.12.4"
    if [ "$(printf '%s\n%s\n' "$sing_box_version" "$required_version" | sort -V | head -n1)" != "$required_version" ]; then
        msg "Обновляем sing-box..."
        service podkop stop 2>/dev/null
        pkg_remove sing-box
        pkg_install sing-box || { msg "Ошибка обновления sing-box"; exit 1; }
    fi
}

download_release_files() {
    msg "Загружаем пакеты podkop..."
    local grep_url_pattern
    [ "$PKG_IS_APK" -eq 1 ] && grep_url_pattern='https://[^"[:space:]]*\.apk' || grep_url_pattern='https://[^"[:space:]]*\.ipk'

    wget -qO- "$REPO" | grep -o "$grep_url_pattern" | while read -r url; do
        filename=$(basename "$url")
        filepath="$DOWNLOAD_DIR/$filename"
        attempt=0
        while [ $attempt -lt $COUNT ]; do
            msg "Пробуем скачать $filename (попытка $((attempt+1)))..."
            if wget -q -O "$filepath" "$url"; then
                [ -s "$filepath" ] && { msg "$filename скачан успешно"; break; }
            fi
            rm -f "$filepath"
            attempt=$((attempt+1))
        done
        [ $attempt -eq $COUNT ] && { msg "Ошибка: не удалось скачать $filename"; exit 1; }
    done

    ls "$DOWNLOAD_DIR"/*podkop* >/dev/null 2>&1 || { msg "Ошибка: не удалось загрузить релиз с GitHub"; exit 1; }
}

install_packages() {
    for pkg in podkop luci-app-podkop; do
        for f in "$DOWNLOAD_DIR"/"$pkg"*; do
            [ -f "$f" ] || continue
            msg "Устанавливаем $(basename "$f")..."
            pkg_install "$f" || { msg "Ошибка установки $f"; exit 1; }
            sleep 2
        done
    done
}

main() {
    check_system

    pkg_list_update || {
        msg "❌ Проблема доступности репозиториев. Повторите позже или проверьте distfeeds.conf"
        exit 1
    }

    download_release_files
    sing_box_check
    check_podkop_version
    install_packages

    msg "✅ Установка podkop завершена успешно!"
}

main
