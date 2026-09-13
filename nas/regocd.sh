#!/usr/bin/env bash
#
# Richtet REGOcd auf einem NAS oder Linux-Rechner mit Docker ein: Abbild aus
# der eigenen Registry holen, Verzeichnisse anlegen, Container starten.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd.sh)"
#
# Warum aus einer eigenen Registry und nicht vor Ort gebaut: Der Bau braucht
# Node, Python und einige Minuten. Das Abbild ist fertig, kommt in Sekunden
# und ist nachweislich dasselbe, das anderswo geprüft wurde.

set -euo pipefail

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

# Jede Frage lässt sich vorab beantworten: Der Name der Zielvariablen ist
# zugleich die Umgebungsvariable. So bleibt das Skript unverändert nutzbar --
# wer es über `curl` aufruft, kann seine Werte trotzdem setzen, ohne es
# bearbeiten zu müssen. Mit REGOCD_STILL=ja wird gar nicht gefragt.
frage() {
  local text="$1" vorgabe="$2" ziel="$3" eingabe=""
  local gesetzt="${!ziel-}"

  if [ -n "$gesetzt" ]; then
    sagen "  ${text}: ${gesetzt}"
    return
  fi
  if [ "${REGOCD_STILL:-}" = "ja" ]; then
    printf -v "$ziel" '%s' "$vorgabe"
    sagen "  ${text}: ${vorgabe}"
    return
  fi
  read -r -p "  ${text} [${vorgabe}]: " eingabe </dev/tty || true
  printf -v "$ziel" '%s' "${eingabe:-$vorgabe}"
}

# ------------------------------------------------------------- Voraussetzungen

[ "$(id -u)" -eq 0 ] || ende "Bitte als root ausführen (oder mit sudo)."
command -v docker >/dev/null 2>&1 || ende "Docker fehlt."
docker compose version >/dev/null 2>&1 || ende "Das Compose-Zusatzmodul fehlt."

schritt "REGOcd einrichten"
sagen ""

frage "Registry (Rechner:Port)" "192.168.1.43:5000" REGOCD_REGISTRY
frage "Ausgabe (latest oder z. B. b45)" "latest" REGOCD_MARKE
# 8090 wie bei der Entwicklungsinstanz -- ein Port für alle Stellen erspart
# das Nachdenken, unter welcher Adresse man gerade sucht.
frage "Port für die Oberfläche" "8090" REGOCD_PORT
frage "CD-Laufwerk" "/dev/sr0" REGOCD_LAUFWERK
# Steht in der Seitenspalte. Zwei gleich aussehende Instanzen im selben Netz
# sind sonst kaum auseinanderzuhalten -- man rippt auf der einen und sucht das
# Album auf der anderen.
frage "Name dieser Instanz (steht in der Oberfläche)" "NAS" REGOCD_STELLE
# Ohne Zeitzone läuft ein Container in UTC. Der Dienst sichert nachts um 03:00
# -- nach *seiner* Uhr. Steht sie auf UTC, rödelt die Platte im Sommer um
# 05:00 Ortszeit los. Deshalb wird sie gefragt und nicht geraten.
frage "Zeitzone" "Europe/Berlin" REGOCD_ZEITZONE

# Die Einhängepunkte einzeln, nicht unter einer Wurzel: Auf einem NAS liegen
# sie selten beieinander. Das CD-Archiv gehört auf den grossen Speicherpool,
# die Sicherung auf eine externe Platte (die auch mal abgezogen wird), und die
# Datenbank auf etwas Zuverlässiges. Der Arbeitsordner ist der einzige, der
# meist einfach neben der Datenbank bleiben kann -- dort liegen die Daten nur,
# solange eine CD gerippt wird.
#
# **Die Vorgaben sind die des Hauses**, nicht erfunden: Die Musik liegt im
# Musikbereich (dort suchen die Player), Datenbank und Arbeit im
# Docker-Bereich (dort gehört die Betriebsablage eines Containers hin).
# Wer es anders will, tippt es einfach über.
sagen ""
sagen "  Wohin die Bereiche gehören:"
frage "  CD-Archiv (die FLAC-Dateien, wächst)" "/volume2/music/regocd" REGOCD_ARCHIV
frage "  Docker-Ordner (Datenbank und Arbeit darunter)" "/volume1/docker/regocd" REGOCD_WURZEL
frage "  Datenbank (mit den Covern, klein)" "${REGOCD_WURZEL}/data" REGOCD_DATENBANK
frage "  Arbeitsordner (nur während des Rippens)" "${REGOCD_WURZEL}/arbeit" REGOCD_ARBEIT
# **Wohin die Sicherung gehört: auf eine Platte, die nicht im Gerät steckt.**
# Wo ein NAS seine USB-Datenträger einhängt, ist je Hersteller verschieden --
# und wer es rät, schreibt die Sicherung in ein leeres Verzeichnis, das
# aussieht wie ein Einhängepunkt. Deshalb wird nachgesehen statt geraten:
# `lsblk` weiss, welche Datenträger über USB angeschlossen sind und wo sie
# hängen.
USB_ZIEL=""
if command -v lsblk >/dev/null 2>&1; then
  # Nur eingehängte USB-Datenträger, und nur die erste Zeile: Bei mehreren
  # entscheidet der Mensch, nicht das Skript.
  USB_ZIEL="$(lsblk -rno TRAN,MOUNTPOINT 2>/dev/null \
    | awk '$1 == "usb" && $2 != "" && $2 != "/" { print $2; exit }')"
fi
if [ -n "$USB_ZIEL" ]; then
  gut "USB-Datenträger gefunden: $USB_ZIEL"
  frage "  Sicherung (externe Platte)" "${USB_ZIEL}/regocd-sicherung" REGOCD_SICHERUNG
else
  # Kein USB-Datenträger da -- dann neben die Datenbank. Das schützt vor
  # Versehen (eine gelöschte Datenbank ist zurückzuholen), nicht vor einem
  # Plattenausfall. Sobald eine Platte steckt, dieses Skript noch einmal
  # laufen lassen: Dann steht sie als Vorgabe da.
  warnen "Kein eingehängter USB-Datenträger gefunden."
  warnen "Was angeschlossen ist, zeigt:  lsblk -o NAME,TRAN,SIZE,MOUNTPOINT"
  warnen "Auf UGREEN-Geräten hängen sie unter /mnt/@usb/<gerät> — gemessen an einem DXP2800."
  frage "  Sicherung (ohne externe Platte)" "${REGOCD_WURZEL}/sicherung" REGOCD_SICHERUNG
fi

# ------------------------------------------------------------------ Laufwerk

if [ ! -e "$REGOCD_LAUFWERK" ]; then
  warnen "$REGOCD_LAUFWERK gibt es nicht. Ohne Laufwerk läuft alles ausser dem Rippen."
  warnen "Bei einem USB-Laufwerk hilft meist: Gerät anstecken, dann 'lsblk' prüfen."
  if [ "${REGOCD_STILL:-}" = "ja" ]; then
    warnen "Weiter ohne Laufwerk (REGOCD_STILL=ja)."
  else
    read -r -p "  Trotzdem weitermachen? [j/N]: " weiter </dev/tty || true
    case "${weiter:-N}" in [JjYy]*) : ;; *) ende "Abgebrochen." ;; esac
  fi
  LAUFWERK=""
fi

# Der Container braucht die Gruppe des Laufwerks, sonst darf er nicht lesen.
GRUPPE=""
if [ -n "$REGOCD_LAUFWERK" ]; then
  GRUPPE="$(stat -c '%g' "$REGOCD_LAUFWERK" 2>/dev/null || true)"
  [ -n "$GRUPPE" ] && gut "Laufwerk gehört Gruppe $GRUPPE"
fi

# ------------------------------------------------------------------- Registry

schritt "Registry erreichbar?"
if ! curl -fsS --max-time 10 "http://${REGOCD_REGISTRY}/v2/_catalog" >/dev/null 2>&1; then
  ende "Unter http://${REGOCD_REGISTRY}/v2/ antwortet nichts. Läuft die Registry, und ist sie erreichbar?"
fi
gut "erreichbar"

# Docker verlangt für unverschlüsselte Registrys eine ausdrückliche Erlaubnis.
# Im eigenen Netz ist das vertretbar -- aber es muss eingetragen sein, sonst
# scheitert das Holen mit einer Meldung über HTTPS, die niemand erwartet.
if ! docker info 2>/dev/null | grep -q "$REGOCD_REGISTRY"; then
  schritt "Registry als unverschlüsselt eintragen"
  mkdir -p /etc/docker
  if [ -s /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.vor-regocd"
    python3 - "$REGOCD_REGISTRY" <<'PY' || warnen "daemon.json liess sich nicht ändern — bitte von Hand."
import json, sys
pfad = "/etc/docker/daemon.json"
with open(pfad) as f:
    daten = json.load(f)
liste = daten.setdefault("insecure-registries", [])
if sys.argv[1] not in liste:
    liste.append(sys.argv[1])
with open(pfad, "w") as f:
    json.dump(daten, f, indent=2)
PY
  else
    printf '{\n  "insecure-registries": ["%s"]\n}\n' "$REGOCD_REGISTRY" > /etc/docker/daemon.json
  fi
  systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
  sleep 3
  gut "eingetragen"
fi

# ------------------------------------------------------------------ Einrichten

schritt "Verzeichnisse anlegen"
for verzeichnis in "$REGOCD_ARCHIV" "$REGOCD_DATENBANK" "$REGOCD_ARBEIT" "$REGOCD_SICHERUNG"; do
  mkdir -p "$verzeichnis" || ende "$verzeichnis liess sich nicht anlegen."
  [ -w "$verzeichnis" ] || ende "$verzeichnis ist nicht beschreibbar."
done
gut "CD-Archiv  $REGOCD_ARCHIV"
gut "Datenbank  $REGOCD_DATENBANK"
gut "Sicherung  $REGOCD_SICHERUNG"
gut "Arbeit     $REGOCD_ARBEIT"

# Die Sicherungsplatte ist oft nicht angesteckt -- das ist kein Fehler, aber
# es gehört gesagt, damit später niemand rätselt, warum dort nichts ankommt.
if ! mountpoint -q "$REGOCD_SICHERUNG" 2>/dev/null && [ "$REGOCD_SICHERUNG" = "${REGOCD_WURZEL}/sicherung" ]; then
  warnen "Die Sicherung liegt im Docker-Ordner, also auf derselben Platte."
  warnen "Das schützt vor Versehen, nicht vor Plattenausfall — ein Ziel ausserhalb steht noch aus."
fi

schritt "Abbild holen"
docker pull "${REGOCD_REGISTRY}/regocd:${REGOCD_MARKE}" >/dev/null \
  || ende "Das Abbild ${REGOCD_REGISTRY}/regocd:${REGOCD_MARKE} liess sich nicht holen."
gut "geholt"

schritt "Container einrichten"
mkdir -p /etc/regocd
# Das Netz des Wirts, nicht das eigene: Die Player im Netz werden über SSDP
# gesucht, und das ist Multicast. Aus einem Bridge-Netz kommt es nicht heraus
# beziehungsweise die Antworten nicht hinein -- der Container fände dann
# **keinen einzigen** Player, während alles andere tadellos läuft.
# Nachgemessen: Bridge 0 Player, Wirtsnetz 5.
#
# Damit entfällt die Port-Zuordnung: Der Dienst horcht direkt auf dem Wirt,
# und der Port kommt als Einstellung statt als Abbildung.
cat > /etc/regocd/docker-compose.yml <<COMPOSE
services:
  regocd:
    image: ${REGOCD_REGISTRY}/regocd:${REGOCD_MARKE}
    container_name: regocd
    restart: unless-stopped
    network_mode: host
    environment:
      REGOCD_PORT: "${REGOCD_PORT}"
      REGOCD_STELLE: "${REGOCD_STELLE}"
      # Nur zum Fragen, ob eine neuere Ausgabe bereitliegt -- der Dienst holt
      # und startet nichts von selbst. Ohne diesen Eintrag bliebe der Hinweis
      # aus, und genau das war der Grund, warum der NAS wochenlang auf einer
      # alten Baunummer stand, ohne dass es jemandem auffiel.
      REGOCD_REGISTRY: "${REGOCD_REGISTRY}"
      TZ: "${REGOCD_ZEITZONE}"
    volumes:
      - ${REGOCD_DATENBANK}:/data
      - ${REGOCD_ARCHIV}:/musik
      - ${REGOCD_ARBEIT}:/arbeit
      - ${REGOCD_SICHERUNG}:/sicherung
COMPOSE

if [ -n "$REGOCD_LAUFWERK" ]; then
  cat >> /etc/regocd/docker-compose.yml <<COMPOSE
    devices:
      - ${REGOCD_LAUFWERK}:/dev/sr0
COMPOSE
  [ -n "$GRUPPE" ] && cat >> /etc/regocd/docker-compose.yml <<COMPOSE
    group_add:
      - "${GRUPPE}"
COMPOSE
fi

docker compose -f /etc/regocd/docker-compose.yml up -d >/dev/null \
  || ende "Der Container liess sich nicht starten."

# ------------------------------------------------------------------- Nachsehen

schritt "Anlaufen abwarten"
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${REGOCD_PORT}/api/system" >/dev/null 2>&1; then
    gut "antwortet"
    break
  fi
  sleep 2
done

if ! curl -fsS --max-time 5 "http://127.0.0.1:${REGOCD_PORT}/api/system" >/dev/null 2>&1; then
  warnen "Der Dienst antwortet noch nicht. Was er sagt:"
  docker logs --tail 20 regocd 2>&1 | sed 's/^/    /'
  ende "Nicht angelaufen."
fi

ZUSTAND="$(curl -fsS "http://127.0.0.1:${REGOCD_PORT}/api/system" 2>/dev/null \
  | sed -n 's/.*"laufwerk":"\([^"]*\)".*/\1/p')"

# ------------------------------------------------- Landet die Musik draussen?
#
# **Die Frage, die sonst erst beim nächsten Update auffällt.** Läuft ein
# Container ohne Volume (oder mit einem anderen Pfad), schreibt der Dienst
# fröhlich weiter -- nur eben *in den Container*. Alles sieht richtig aus, die
# Alben stehen in der Oberfläche, und beim nächsten `docker compose up -d`
# sind sie weg, weil der Container ersetzt wird.
#
# Deshalb wird hier verglichen: Was sieht der Dienst unter /musik, und was
# liegt auf dem NAS im eingehängten Ordner? Beides muss dasselbe sein.
schritt "Landet die Musik auf dem NAS?"
IM_CONTAINER="$(docker exec regocd sh -c 'ls -1 /musik 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \r')"
AUF_DEM_NAS="$(ls -1 "$REGOCD_ARCHIV" 2>/dev/null | wc -l | tr -d ' ')"
: "${IM_CONTAINER:=0}"
: "${AUF_DEM_NAS:=0}"

if [ "$IM_CONTAINER" -gt 0 ] && [ "$AUF_DEM_NAS" -eq 0 ]; then
  warnen "Der Dienst sieht ${IM_CONTAINER} Einträge unter /musik — auf dem NAS liegt nichts."
  warnen "Die Aufnahmen liegen dann IM CONTAINER und sind beim nächsten Update weg."
  warnen "Retten, bevor der Container ersetzt wird:"
  warnen "    docker cp regocd:/musik/. \"${REGOCD_ARCHIV}/\""
  warnen "Danach dieses Skript noch einmal laufen lassen."
elif [ "$IM_CONTAINER" -ne "$AUF_DEM_NAS" ]; then
  warnen "Der Dienst sieht ${IM_CONTAINER} Einträge, auf dem NAS liegen ${AUF_DEM_NAS}."
  warnen "Zeigt ${REGOCD_ARCHIV} wirklich dorthin, wo die Alben liegen?"
else
  gut "${AUF_DEM_NAS} Einträge — Dienst und NAS sehen dasselbe"
fi

# Und die Gegenprobe mit einer Datei: Lesen allein beweist nicht, dass der
# Dienst auch schreiben darf. Ein Volume, das dem Container nur lesend
# gehört, fällt sonst erst beim ersten Rippen auf -- nach 40 Minuten.
if docker exec regocd sh -c 'touch /musik/.regocd-probe && rm -f /musik/.regocd-probe' 2>/dev/null; then
  gut "der Dienst darf ins Archiv schreiben"
else
  warnen "Der Dienst darf NICHT in ${REGOCD_ARCHIV} schreiben — Rechte prüfen."
fi

sagen ""
schritt "Fertig"
sagen "  Oberfläche   http://$(hostname -I 2>/dev/null | awk '{print $1}'):${REGOCD_PORT}"
sagen "  CD-Archiv    ${REGOCD_ARCHIV}"
sagen "  Datenbank    ${REGOCD_DATENBANK}"
sagen "  Sicherung    ${REGOCD_SICHERUNG}"
sagen "  Arbeit       ${REGOCD_ARBEIT}"
sagen "  Laufwerk     ${LAUFWERK:-keines} (meldet: ${ZUSTAND:-unbekannt})"
sagen "  Instanz      ${REGOCD_STELLE}"
sagen "  Einstellung  /etc/regocd/docker-compose.yml"
sagen ""
sagen "  Neue Ausgabe holen:"
sagen "      docker compose -f /etc/regocd/docker-compose.yml pull"
sagen "      docker compose -f /etc/regocd/docker-compose.yml up -d"
sagen ""
