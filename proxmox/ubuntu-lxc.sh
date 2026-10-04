#!/usr/bin/env bash
#
# Legt auf einem Proxmox-Wirt einen LXC-Container an: neuestes Ubuntu LTS
# (oder Debian), unprivilegiert, DHCP, Benutzer "rego" mit sudo. Fragt nichts --
# die Kennung kommt als Argument:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/proxmox/ubuntu-lxc.sh)" _ 123
#
# Das "_" ist kein Tippfehler: Bei `bash -c` ist das erste Wort danach $0, erst
# das zweite ist $1. Ohne Kennung nimmt das Skript die nächste freie.
#
# Alles andere hat eine Vorgabe und lässt sich als Umgebungsvariable setzen:
#
#   CT_NAME, CT_RAM (MB), CT_SWAP (MB), CT_KERNE, CT_PLATTE (GB), CT_BENUTZER,
#   CT_SPEICHER, CT_BRUECKE, CT_SYSTEM (ubuntu|debian), CT_PASSWORT,
#   CT_SCHLUESSEL (öffentliche Schlüssel, eine Zeile je Schlüssel, oder ein
#   Dateipfad), CT_AUTOSTART (ja|nein), CT_PRIVILEGIERT (nein|ja)
#
# Ohne CT_PASSWORT wird ein Passwort erzeugt und am Ende einmal angezeigt.
#
# Warum ein Container und keine VM: Er teilt sich den Kern mit dem Wirt, startet
# in Sekunden und braucht nur, was die Dienste darin wirklich belegen. Für
# alles, was einen eigenen Kern will (andere Kernmodule, ein anderes
# Betriebssystem), ist ubuntu-vm.sh daneben der richtige Weg.
#
# Warum unprivilegiert: Root im Container ist dann auf dem Wirt ein
# gewöhnlicher Benutzer ohne Rechte. Bricht jemand aus dem Container aus, steht
# er nicht als root auf dem Wirt.
#
# Warum "nesting" an: Ohne läuft Docker im Container nicht, und systemd meldet
# bei neueren Ubuntu-Ausgaben Fehler beim Start einzelner Dienste. Proxmox
# selbst setzt es bei neuen unprivilegierten Containern inzwischen als Vorgabe.

set -euo pipefail

# ------------------------------------------------------------------ Ausgabe

if [ -t 1 ]; then
  ROT=$'\e[31m'; GRUEN=$'\e[32m'; GELB=$'\e[33m'; FETT=$'\e[1m'; AUS=$'\e[0m'
else
  ROT=""; GRUEN=""; GELB=""; FETT=""; AUS=""
fi

sagen()   { printf '%s\n' "$*"; }
schritt() { printf '%s==>%s %s\n' "$FETT" "$AUS" "$*"; }
gut()     { printf '%s  ✓%s %s\n' "$GRUEN" "$AUS" "$*"; }
warnen()  { printf '%s  !%s %s\n' "$GELB" "$AUS" "$*"; }
ende()    { printf '%s  ✗ %s%s\n' "$ROT" "$*" "$AUS" >&2; exit 1; }

# Beim Abbruch nicht den halben Container stehen lassen.
SCHLUESSEL_DATEI=""
aufraeumen() {
  local stand=$?
  [ -n "$SCHLUESSEL_DATEI" ] && rm -f "$SCHLUESSEL_DATEI" || true
  if [ "$stand" -ne 0 ] && [ -n "${CT_ANGELEGT:-}" ]; then
    warnen "Abgebrochen. Der halbfertige Container $CT_ANGELEGT wird entfernt."
    pct stop "$CT_ANGELEGT" >/dev/null 2>&1 || true
    pct destroy "$CT_ANGELEGT" --purge >/dev/null 2>&1 || true
  fi
}
trap aufraeumen EXIT

# ------------------------------------------------------------- Voraussetzungen

[ "$(id -u)" -eq 0 ] || ende "Bitte als root ausführen (auf dem Proxmox-Wirt)."
command -v pct >/dev/null 2>&1 || ende "Kein 'pct' gefunden — läuft das hier wirklich auf Proxmox?"
command -v pveam >/dev/null 2>&1 || ende "Kein 'pveam' gefunden — läuft das hier wirklich auf Proxmox?"

# ------------------------------------------------------------------ Werte

# wert <Text> <Vorgabe> <Variablenname>
#
# Gesetzt ist, was als Umgebungsvariable mitkommt, sonst die Vorgabe. Gefragt
# wird nichts; angezeigt wird jeder Wert, damit man sieht, womit gebaut wird.
wert() {
  local text="$1" vorgabe="$2" ziel="$3"
  local gesetzt="${!ziel-}"
  printf -v "$ziel" '%s' "${gesetzt:-$vorgabe}"
  sagen "  ${text}: ${!ziel}"
}

naechste_freie_id() {
  local id
  if command -v pvesh >/dev/null 2>&1; then
    id="$(pvesh get /cluster/nextid 2>/dev/null || true)"
    if [ -n "$id" ]; then printf '%s' "$id"; return; fi
  fi
  id=100
  while qm status "$id" >/dev/null 2>&1 || pct status "$id" >/dev/null 2>&1; do
    id=$((id + 1))
  done
  printf '%s' "$id"
}

# Der erste aktive Speicher, der eine bestimmte Art Inhalt aufnimmt.
speicher_fuer() {
  pvesm status --content "$1" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}'
}

schritt "LXC-Container auf Proxmox anlegen"
sagen ""

[ -n "${1:-}" ] && CT_ID="$1"
wert "Kennung (ID)" "$(naechste_freie_id)" CT_ID
[[ "$CT_ID" =~ ^[0-9]+$ ]] || ende "Die Kennung muss eine Zahl sein, nicht '$CT_ID'."
[ "$CT_ID" -ge 100 ] || ende "Proxmox vergibt Kennungen ab 100."
if pct status "$CT_ID" >/dev/null 2>&1 || qm status "$CT_ID" >/dev/null 2>&1; then
  ende "Kennung $CT_ID ist schon vergeben."
fi

wert "System" "ubuntu" CT_SYSTEM
case "$CT_SYSTEM" in ubuntu|debian) ;; *) ende "CT_SYSTEM kennt nur 'ubuntu' und 'debian'." ;; esac
wert "Name (Rechnername)" "${CT_SYSTEM}-$CT_ID" CT_NAME
wert "Arbeitsspeicher in MB" "2048" CT_RAM
wert "Auslagerung in MB" "512" CT_SWAP
wert "Prozessorkerne" "2" CT_KERNE
wert "Festplatte in GB" "16" CT_PLATTE
wert "Benutzername" "rego" CT_BENUTZER
VORGABE_SPEICHER="$(speicher_fuer rootdir)"
wert "Speicherort" "${VORGABE_SPEICHER:-local-lvm}" CT_SPEICHER
wert "Netzwerkbrücke" "vmbr0" CT_BRUECKE
wert "Beim Hochfahren des Wirts starten" "ja" CT_AUTOSTART
wert "Privilegiert" "nein" CT_PRIVILEGIERT

# Ein Rechnername darf nur Buchstaben, Ziffern und Bindestriche enthalten --
# Proxmox lehnt sonst erst beim Anlegen ab, mit einer Meldung über "hostname".
[[ "$CT_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
  || ende "Der Name '$CT_NAME' taugt nicht als Rechnername (nur Buchstaben, Ziffern, Bindestriche)."
[[ "$CT_BENUTZER" =~ ^[a-z_][a-z0-9_-]*$ ]] \
  || ende "Der Benutzername '$CT_BENUTZER' ist unter Linux nicht erlaubt."

# Kein Passwort mitgegeben: eines erzeugen. Ein festes Vorgabepasswort stünde
# in einem öffentlichen Skript -- für jeden Container dasselbe.
PASSWORT_ERZEUGT="nein"
if [ -n "${CT_PASSWORT:-}" ]; then
  PASSWORT="$CT_PASSWORT"
  sagen "  Passwort für ${CT_BENUTZER}: (aus CT_PASSWORT übernommen)"
else
  # Ohne verwechselbare Zeichen (0/O, 1/l/I): Es wird von Hand abgetippt.
  PASSWORT="$(LC_ALL=C tr -dc 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789' </dev/urandom | head -c 16 || true)"
  [ "${#PASSWORT}" -eq 16 ] || ende "Es liess sich kein Passwort erzeugen."
  PASSWORT_ERZEUGT="ja"
  sagen "  Passwort für ${CT_BENUTZER}: (wird erzeugt, steht am Ende)"
fi

# Öffentliche Schlüssel: die des Wirts von selbst, dazu CT_SCHLUESSEL.
SCHLUESSEL_DATEI="$(mktemp)"
for kandidat in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys; do
  if [ -s "$kandidat" ]; then
    cat "$kandidat" >> "$SCHLUESSEL_DATEI"
    sagen "  Schlüssel aus ${kandidat} übernommen"
    break
  fi
done
if [ -n "${CT_SCHLUESSEL:-}" ]; then
  if [ -f "$CT_SCHLUESSEL" ]; then zusatz="$(cat "$CT_SCHLUESSEL")"; else zusatz="$CT_SCHLUESSEL"; fi
  while IFS= read -r zeile; do
    [ -z "$zeile" ] && continue
    case "$zeile" in
      ssh-*|ecdsa-*|sk-*) printf '%s\n' "$zeile" >> "$SCHLUESSEL_DATEI" ;;
      *) warnen "Aus CT_SCHLUESSEL übergangen, kein öffentlicher Schlüssel: ${zeile:0:30}…" ;;
    esac
  done <<< "$zusatz"
  unset zusatz
fi

# ------------------------------------------------------------------ Vorlage

schritt "Neueste Vorlage ermitteln"

pveam update >/dev/null 2>&1 || warnen "Die Vorlagenliste liess sich nicht auffrischen — nehme die vorhandene."

# Dynamisch statt fest verdrahtet: Eine feste Version veraltet. Bei Ubuntu nur
# LTS -- gerade Jahreszahl, April (24.04, 26.04). Eine Zwischenversion läuft
# nach neun Monaten aus und wäre für einen Dienst die falsche Wahl.
VERFUEGBAR="$(pveam available --section system 2>/dev/null | awk '{print $2}')"
if [ "$CT_SYSTEM" = "ubuntu" ]; then
  VORLAGE="$(printf '%s\n' "$VERFUEGBAR" \
    | grep -E '^ubuntu-[0-9]+\.04-standard_.*_amd64\.tar\.(zst|gz|xz)$' \
    | awk -F'[-.]' '($2 % 2) == 0' \
    | sort -V | tail -1 || true)"
else
  VORLAGE="$(printf '%s\n' "$VERFUEGBAR" \
    | grep -E '^debian-[0-9]+-standard_.*_amd64\.tar\.(zst|gz|xz)$' \
    | sort -V | tail -1 || true)"
fi
[ -n "$VORLAGE" ] || ende "Keine passende Vorlage für $CT_SYSTEM in 'pveam available' gefunden."
gut "$VORLAGE"

VORLAGEN_SPEICHER="$(speicher_fuer vztmpl)"
VORLAGEN_SPEICHER="${VORLAGEN_SPEICHER:-local}"

if pveam list "$VORLAGEN_SPEICHER" 2>/dev/null | awk '{print $1}' | grep -q "/${VORLAGE}\$"; then
  gut "Vorlage liegt schon da (${VORLAGEN_SPEICHER})"
else
  schritt "Vorlage laden"
  pveam download "$VORLAGEN_SPEICHER" "$VORLAGE" >/dev/null \
    || ende "Die Vorlage liess sich nicht nach '$VORLAGEN_SPEICHER' laden."
  gut "Geladen"
fi

# ------------------------------------------------------------------ Anlegen

schritt "Container $CT_ID anlegen"

UNPRIVILEGIERT=1
MERKMALE="nesting=1"
if [ "$CT_PRIVILEGIERT" = "ja" ]; then
  UNPRIVILEGIERT=0
  warnen "Privilegiert: root im Container ist root auf dem Wirt."
else
  # keyctl braucht Docker in unprivilegierten Containern.
  MERKMALE="nesting=1,keyctl=1"
fi
AUTOSTART=0
[ "$CT_AUTOSTART" = "ja" ] && AUTOSTART=1

SCHLUESSEL_ARG=()
[ -s "$SCHLUESSEL_DATEI" ] && SCHLUESSEL_ARG=(--ssh-public-keys "$SCHLUESSEL_DATEI")

pct create "$CT_ID" "${VORLAGEN_SPEICHER}:vztmpl/${VORLAGE}" \
  --hostname "$CT_NAME" \
  --memory "$CT_RAM" \
  --swap "$CT_SWAP" \
  --cores "$CT_KERNE" \
  --rootfs "${CT_SPEICHER}:${CT_PLATTE}" \
  --net0 "name=eth0,bridge=${CT_BRUECKE},ip=dhcp" \
  --unprivileged "$UNPRIVILEGIERT" \
  --features "$MERKMALE" \
  --onboot "$AUTOSTART" \
  --description "${CT_SYSTEM} · angelegt am $(date '+%d.%m.%Y') mit REGOeinzeiler" \
  "${SCHLUESSEL_ARG[@]}" \
  >/dev/null || ende "pct create ist gescheitert."
CT_ANGELEGT="$CT_ID"

schritt "Container starten"
pct start "$CT_ID" >/dev/null || ende "Der Container liess sich nicht starten."

# Auf das Netz warten: DHCP braucht ein paar Sekunden, und ohne Netz scheitern
# die Paketquellen.
ADRESSE=""
for _ in $(seq 1 30); do
  ADRESSE="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [ -n "$ADRESSE" ] && break
  sleep 2
done
if [ -n "$ADRESSE" ]; then gut "Netz da: $ADRESSE"; else warnen "Nach einer Minute noch keine Adresse über DHCP."; fi

# ------------------------------------------------------------ Einrichten

schritt "Benutzer ${CT_BENUTZER} einrichten"

# Debian-Vorlagen bringen kein sudo mit. Ohne Netz geht es eben nicht -- dann
# meldet es sich, der Container steht trotzdem.
if ! pct exec "$CT_ID" -- sh -c 'command -v sudo >/dev/null 2>&1'; then
  pct exec "$CT_ID" -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo' >/dev/null 2>&1 \
    || warnen "sudo liess sich nicht installieren (Netz?)."
fi

pct exec "$CT_ID" -- useradd -m -s /bin/bash "$CT_BENUTZER" \
  || ende "Der Benutzer liess sich nicht anlegen."
pct exec "$CT_ID" -- sh -c "getent group sudo >/dev/null && usermod -aG sudo '$CT_BENUTZER'" \
  || warnen "Keine Gruppe sudo im Container."

# Das Passwort geht über die Standardeingabe, nicht über die Befehlszeile:
# Argumente stehen in der Prozessliste des Wirts und wären mitzulesen.
printf '%s:%s\n' "$CT_BENUTZER" "$PASSWORT" | pct exec "$CT_ID" -- chpasswd \
  || ende "Das Passwort liess sich nicht setzen."

# Dieselben Schlüssel wie root, auch für den Benutzer.
if [ -s "$SCHLUESSEL_DATEI" ]; then
  pct exec "$CT_ID" -- sh -c "install -d -m 700 -o '$CT_BENUTZER' -g '$CT_BENUTZER' /home/$CT_BENUTZER/.ssh" \
    && pct push "$CT_ID" "$SCHLUESSEL_DATEI" "/home/$CT_BENUTZER/.ssh/authorized_keys" \
         --user "$CT_BENUTZER" --group "$CT_BENUTZER" --perms 600 \
    && gut "SSH-Schlüssel für ${CT_BENUTZER} und root übernommen" \
    || warnen "Die SSH-Schlüssel liessen sich für ${CT_BENUTZER} nicht ablegen."
fi

# SSH: Debian-Vorlagen haben keinen Server, Ubuntu-Vorlagen schon. Passwort-
# anmeldung ausdrücklich erlauben -- sonst gälte das Passwort nur an der Konsole.
pct exec "$CT_ID" -- sh -c '
  if ! command -v sshd >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server >/dev/null 2>&1 || exit 1
  fi
  mkdir -p /etc/ssh/sshd_config.d
  printf "PasswordAuthentication yes\n" > /etc/ssh/sshd_config.d/10-regoeinzeiler.conf
  # Neu starten, nicht nur einschalten: Läuft der Dienst schon (Ubuntu), läse
  # er die neue Einstellung sonst erst beim nächsten Hochfahren.
  systemctl enable ssh >/dev/null 2>&1 || true
  systemctl restart ssh >/dev/null 2>&1 || true
' && gut "SSH an, Anmeldung mit Schlüssel oder Passwort" \
  || warnen "SSH liess sich nicht einrichten (Netz?)."

schritt "Pakete auf den neuesten Stand bringen"
if pct exec "$CT_ID" -- sh -c 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get -y -qq -o Dpkg::Options::=--force-confold full-upgrade' >/dev/null 2>&1; then
  gut "Aktuell"
else
  warnen "Das Aktualisieren ist gescheitert — der Container läuft trotzdem."
fi

CT_ANGELEGT=""   # ab hier ist er fertig und wird bei Fehlern nicht mehr entfernt
[ -n "$ADRESSE" ] || ADRESSE="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"

# ------------------------------------------------------------------ Fertig

sagen ""
schritt "Fertig"
sagen "  Kennung   $CT_ID"
sagen "  Name      $CT_NAME"
sagen "  System    ${VORLAGE%%_*}"
sagen "  Benutzer  $CT_BENUTZER (mit sudo)"
if [ "$PASSWORT_ERZEUGT" = "ja" ]; then
  sagen "  Passwort  ${FETT}${PASSWORT}${AUS}   (erzeugt -- jetzt notieren, es steht nirgends sonst)"
fi
unset PASSWORT
sagen "  Netz      ${ADRESSE:-DHCP, Adresse noch unbekannt} über $CT_BRUECKE"
sagen ""
sagen "  Anmelden:  ssh ${CT_BENUTZER}@${ADRESSE:-<adresse>}"
sagen "  Konsole:   pct enter $CT_ID"
sagen ""
