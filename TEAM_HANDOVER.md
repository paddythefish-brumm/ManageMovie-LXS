Version: 0.2.37

# Team Handover ManageMovie LXS

## Abgabestand
- Repo-Typ: eigenständiges LXC-Repo
- Version: `0.2.37`
- Plattform: Proxmox LXC auf Debian 13

## Kernpfade
- `scripts/proxmox/deploy_lxc_on_proxmox.sh`
- `scripts/proxmox/install_inside_lxc.sh`
- `managemovie-web/app/managemovie.py`
- `managemovie-web/web/app.py`

## Betriebsregeln
- Keine Abhängigkeit zu Mac-Hauptrepo-Skripten
- Erststart-Sperre bleibt aktiv, bis Einstellungen und API-Keys gespeichert wurden
- Live-Secrets bleiben außerhalb von Git
- Standardfall bei vorhandenem CT: Update statt Neuaufbau
- `--recreate` ist der explizite Zerstör-/Neuaufbaupfad

## Release-Hinweis
- Dieses Repo enthält nur den Container-relevanten Teil.
- Mac-Hauptrepo-Deploymentdateien werden bewusst nicht ausgeliefert.
