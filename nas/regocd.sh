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

frage() {
  local text="$1" vorgabe="$2" ziel="$3" eingabe=""
  read -r -p "  ${text} [${vorgabe}]: " eingabe </dev/tty || true
  printf -v "$ziel" '%s' "${eingabe:-$vorgabe}"
}

# ------------------------------------------------------------- Voraussetzungen

[ "$(id -u)" -eq 0 ] || ende "Bitte als root ausführen (oder mit sudo)."
command -v docker >/dev/null 2>&1 || ende "Docker fehlt."
docker compose version >/dev/null 2>&1 || ende "Das Compose-Zusatzmodul fehlt."

schritt "REGOcd einrichten"
sagen ""

frage "Registry (Rechner:Port)" "192.168.1.43:5000" REGISTRY
frage "Ausgabe (latest oder z. B. b45)" "latest" MARKE
frage "Port für die Oberfläche" "8080" PORT
frage "CD-Laufwerk" "/dev/sr0" LAUFWERK

# Die Einhängepunkte einzeln, nicht unter einer Wurzel: Auf einem NAS liegen
# sie selten beieinander. Das CD-Archiv gehört auf den grossen Speicherpool,
# die Sicherung auf eine externe Platte (die auch mal abgezogen wird), und die
# Datenbank auf etwas Zuverlässiges. Der Arbeitsordner ist der einzige, der
# meist einfach bei der Wurzel bleiben kann -- dort liegen die Daten nur,
# solange eine CD gerippt wird.
sagen ""
sagen "  Wohin die Bereiche gehören:"
frage "  Grundverzeichnis (Vorgabe für alles Weitere)" "/volume1/regocd" WURZEL
frage "  CD-Archiv (die FLAC-Dateien, wächst)" "${WURZEL}/musik" MUSIK
frage "  Datenbank (mit den Covern, klein)" "${WURZEL}/daten" DATEN
frage "  Sicherung (die externe Platte)" "${WURZEL}/sicherung" SICHERUNG
frage "  Arbeitsordner (nur während des Rippens)" "${WURZEL}/arbeit" ARBEIT

# ------------------------------------------------------------------ Laufwerk

if [ ! -e "$LAUFWERK" ]; then
  warnen "$LAUFWERK gibt es nicht. Ohne Laufwerk läuft alles ausser dem Rippen."
  warnen "Bei einem USB-Laufwerk hilft meist: Gerät anstecken, dann 'lsblk' prüfen."
  read -r -p "  Trotzdem weitermachen? [j/N]: " weiter </dev/tty || true
  case "${weiter:-N}" in [JjYy]*) : ;; *) ende "Abgebrochen." ;; esac
  LAUFWERK=""
fi

# Der Container braucht die Gruppe des Laufwerks, sonst darf er nicht lesen.
GRUPPE=""
if [ -n "$LAUFWERK" ]; then
  GRUPPE="$(stat -c '%g' "$LAUFWERK" 2>/dev/null || true)"
  [ -n "$GRUPPE" ] && gut "Laufwerk gehört Gruppe $GRUPPE"
fi

# ------------------------------------------------------------------- Registry

schritt "Registry erreichbar?"
if ! curl -fsS --max-time 10 "http://${REGISTRY}/v2/_catalog" >/dev/null 2>&1; then
  ende "Unter http://${REGISTRY}/v2/ antwortet nichts. Läuft die Registry, und ist sie erreichbar?"
fi
gut "erreichbar"

# Docker verlangt für unverschlüsselte Registrys eine ausdrückliche Erlaubnis.
# Im eigenen Netz ist das vertretbar -- aber es muss eingetragen sein, sonst
# scheitert das Holen mit einer Meldung über HTTPS, die niemand erwartet.
if ! docker info 2>/dev/null | grep -q "$REGISTRY"; then
  schritt "Registry als unverschlüsselt eintragen"
  mkdir -p /etc/docker
  if [ -s /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.vor-regocd"
    python3 - "$REGISTRY" <<'PY' || warnen "daemon.json liess sich nicht ändern — bitte von Hand."
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
    printf '{\n  "insecure-registries": ["%s"]\n}\n' "$REGISTRY" > /etc/docker/daemon.json
  fi
  systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
  sleep 3
  gut "eingetragen"
fi

# ------------------------------------------------------------------ Einrichten

schritt "Verzeichnisse anlegen"
for verzeichnis in "$MUSIK" "$DATEN" "$ARBEIT" "$SICHERUNG"; do
  mkdir -p "$verzeichnis" || ende "$verzeichnis liess sich nicht anlegen."
  [ -w "$verzeichnis" ] || ende "$verzeichnis ist nicht beschreibbar."
done
gut "CD-Archiv  $MUSIK"
gut "Datenbank  $DATEN"
gut "Sicherung  $SICHERUNG"
gut "Arbeit     $ARBEIT"

# Die Sicherungsplatte ist oft nicht angesteckt -- das ist kein Fehler, aber
# es gehört gesagt, damit später niemand rätselt, warum dort nichts ankommt.
if ! mountpoint -q "$SICHERUNG" 2>/dev/null && [ "$SICHERUNG" = "${WURZEL}/sicherung" ]; then
  warnen "Die Sicherung liegt im Grundverzeichnis, also auf derselben Platte."
  warnen "Eine Sicherung auf derselben Platte schützt vor Versehen, nicht vor Plattenausfall."
fi

schritt "Abbild holen"
docker pull "${REGISTRY}/regocd:${MARKE}" >/dev/null \
  || ende "Das Abbild ${REGISTRY}/regocd:${MARKE} liess sich nicht holen."
gut "geholt"

schritt "Container einrichten"
mkdir -p /etc/regocd
cat > /etc/regocd/docker-compose.yml <<COMPOSE
services:
  regocd:
    image: ${REGISTRY}/regocd:${MARKE}
    container_name: regocd
    restart: unless-stopped
    ports:
      - "${PORT}:8080"
    volumes:
      - ${DATEN}:/data
      - ${MUSIK}:/musik
      - ${ARBEIT}:/arbeit
      - ${SICHERUNG}:/sicherung
COMPOSE

if [ -n "$LAUFWERK" ]; then
  cat >> /etc/regocd/docker-compose.yml <<COMPOSE
    devices:
      - ${LAUFWERK}:/dev/sr0
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
  if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/system" >/dev/null 2>&1; then
    gut "antwortet"
    break
  fi
  sleep 2
done

if ! curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/system" >/dev/null 2>&1; then
  warnen "Der Dienst antwortet noch nicht. Was er sagt:"
  docker logs --tail 20 regocd 2>&1 | sed 's/^/    /'
  ende "Nicht angelaufen."
fi

ZUSTAND="$(curl -fsS "http://127.0.0.1:${PORT}/api/system" 2>/dev/null \
  | sed -n 's/.*"laufwerk":"\([^"]*\)".*/\1/p')"

sagen ""
schritt "Fertig"
sagen "  Oberfläche   http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}"
sagen "  CD-Archiv    ${MUSIK}"
sagen "  Datenbank    ${DATEN}"
sagen "  Sicherung    ${SICHERUNG}"
sagen "  Arbeit       ${ARBEIT}"
sagen "  Laufwerk     ${LAUFWERK:-keines} (meldet: ${ZUSTAND:-unbekannt})"
sagen "  Einstellung  /etc/regocd/docker-compose.yml"
sagen ""
sagen "  Neue Ausgabe holen:"
sagen "      docker compose -f /etc/regocd/docker-compose.yml pull"
sagen "      docker compose -f /etc/regocd/docker-compose.yml up -d"
sagen ""
