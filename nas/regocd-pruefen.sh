#!/usr/bin/env bash
#
# Sieht nach, **wo die Aufnahmen wirklich liegen**. Ändert nichts.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd-pruefen.sh)"
#
# Die Frage, die dieses Skript beantwortet: Die Oberfläche zeigt vier Alben,
# auf der Platte liegt eines -- wo sind die anderen drei?
#
# Drei Antworten kommen in Frage, und alle drei sehen in der Oberfläche
# gleich aus:
#
#   1. Sie liegen **im Container** -- dann sind sie beim nächsten Update weg.
#   2. Sie liegen **unter einem alten Pfad**, weil die Einhängepunkte später
#      geändert wurden. Der Dienst hat sie damals dorthin geschrieben und
#      merkt sich den Pfad je Titel.
#   3. Sie sind **gelöscht** worden, die Einträge stehen noch.
#
# Deshalb wird nicht geraten, sondern die Datenbank gefragt: Sie führt zu
# jedem Titel den Pfad, unter dem er abgelegt wurde.

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

# **Ein Skript, das wortlos endet, ist unbrauchbar.** `set -e` bricht bei
# jedem Befehl ab, der nicht 0 liefert -- und sagt dabei kein Wort. Diese
# Falle sagt wenigstens, in welcher Zeile es war; das hat beim Umzug zwei
# Anläufe gekostet, weil ein erfolgloses `grep` genügte.
trap 'zeile=$LINENO; printf "%s  ✗ Abbruch in Zeile %s: %s%s\n" "${ROT}" "$zeile" "$BASH_COMMAND" "${AUS}" >&2' ERR

# ------------------------------------------------- Welcher Container ist es?
#
# **Nicht am Namen festmachen.** Wer den Container über die Oberfläche des
# NAS anlegt, vergibt einen eigenen Namen -- und genau dann stimmt auch sonst
# oft etwas nicht, weil die Einhängepunkte dort von Hand eingetragen werden.
# Gesucht wird deshalb am Abbild: Was „regocd" im Namen des Abbilds trägt,
# ist es.
command -v docker >/dev/null 2>&1 || ende \
  "Docker gibt es hier nicht. Dieses Skript gehört auf das Gerät, auf dem REGOcd läuft."

# **Darf ich Docker überhaupt fragen?** Ohne Rechte am Docker-Socket scheitert
# jeder Aufruf mit „permission denied" -- und ein Skript, das daraus „läuft
# nicht" macht, schickt einen auf die falsche Fährte. Genau das ist passiert.
if ! docker ps >/dev/null 2>&1; then
  warnen "Docker antwortet nicht — vermutlich fehlen die Rechte."
  sagen ""
  sagen "  Noch einmal mit sudo:"
  sagen "      sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd-pruefen.sh)\""
  sagen ""
  ende "Ohne Zugriff auf Docker ist nichts zu sehen."
fi

BEHAELTER="${REGOCD_CONTAINER:-}"
if [ -z "$BEHAELTER" ]; then
  BEHAELTER="$(docker ps -a --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
    | awk -F'\t' 'tolower($2) ~ /regocd/ { print $1; exit }' || true)"
fi
if [ -z "$BEHAELTER" ]; then
  warnen "Kein Container mit einem REGOcd-Abbild gefunden. Vorhanden sind:"
  docker ps -a --format '      {{.Names}}   {{.Image}}   {{.Status}}' 2>/dev/null | head -20
  sagen ""
  sagen "  Läuft REGOcd auf einem anderen Gerät? Dann dieses Skript dort ausführen."
  sagen "  Heisst der Container anders und trägt ein fremdes Abbild:"
  sagen "      REGOCD_CONTAINER=<name> bash -c \"\$(curl -fsSL .../nas/regocd-pruefen.sh)\""
  ende "Nichts zu prüfen."
fi
gut "Container: $BEHAELTER ($(docker inspect -f '{{.Config.Image}}' "$BEHAELTER" 2>/dev/null))"

schritt "Was eingehängt ist"
docker inspect -f '{{range .Mounts}}      {{.Source}} → {{.Destination}}{{"\n"}}{{end}}' "$BEHAELTER" \
  | sed '/^\s*$/d'

ARCHIV="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/musik"}}{{.Source}}{{end}}{{end}}' "$BEHAELTER")"
if [ -z "$ARCHIV" ]; then
  warnen "Auf /musik ist NICHTS eingehängt."
  warnen "Alles Gerippte liegt dann im Container und geht beim nächsten Update verloren."
else
  gut "CD-Archiv auf dem NAS: $ARCHIV"
fi

# ------------------------------------------------------- Die Datenbank fragen
#
# Im Container, weil dort Python und die Datenbank beieinander liegen. Gelesen
# wird nur -- das Skript ändert nichts, es sieht nach.
schritt "Was die Datenbank sagt"
# **`-i`, sonst bleibt es stumm.** Ohne `-i` reicht `docker exec` die
# Standardeingabe nicht durch: Python bekommt ein leeres Programm, tut nichts
# und meldet Erfolg. Der ganze Abschnitt blieb dadurch leer, ohne Fehler.
docker exec -i "$BEHAELTER" python3 - <<'PY'
import os
import sqlite3
from collections import Counter
from pathlib import Path

daten = Path(os.environ.get("REGOCD_DATA_DIR", "/data"))
musik = Path(os.environ.get("REGOCD_MUSIK_DIR", "/musik"))
datei = daten / "regocd.db"
if not datei.exists():
    raise SystemExit(f"  Keine Datenbank unter {datei}")

verbindung = sqlite3.connect(f"file:{datei}?mode=ro", uri=True)
alben = verbindung.execute(
    "SELECT a.id, a.titel, i.name FROM alben a "
    "LEFT JOIN interpreten i ON i.id = a.interpret_id ORDER BY a.id").fetchall()

print(f"  {len(alben)} Alben in der Datenbank\n")
ordner = Counter()

for album_id, titel, interpret in alben:
    zeilen = verbindung.execute(
        "SELECT pfad FROM titel WHERE album_id = ?", (album_id,)).fetchall()
    pfade = [z[0] for z in zeilen if z[0]]
    da = [p for p in pfade if Path(p).exists()]
    # Wo liegt dieses Album? Der gemeinsame Ordner der Titel sagt es.
    wo = {str(Path(p).parent) for p in pfade} or {"—"}
    for p in pfade:
        ordner[str(Path(p).parent)] += 1

    zeichen = "✓" if pfade and len(da) == len(pfade) else "!"
    print(f"  {zeichen} {interpret or '?'} — {titel}")
    print(f"      {len(da)} von {len(pfade)} Dateien vorhanden")
    for eintrag in sorted(wo):
        drinnen = eintrag.startswith(str(musik))
        print(f"      {eintrag}"
              + ("" if drinnen else "   ← liegt NICHT im CD-Archiv"))
    print()

fremd = {o: n for o, n in ordner.items() if not o.startswith(str(musik))}
if fremd:
    print("  Zusammengefasst — diese Ordner liegen ausserhalb des Archivs:")
    for o, n in sorted(fremd.items()):
        print(f"      {n:4} Titel   {o}")
PY

# ------------------------------------------------ Und was tatsächlich da ist
schritt "Was auf der Platte liegt"
if [ -n "$ARCHIV" ]; then
  ANZAHL="$(find "$ARCHIV" -name '*.flac' 2>/dev/null | wc -l | tr -d ' ')"
  ORDNER="$(ls -1 "$ARCHIV" 2>/dev/null | wc -l | tr -d ' ')"
  sagen "      ${ORDNER} Einträge, ${ANZAHL} FLAC-Dateien unter ${ARCHIV}"
fi

# Und im Container selbst: Was dort unter /musik liegt und **nicht** aus dem
# eingehängten Ordner kommt, ist genau das, was beim Update verlorengeht.
IM_CONTAINER="$(docker exec "$BEHAELTER" sh -c 'find /musik -name "*.flac" 2>/dev/null | wc -l' | tr -d ' \r')"
sagen "      ${IM_CONTAINER} FLAC-Dateien sieht der Dienst unter /musik"

# ----------------------------------------------- Wohin die Sicherung könnte
#
# Wo ein NAS seine USB-Datenträger einhängt, ist je Hersteller verschieden.
# Statt zu raten, wird nachgesehen -- das gilt für jedes Gerät.
schritt "Angeschlossene USB-Datenträger"
if command -v lsblk >/dev/null 2>&1; then
  AUSGABE="$(lsblk -o NAME,TRAN,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null \
    | awk 'NR == 1 || /usb/ { print "      " $0 }')"
  if printf '%s' "$AUSGABE" | grep -q usb; then
    printf '%s\n' "$AUSGABE"
    sagen "      Ein eingehängter USB-Datenträger ist das richtige Ziel für die Sicherung."
  else
    sagen "      Keiner angeschlossen (oder keiner eingehängt)."
  fi
else
  sagen "      lsblk gibt es hier nicht — dann hilft:  mount | grep -i usb"
fi

sagen ""
schritt "Was daraus folgt"
if [ -z "$ARCHIV" ]; then
  warnen "Ohne eingehängtes Archiv: erst retten, dann einrichten."
  sagen  "      docker cp ${BEHAELTER}:/musik/. /volume2/music/regocd/"
  sagen  "      bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd.sh)\""
elif [ "${IM_CONTAINER:-0}" -gt "${ANZAHL:-0}" ]; then
  warnen "Der Dienst sieht mehr Dateien als auf der Platte liegen."
  warnen "Der Unterschied liegt im Container und geht beim nächsten Update verloren:"
  sagen  "      docker cp ${BEHAELTER}:/musik/. \"${ARCHIV}/\""
else
  gut "Dienst und Platte sehen dasselbe."
  sagen "      Fehlen oben Alben, liegen ihre Dateien unter einem alten Pfad —"
  sagen "      die Zeile „liegt NICHT im CD-Archiv“ zeigt, wo. Von dort lassen"
  sagen "      sie sich in ${ARCHIV:-das Archiv} verschieben; danach in der"
  sagen "      Oberfläche „Bibliothek prüfen“ laufen lassen."
fi
sagen ""
