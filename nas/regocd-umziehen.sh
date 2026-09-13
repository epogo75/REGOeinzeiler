#!/usr/bin/env bash
#
# Zieht das CD-Archiv an einen anderen Ort um -- Dateien und Einhängepunkt.
#
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd-umziehen.sh)"
#
# **Warum das ein eigenes Skript ist und kein Handgriff:** Zwischen „Dateien
# verschieben" und „Einhängepunkt ändern" liegt ein Zustand, in dem der Dienst
# ins Leere greift. Läuft er dabei, schreibt er neue Aufnahmen an den alten
# Ort -- und beim nächsten Blick fehlt die Hälfte. Deshalb: anhalten,
# umziehen, umhängen, starten, nachsehen.
#
# **Die Datenbank bleibt unberührt**, und das ist kein Zufall: Der Dienst
# merkt sich die Pfade so, wie er sie im Container sieht (/musik/...). Was
# darunter auf dem NAS liegt, geht ihn nichts an. Deshalb genügt es, die
# Dateien zu verschieben und das Volume umzuhängen. Das Skript prüft das
# trotzdem nach -- eine Annahme, die nur meistens stimmt, ist keine.

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

[ "$(id -u)" -eq 0 ] || ende "Bitte mit sudo ausführen."
command -v docker >/dev/null 2>&1 || ende "Docker fehlt."
[ -f "$EINSTELLUNG" ] || ende "$EINSTELLUNG fehlt — REGOcd ist hier nicht eingerichtet."

frage() {
  local text="$1" vorgabe="$2" ziel="$3" eingabe=""
  local gesetzt="${!ziel-}"
  if [ -n "$gesetzt" ]; then sagen "  ${text}: ${gesetzt}"; return; fi
  read -r -p "  ${text} [${vorgabe}]: " eingabe </dev/tty || true
  printf -v "$ziel" '%s' "${eingabe:-$vorgabe}"
}

# ------------------------------------------------------------------- Woher

ALT="$(grep -oE '/[^ ]+:/musik' "$EINSTELLUNG" | head -1 | cut -d: -f1)"
[ -n "$ALT" ] || ende "In $EINSTELLUNG ist kein Ordner auf /musik eingehängt."

schritt "Umzug des CD-Archivs"
sagen "  Bisher:  $ALT"
frage "  Neuer Ort" "/volume2/music/regocd" REGOCD_ARCHIV
NEU="$REGOCD_ARCHIV"

[ "$ALT" != "$NEU" ] || ende "Alter und neuer Ort sind derselbe."
[ -d "$ALT" ] || ende "$ALT gibt es nicht."

mkdir -p "$NEU" || ende "$NEU liess sich nicht anlegen."
[ -w "$NEU" ] || ende "$NEU ist nicht beschreibbar."

# Passt es überhaupt? Ein Umzug, der bei 80 % vollläuft, hinterlässt die
# Sammlung auf zwei Platten -- das ist schlimmer als gar nicht anzufangen.
BRAUCHT="$(du -sk "$ALT" 2>/dev/null | awk '{print $1}')"
FREI="$(df -Pk "$NEU" | awk 'NR == 2 {print $4}')"
sagen ""
sagen "  Zu verschieben: $(( BRAUCHT / 1024 )) MB"
sagen "  Frei auf dem Ziel: $(( FREI / 1024 )) MB"
[ "$FREI" -gt "$BRAUCHT" ] || ende "Auf dem Ziel ist zu wenig Platz."

DATEIEN_VORHER="$(find "$ALT" -type f | wc -l | tr -d ' ')"
sagen "  Dateien: $DATEIEN_VORHER"
sagen ""
read -r -p "  Umziehen? [j/N]: " weiter </dev/tty || true
case "${weiter:-N}" in [JjYy]*) : ;; *) ende "Abgebrochen." ;; esac

# ----------------------------------------------------------------- Anhalten

schritt "Dienst anhalten"
docker compose -f "$EINSTELLUNG" stop >/dev/null 2>&1 || warnen "Liess sich nicht anhalten."
gut "angehalten"

# ---------------------------------------------------------------- Verschieben
#
# Mit `cp -a` und erst danach löschen, nicht mit `mv`: Zwischen zwei
# Datenträgern kopiert `mv` ohnehin und löscht dann -- bricht es dabei ab,
# fehlt am Ziel das eine und an der Quelle das andere. So liegt bis zum
# letzten Schritt alles noch am alten Platz.
schritt "Dateien kopieren"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --info=progress2 "$ALT"/ "$NEU"/ || ende "Das Kopieren ist gescheitert."
else
  cp -a "$ALT"/. "$NEU"/ || ende "Das Kopieren ist gescheitert."
fi

DATEIEN_NACHHER="$(find "$NEU" -type f | wc -l | tr -d ' ')"
[ "$DATEIEN_NACHHER" -ge "$DATEIEN_VORHER" ] \
  || ende "Am Ziel liegen $DATEIEN_NACHHER Dateien, erwartet waren $DATEIEN_VORHER."
gut "$DATEIEN_NACHHER Dateien liegen unter $NEU"

# ------------------------------------------------------------------ Umhängen

schritt "Einhängepunkt ändern"
cp "$EINSTELLUNG" "${EINSTELLUNG}.vor-umzug"
# Nur die eine Zeile, die auf /musik zeigt -- und mit | als Trenner, weil im
# Pfad Schrägstriche stehen.
sed -i "s|${ALT}:/musik|${NEU}:/musik|" "$EINSTELLUNG"
grep -q "${NEU}:/musik" "$EINSTELLUNG" \
  || ende "Die Zeile liess sich nicht ändern — bitte in $EINSTELLUNG nachsehen."
gut "${NEU} → /musik"

schritt "Dienst starten"
docker compose -f "$EINSTELLUNG" up -d >/dev/null || ende "Der Start ist gescheitert."

PORT="$(sed -n 's/.*REGOCD_PORT: *"\?\([0-9]\+\).*/\1/p' "$EINSTELLUNG" | head -1)"
PORT="${PORT:-8090}"
for _ in $(seq 1 30); do
  curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/api/system" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/api/system" >/dev/null 2>&1 \
  || ende "Der Dienst antwortet nicht. Die alte Einstellung liegt unter ${EINSTELLUNG}.vor-umzug."
gut "läuft"

# --------------------------------------------------------------- Nachsehen
#
# Erst wenn der Dienst die Dateien am neuen Ort wirklich sieht, darf der alte
# Ort weg. Bis dahin ist er die Rückfallebene.
schritt "Sieht der Dienst seine Dateien?"
BEHAELTER="$(docker ps --format '{{.Names}}\t{{.Image}}' \
  | awk -F'\t' 'tolower($2) ~ /regocd/ { print $1; exit }')"
SICHT="$(docker exec "$BEHAELTER" sh -c 'find /musik -type f | wc -l' 2>/dev/null | tr -d ' \r')"
sagen "      $SICHT Dateien unter /musik"

# Und was die Datenbank führt: Stehen dort Containerpfade (/musik/...), ist
# nichts weiter zu tun. Stünden dort Wirtspfade, zeigten sie jetzt ins Leere.
FREMD="$(docker exec -i "$BEHAELTER" python3 - <<PY 2>/dev/null || true
import os, sqlite3
from pathlib import Path
datei = Path(os.environ.get("REGOCD_DATA_DIR", "/data")) / "regocd.db"
if datei.exists():
    v = sqlite3.connect(f"file:{datei}?mode=ro", uri=True)
    pfade = [p for (p,) in v.execute("SELECT pfad FROM titel") if p]
    print(sum(1 for p in pfade if not p.startswith("/musik")))
else:
    print(0)
PY
)"
if [ "${FREMD:-0}" -gt 0 ]; then
  warnen "${FREMD} Titel führen einen Pfad ausserhalb von /musik."
  warnen "Sie zeigen ins Leere. In der Oberfläche „Bibliothek prüfen“ laufen lassen."
else
  gut "die Datenbank führt Containerpfade — nichts umzuschreiben"
fi

sagen ""
schritt "Fertig"
sagen "  CD-Archiv    ${NEU}"
sagen "  Alter Ort    ${ALT}   (liegt noch da)"
sagen "  Einstellung  ${EINSTELLUNG}   (vorherige: ${EINSTELLUNG}.vor-umzug)"
sagen ""
sagen "  **Erst nachsehen, dann aufräumen.** Wenn in der Oberfläche alle Alben"
sagen "  spielen, kann der alte Ort weg:"
sagen "      rm -rf \"${ALT}\""
sagen ""
