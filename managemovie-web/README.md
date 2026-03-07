# ManageMovie Web (0.2.11)

Dieser Unterbau enthält die Web-App und den Runner für den LXC-Betrieb.

## Relevante Pfade
- `app/managemovie.py`
- `app/run_managemovie.sh`
- `web/app.py`
- `start_web.sh`

## Betrieb im LXC
- Start über das Top-Level-`start.sh`
- Stop über das Top-Level-`stop.sh`
- systemd-Installation über `install_systemd_service.sh`
- HTTPS-Zertifikate über `setup_https.sh`

## Hinweise
- Dieses Unterverzeichnis ist im LXC-Repo bewusst frei von Mac-/VM-Betriebsdoku.
- Erststart-Sperre und Settings-Gate werden serverseitig über die Web-App erzwungen.
