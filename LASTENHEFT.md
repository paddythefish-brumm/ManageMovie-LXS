Version: 0.2.45

# Lastenheft ManageMovie LXS

## 1. Zielbild
ManageMovie LXS ist eine eigenständige Web-Anwendung für Analyse, Copy und Encode von Videoquellen im Proxmox-LXC-Container.

## 2. In Scope
- Web-UI für `Analyze`, `Copy`, `Encode`
- Freigabe- und Editor-Workflow
- HTTPS-Betrieb im Container
- Lokale MariaDB im Container
- Proxmox-Host-Deployment direkt aus einem öffentlichen Git-Repo
- Seedloser Kunden-Container mit leerer Konfiguration und Erststart-Sperre
- Mehrere Worker-LXC auf `pve01-04`, die aus einem zentralen Master-Container neu aufgebaut werden koennen

## 3. Funktionale Anforderungen
- Ein Git-Aufruf auf dem Proxmox-Host erzeugt und provisioniert den LXC-Container.
- Die Anwendung startet nach Container-Erstellung automatisch per systemd.
- Existiert der Ziel-Container bereits, wird standardmäßig ein Update ausgeführt.
- Nur `--recreate` darf den Ziel-Container löschen und neu erzeugen.
- Beim Erststart bleiben `Analyze`, `Copy` und `Encode` blockiert, bis Einstellungen und API-Keys gespeichert wurden.
- Ohne Seed-Dateien muss eine leere, produktionsfähige Kundeninstanz ohne vorgefüllte API-Keys erzeugt werden.
- Der laufende Master-Container `CT240` ist die operative Quelle fuer releasefaehigen LXS-Code.
- Releases muessen als Git-Tag veroeffentlicht und anschliessend per `update_ManageMovie.sh --tag <version>` auf `CT240` und die Worker ausgerollt werden.
- Worker-Container muessen ueber `Kill`/`Init` reproduzierbar aus dem neuesten frischen `CT240`-Backup wiederherstellbar sein.
- Das `CT240`-Backup muss im Proxmox-Dump-Pfad `/mnt/pve/nfs/dump/vzdump-lxc-240-*.tar.zst` liegen und fuer Worker-Restores automatisch auffindbar sein.

## 4. Nicht-funktionale Anforderungen
- Debian 13 ohne X
- HTTPS aktiviert
- Keine Abhängigkeit zu Mac-spezifischen Deploy-Skripten
- Öffentliches Git-Repository ohne Secrets

## 5. Abnahme
- LXC lässt sich direkt vom Proxmox-Host deployen
- Webservice antwortet auf `/api/state`
- Erststart-Sperre blockiert Jobstarts serverseitig
- Ein neues Git-Tag laesst sich per Self-Update auf `CT240` und `CT241-244` ausrollen
- Ein frisches `vzdump` von `CT240` liegt nach dem Rollout auf dem NFS-Dump-Storage vor
