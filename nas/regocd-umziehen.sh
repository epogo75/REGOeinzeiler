#!/usr/bin/env bash
#
# Zieht die Ordner von REGOcd an ihren vorgesehenen Ort um -- Dateien **und**
# Einhängepunkte.
#
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd-umziehen.sh)"
#
# **Warum das ein eigenes Skript ist und kein Handgriff:** Zwischen „Dateien
# verschieben" und „Einhängepunkt ändern" liegt ein Zustand, in dem der Dienst
# ins Leere greift. Läuft er dabei, schreibt er neue Aufnahmen an den alten
# Ort -- und beim nächsten Blick fehlt die Hälfte. Deshalb: anhalten, alle
# Bereiche umziehen, umhängen, starten, nachsehen.
#
# **Die Datenbank bleibt inhaltlich unberührt**, und das ist kein Zufall: Der
# Dienst merkt sich die Pfade so, wie er sie im Container sieht (/musik/...).
# Was darunter auf dem NAS liegt, geht ihn nichts an. Deshalb genügt es, die
# Dateien zu verschieben und die Volumes umzuhängen. Das Skript prüft das
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

# Dieselben Pfade wie im Update-Skript. Jeder lässt sich überschreiben.
SOLL_ARCHIV="${REGOCD_ARCHIV:-/volume2/music/regocd}"
SOLL_DATEN="${REGOCD_DATENBANK:-/volume1/docker/regocd/data}"
SOLL_ARBEIT="${REGOCD_ARBEIT:-/volume1/docker/regocd/arbeit}"
SOLL_SICHERUNG="${REGOCD_SICHERUNG:-/mnt/@usb/sdc1/regocd-sicherung}"

# **Das `|| true` ist nicht Bequemlichkeit, sondern nötig.** Findet `grep`
# nichts, liefert es 1; unter `set -euo pipefail` bricht die Zuweisung -- und
# damit das ganze Skript -- wortlos ab. „Kein Treffer" ist hier aber eine
# gültige Antwort: Dann ist eben nichts eingehängt.
ist_pfad() { grep -oE "/[^ ]+:$1\b" "$EINSTELLUNG" 2>/dev/null | head -1 | cut -d: -f1 || true; }

# **Wo lag es vorher?** Jedes Skript hier legt die alte Einstellung daneben,
# bevor es sie ändert. Genau darin steht, wohin ein Einhängepunkt früher
# zeigte -- und das ist die Spur zu den Dateien, wenn der Punkt schon auf das
# neue Ziel zeigt, dort aber nichts liegt.
frueher_pfad() {
  local ziel="$1" datei
  for datei in "${EINSTELLUNG}.vor-umzug" "${EINSTELLUNG}.vor-update" \
               "${EINSTELLUNG}.vor-regocd"; do
    [ -f "$datei" ] || continue
    grep -oE "/[^ ]+:${ziel}\b" "$datei" 2>/dev/null | head -1 | cut -d: -f1 || true
    return
  done
}

# Wie viele Dateien liegen in einem Ordner? Leer heisst hier: keine einzige.
dateien_in() { find "$1" -type f 2>/dev/null | wc -l | tr -d ' ' || true; }

# ------------------------------------------------------------- Was ansteht

schritt "Was umzuziehen wäre"
ZIELE=("/musik" "/data" "/arbeit" "/sicherung")
SOLLS=("$SOLL_ARCHIV" "$SOLL_DATEN" "$SOLL_ARBEIT" "$SOLL_SICHERUNG")
NAMEN=("CD-Archiv" "Datenbank" "Arbeit" "Sicherung")
ANSTEHEND=()
# Woher kopiert wird -- fast immer der eingehängte Ordner selbst; steht der
# Punkt schon aufs Ziel und ist leer, der frühere.
declare -A QUELLEN=()

for i in "${!ZIELE[@]}"; do
  ist="$(ist_pfad "${ZIELE[$i]}")"
  soll="${SOLLS[$i]}"
  name="${NAMEN[$i]}"
  if [ -z "$ist" ]; then
    warnen "${name}: nichts auf ${ZIELE[$i]} eingehängt — bitte erst einrichten."
  elif [ "$ist" = "$soll" ]; then
    # **Der Punkt stimmt -- liegt auch etwas darin?** Wer die Einrichtung
    # noch einmal laufen lässt, hängt den neuen Ordner ein; die Dateien
    # bleiben am alten Platz. Der Dienst sieht dann ein leeres Archiv und
    # meldet jede Aufnahme als fehlend. Deshalb wird hier nicht nur der
    # Pfad verglichen, sondern nachgesehen.
    hier="$(dateien_in "$ist")"
    vorher="$(frueher_pfad "${ZIELE[$i]}")"
    dort=0
    if [ -n "$vorher" ] && [ "$vorher" != "$ist" ]; then
      dort="$(dateien_in "$vorher")"
    fi
    if [ "${hier:-0}" -eq 0 ] && [ "${dort:-0}" -gt 0 ]; then
      warnen "${name}: ${ist} ist LEER — ${dort} Dateien liegen noch unter ${vorher}."
      QUELLEN[$i]="$vorher"
      ANSTEHEND+=("$i")
    else
      gut "${name}: ${ist}   (${hier} Dateien)"
    fi
  else
    anzahl="$(dateien_in "$ist")"
    sagen "      ${name}: ${ist}  →  ${soll}   (${anzahl} Dateien)"
    QUELLEN[$i]="$ist"
    ANSTEHEND+=("$i")
  fi
done

if [ "${#ANSTEHEND[@]}" -eq 0 ]; then
  sagen ""
  gut "Alles liegt schon dort, wo es hingehört."
  exit 0
fi

# Passt es? Ein Umzug, der bei 80 % vollläuft, hinterlässt die Sammlung auf
# zwei Platten -- das ist schlimmer als gar nicht anzufangen.
sagen ""
for i in "${ANSTEHEND[@]}"; do
  quelle="${QUELLEN[$i]}"
  soll="${SOLLS[$i]}"
  mkdir -p "$soll" || ende "$soll liess sich nicht anlegen."
  [ -w "$soll" ] || ende "$soll ist nicht beschreibbar."
  braucht="$(du -sk "$quelle" 2>/dev/null | awk '{print $1}')"
  frei="$(df -Pk "$soll" | awk 'NR == 2 {print $4}')"
  sagen "  ${NAMEN[$i]}: $(( ${braucht:-0} / 1024 )) MB zu verschieben, $(( frei / 1024 )) MB frei"
  [ "${frei:-0}" -gt "${braucht:-0}" ] || ende "Auf dem Ziel von ${NAMEN[$i]} ist zu wenig Platz."
done

sagen ""
read -r -p "  Umziehen? [j/N]: " weiter </dev/tty || true
case "${weiter:-N}" in [JjYy]*) : ;; *) ende "Abgebrochen." ;; esac

# ----------------------------------------------------------------- Anhalten

schritt "Dienst anhalten"
docker compose -f "$EINSTELLUNG" stop >/dev/null 2>&1 || warnen "Liess sich nicht anhalten."
gut "angehalten"

cp "$EINSTELLUNG" "${EINSTELLUNG}.vor-umzug"

# ---------------------------------------------------------------- Verschieben
#
# Kopiert wird, gelöscht wird nicht: Bricht es ab, liegt alles noch am alten
# Platz. Weggeräumt wird am Ende vom Menschen, nicht vom Skript.
for i in "${ANSTEHEND[@]}"; do
  quelle="${QUELLEN[$i]}"
  ist="$(ist_pfad "${ZIELE[$i]}")"
  soll="${SOLLS[$i]}"
  name="${NAMEN[$i]}"

  schritt "${name} kopieren"
  sagen "      von ${quelle}"
  sagen "      nach ${soll}"
  vorher="$(dateien_in "$quelle")"
  if command -v rsync >/dev/null 2>&1; then
    # Fortschritt nur am Terminal: In eine Datei geleitet schreibt
    # `--info=progress2` tausend Zeilen, in denen die eine Meldung untergeht,
    # auf die es ankommt.
    if [ -t 1 ]; then
      rsync -a --info=progress2 "$quelle"/ "$soll"/ || ende "${name}: Kopieren gescheitert."
    else
      rsync -a "$quelle"/ "$soll"/ || ende "${name}: Kopieren gescheitert."
    fi
  else
    cp -a "$quelle"/. "$soll"/ 2>/dev/null || ende "${name}: Kopieren gescheitert."
  fi
  nachher="$(dateien_in "$soll")"
  [ "$nachher" -ge "$vorher" ] \
    || ende "${name}: am Ziel liegen ${nachher} Dateien, erwartet waren ${vorher}."
  gut "${nachher} Dateien unter ${soll}"

  # Zeigt der Einhängepunkt schon aufs Ziel, ist nichts zu ändern -- dann
  # fehlten nur die Dateien.
  if [ "$ist" != "$soll" ]; then
    # Mit | als Trenner, weil im Pfad Schrägstriche stehen.
    sed -i "s|${ist}:${ZIELE[$i]}|${soll}:${ZIELE[$i]}|" "$EINSTELLUNG"
    grep -q "${soll}:${ZIELE[$i]}" "$EINSTELLUNG" \
      || ende "${name}: Die Zeile liess sich nicht ändern — siehe $EINSTELLUNG."
    gut "${soll} → ${ZIELE[$i]}"
  fi
done

# -------------------------------------------------------------------- Starten

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

schritt "Sieht der Dienst seine Dateien?"
BEHAELTER="$(docker ps --format '{{.Names}}\t{{.Image}}' \
  | awk -F'\t' 'tolower($2) ~ /regocd/ { print $1; exit }')"
SICHT="$(docker exec "$BEHAELTER" sh -c 'find /musik -type f | wc -l' 2>/dev/null | tr -d ' \r')"
sagen "      ${SICHT} Dateien unter /musik"

# Und was die Datenbank führt: Stehen dort Containerpfade (/musik/...), ist
# nichts weiter zu tun. Stünden dort Wirtspfade, zeigten sie jetzt ins Leere.
FREMD="$(docker exec -i "$BEHAELTER" python3 - <<'PY' 2>/dev/null || true
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
  warnen "${FREMD} Titel führen einen Pfad ausserhalb von /musik — sie zeigen ins Leere."
  warnen "In der Oberfläche „Bibliothek prüfen“ laufen lassen."
else
  gut "die Datenbank führt Containerpfade — nichts umzuschreiben"
fi

sagen ""
schritt "Fertig"
for i in "${!ZIELE[@]}"; do
  printf '  %-11s %s\n' "${NAMEN[$i]}" "$(ist_pfad "${ZIELE[$i]}")"
done
sagen "  Einstellung ${EINSTELLUNG}   (vorherige: ${EINSTELLUNG}.vor-umzug)"
sagen ""
sagen "  Erst nachsehen, dann aufräumen. Wenn in der Oberfläche alles da ist"
sagen "  und spielt, können die alten Ordner weg — sie stehen oben unter"
sagen "  „Was umzuziehen wäre“ als erster Pfad jeder Zeile."
sagen ""
