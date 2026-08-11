#!/bin/bash

set -e

if [ -n "$1" ]; then
    BACKUP="$1"
else
    BACKUP=$(ls -d "$HOME"/rpi-migration-* 2>/dev/null | sort | tail -n1)
fi

if [ -z "$BACKUP" ] || [ ! -d "$BACKUP" ]; then
    echo "Nie znaleziono katalogu backupu."
    echo "Użycie: $0 /sciezka/do/rpi-migration-YYYY-MM-DD-HHMM"
    exit 1
fi

LOG="$HOME/restore-$(date +%Y-%m-%d-%H%M).log"
exec > >(tee "$LOG") 2>&1
echo "Log: $LOG"

echo
echo "=========================================="
echo " Raspberry Pi MIGRATION RESTORE"
echo "=========================================="
echo
echo "Backup: $BACKUP"
echo

# ==================================================
# PAKIETY
# ==================================================
#
# UWAGA: packages.txt pochodzi ze starego systemu (32-bit/inne wydanie)
# i zawiera nazwy pakietów przypięte do tamtej wersji (np. php7.4,
# mariadb-client-10.5, sufiksy :armhf) - na nowym wydaniu/architekturze
# te nazwy zwykle nie istnieją, a apt-get install z choć jedną złą nazwą
# przerywa CAŁĄ instalację. Dlatego instalujemy jawną listę pakietów pod
# generycznymi nazwami (bez wersji), odpowiadającą usługom z
# enabled-services.txt / qbittorrent / VPN. Sprawdź czy nic nie brakuje
# względem $BACKUP/packages.txt, jeśli masz dodatkowe niestandardowe usługi.

echo "==> Instalacja kluczowych pakietów..."

sudo apt-get update

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::="--force-confold" \
    apache2 \
    mariadb-server \
    php php-cli libapache2-mod-php php-mysql php-gd php-mbstring \
    php-xml php-curl php-zip php-sqlite3 php-bz2 php-opcache php-readline \
    python3 python3-pip python3-smbus i2c-tools \
    samba \
    qbittorrent-nox \
    phpmyadmin \
    openvpn wireguard wireguard-tools \
    fail2ban iptables-persistent netfilter-persistent \
    certbot python3-certbot-apache \
    rsyslog acl wtmpdb \
    || true

# ==================================================
# PYTHON (pip)
# ==================================================
#
# Moduły spoza apt (np. sterowniki czujników, konektory do MySQL z
# poziomu Pythona) - packages.txt/apt ich nie widzi. UWAGA: wersje
# zamrożone w pip-freeze.txt mogą nie mieć gotowych wheeli dla nowej
# architektury/wersji Pythona - stąd || true, sprawdź ręcznie co nie
# wgrało się poprawnie.

echo
echo "==> Instalacja pakietów Python (pip)..."

if [ -f "$BACKUP/pip-freeze.txt" ]; then
    sudo pip3 install -r "$BACKUP/pip-freeze.txt" --break-system-packages || true
fi

# Tailscale - własne repo, nie ma go w domyślnych źródłach Debiana
if ! command -v tailscale >/dev/null 2>&1; then
    echo "==> Dodawanie repo Tailscale..."
    CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
        | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.tailscale-keyring.list" \
        | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y tailscale || true
fi

# ZeroTier - oficjalny skrypt instalacyjny
if ! command -v zerotier-cli >/dev/null 2>&1; then
    echo "==> Instalacja ZeroTier..."
    curl -s https://install.zerotier.com | sudo bash || true
fi

# ==================================================
# WWW
# ==================================================

echo
echo "==> Przywracanie /var/www..."

if [ -f "$BACKUP/www.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/www.tar.gz" -C /
fi

# ==================================================
# APACHE
# ==================================================

echo
echo "==> Przywracanie Apache..."

if [ -f "$BACKUP/apache2.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/apache2.tar.gz" -C /
fi

# ==================================================
# PHP
# ==================================================

echo
echo "==> Przywracanie PHP..."

if [ -f "$BACKUP/php.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/php.tar.gz" -C /
fi

# ==================================================
# APACHE MPM (dokończenie konfiguracji po konflikcie modułów)
# ==================================================
#
# apache2.tar.gz (wyżej) przywraca stary config ze starego systemu,
# w którym mpm_prefork był już ręcznie włączony (wymagany przez
# mod_php). Świeżo zainstalowany pakiet apache2 ma jeszcze
# niedokończoną konfigurację (postinst chce enable'ować swój domyślny
# mpm_event) i odmawia się skonfigurować, dopóki widzi "obcy" już
# włączony mpm_prefork - trzeba go przeprowadzić przez to w dwóch
# krokach: najpierw pozwolić dokończyć konfigurację na jego defaultcie,
# potem ręcznie wrócić na prefork + włączyć moduł php.
#
# Dodatkowo apache2.tar.gz może zawierać osierocone wpisy modułów php
# z innej wersji niż faktycznie zainstalowana (np. php8.3 gdy tu jest
# php8.4) - trzeba je zdjąć, bo blokują wyłączenie prefork.

echo
echo "==> Naprawa modułu MPM Apache..."

if [ -d /etc/apache2/mods-enabled ]; then

    PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)

    # Zdejmij osierocone moduły php (inne wersje niż zainstalowana)
    for f in /etc/apache2/mods-enabled/php*.load; do
        [ -e "$f" ] || continue
        MOD=$(basename "$f" .load)
        if [ "$MOD" != "php$PHP_VER" ]; then
            sudo a2dismod "$MOD" || true
        fi
    done

    # Krok 1: pozwól apache2 dokończyć konfigurację na swoim defaultcie
    sudo a2dismod mpm_prefork || true
    sudo a2enmod mpm_event || true
    sudo apt-get -f install -y || true
    sudo dpkg --configure -a || true

    # Krok 2: wróć na prefork (wymagany przez mod_php) + włącz moduł php
    sudo a2dismod mpm_event || true
    sudo a2enmod mpm_prefork || true
    if [ -n "$PHP_VER" ]; then
        sudo a2enmod "php$PHP_VER" || true
    fi

    sudo apache2ctl configtest || true
fi

# ==================================================
# MARIADB
# ==================================================

echo
echo "==> Przywracanie baz danych..."

if [ -f "$BACKUP/databases.sql" ]; then

    # Zrzut (--all-databases) zawiera też systemową bazę `mysql` z INNEJ
    # wersji MariaDB niż ta na nowym systemie - bezpośredni import psuje
    # tabele systemowe (mysql.proc itp.). Wycinamy mysql/sys/
    # performance_schema/information_schema, zostają tylko realne bazy
    # aplikacji. UWAGA: konta/uprawnienia MySQL ze starego serwera NIE
    # zostaną przez to odtworzone - trzeba je założyć ręcznie (patrz
    # podsumowanie na końcu skryptu).

    awk '
        /^-- Current Database: `/ {
            skip = ($0 ~ /`(mysql|sys|performance_schema|information_schema)`/) ? 1 : 0
        }
        { if (!skip) print }
    ' "$BACKUP/databases.sql" > /tmp/databases-clean.sql

    sudo mysql < /tmp/databases-clean.sql
    rm -f /tmp/databases-clean.sql

fi

# Konfiguracja serwera (np. niestandardowy port) - odtwarzana OSOBNO od
# samych danych. debian.cnf świadomie NIE jest w tym archiwum (patrz
# backup.sh) - zostaje świeżo wygenerowany, pasujący do konta
# debian-sys-maint, które i tak nie zostało odtworzone z bazy systemowej.
if [ -f "$BACKUP/mysql-config.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/mysql-config.tar.gz" -C /
    sudo systemctl restart mariadb || true
fi

# ==================================================
# CRON
# ==================================================

echo
echo "==> Przywracanie cron..."

if [ -s "$BACKUP/crontab-user.txt" ]; then
    crontab "$BACKUP/crontab-user.txt"
fi

if [ -s "$BACKUP/crontab-root.txt" ]; then
    sudo crontab "$BACKUP/crontab-root.txt"
fi

# Zadania cykliczne spoza crontabów użytkowników (np. dla www-data) -
# pliki w /etc/cron.d, z nazwą usera wpisaną wprost w każdej linii.
if [ -f "$BACKUP/cron.d.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/cron.d.tar.gz" -C /
fi

# ==================================================
# SSH UŻYTKOWNIKA
# ==================================================

echo
echo "==> Przywracanie SSH użytkownika..."

if [ -f "$BACKUP/user-ssh.tar.gz" ]; then
    tar xzpf "$BACKUP/user-ssh.tar.gz" -C "$HOME"
    chmod 700 "$HOME/.ssh"
    chmod 600 "$HOME"/.ssh/* 2>/dev/null || true
fi

# ==================================================
# SSH SERVER CONFIG
# ==================================================

echo
echo "==> Przywracanie SSH server..."

if [ -f "$BACKUP/ssh-config.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/ssh-config.tar.gz" -C /
fi

# ==================================================
# LET'S ENCRYPT
# ==================================================

echo
echo "==> Przywracanie Let's Encrypt..."

if [ -f "$BACKUP/letsencrypt.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/letsencrypt.tar.gz" -C /
fi

# ==================================================
# VPN (OpenVPN / WireGuard / Tailscale / ZeroTier)
# ==================================================

echo
echo "==> Przywracanie VPN..."

if [ -f "$BACKUP/openvpn.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/openvpn.tar.gz" -C /

    # Pliki (np. crl.pem) należą do konkretnego UID/GID starego systemu -
    # pakiet openvpn może nie utworzyć usera "openvpn" automatycznie.
    # Odtwarzamy go z tym samym UID/GID jeśli wolne, żeby uprawnienia się
    # zgadzały bez ręcznego chown.
    if [ -f "$BACKUP/openvpn-user.txt" ] && ! id openvpn >/dev/null 2>&1; then
        OLD_UID=$(awk -F: '/^openvpn:/{print $3}' "$BACKUP/openvpn-user.txt")
        sudo groupadd --system openvpn 2>/dev/null || true
        if [ -n "$OLD_UID" ] && ! getent passwd "$OLD_UID" >/dev/null; then
            sudo useradd -u "$OLD_UID" -g openvpn -r -M -s /usr/sbin/nologin openvpn 2>/dev/null || true
        else
            sudo useradd --system --no-create-home --shell /usr/sbin/nologin --gid openvpn openvpn 2>/dev/null || true
        fi
    fi
    sudo chown -R openvpn:openvpn /etc/openvpn/crl.pem 2>/dev/null || true
fi

if [ -f "$BACKUP/wireguard.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/wireguard.tar.gz" -C /
    sudo chmod 600 /etc/wireguard/*.conf 2>/dev/null || true
fi

if [ -f "$BACKUP/tailscale.tar.gz" ]; then
    sudo systemctl stop tailscaled 2>/dev/null || true
    sudo tar xzpf "$BACKUP/tailscale.tar.gz" -C /
fi

if [ -f "$BACKUP/zerotier-one.tar.gz" ]; then
    sudo systemctl stop zerotier-one 2>/dev/null || true
    sudo tar xzpf "$BACKUP/zerotier-one.tar.gz" -C /
fi

# ==================================================
# SIEĆ (WiFi / statyczny IP / firewall / fail2ban / hostname)
# ==================================================

echo
echo "==> Przywracanie konfiguracji sieciowej..."

if [ -f "$BACKUP/wpa_supplicant.conf" ]; then
    sudo mkdir -p /etc/wpa_supplicant
    sudo cp "$BACKUP/wpa_supplicant.conf" /etc/wpa_supplicant/wpa_supplicant.conf
fi

if [ -f "$BACKUP/dhcpcd.conf" ]; then
    sudo cp "$BACKUP/dhcpcd.conf" /etc/dhcpcd.conf
fi

if [ -f "$BACKUP/iptables.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/iptables.tar.gz" -C /
fi

if [ -f "$BACKUP/fail2ban.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/fail2ban.tar.gz" -C /
fi

if [ -f "$BACKUP/hostname" ]; then
    echo "Aktualny hostname:   $(cat /etc/hostname)"
    echo "Hostname z backupu:  $(cat "$BACKUP/hostname")"
    read -p "Ustawić hostname z backupu? [t/N] " ans
    if [ "$ans" = "t" ] || [ "$ans" = "T" ]; then
        sudo hostnamectl set-hostname "$(cat "$BACKUP/hostname")"
    fi
fi

if [ -f "$BACKUP/hosts" ]; then
    sudo cp "$BACKUP/hosts" /etc/hosts
fi

# ==================================================
# BOOT CONFIG (I2C / SPI / dtoverlay)
# ==================================================
#
# Dopisujemy TYLKO brakujące linie dtparam=/dtoverlay= (nie nadpisujemy
# całego pliku - nowy system/model Pi może mieć własne, inne domyślne
# wpisy, których nie chcemy stracić). Wymaga rebootu, żeby zadziałało.

echo
echo "==> Scalanie /boot/firmware/config.txt..."

if [ -f "$BACKUP/boot-config.txt" ]; then
    CFG=/boot/firmware/config.txt
    [ -f "$CFG" ] || CFG=/boot/config.txt

    grep -E '^dtparam=|^dtoverlay=' "$BACKUP/boot-config.txt" 2>/dev/null | while read -r line; do
        grep -qxF "$line" "$CFG" 2>/dev/null || echo "$line" | sudo tee -a "$CFG" > /dev/null
    done

    # I2C potrzebuje też załadowanego modułu i2c-dev, żeby powstał /dev/i2c-*
    if grep -q '^dtparam=i2c_arm=on' "$CFG" 2>/dev/null; then
        grep -qxF "i2c-dev" /etc/modules 2>/dev/null || echo "i2c-dev" | sudo tee -a /etc/modules > /dev/null
    fi

    echo "Uwaga: zmiany w config.txt (I2C/SPI) wymagają restartu systemu."
fi

# ==================================================
# FSTAB (tylko wpis dysku zewnętrznego)
# ==================================================

echo
echo "==> Dopisywanie wpisu /mnt/external do fstab..."

if [ -f "$BACKUP/fstab" ]; then
    sudo mkdir -p /mnt/external
    grep external "$BACKUP/fstab" | while read -r line; do
        UUID=$(echo "$line" | awk '{print $1}')
        if ! grep -q "$UUID" /etc/fstab; then
            echo "$line" | sudo tee -a /etc/fstab > /dev/null
        fi
    done
fi

echo "Pamiętaj: przełóż fizyczny dysk zewnętrzny do nowego RPi przed 'sudo mount -a'."

# ==================================================
# SAMBA
# ==================================================

echo
echo "==> Przywracanie Samba..."

if [ -f "$BACKUP/samba.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/samba.tar.gz" -C /
fi

# Baza kont/haseł SMB - bez tego Windows nie ma się jak uwierzytelnić,
# mimo że sam config share'ów już działa (osobny system haseł od Linuksa).
if [ -f "$BACKUP/samba-private.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/samba-private.tar.gz" -C /
    sudo systemctl restart smbd nmbd || true
fi

# ==================================================
# SYSTEMD - WŁASNE JEDNOSTKI
# ==================================================

echo
echo "==> Przywracanie własnych jednostek systemd..."

if [ -d "$BACKUP/systemd-units" ]; then
    sudo cp "$BACKUP"/systemd-units/*.service /etc/systemd/system/ 2>/dev/null || true
    sudo systemctl daemon-reload
fi

# ==================================================
# QBITTORRENT
# ==================================================

echo
echo "==> Przywracanie qBittorrent..."

if [ -f "$BACKUP/qbittorrent-config.tar.gz" ]; then
    tar xzpf "$BACKUP/qbittorrent-config.tar.gz" -C "$HOME"
fi

if [ -f "$BACKUP/qbittorrent-data.tar.gz" ]; then
    tar xzpf "$BACKUP/qbittorrent-data.tar.gz" -C "$HOME"
fi

if [ -f "$BACKUP/qbittorrent-cache.tar.gz" ]; then
    tar xzpf "$BACKUP/qbittorrent-cache.tar.gz" -C "$HOME"
fi

# (jednostka systemd qBittorrenta wraca już przez sekcję "SYSTEMD - WŁASNE
# JEDNOSTKI" wyżej, niezależnie od jej nazwy)

# ==================================================
# WŁAŚCICIEL PLIKÓW UŻYTKOWNIKA
# ==================================================

echo
echo "==> Ustawianie właściciela plików użytkownika..."

sudo chown -R "$USER:$USER" \
    "$HOME/.ssh" \
    "$HOME/.config/qBittorrent" \
    "$HOME/.local/share/data/qBittorrent" \
    "$HOME/.cache/qBittorrent" \
    2>/dev/null || true

# ==================================================
# USŁUGI
# ==================================================

echo
echo "==> Włączanie usług z enabled-services.txt..."

if [ -f "$BACKUP/enabled-services.txt" ]; then
    awk '/\.service/{print $1}' "$BACKUP/enabled-services.txt" | while read -r svc; do
        sudo systemctl enable "$svc" 2>/dev/null || true
    done
fi

sudo systemctl daemon-reload

# ==================================================
# SUDOERS.D
# ==================================================
#
# Reguły NOPASSWD (np. dla dashboardu admina działającego jako www-data).
# ZAWSZE walidujemy visudo -c przed użyciem - błąd składni w sudoers.d
# może zablokować sudo w całym systemie.

echo
echo "==> Przywracanie /etc/sudoers.d..."

if [ -f "$BACKUP/sudoers.d.tar.gz" ]; then
    sudo tar xzpf "$BACKUP/sudoers.d.tar.gz" -C /
    sudo chmod 440 /etc/sudoers.d/* 2>/dev/null || true
    if ! sudo visudo -c >/tmp/visudo-check.txt 2>&1; then
        echo "UWAGA: błąd składni w przywróconych /etc/sudoers.d - sprawdź ręcznie!"
        cat /tmp/visudo-check.txt
    fi
    rm -f /tmp/visudo-check.txt
fi

# ==================================================
# GRUPY DODATKOWE www-data
# ==================================================

echo
echo "==> Przywracanie grup www-data..."

if [ -f "$BACKUP/www-data-groups.txt" ]; then
    for g in $(cat "$BACKUP/www-data-groups.txt"); do
        [ "$g" = "www-data" ] && continue
        sudo usermod -aG "$g" www-data 2>/dev/null || true
    done
fi

# ==================================================
# PHP error_log
# ==================================================
#
# Nie był ustawiony nawet na starym systemie (błędy leciały tylko do logu
# Apache), ale dashboard admina ma na to osobną zakładkę - włączamy, żeby
# faktycznie z niej był pożytek.

PHP_VER=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null)
if [ -n "$PHP_VER" ] && [ -d "/etc/php/$PHP_VER" ]; then
    sudo touch /var/log/php_errors.log
    sudo chown www-data:www-data /var/log/php_errors.log
    sudo chmod 640 /var/log/php_errors.log
    for ini in "/etc/php/$PHP_VER/apache2/php.ini" "/etc/php/$PHP_VER/cli/php.ini"; do
        [ -f "$ini" ] || continue
        sudo grep -q '^error_log' "$ini" \
            && sudo sed -i 's|^error_log.*|error_log = /var/log/php_errors.log|' "$ini" \
            || echo "error_log = /var/log/php_errors.log" | sudo tee -a "$ini" > /dev/null
    done
fi

# ==================================================
# PODSUMOWANIE
# ==================================================

echo
echo "=========================================="
echo " RESTORE ZAKOŃCZONY"
echo "=========================================="
echo
echo "Zalecane kolejne kroki ręcznie:"
echo
echo "1. Przełóż dysk zewnętrzny do nowego RPi, następnie:"
echo "     sudo mount -a"
grep UUID "$BACKUP/fstab" 2>/dev/null || true
echo
echo "2. Zrestartuj kluczowe usługi:"
echo "     sudo systemctl restart apache2 mariadb smbd nmbd fail2ban netfilter-persistent"
echo
echo "3. WAŻNE: konta MySQL/MariaDB (poza root) NIE zostały odtworzone"
echo "   (celowo pominęliśmy bazę systemową mysql - patrz wyżej)."
echo "   Sprawdź w kodzie /var/www/html (np. config.php) jakiego"
echo "   użytkownika/hasła używa aplikacja i załóż go ręcznie:"
echo "     sudo mysql -e \"CREATE USER 'user'@'localhost' IDENTIFIED BY 'haslo';\""
echo "     sudo mysql -e \"GRANT ALL ON nazwa_bazy.* TO 'user'@'localhost';\""
echo
echo "4. WAŻNE: konto/hasło SMB (Samba) NIE zostało odtworzone"
echo "   (baza haseł SMB to osobny system od kont Linuksa i od kont MySQL)."
echo "   Załóż je ręcznie dla użytkownika, który ma dostęp do share'ów:"
echo "     sudo smbpasswd -a fifcok"
echo
echo "5. VPN - OpenVPN powinien wstać sam (user/grupa odtworzone"
echo "   automatycznie), ale i tak wymaga weryfikacji:"
echo "     sudo systemctl status openvpn@server"
echo "     sudo tailscale up          # ponowna autoryzacja węzła"
echo "     sudo zerotier-cli listnetworks"
echo
echo "6. Sprawdź certyfikaty Let's Encrypt:"
echo "     sudo certbot renew --dry-run"
echo
echo "7. Jeśli backup zawierał wpisy I2C/SPI (boot-config.txt) - reboot"
echo "   jest wymagany, żeby device tree je faktycznie zastosował."
echo
echo "8. Na koniec zrestartuj system:"
echo "     sudo reboot"
echo
