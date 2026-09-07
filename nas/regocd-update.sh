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

[ "$(id -u)" -eq 0 ] || ende "Bitte als root ausführen (oder mit sudo)."
[ -f "$EINSTELLUNG" ] || ende "$EINSTELLUNG fehlt — REGOcd ist hier nicht eingerichtet."
command -v docker >/dev/null 2>&1 || ende "Docker fehlt."

# Welche Ausgabe gerade läuft, für den Fall, dass zurückgegangen werden muss.
ALT="$(docker inspect --format '{{.Image}}' regocd 2>/dev/null || true)"
# Der Port steht in der Einstellungsdatei als "aussen:innen". Innen ist immer
# 8080 -- darauf horcht der Dienst im Container, das ist im Abbild festgelegt.
# Gesucht wird also die Zahl davor.
PORT="$(sed -n 's/.*"\([0-9]\+\):8080".*/\1/p' "$EINSTELLUNG" | head -1)"
PORT="${PORT:-8090}"

VORHER="$(curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/version" 2>/dev/null \
  | sed -n 's/.*"build":\([0-9]*\).*/\1/p')"
[ -n "$VORHER" ] && sagen "  Läuft gerade: Build ${VORHER}"

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
[ -n "$BEREIT" ] && gut "antwortet"

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
[ -n "$ALBEN" ] && sagen "  Bibliothek: ${ALBEN} Alben — unverändert"

# Alte Abbilder liegen sonst unbemerkt herum -- auf einem NAS mit begrenztem
# Systemspeicher fällt das irgendwann unangenehm auf.
schritt "Alte Abbilder aufräumen"
docker image prune -f >/dev/null 2>&1 || true
gut "erledigt"
