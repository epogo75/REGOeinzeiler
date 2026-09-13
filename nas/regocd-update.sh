#!/usr/bin/env bash
#
# Holt die neueste Ausgabe von REGOcd und startet sie. Nichts weiter.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd-update.sh)"
#
# Sicher gegen Fehlschläge: Ist das neue Abbild kaputt oder antwortet der
# Dienst nicht, wird die vorherige Ausgabe wieder gestartet. Ein Update, das
# einen laufenden Dienst zerstört, ist schlimmer als keines.

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

EINSTELLUNG="/etc/regocd/docker-compose.yml"

# ------------------------------------------------------ Die Pfade des Hauses
#
# **Hier stehen sie, damit niemand sie tippen muss.** Das Update hängt sie
# nicht einfach um -- wo Dateien liegen, entscheidet nicht ein Update. Es
# vergleicht und sagt, was abweicht: Ein leerer Einhängepunkt wird
# nachgetragen, ein voller bleibt, und dafür gibt es das Umzugsskript.
#
# Jeder Wert lässt sich vorab überschreiben (REGOCD_ARCHIV=... usw.).
SOLL_ARCHIV="${REGOCD_ARCHIV:-/volume2/music/regocd}"
SOLL_DATEN="${REGOCD_DATENBANK:-/volume1/docker/regocd/data}"
SOLL_ARBEIT="${REGOCD_ARBEIT:-/volume1/docker/regocd/arbeit}"
# Die externe Platte. Auf UGREEN-Geräten hängen USB-Datenträger unter
# /mnt/@usb/<gerät>; steckt sie nicht, bleibt die Sicherung, wo sie ist --
# eine Sicherung, die ins Leere läuft, ist schlimmer als eine am falschen Ort.
SOLL_SICHERUNG="${REGOCD_SICHERUNG:-/mnt/@usb/sdc1/regocd-sicherung}"

[ "$(id -u)" -eq 0 ] || ende "Bitte als root ausführen (oder mit sudo)."
[ -f "$EINSTELLUNG" ] || ende "$EINSTELLUNG fehlt — REGOcd ist hier nicht eingerichtet."
command -v docker >/dev/null 2>&1 || ende "Docker fehlt."

# Welche Ausgabe gerade läuft, für den Fall, dass zurückgegangen werden muss.
ALT="$(docker inspect --format '{{.Image}}' regocd 2>/dev/null || true)"
# Der Port steht als Einstellung in der Datei (REGOCD_PORT). Ältere
# Einrichtungen nutzten noch eine Port-Abbildung "aussen:8080" -- beides wird
# gelesen, damit ein Update nicht an der eigenen Vorgeschichte scheitert.
PORT="$(sed -n 's/.*REGOCD_PORT: *"\?\([0-9]\+\).*/\1/p' "$EINSTELLUNG" | head -1)"
[ -z "$PORT" ] && PORT="$(sed -n 's/.*"\([0-9]\+\):8080".*/\1/p' "$EINSTELLUNG" | head -1)" || true
PORT="${PORT:-8090}"

VORHER="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/version" 2>/dev/null \
  | sed -n 's/.*"build":\([0-9]*\).*/\1/p')"
[ -n "$VORHER" ] && sagen "  Läuft gerade: Build ${VORHER}" || true

# Wo die Daten liegen -- das Wichtigste beim Update: Sie liegen **ausserhalb**
# des Containers. Getauscht wird nur das Abbild; Datenbank, Musik und Cover
# bleiben, wo sie sind. Trotzdem hingeschrieben, damit niemand raten muss.
sagen ""
sagen "  Diese Verzeichnisse bleiben unangetastet:"
# Mit grep und awk statt einem sed-Muster: Das war zu leicht danebengegriffen,
# und eine leere Liste an dieser Stelle wäre die schlechteste Auskunft --
# gerade hier will man sichergehen.
grep -oE '/[^ ]+:/(data|musik|arbeit|sicherung)' "$EINSTELLUNG" 2>/dev/null \
  | awk -F: '
      { name = $2
        sub("^/", "", name)
        if (name == "data")      name = "Datenbank"
        else if (name == "musik") name = "CD-Archiv"
        else if (name == "arbeit") name = "Arbeit"
        else if (name == "sicherung") name = "Sicherung"
        printf "      %-11s %s\n", name, $1 }' || true
sagen ""

# Nachrüsten, was in älteren Einrichtungen fehlt: Der Name der Instanz steht
# seit Build 48 in der Seitenspalte -- ohne ihn sähe das NAS aus wie die
# Entwicklungsmaschine, und genau diese Verwechslung soll er verhindern.
if ! grep -q "REGOCD_STELLE" "$EINSTELLUNG"; then
  schritt "Name der Instanz nachtragen"
  NAME="${REGOCD_STELLE:-NAS}"
  if grep -q "REGOCD_PORT" "$EINSTELLUNG"; then
    sed -i "/REGOCD_PORT/a\      REGOCD_STELLE: \"${NAME}\"" "$EINSTELLUNG"
    gut "als \"${NAME}\" eingetragen (mit REGOCD_STELLE=... änderbar)"
  else
    warnen "Kein Platz für den Namen gefunden — bitte von Hand in $EINSTELLUNG."
  fi
fi

# Ebenso nachrüsten: Woher die Abbilder kommen. Der Dienst fragt damit von
# sich aus, ob eine neuere Ausgabe bereitliegt, und sagt es im Über-Dialog --
# er holt und startet nichts. Ohne diesen Eintrag bliebe der Hinweis stumm,
# und genau daran lag es, dass das NAS wochenlang auf einer alten Baunummer
# stand, ohne dass es jemandem auffiel. Die Adresse steht schon in der Datei:
# in der Zeile mit dem Abbild.
if ! grep -q "REGOCD_REGISTRY" "$EINSTELLUNG"; then
  ADRESSE="$(sed -n 's|^ *image: *\([^/]*\)/regocd:.*|\1|p' "$EINSTELLUNG" | head -1)"
  if [ -n "$ADRESSE" ] && grep -q "REGOCD_PORT" "$EINSTELLUNG"; then
    schritt "Registry-Adresse nachtragen"
    sed -i "/REGOCD_PORT/a\      REGOCD_REGISTRY: \"${ADRESSE}\"" "$EINSTELLUNG"
    gut "${ADRESSE} eingetragen — künftige Ausgaben melden sich von selbst"
  fi
fi

# Und die Zeitzone. Ohne sie läuft der Behälter in UTC -- der Nachtdienst
# sichert dann um 03:00 UTC, was im Sommer 05:00 Ortszeit ist. Beim ersten
# Probelauf fiel die Sicherung dadurch mitten in den Abend.
if ! grep -q "TZ:" "$EINSTELLUNG"; then
  ZONE="${REGOCD_ZEITZONE:-$(cat /etc/timezone 2>/dev/null || echo Europe/Berlin)}"
  if grep -q "REGOCD_PORT" "$EINSTELLUNG"; then
    schritt "Zeitzone nachtragen"
    sed -i "/REGOCD_PORT/a\      TZ: \"${ZONE}\"" "$EINSTELLUNG"
    gut "${ZONE} eingetragen (mit REGOCD_ZEITZONE=... änderbar)"
  fi
fi

# ------------------------------------------------------- Stimmen die Pfade?
#
# Verglichen wird gegen die Pfade des Hauses (oben). Umgehängt wird nur, was
# gefahrlos ist: ein Einhängepunkt, der fehlt, oder einer, dessen alter Ort
# leer ist. Wo Dateien liegen, bleibt es beim alten Ort -- und es steht da,
# was zu tun wäre.
pfad_pruefen() {
  local ziel="$1" soll="$2" name="$3"
  local ist
  # Ohne `|| true` beendet ein erfolgloses `grep` unter `set -e` das Skript.
  ist="$(grep -oE "/[^ ]+:${ziel}\b" "$EINSTELLUNG" 2>/dev/null | head -1 | cut -d: -f1 || true)"

  if [ -z "$ist" ]; then
    warnen "${name}: nichts auf ${ziel} eingehängt — wird auf ${soll} gesetzt."
    mkdir -p "$soll"
    sed -i "/volumes:/a\      ${soll}:${ziel}" "$EINSTELLUNG"
    return
  fi
  if [ "$ist" = "$soll" ]; then
    gut "${name}: ${ist}"
    return
  fi

  local anzahl
  anzahl="$(find "$ist" -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${anzahl:-0}" -eq 0 ]; then
    mkdir -p "$soll"
    sed -i "s|${ist}:${ziel}|${soll}:${ziel}|" "$EINSTELLUNG"
    gut "${name}: ${ist} war leer → ${soll}"
  else
    warnen "${name}: liegt unter ${ist} (${anzahl} Dateien), vorgesehen ist ${soll}."
    warnen "Ein Update verschiebt nichts. Zum Umziehen:"
    sagen  "      sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd-umziehen.sh)\""
  fi
}

schritt "Stimmen die Pfade?"
cp "$EINSTELLUNG" "${EINSTELLUNG}.vor-update"
pfad_pruefen "/musik"     "$SOLL_ARCHIV"    "CD-Archiv"
pfad_pruefen "/data"      "$SOLL_DATEN"     "Datenbank"
pfad_pruefen "/arbeit"    "$SOLL_ARBEIT"    "Arbeit"
# Die Sicherung nur, wenn die Platte auch steckt -- sonst schreibt der
# Nachtdienst in ein Verzeichnis, das aussieht wie ein Einhängepunkt.
if [ -d "$(dirname "$SOLL_SICHERUNG")" ]; then
  pfad_pruefen "/sicherung" "$SOLL_SICHERUNG" "Sicherung"
else
  warnen "Sicherung: $(dirname "$SOLL_SICHERUNG") gibt es nicht — bleibt, wie es ist."
  warnen "Steckt die Platte? Was angeschlossen ist, zeigt: lsblk -o NAME,TRAN,SIZE,MOUNTPOINT"
fi

# ----------------------------------------- Liegt die Musik wirklich draussen?
#
# **Der gefährlichste Augenblick eines Updates.** Gleich wird der Container
# ersetzt. Alles, was *in ihm* liegt statt in einem eingehängten Ordner, ist
# danach weg -- und ein Container ohne Volume schreibt fröhlich weiter,
# solange er läuft: Die Alben stehen in der Oberfläche, die Platte des NAS
# bleibt leer, und niemand merkt es, bis genau hier getauscht wird.
#
# Deshalb wird vorher verglichen, und im Zweifel wird **nicht** getauscht.
schritt "Liegt die Musik ausserhalb des Containers?"
ARCHIV="$(grep -oE '/[^ ]+:/musik' "$EINSTELLUNG" 2>/dev/null | head -1 | cut -d: -f1 || true)"
if [ -z "$ARCHIV" ]; then
  warnen "In $EINSTELLUNG ist kein Ordner auf /musik eingehängt."
  warnen "Alles, was gerippt wurde, liegt dann im Container und geht beim Tausch verloren."
  ende "Bitte zuerst einrichten (nas/regocd.sh) — das Update würde Aufnahmen kosten."
fi

IM_CONTAINER="$(docker exec regocd sh -c 'ls -1 /musik 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \r')"
AUF_DEM_NAS="$(ls -1 "$ARCHIV" 2>/dev/null | wc -l | tr -d ' ')"
: "${IM_CONTAINER:=0}"
: "${AUF_DEM_NAS:=0}"

if [ "$IM_CONTAINER" -gt 0 ] && [ "$AUF_DEM_NAS" -eq 0 ]; then
  warnen "Der Dienst sieht ${IM_CONTAINER} Einträge unter /musik, in ${ARCHIV} liegt nichts."
  warnen "Die Aufnahmen liegen im Container. Ein Tausch würde sie löschen."
  sagen ""
  sagen "  Erst retten, dann erneut starten:"
  sagen "      docker cp regocd:/musik/. \"${ARCHIV}/\""
  sagen ""
  ende "Abgebrochen, damit nichts verlorengeht."
fi
gut "${AUF_DEM_NAS} Einträge in ${ARCHIV} (der Dienst sieht ${IM_CONTAINER})"

schritt "Neues Abbild holen"
# Am Rückgabewert, nicht an der Ausgabe: Docker formuliert je nach Ausgabe
# anders, und eine Warnung, die bei jedem geglückten Lauf erscheint, gewöhnt
# einem das Hinsehen ab.
if ! docker compose -f "$EINSTELLUNG" pull >/dev/null 2>&1; then
  ende "Das Abbild liess sich nicht holen. Läuft die Registry, und ist sie erreichbar?"
fi
gut "geholt"

schritt "Neu starten"
docker compose -f "$EINSTELLUNG" up -d >/dev/null || ende "Der Start ist gescheitert."

schritt "Anlaufen abwarten"
BEREIT=""
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/system" >/dev/null 2>&1; then
    BEREIT="ja"
    break
  fi
  sleep 2
done
[ -n "$BEREIT" ] && gut "antwortet" || true

if [ -z "$BEREIT" ]; then
  warnen "Die neue Ausgabe antwortet nicht. Was sie sagt:"
  docker logs --tail 20 regocd 2>&1 | sed 's/^/    /'
  if [ -n "$ALT" ]; then
    schritt "Zurück auf die vorherige Ausgabe"
    # Über dieselbe Compose-Datei, nur mit der alten Abbildkennung: So kommen
    # die Verzeichnisse wieder mit. Ein blosses `docker run` startete den
    # Dienst **ohne** Datenbank und Musik -- er sähe leer aus, und wer das
    # sieht, glaubt an Datenverlust.
    cp "$EINSTELLUNG" "${EINSTELLUNG}.neu"
    sed -i "s|^\( *image: \).*|\1${ALT}|" "$EINSTELLUNG"
    if docker compose -f "$EINSTELLUNG" up -d >/dev/null 2>&1; then
      warnen "Die vorherige Ausgabe läuft wieder, mit allen Verzeichnissen."
      warnen "Die neue Einstellung liegt als ${EINSTELLUNG}.neu daneben."
    else
      mv "${EINSTELLUNG}.neu" "$EINSTELLUNG"
      warnen "Auch der Rückweg ist gescheitert — bitte von Hand nachsehen."
    fi
  fi
  ende "Update fehlgeschlagen."
fi

NACHHER="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/version" 2>/dev/null \
  | sed -n 's/.*"build":\([0-9]*\).*/\1/p')"

sagen ""
if [ -n "$VORHER" ] && [ "$VORHER" = "$NACHHER" ]; then
  gut "Schon aktuell (Build ${NACHHER}) — nichts zu tun."
else
  gut "Jetzt Build ${NACHHER:-unbekannt}${VORHER:+ (vorher ${VORHER})}"
fi
sagen "  Oberfläche: http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}"
ALBEN="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/system" 2>/dev/null \
  | sed -n 's/.*"alben":\([0-9]*\).*/\1/p')"
[ -n "$ALBEN" ] && sagen "  Bibliothek: ${ALBEN} Alben — unverändert" || true

# Alte Abbilder liegen sonst unbemerkt herum -- auf einem NAS mit begrenztem
# Systemspeicher fällt das irgendwann unangenehm auf.
schritt "Alte Abbilder aufräumen"
docker image prune -f >/dev/null 2>&1 || true
gut "erledigt"
