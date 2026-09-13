# REGOeinzeiler

Einzeiler für wiederkehrende Einrichtungsarbeiten. Ein Befehl, ein paar Fragen, fertig.

> *One-liners for recurring setup work on Proxmox and friends. Documentation is in German.*

## Was hier drin ist

| Skript | Was es tut |
|---|---|
| [`proxmox/ubuntu-vm.sh`](proxmox/ubuntu-vm.sh) | Legt auf einem Proxmox-Wirt eine Ubuntu-Server-VM an |
| [`nas/regocd.sh`](nas/regocd.sh) | Richtet REGOcd auf einem NAS ein (Abbild aus der eigenen Registry) |
| [`nas/regocd-update.sh`](nas/regocd-update.sh) | Holt die neueste Ausgabe und startet sie, mit Rückweg bei Fehlschlag |
| [`nas/regocd-pruefen.sh`](nas/regocd-pruefen.sh) | Sieht nach, wo die Aufnahmen wirklich liegen — ändert nichts |
| [`nas/regocd-umziehen.sh`](nas/regocd-umziehen.sh) | Zieht die Ordner an ihren vorgesehenen Ort um: Dateien und Einhängepunkte |
| [`nas/documento.sh`](nas/documento.sh) | Richtet documento auf einem NAS ein (Stundenverwaltung, Abbild aus der eigenen Registry) |
| [`nas/documento-update.sh`](nas/documento-update.sh) | Holt die neueste documento-Ausgabe und startet sie, mit Rückweg bei Fehlschlag |

## Ubuntu-Server-VM auf Proxmox

Auf dem **Proxmox-Wirt** als `root` ausführen:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/proxmox/ubuntu-vm.sh)"
```

Gefragt wird nach VM-Kennung, Name, Speicher, Kernen, Platte, Benutzername und Passwort —
alles mit brauchbaren Vorgaben, sodass meist Enter genügt. Die freie Kennung schlägt Proxmox
selbst vor.

**Was dabei herauskommt:** eine laufende VM mit dem neuesten Ubuntu LTS, Netz über DHCP,
Benutzer `rego` (änderbar), QEMU-Gastdienst an, serieller Konsole. Anmelden geht per SSH oder
über `qm terminal <kennung>`.

### Wenn SSH „Permission denied (publickey)" sagt

Ubuntu-Cloud-Abbilder schalten die **Passwortanmeldung über SSH ab Werk ab**
(`/etc/ssh/sshd_config.d/60-cloudimg-settings.conf`). Ein gesetztes Passwort gilt dann nur an der
Konsole. Das Skript schaltet die Passwortanmeldung ein, wenn auf dem Wirt ein Speicher für
cloud-init-Schnipsel bereitsteht — sonst sagt es beim Beenden, dass es das nicht konnte.

Nachträglich einschalten, an der Konsole (`qm terminal <kennung>`):

```bash
sudo sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config.d/*.conf
sudo systemctl restart ssh
```

Schlüssel sind der bessere Weg: Das Skript fragt beim Anlegen nach weiteren öffentlichen
Schlüsseln, damit nicht nur der Wirt hineinkommt, sondern auch das Notebook.

### Entscheidungen, die das Skript trifft

**Cloud-Abbild statt ISO-Installation.** Das Abbild ist fertig eingerichtet und startet in etwa
einer Minute. Eine ISO-Installation müsste entweder beaufsichtigt werden oder eine
`autoinstall`-Datei mitbringen — beides mehr Aufwand für dasselbe Ergebnis.

**Immer die Server-Variante, nie ein Desktop.** Eine VM, die Dienste trägt, braucht kein Fenster;
ein Desktop kostet Speicher, Platte und Angriffsfläche.

**Immer die neueste LTS, dynamisch ermittelt.** Eine fest verdrahtete Version veraltet, und eine
Zwischenversion wäre für einen Server die falsche Wahl — die läuft nach neun Monaten aus, LTS
bekommt fünf Jahre. Das Skript liest die Liste bei Canonical und nimmt die höchste LTS.

**Das Passwort geht über eine Datei, nicht über die Befehlszeile.** Argumente stehen in der
Prozessliste und wären für jeden anderen Benutzer des Wirts mitzulesen.

**Bei Abbruch wird aufgeräumt.** Schlägt ein Schritt fehl, verschwindet die halbfertige VM wieder,
statt als Leiche in der Liste zu stehen.

### Voraussetzungen

Proxmox VE (getestet ab 8), `root`-Rechte auf dem Wirt, ein Netzzugang zu
`cloud-images.ubuntu.com`. Das Abbild wird unter `/var/lib/vz/template/cache/` abgelegt und beim
nächsten Lauf wiederverwendet.

## REGOcd auf einem NAS

Auf dem **NAS** als `root` (oder mit `sudo`):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd.sh)"
```

Gefragt wird nach der Registry, dem Port, dem CD-Laufwerk — und nach den
Einhängepunkten **einzeln**: CD-Archiv, Datenbank, Sicherung, Arbeitsordner. Auf einem NAS
liegen die selten beieinander: Das Archiv gehört auf den grossen Speicherpool, die Sicherung
auf eine externe Platte, die auch mal abgezogen wird.

Die Vorgaben sind eingetragen und passen zum üblichen Aufbau:

| Bereich | Vorgabe | warum dort |
|---|---|---|
| CD-Archiv | `/volume2/music/regocd` | im Musikbereich — dort suchen die Player |
| Docker-Ordner | `/volume1/docker/regocd` | Betriebsablage eines Containers |
| Datenbank | `…/data` | klein, gehört zur Betriebsablage |
| Arbeit | `…/arbeit` | nur belegt, solange eine CD läuft |
| Sicherung | eingehängter USB-Datenträger | **wird gesucht**, nicht geraten |

**Wo ein NAS seine USB-Datenträger einhängt, ist je Hersteller verschieden** — das Skript
liest es mit `lsblk` aus und schlägt den gefundenen Pfad vor. (Auf UGREEN-Geräten hängen sie
unter `/mnt/@usb/<gerät>`, nachgemessen an einem DXP2800.) Steckt keiner, landet die
Sicherung neben der Datenbank; das schützt vor Versehen, nicht vor einem Plattenausfall. Was
angeschlossen ist, zeigt:

```bash
lsblk -o NAME,TRAN,SIZE,FSTYPE,MOUNTPOINT
```

### Ohne Nachfragen, mit eigenen Werten

Jede Frage lässt sich vorab beantworten — der Aufruf bleibt derselbe, das Skript muss nicht
bearbeitet werden:

```bash
sudo env REGOCD_REGISTRY=192.168.1.43:5000 \
         REGOCD_ARCHIV=/volume2/musik \
         REGOCD_DATENBANK=/volume1/regocd/daten \
         REGOCD_SICHERUNG=/mnt/usb-platte \
         REGOCD_PORT=8090 \
         bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd.sh)"
```

| Variable | wofür |
|---|---|
| `REGOCD_REGISTRY` | Rechner:Port der Registry |
| `REGOCD_MARKE` | `latest` oder eine bestimmte Ausgabe (`b46`) |
| `REGOCD_PORT` | Port der Oberfläche |
| `REGOCD_LAUFWERK` | CD-Laufwerk |
| `REGOCD_WURZEL` | Grundverzeichnis, Vorgabe für die vier folgenden |
| `REGOCD_ARCHIV` | CD-Archiv (FLAC-Dateien) |
| `REGOCD_DATENBANK` | Datenbank und Cover |
| `REGOCD_SICHERUNG` | Sicherungsplatte |
| `REGOCD_ARBEIT` | Arbeitsordner |

Was gesetzt ist, wird nicht gefragt. `REGOCD_STILL=ja` nimmt für alles Übrige die Vorgabe und
fragt gar nichts — dann läuft das Skript ohne Zutun durch.

Beim VM-Skript geht dasselbe mit `VM_ID`, `VM_NAME`, `VM_RAM`, `VM_KERNE`, `VM_PLATTE`,
`VM_BENUTZER`, `VM_SPEICHER`, `VM_BRUECKE`, `VM_PASSWORT` und `VM_STILL=ja`.

Aktualisieren später:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd-update.sh)"
```

### Wo liegen die Aufnahmen wirklich?

Die Oberfläche zeigt vier Alben, auf der Platte liegt eines — das kann drei Gründe haben, und
alle drei sehen gleich aus: Die Dateien liegen **im Container** (dann sind sie beim nächsten
Update weg), unter einem **alten Pfad** (weil die Einhängepunkte später geändert wurden), oder
sie wurden **gelöscht**. Dieses Skript fragt die Datenbank nach dem Pfad jedes Titels und sagt,
welcher davon wo liegt. Es ändert nichts:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd-pruefen.sh)"
```

**Mit `sudo`**: Ohne Rechte am Docker-Socket scheitert jede Frage an Docker mit „permission
denied" — und das sieht von aussen aus, als liefe kein Container.

Dasselbe prüft das Update-Skript vor jedem Tausch — und bricht ab, statt Aufnahmen zu
verlieren.

### Ordner umziehen

Liegt etwas am falschen Ort, verschiebt dieses Skript Dateien **und** Einhängepunkte — alle
vier Bereiche, jeder einzeln geprüft: Platz vorher, Dienst angehalten währenddessen, Zählung
danach. Die alten Ordner bleiben bestehen, bis Sie sie selbst wegräumen:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/regocd-umziehen.sh)"
```

Die Datenbank bleibt dabei unberührt: Der Dienst merkt sich die Pfade so, wie er sie im
Container sieht (`/musik/...`) — was darunter auf dem NAS liegt, geht ihn nichts an. Das Skript
prüft es trotzdem nach.

**Der Container läuft im Netz des Wirts** (`network_mode: host`). Das ist kein Versehen: Die
Player im Netz werden über SSDP gesucht, und das ist Multicast — aus einem Bridge-Netz kommt es
nicht heraus. Nachgemessen: im Bridge-Netz **kein einziger** Player, im Wirtsnetz alle fünf.
Rippen, Bibliothek und Oberfläche funktionieren in beiden Fällen, deshalb fällt es erst auf,
wenn man abspielen will. Weil damit die Port-Zuordnung entfällt, kommt der Port als Einstellung
(`REGOCD_PORT`) statt als Abbildung.

Das Update tauscht **nur das Abbild**. Datenbank, Archiv und Sicherung liegen ausserhalb des
Containers und bleiben unangetastet — das Skript zeigt vor dem Tausch, um welche Verzeichnisse
es geht. Antwortet die neue Ausgabe nicht, wird die vorherige wieder gestartet, und zwar über
dieselbe Einstellungsdatei, damit die Verzeichnisse mitkommen.

**Warum aus einer eigenen Registry?** Der Bau braucht Node, Python und einige Minuten. Das
Abbild ist fertig, kommt in Sekunden, und ist nachweislich dasselbe, das anderswo geprüft
wurde. Eine Registry aufsetzen geht in einer Zeile:

```bash
docker run -d --name registry --restart unless-stopped \
  -p 5000:5000 -v /srv/registry:/var/lib/registry registry:2
```

## Vor dem Ausführen hineinsehen

`curl | bash` ist bequem und verlangt Vertrauen. Wer erst lesen will:

```bash
curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/proxmox/ubuntu-vm.sh | less
```

Oder das Repo klonen und das Skript von dort starten. Die Skripte sind bewusst in einer Datei
gehalten und kommentiert, damit das Lesen nicht länger dauert als das Ausführen.

## Lizenz

MIT — siehe [LICENSE](LICENSE).

## documento auf einem NAS

Auf dem **NAS** als `root` ausführen:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/documento.sh)"
```

Gefragt werden Registry, Port, Zeitzone, die drei Verzeichnisse (Datenbank,
Dokumente, Sicherung) und das Anfangskennwort für den Benutzer `admin`. Jede
Frage lässt sich vorab als Umgebungsvariable setzen; mit `DOCUMENTO_STILL=ja`
wird gar nicht gefragt.

Aktualisieren:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/nas/documento-update.sh)"
```

Die Datenbank und die Dokumente liegen ausserhalb des Containers und bleiben
beim Wechsel des Abbilds unangetastet.
