#!/bin/bash

set -e

BACKUP="$HOME/rpi-migration-$(date +%Y-%m-%d-%H%M)"

mkdir -p "$BACKUP"

echo
echo "=========================================="
echo " Raspberry Pi MIGRATION BACKUP"
echo "=========================================="
echo
echo "Backup: $BACKUP"
echo

# ==================================================
# SYSTEM
# ==================================================

echo "==> Informacje o systemie..."

uname -a > "$BACKUP/system-info.txt"
cat /etc/os-release >> "$BACKUP/system-info.txt"
dpkg --print-architecture >> "$BACKUP/system-info.txt"

dpkg --get-selections > "$BACKUP/packages.txt"

# ==================================================
# WWW
# ==================================================

echo
echo "==> Backup /var/www..."

sudo tar czpf "$BACKUP/www.tar.gz" /var/www

# ==================================================
# APACHE
# ==================================================

echo
echo "==> Backup Apache..."

sudo tar czpf "$BACKUP/apache2.tar.gz" /etc/apache2

# ==================================================
# PHP
# ==================================================

echo
echo "==> Backup PHP..."

if [ -d /etc/php ]; then
    sudo tar czpf "$BACKUP/php.tar.gz" /etc/php
fi

php -v > "$BACKUP/php-version.txt" 2>&1 || true
php -m > "$BACKUP/php-modules.txt" 2>&1 || true

# ==================================================
# PYTHON (pip)
# ==================================================
#
# dpkg/packages.txt widzi tylko pakiety apt - moduły doinstalowane przez
# pip (np. do obsługi czujników, MySQL z poziomu Pythona) w ogóle się tam
# nie pojawiają i restore.sh by o nich nie wiedział.

echo
echo "==> Backup pakietów Python (pip)..."

pip3 freeze > "$BACKUP/pip-freeze.txt" 2>/dev/null || true

# ==================================================
# MARIADB
# ==================================================

echo
echo "==> Backup MariaDB..."

# --events wymaga event schedulera co najmniej w stanie OFF (nie
# DISABLED); gdy jest DISABLED na starcie serwera, nawet samo sprawdzenie
# listy zdarzeń zwraca błąd i nie da się tego przełączyć w locie (trzeba
# by zmienić config i zrestartować MariaDB). Żeby backup nie zależał od
# tego ustawienia na serwerze, po prostu nie dumpujemy EVENT-ów -
# --routines/--triggers (procedury, funkcje, triggery) zostają.
sudo mysqldump \
    --all-databases \
    --single-transaction \
    --routines \
    --triggers \
    > "$BACKUP/databases.sql"

mysql --version > "$BACKUP/mysql-version.txt" 2>&1 || true

# Konfiguracja serwera (np. niestandardowy port) - OSOBNA rzecz od samego
# zrzutu danych powyżej. debian.cnf wykluczamy celowo: zawiera hasło konta
# konserwacyjnego (debian-sys-maint) powiązane z bazą `mysql`, której i tak
# świadomie nie przywracamy (patrz restore.sh) - podstawienie starego pliku
# rozjechałoby się z nowym, świeżo wygenerowanym kontem.
if [ -d /etc/mysql ]; then
    sudo tar czpf "$BACKUP/mysql-config.tar.gz" \
        --exclude='etc/mysql/debian.cnf' \
        /etc/mysql
fi

# ==================================================
# CRON
# ==================================================

echo
echo "==> Backup cron..."

crontab -l > "$BACKUP/crontab-user.txt" 2>/dev/null || true
sudo crontab -l > "$BACKUP/crontab-root.txt" 2>/dev/null || true

# Zadania cykliczne poza crontabami użytkowników (np. dla www-data, które
# nie ma własnego loginu/crontaba w normalnym sensie) - żyją jako pliki w
# /etc/cron.d, każdy z nazwą usera wpisaną wprost w linii. Łatwo je pominąć,
# bo "crontab -l" ich w ogóle nie pokazuje.
if [ -d /etc/cron.d ]; then
    sudo tar czpf "$BACKUP/cron.d.tar.gz" /etc/cron.d
fi

# ==================================================
# SSH USER
# ==================================================

echo
echo "==> Backup SSH użytkownika..."

if [ -d "$HOME/.ssh" ]; then

    tar czpf "$BACKUP/user-ssh.tar.gz" \
        -C "$HOME" .ssh

fi

# ==================================================
# SSH SERVER CONFIG
# ==================================================

echo
echo "==> Backup SSH server..."

sudo tar czpf "$BACKUP/ssh-config.tar.gz" /etc/ssh

# ==================================================
# LET'S ENCRYPT
# ==================================================

echo
echo "==> Backup Let's Encrypt..."

if [ -d /etc/letsencrypt ]; then

    sudo tar czpf "$BACKUP/letsencrypt.tar.gz" \
        /etc/letsencrypt

fi

# ==================================================
# VPN (OpenVPN / WireGuard / Tailscale / ZeroTier)
# ==================================================

echo
echo "==> Backup VPN..."

# OpenVPN
if [ -d /etc/openvpn ]; then
    sudo tar czpf "$BACKUP/openvpn.tar.gz" /etc/openvpn

    # Pliki w /etc/openvpn (np. crl.pem) są własnością systemowego usera
    # "openvpn" z konkretnym UID/GID - pakiet openvpn na nowym systemie
    # może go nie utworzyć automatycznie. Zapisujemy UID/GID, żeby restore
    # mógł odtworzyć tego samego usera i uniknąć rozjazdu uprawnień.
    getent passwd openvpn > "$BACKUP/openvpn-user.txt" 2>/dev/null || true
    getent group openvpn >> "$BACKUP/openvpn-user.txt" 2>/dev/null || true
fi

# WireGuard
if [ -d /etc/wireguard ]; then
    sudo tar czpf "$BACKUP/wireguard.tar.gz" /etc/wireguard
fi

# Tailscale (stan węzła / klucz maszyny)
if [ -d /var/lib/tailscale ]; then
    sudo tar czpf "$BACKUP/tailscale.tar.gz" /var/lib/tailscale
fi
tailscale status > "$BACKUP/tailscale-status.txt" 2>&1 || true

# ZeroTier (tożsamość węzła i sieci)
if [ -d /var/lib/zerotier-one ]; then
    sudo tar czpf "$BACKUP/zerotier-one.tar.gz" /var/lib/zerotier-one
fi
sudo zerotier-cli listnetworks > "$BACKUP/zerotier-networks.txt" 2>&1 || true

# ==================================================
# SIEĆ (WiFi / statyczny IP / firewall / fail2ban / hostname)
# ==================================================

echo
echo "==> Backup konfiguracji sieciowej..."

# WiFi
if [ -f /etc/wpa_supplicant/wpa_supplicant.conf ]; then
    sudo cp /etc/wpa_supplicant/wpa_supplicant.conf "$BACKUP/wpa_supplicant.conf"
fi

# Statyczny IP
if [ -f /etc/dhcpcd.conf ]; then
    sudo cp /etc/dhcpcd.conf "$BACKUP/dhcpcd.conf"
fi

# Firewall (netfilter-persistent / iptables)
if [ -d /etc/iptables ]; then
    sudo tar czpf "$BACKUP/iptables.tar.gz" /etc/iptables
fi

# fail2ban
if [ -d /etc/fail2ban ]; then
    sudo tar czpf "$BACKUP/fail2ban.tar.gz" /etc/fail2ban
fi

# Hostname / hosts
sudo cp /etc/hostname "$BACKUP/hostname"
sudo cp /etc/hosts "$BACKUP/hosts"

# ==================================================
# BOOT CONFIG (I2C / SPI / dtoverlay - Raspberry Pi)
# ==================================================
#
# Ustawienia typu "dtparam=i2c_arm=on" (czujniki na I2C/SPI) żyją w
# /boot/firmware/config.txt (starsze systemy: /boot/config.txt) - to nie
# pakiet ani config usługi, tylko firmware/device-tree, więc żadna inna
# sekcja tego nie obejmuje.

echo
echo "==> Backup /boot/firmware/config.txt..."

if [ -f /boot/firmware/config.txt ]; then
    sudo cp /boot/firmware/config.txt "$BACKUP/boot-config.txt"
elif [ -f /boot/config.txt ]; then
    sudo cp /boot/config.txt "$BACKUP/boot-config.txt"
fi

# ==================================================
# FSTAB
# ==================================================

echo
echo "==> Backup fstab..."

sudo cp /etc/fstab "$BACKUP/fstab"

# ==================================================
# SAMBA
# ==================================================

echo
echo "==> Backup Samba..."

if [ -d /etc/samba ]; then

    sudo tar czpf "$BACKUP/samba.tar.gz" \
        /etc/samba

fi

# Baza kont/haseł SMB - CAŁKOWICIE osobna od /etc/samba i od kont Linuksa.
# Bez niej Windows nie ma się jak uwierzytelnić do share'a, mimo że sam
# config (kto/co jest udostępnione) już działa.
# UWAGA BEZPIECZEŃSTWO: ten plik zawiera hashe haseł SMB - traktuj folder
# backupu jako wrażliwy, tak samo jak wpa_supplicant.conf.
if [ -d /var/lib/samba/private ]; then
    sudo tar czpf "$BACKUP/samba-private.tar.gz" /var/lib/samba/private
fi

# ==================================================
# SYSTEMD - WŁASNE JEDNOSTKI
# ==================================================
#
# Dowolne pliki .service dodane ręcznie w /etc/systemd/system (nie
# symlinki do /lib|/usr/lib - to są jednostki z pakietów, już wracają
# same z apt). Wcześniej backupowaliśmy tylko qbittorrent-nox.service na
# sztywno, ale na starym systemie realną, włączoną jednostką była inna,
# niebackupowana nazwa (qbittorrent.service) - stąd generyczne podejście:
# łapiemy wszystko co faktycznie jest plikiem, a nie linkiem.

echo
echo "==> Backup własnych jednostek systemd..."

mkdir -p "$BACKUP/systemd-units"

find /etc/systemd/system -maxdepth 1 -name "*.service" -type f 2>/dev/null | while read -r unit; do
    sudo cp "$unit" "$BACKUP/systemd-units/"
done

# ==================================================
# QBITTORRENT
# ==================================================

echo
echo "==> Backup qBittorrent..."

if command -v qbittorrent-nox >/dev/null 2>&1; then

    # Konfiguracja
    if [ -d "$HOME/.config/qBittorrent" ]; then

        tar czpf "$BACKUP/qbittorrent-config.tar.gz" \
            -C "$HOME" .config/qBittorrent

    fi

    # Dane / stan torrentów
    if [ -d "$HOME/.local/share/data/qBittorrent" ]; then

        tar czpf "$BACKUP/qbittorrent-data.tar.gz" \
            -C "$HOME" .local/share/data/qBittorrent

    fi

    # Cache
    if [ -d "$HOME/.cache/qBittorrent" ]; then

        tar czpf "$BACKUP/qbittorrent-cache.tar.gz" \
            -C "$HOME" .cache/qBittorrent

    fi

    # Systemd service - patrz sekcja "SYSTEMD - WŁASNE JEDNOSTKI" wyżej,
    # łapie każdą jednostkę .service niezależnie od jej nazwy.

    # Informacje
    {
        echo "=== qBittorrent ==="
        qbittorrent-nox --version 2>/dev/null || true

        echo
        echo "=== Service ==="
        systemctl status qbittorrent-nox --no-pager || true

        echo
        echo "=== Process ==="
        ps aux | grep -i qbittorrent | grep -v grep || true

        echo
        echo "=== Paths ==="
        grep -E 'SavePath|TempPath' \
            "$HOME/.config/qBittorrent/qBittorrent.conf" \
            2>/dev/null || true

    } > "$BACKUP/qbittorrent-info.txt"

fi

# ==================================================
# EXTERNAL DISK INFO
# ==================================================

echo
echo "==> Informacje o dysku zewnętrznym..."

findmnt /mnt/external \
    > "$BACKUP/external-disk.txt"

lsblk -f \
    >> "$BACKUP/external-disk.txt"

# NIE kopiujemy /mnt/external.
# Ten sam fizyczny dysk zostanie przełożony do nowego RPi.

# ==================================================
# SERVICES
# ==================================================

echo
echo "==> Lista usług..."

systemctl list-unit-files --state=enabled \
    > "$BACKUP/enabled-services.txt"

# ==================================================
# SUDOERS.D
# ==================================================
#
# Własne reguły NOPASSWD (np. dla dashboardu administracyjnego działającego
# jako www-data, żeby mógł odpytywać fail2ban-client/logi/certy bez hasła).
# Bez tego appka na nowym systemie milczy tam, gdzie potrzebuje uprawnień
# roota, mimo że sama usługa działa poprawnie.

echo
echo "==> Backup /etc/sudoers.d..."

if [ -d /etc/sudoers.d ]; then
    sudo tar czpf "$BACKUP/sudoers.d.tar.gz" /etc/sudoers.d
fi

# ==================================================
# GRUPY DODATKOWE www-data
# ==================================================
#
# Np. członkostwo w grupie "adm" daje www-data prawo czytania /var/log/*
# (potrzebne dashboardom czytającym logi bezpośrednio z plików).

echo "==> Zapisywanie dodatkowych grup www-data..."

groups www-data 2>/dev/null | cut -d: -f2 > "$BACKUP/www-data-groups.txt" || true

# ==================================================
# OWNERSHIP
# ==================================================

sudo chown -R "$USER:$USER" "$BACKUP"

# ==================================================
# SUMMARY
# ==================================================

echo
echo "=========================================="
echo " BACKUP ZAKOŃCZONY"
echo "=========================================="
echo
echo "Backup:"
echo "$BACKUP"
echo
du -sh "$BACKUP"
echo
echo "Zawartość:"
ls -lh "$BACKUP"

echo
echo "=========================================="
echo " WAŻNE"
echo "=========================================="
echo
echo "Dysk /mnt/external NIE został skopiowany."
echo "Przełóż ten sam dysk do nowego RPi."
echo
echo "UUID dysku:"
grep UUID "$BACKUP/fstab" || true
echo
