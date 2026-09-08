#!/usr/bin/env bash
#
# Richtet documento auf einem NAS oder Linux-Rechner mit Docker ein: Abbild aus
# der eigenen Registry holen, Verzeichnisse anlegen, Container starten.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/documento.sh)"
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
# bearbeiten zu müssen. Mit DOCUMENTO_STILL=ja wird gar nicht gefragt.
frage() {
  local text="$1" vorgabe="$2" ziel="$3" eingabe=""
  local gesetzt="${!ziel-}"

  if [ -n "$gesetzt" ]; then
    sagen "  ${text}: ${gesetzt}"
    return
  fi
  if [ "${DOCUMENTO_STILL:-}" = "ja" ]; then
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

schritt "documento einrichten"
sagen ""

frage "Registry (Rechner:Port)" "192.168.1.43:5000" DOCUMENTO_REGISTRY
frage "Ausgabe (latest oder z. B. b3)" "latest" DOCUMENTO_MARKE
frage "Port für die Oberfläche" "8091" DOCUMENTO_PORT
# Steht in der Oberfläche. Zwei gleich aussehende Instanzen im selben Netz
# sind sonst kaum auseinanderzuhalten -- man erfasst auf der einen und sucht
# die Stunden auf der anderen.
frage "Name dieser Instanz (steht in der Oberfläche)" "NAS" DOCUMENTO_STELLE
# Ohne Zeitzone läuft ein Container in UTC. Bei Tagesrapporten entscheidet
# sie, welchem Tag eine Erfassung zugerechnet wird -- und wann nachts
# gesichert wird. Deshalb wird sie gefragt und nicht geraten.
frage "Zeitzone" "Europe/Berlin" DOCUMENTO_ZEITZONE

# Die Einhängepunkte einzeln, nicht unter einer Wurzel: Auf einem NAS liegen
# sie selten beieinander. Die Dokumente gehören auf den grossen Speicherpool,
# die Sicherung auf eine externe Platte (die auch mal abgezogen wird), und die
# Datenbank auf etwas Zuverlässiges.
sagen ""
sagen "  Wohin die Bereiche gehören:"
frage "  Grundverzeichnis (Vorgabe für alles Weitere)" "/volume1/documento" DOCUMENTO_WURZEL
frage "  Datenbank (die Stunden selbst, klein)" "${DOCUMENTO_WURZEL}/daten" DOCUMENTO_DATENBANK
frage "  Dokumente (Fotos und PDF je Projekt, wächst)" "${DOCUMENTO_WURZEL}/dokumente" DOCUMENTO_DOKUMENTE
frage "  Sicherung (die externe Platte)" "${DOCUMENTO_WURZEL}/sicherung" DOCUMENTO_SICHERUNG

# Das Anfangskennwort des Admins. Es steht sonst im Protokoll des Containers,
# und dort sieht es niemand -- hier wird danach gefragt, damit es von Anfang
# an ein eigenes ist.
sagen ""
frage "Anfangskennwort für den Benutzer „admin“" "documento-start" DOCUMENTO_ADMIN_PASSWORT

# ------------------------------------------------------------------- Registry

schritt "Registry erreichbar?"
if ! curl -fsS --max-time 10 "http://${DOCUMENTO_REGISTRY}/v2/_catalog" >/dev/null 2>&1; then
  ende "Unter http://${DOCUMENTO_REGISTRY}/v2/ antwortet nichts. Läuft die Registry?"
fi
gut "erreichbar"

# Docker verlangt für unverschlüsselte Registrys eine ausdrückliche Erlaubnis.
# Im eigenen Netz ist das vertretbar -- aber es muss eingetragen sein, sonst
# scheitert das Holen mit einer Meldung über HTTPS, die niemand erwartet.
if ! docker info 2>/dev/null | grep -q "$DOCUMENTO_REGISTRY"; then
  schritt "Registry als unverschlüsselt eintragen"
  mkdir -p /etc/docker
  if [ -s /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json "/etc/docker/daemon.json.vor-documento"
    python3 - "$DOCUMENTO_REGISTRY" <<'PY' || warnen "daemon.json liess sich nicht ändern — bitte von Hand."
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
    printf '{\n  "insecure-registries": ["%s"]\n}\n' "$DOCUMENTO_REGISTRY" > /etc/docker/daemon.json
  fi
  systemctl restart docker 2>/dev/null || service docker restart 2>/dev/null || true
  sleep 3
  gut "eingetragen"
fi

# ------------------------------------------------------------------ Einrichten

schritt "Verzeichnisse anlegen"
for verzeichnis in "$DOCUMENTO_DATENBANK" "$DOCUMENTO_DOKUMENTE" "$DOCUMENTO_SICHERUNG"; do
  mkdir -p "$verzeichnis" || ende "$verzeichnis liess sich nicht anlegen."
  [ -w "$verzeichnis" ] || ende "$verzeichnis ist nicht beschreibbar."
done
gut "Datenbank  $DOCUMENTO_DATENBANK"
gut "Dokumente  $DOCUMENTO_DOKUMENTE"
gut "Sicherung  $DOCUMENTO_SICHERUNG"

# Die Sicherungsplatte ist oft nicht angesteckt -- das ist kein Fehler, aber
# es gehört gesagt, damit später niemand rätselt, warum dort nichts ankommt.
if ! mountpoint -q "$DOCUMENTO_SICHERUNG" 2>/dev/null \
   && [ "$DOCUMENTO_SICHERUNG" = "${DOCUMENTO_WURZEL}/sicherung" ]; then
  warnen "Die Sicherung liegt im Grundverzeichnis, also auf derselben Platte."
  warnen "Das schützt vor Versehen, nicht vor Plattenausfall."
fi

schritt "Abbild holen"
docker pull "${DOCUMENTO_REGISTRY}/documento:${DOCUMENTO_MARKE}" >/dev/null \
  || ende "Das Abbild ${DOCUMENTO_REGISTRY}/documento:${DOCUMENTO_MARKE} liess sich nicht holen."
gut "geholt"

schritt "Container einrichten"
mkdir -p /etc/documento
# Anders als REGOcd braucht documento **kein** Wirtsnetz: Es sucht nichts per
# Multicast, es wartet nur auf Anfragen. Eine gewöhnliche Portabbildung ist
# hier die einfachere und besser eingegrenzte Lösung.
cat > /etc/documento/docker-compose.yml <<COMPOSE
services:
  documento:
    image: ${DOCUMENTO_REGISTRY}/documento:${DOCUMENTO_MARKE}
    container_name: documento
    restart: unless-stopped
    ports:
      - "${DOCUMENTO_PORT}:8091"
    environment:
      DOCUMENTO_PORT: "8091"
      DOCUMENTO_STELLE: "${DOCUMENTO_STELLE}"
      DOCUMENTO_ADMIN_PASSWORT: "${DOCUMENTO_ADMIN_PASSWORT}"
      TZ: "${DOCUMENTO_ZEITZONE}"
    volumes:
      - ${DOCUMENTO_DATENBANK}:/data
      - ${DOCUMENTO_DOKUMENTE}:/dokumente
      - ${DOCUMENTO_SICHERUNG}:/sicherung
COMPOSE

docker compose -f /etc/documento/docker-compose.yml up -d >/dev/null \
  || ende "Der Container liess sich nicht starten."

# ------------------------------------------------------------------- Nachsehen

schritt "Anlaufen abwarten"
# `/api/version` und nicht `/api/system`: Letzteres verlangt eine Anmeldung --
# es täte hier so, als sei der Dienst kaputt, obwohl er nur richtig arbeitet.
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${DOCUMENTO_PORT}/api/version" >/dev/null 2>&1; then
    gut "antwortet"
    break
  fi
  sleep 2
done

if ! curl -fsS --max-time 5 "http://127.0.0.1:${DOCUMENTO_PORT}/api/version" >/dev/null 2>&1; then
  warnen "Der Dienst antwortet noch nicht. Was er sagt:"
  docker logs --tail 20 documento 2>&1 | sed 's/^/    /'
  ende "Nicht angelaufen."
fi

BUILD="$(curl -fsS "http://127.0.0.1:${DOCUMENTO_PORT}/api/version" 2>/dev/null \
  | sed -n 's/.*"build":\([0-9]*\).*/\1/p')"

ADRESSE="$(hostname -I 2>/dev/null | awk '{print $1}')"
sagen ""
schritt "Fertig"
sagen "  Oberfläche   http://${ADRESSE:-<dieser Rechner>}:${DOCUMENTO_PORT}"
sagen "  Build        ${BUILD:-unbekannt}"
sagen "  Instanz      ${DOCUMENTO_STELLE}"
sagen "  Datenbank    ${DOCUMENTO_DATENBANK}"
sagen "  Dokumente    ${DOCUMENTO_DOKUMENTE}"
sagen "  Sicherung    ${DOCUMENTO_SICHERUNG}"
sagen "  Einstellung  /etc/documento/docker-compose.yml"
sagen ""
sagen "  Erste Anmeldung: Benutzer „admin“, das eben vergebene Kennwort."
warnen "Das Kennwort steht jetzt in der Compose-Datei — nach der ersten Anmeldung"
warnen "in der Verwaltung ändern und die Zeile dort entfernen."
