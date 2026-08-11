# RPi Migration Scripts

Skrypty do backupu i odtwarzania konfiguracji Raspberry Pi (Apache, PHP,
MariaDB, Samba, VPN, cron, itd.) przy migracji na nowy system/architekturę.

## Użycie

Wgraj oba skrypty do katalogu domowego użytkownika na Raspberry Pi
(`/home/<user>`, czyli `~`), np.:
```bash
scp backup.sh restore.sh <user>@<pi>:~/
```

Na starym systemie:
```bash
chmod +x backup.sh
./backup.sh
```
Backup wyląduje w `~/rpi-migration-<data>-<godzina>/`.

Na nowym systemie:
```bash
chmod +x restore.sh
./restore.sh ~/rpi-migration-<data>-<godzina>
```

## Ważne

Wygenerowany backup (klucze SSH/TLS, hasła, zrzuty baz danych) zawiera
dane wrażliwe i **celowo nie jest częścią tego repozytorium** — trzymaj go
osobno, offline, poza kontrolą wersji.
