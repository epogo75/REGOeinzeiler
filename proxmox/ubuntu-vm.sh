#!/usr/bin/env bash
#
# Legt auf einem Proxmox-Wirt eine Ubuntu-Server-VM an: neuestes LTS als
# Cloud-Abbild, DHCP, Benutzer "rego". Kennung und Passwort werden gefragt.
#
# Immer die Server-Variante, nie ein Desktop: Das Cloud-Abbild
# (ubuntu-*-server-cloudimg-amd64.img) bringt keine grafische Oberfläche mit
# und soll auch keine bekommen -- eine VM, die Dienste trägt, braucht kein
# Fenster, und ein Desktop kostet Speicher, Platte und Angriffsfläche.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/proxmox/ubuntu-vm.sh)"
#
# Warum ein Cloud-Abbild und keine ISO-Installation: Das Abbild ist fertig
# eingerichtet und startet in etwa einer Minute. Eine ISO-Installation müsste
# beaufsichtigt werden oder eine autoinstall-Datei mitbringen -- beides mehr
# Aufwand für dasselbe Ergebnis.

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

# Beim Abbruch nicht die halbe VM stehen lassen.
ZU_RAEUMEN=""
aufraeumen() {
  local stand=$?
  [ -n "$ZU_RAEUMEN" ] && rm -f "$ZU_RAEUMEN" || true
  [ -n "${GEHEIM:-}" ] && rm -f "$GEHEIM" || true
  [ -n "${SCHLUESSEL_DATEI:-}" ] && rm -f "$SCHLUESSEL_DATEI" || true
  if [ "$stand" -ne 0 ] && [ -n "${VM_ANGELEGT:-}" ]; then
    warnen "Abgebrochen. Die halbfertige VM $VM_ANGELEGT wird entfernt."
    qm destroy "$VM_ANGELEGT" --purge >/dev/null 2>&1 || true
  fi
}
trap aufraeumen EXIT

# ------------------------------------------------------------- Voraussetzungen

[ "$(id -u)" -eq 0 ] || ende "Bitte als root ausführen (auf dem Proxmox-Wirt)."
command -v qm >/dev/null 2>&1 || ende "Kein 'qm' gefunden — läuft das hier wirklich auf Proxmox?"
command -v curl >/dev/null 2>&1 || ende "curl fehlt."

# ------------------------------------------------------------------- Abfragen

# frage <Text> <Vorgabe> <Variablenname>
#
# Jede Frage lässt sich vorab beantworten: Der Name der Zielvariablen ist
# zugleich die Umgebungsvariable. So bleibt das Skript unverändert nutzbar --
# wer es über `curl` aufruft, kann seine Werte trotzdem setzen, ohne es
# bearbeiten zu müssen. Mit VM_STILL=ja wird gar nicht gefragt.
frage() {
  local text="$1" vorgabe="$2" ziel="$3" eingabe=""
  local gesetzt="${!ziel-}"

  if [ -n "$gesetzt" ]; then
    sagen "  ${text}: ${gesetzt}"
    return
  fi
  if [ "${VM_STILL:-}" = "ja" ]; then
    printf -v "$ziel" '%s' "$vorgabe"
    sagen "  ${text}: ${vorgabe}"
    return
  fi
  read -r -p "  ${text} [${vorgabe}]: " eingabe </dev/tty || true
  printf -v "$ziel" '%s' "${eingabe:-$vorgabe}"
}

naechste_freie_id() {
  # pvesh kennt die nächste freie Kennung; ohne pvesh selbst suchen.
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

schritt "Ubuntu-Server-VM auf Proxmox anlegen"
sagen ""

VORGABE_ID="$(naechste_freie_id)"
frage "VM-Kennung (ID)" "$VORGABE_ID" VM_ID
[[ "$VM_ID" =~ ^[0-9]+$ ]] || ende "Die Kennung muss eine Zahl sein."
[ "$VM_ID" -ge 100 ] || ende "Proxmox vergibt Kennungen ab 100."
if qm status "$VM_ID" >/dev/null 2>&1 || pct status "$VM_ID" >/dev/null 2>&1; then
  ende "Kennung $VM_ID ist schon vergeben."
fi

frage "Name der VM" "ubuntu-$VM_ID" VM_NAME
frage "Arbeitsspeicher in MB" "4096" VM_RAM
frage "Prozessorkerne" "2" VM_KERNE
frage "Festplatte in GB" "32" VM_PLATTE
frage "Benutzername" "rego" VM_BENUTZER

# Speicherort: der erste, der Abbilder aufnehmen kann.
VORGABE_SPEICHER="$(
  pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}'
)"
frage "Speicherort" "${VORGABE_SPEICHER:-local-lvm}" VM_SPEICHER
frage "Netzwerkbrücke" "vmbr0" VM_BRUECKE

# Passwort verdeckt und zweimal -- ein Tippfehler fiele sonst erst beim
# Anmelden auf, wenn die VM schon läuft.
if [ -n "${VM_PASSWORT:-}" ]; then
  PASSWORT="$VM_PASSWORT"
  sagen "  Passwort für ${VM_BENUTZER}: (aus VM_PASSWORT übernommen)"
fi
while [ -z "${PASSWORT:-}" ]; do
  read -r -s -p "  Passwort für ${VM_BENUTZER}: " PASSWORT </dev/tty; echo
  [ -n "$PASSWORT" ] || { warnen "Das Passwort darf nicht leer sein."; continue; }
  read -r -s -p "  Passwort wiederholen: " PASSWORT2 </dev/tty; echo
  if [ "$PASSWORT" = "$PASSWORT2" ]; then break; fi
  warnen "Die beiden Eingaben stimmen nicht überein."
  PASSWORT=""
done
unset PASSWORT2

# Öffentliche Schlüssel sammeln. Der des Wirts liegt nahe, reicht aber nicht:
# Wer von einem anderen Rechner zugreift -- Notebook, ein weiterer Container --,
# stünde sonst vor verschlossener Tür.
SCHLUESSEL_DATEI="$(mktemp)"
ZU_RAEUMEN="$SCHLUESSEL_DATEI"

for kandidat in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys; do
  if [ -s "$kandidat" ]; then
    read -r -p "  Schlüssel aus $kandidat übernehmen? [J/n]: " antwort </dev/tty || true
    case "${antwort:-J}" in [Nn]*) : ;; *) cat "$kandidat" >> "$SCHLUESSEL_DATEI" ;; esac
    break
  fi
done

sagen "  Weitere öffentliche Schlüssel einfügen (leere Zeile beendet):"
while IFS= read -r zeile </dev/tty; do
  if [ -z "$zeile" ]; then break; fi
  case "$zeile" in
    ssh-*|ecdsa-*) printf '%s\n' "$zeile" >> "$SCHLUESSEL_DATEI" ;;
    *) warnen "Das sieht nicht nach einem öffentlichen Schlüssel aus — übergangen." ;;
  esac
done

SSH_SCHLUESSEL=""
[ -s "$SCHLUESSEL_DATEI" ] && SSH_SCHLUESSEL="$SCHLUESSEL_DATEI" || true

# ------------------------------------------------------------------- Abbild

schritt "Neuestes Ubuntu-LTS ermitteln"

# Dynamisch statt fest verdrahtet: Eine feste Version veraltet, und eine
# abgelaufene Zwischenversion (25.10 lief im Juli 2026 aus) wäre für einen
# Server die falsche Wahl. LTS bekommt fünf Jahre Pflege.
STROM="https://cloud-images.ubuntu.com/releases/streams/v1/com.ubuntu.cloud:released:download.json"
LESEN='
import json, sys
d = json.load(sys.stdin)
beste = None
for p in d["products"].values():
    if p.get("arch") != "amd64":
        continue
    titel = p.get("release_title", "")
    if "LTS" not in titel:
        continue
    version = p.get("version") or ""
    if not version:
        continue
    if beste is None or [int(t) for t in version.split(".")] > beste[0]:
        beste = ([int(t) for t in version.split(".")], version, p.get("release"))
if beste is None:
    sys.exit(1)
print(beste[1], beste[2])
'
if command -v python3 >/dev/null 2>&1; then
  GEFUNDEN="$(curl -fsSL --max-time 30 "$STROM" 2>/dev/null | python3 -c "$LESEN" || true)"
fi
if [ -n "${GEFUNDEN:-}" ]; then
  VERSION="${GEFUNDEN% *}"
  KURZNAME="${GEFUNDEN#* }"
else
  # Kein Netz zum Verzeichnis oder kein python3: Die Verzeichnisliste geht auch.
  KURZNAME="$(curl -fsSL --max-time 30 https://cloud-images.ubuntu.com/releases/ 2>/dev/null \
    | grep -oE 'href="[a-z]+/"' | cut -d'"' -f2 | tr -d '/' | tail -1)"
  [ -n "$KURZNAME" ] || ende "Die Ubuntu-Abbilder sind nicht erreichbar."
  VERSION="$KURZNAME"
  warnen "Version über die Verzeichnisliste bestimmt: $KURZNAME"
fi
gut "Ubuntu $VERSION ($KURZNAME)"

# "server-cloudimg" ist die Server-Variante ohne grafische Oberfläche. Eine
# Desktop-Ausgabe gibt es als Cloud-Abbild ohnehin nicht -- das hier ist die
# richtige und einzige Wahl für eine VM, die Dienste trägt.
ABBILD="https://cloud-images.ubuntu.com/releases/${KURZNAME}/release/ubuntu-${VERSION}-server-cloudimg-amd64.img"
DATEI="/var/lib/vz/template/cache/ubuntu-${VERSION}-cloudimg-amd64.img"
mkdir -p "$(dirname "$DATEI")"

if [ -s "$DATEI" ]; then
  gut "Abbild liegt schon da: $DATEI"
else
  schritt "Abbild laden (rund 600 MB)"
  ZU_RAEUMEN="${DATEI}.teil"
  curl -fL --progress-bar -o "${DATEI}.teil" "$ABBILD" \
    || ende "Das Abbild liess sich nicht laden: $ABBILD"
  mv "${DATEI}.teil" "$DATEI"
  ZU_RAEUMEN=""
  gut "Geladen"
fi

# ------------------------------------------------------------------ Anlegen

schritt "VM $VM_ID anlegen"

qm create "$VM_ID" \
  --name "$VM_NAME" \
  --memory "$VM_RAM" \
  --cores "$VM_KERNE" \
  --cpu host \
  --net0 "virtio,bridge=${VM_BRUECKE}" \
  --scsihw virtio-scsi-single \
  --ostype l26 \
  --agent enabled=1 \
  --serial0 socket --vga serial0 \
  >/dev/null
VM_ANGELEGT="$VM_ID"

# Ab hier räumt der Abbruchpfad die VM wieder weg.
schritt "Abbild einspielen"
qm importdisk "$VM_ID" "$DATEI" "$VM_SPEICHER" >/dev/null 2>&1 \
  || ende "Das Abbild liess sich nicht nach '$SPEICHER' einspielen."

# Wie die eingespielte Platte heisst, hängt vom Speichertyp ab -- deshalb
# nicht raten, sondern aus der Beschreibung lesen.
PLATTENNAME="$(qm config "$VM_ID" | awk -F': ' '/^unused0:/ {print $2; exit}')"
[ -n "$PLATTENNAME" ] || ende "Die eingespielte Platte ist nicht auffindbar."

qm set "$VM_ID" \
  --scsi0 "${PLATTENNAME},discard=on,ssd=1" \
  --boot order=scsi0 \
  --ide2 "${VM_SPEICHER}:cloudinit" \
  >/dev/null

qm disk resize "$VM_ID" scsi0 "${VM_PLATTE}G" >/dev/null 2>&1 \
  || warnen "Die Platte liess sich nicht auf ${VM_PLATTE} GB vergrössern."

# --------------------------------------------------------------- cloud-init

schritt "Erstanmeldung einrichten"

# Das Passwort geht über eine Datei mit engen Rechten, nicht über die
# Befehlszeile: Argumente stehen in der Prozessliste und wären für jeden
# anderen Benutzer des Wirts mitzulesen.
GEHEIM="$(mktemp)"
chmod 600 "$GEHEIM"
printf '%s' "$PASSWORT" > "$GEHEIM"

qm set "$VM_ID" \
  --ciuser "$VM_BENUTZER" \
  --cipassword "$(cat "$GEHEIM")" \
  --ipconfig0 ip=dhcp \
  --ciupgrade 1 \
  >/dev/null

# Ubuntu-Cloud-Abbilder schalten die Passwortanmeldung über SSH ab
# (/etc/ssh/sshd_config.d/60-cloudimg-settings.conf). Ohne Gegenmaßnahme gilt
# das eben gesetzte Passwort nur an der seriellen Konsole -- wer sich per SSH
# anmelden will, steht vor verschlossener Tür und weiss nicht warum.
#
# Proxmox kann das nicht selbst; dafür braucht es ein eigenes cloud-init-Stück.
# Gibt es keinen Speicher für Schnipsel, wird wenigstens klar gesagt, was gilt.
SCHNIPSEL_SPEICHER="$(
  pvesm status --content snippets 2>/dev/null | awk 'NR>1 && $3=="active" {print $1; exit}'
)"
PASSWORT_SSH="nein"
if [ -n "$SCHNIPSEL_SPEICHER" ]; then
  SCHNIPSEL_PFAD="$(pvesm path "${SCHNIPSEL_SPEICHER}:snippets/regoeinzeiler-${VM_ID}.yaml" 2>/dev/null || true)"
  if [ -n "$SCHNIPSEL_PFAD" ]; then
    mkdir -p "$(dirname "$SCHNIPSEL_PFAD")"
    cat > "$SCHNIPSEL_PFAD" <<'SCHNIPSEL'
#cloud-config
ssh_pwauth: true
runcmd:
  # Der Gastdienst ist im Abbild enthalten, startet aber nicht von selbst.
  # Ohne ihn zeigt Proxmox keine Adresse an und kann die VM nicht sauber
  # herunterfahren -- beides fällt erst auf, wenn man es braucht.
  - [ systemctl, enable, --now, qemu-guest-agent ]
SCHNIPSEL
    if qm set "$VM_ID" --cicustom "vendor=${SCHNIPSEL_SPEICHER}:snippets/regoeinzeiler-${VM_ID}.yaml" >/dev/null 2>&1; then
      PASSWORT_SSH="ja"
      gut "Anmeldung per Passwort über SSH eingeschaltet"
    else
      rm -f "$SCHNIPSEL_PFAD"
    fi
  fi
fi
if [ "$PASSWORT_SSH" = "nein" ]; then
  warnen "Kein Speicher für cloud-init-Schnipsel gefunden."
  warnen "Das Passwort gilt deshalb nur an der Konsole, nicht über SSH,"
  warnen "und der QEMU-Gastdienst muss von Hand gestartet werden:"
  warnen "    sudo systemctl enable --now qemu-guest-agent"
fi

rm -f "$GEHEIM"
unset PASSWORT

if [ -n "$SSH_SCHLUESSEL" ]; then
  if qm set "$VM_ID" --sshkeys "$SSH_SCHLUESSEL" >/dev/null 2>&1; then
    gut "SSH-Schlüssel übernommen"
  else
    warnen "Der SSH-Schlüssel liess sich nicht übernehmen."
  fi
fi

qm set "$VM_ID" --description "Ubuntu ${VERSION} · angelegt am $(date '+%d.%m.%Y') mit REGOeinzeiler" >/dev/null

# ------------------------------------------------------------------- Starten

schritt "VM starten"
qm start "$VM_ID" >/dev/null || ende "Die VM liess sich nicht starten."
VM_ANGELEGT=""   # ab hier ist sie fertig und wird bei Fehlern nicht mehr entfernt
gut "Läuft"

sagen ""
schritt "Fertig"
sagen "  Kennung   $VM_ID"
sagen "  Name      $VM_NAME"
sagen "  System    Ubuntu $VERSION LTS Server (ohne Oberfläche)"
sagen "  Benutzer  $BENUTZER"
sagen "  Netz      DHCP über $BRUECKE"
sagen ""
sagen '  Die Adresse steht nach etwa einer Minute im Reiter "Zusammenfassung"' 
sagen "  (der QEMU-Gastdienst meldet sie), oder hier:"
sagen ""
sagen "      qm guest cmd $VM_ID network-get-interfaces"
sagen ""
if [ "$PASSWORT_SSH" = "ja" ]; then
  sagen "  Anmelden:  ssh ${VM_BENUTZER}@<adresse>   (Schlüssel oder Passwort)"
else
  sagen "  Anmelden:  ssh ${VM_BENUTZER}@<adresse>   (nur mit Schlüssel)"
  sagen ""
  sagen "  Das Passwort gilt nur an der Konsole. Für Passwort über SSH dort einmal:"
  sagen "      sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' \\"
  sagen "          /etc/ssh/sshd_config.d/*.conf && sudo systemctl restart ssh"
fi
sagen "  Konsole:   qm terminal $VM_ID     (mit Strg+O verlassen)"
sagen ""
