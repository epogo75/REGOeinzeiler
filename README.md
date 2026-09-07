# REGOeinzeiler

Einzeiler für wiederkehrende Einrichtungsarbeiten. Ein Befehl, ein paar Fragen, fertig.

> *One-liners for recurring setup work on Proxmox and friends. Documentation is in German.*

## Was hier drin ist

| Skript | Was es tut |
|---|---|
| [`proxmox/ubuntu-vm.sh`](proxmox/ubuntu-vm.sh) | Legt auf einem Proxmox-Wirt eine Ubuntu-Server-VM an |

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

## Vor dem Ausführen hineinsehen

`curl | bash` ist bequem und verlangt Vertrauen. Wer erst lesen will:

```bash
curl -fsSL https://raw.githubusercontent.com/epogo75/REGOeinzeiler/main/proxmox/ubuntu-vm.sh | less
```

Oder das Repo klonen und das Skript von dort starten. Die Skripte sind bewusst in einer Datei
gehalten und kommentiert, damit das Lesen nicht länger dauert als das Ausführen.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
