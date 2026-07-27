# check-libvirt.sh — Smoke-Check: libvirt gesund?

**Zweck:** Nach einem Update prüfen, ob `libvirtd` läuft und alle Netze, die auf **Autostart**
stehen, auch wirklich aktiv sind. Autostart heißt „soll nach Boot/Update von selbst laufen" —
genau die Invariante, die ein Update brechen kann. **On-Demand-Netze ohne Autostart sind bewusst
kein Kriterium** — die gehören den `deploy-*-vm.sh`.

## Aufruf

```bash
bash check-libvirt.sh   # manuell; läuft sonst automatisch in update-all.sh (Abschnitt 2b)
```

Verwendet `sudo virsh` (System-URI) — dasselbe Muster wie die `deploy-*-vm.sh`, unabhängig von
Gruppenmitgliedschaften; im update-all-Lauf ist der sudo-Timestamp vom `switch` ohnehin noch warm.

## Was genau geprüft wird

1. **Guard:** kein `virsh` im PATH oder keine `libvirtd.service`-Unit → dieser Host nutzt libvirt
   nicht → still Exit 0.
2. **Daemon:** `libvirtd` aktiv? Wenn nicht → Warnung und Ende (ohne Daemon sind Netz-Abfragen
   sinnlos).
3. **Netze:** alle Autostart-Netze (`virsh net-list --all --autostart`) müssen aktiv sein. Die
   VM-Netze `dev-vm-net` und `browser-vm-net` stehen per Deploy auf Autostart und werden hier
   also mitgeprüft. Ein etwaiges `default`-Netz wird in dieser Schleife **übersprungen** —
   sonst würde die Inaktiv-Warnung widersinnig empfehlen, es zu starten (s. Punkt 4).
4. **Policy (s. `README-deploy-*-vm.md`):** das libvirt-**`default`-Netz darf nicht existieren** — jede VM
   hat ihre eigene Bridge (nftables-Anker der VM-Isolierung); die `deploy-*-vm.sh` räumen es
   weg. Taucht es wieder auf (z. B. nach einem libvirt-Update), **warnt** der Check nur —
   Smoke-Checks bleiben read-only.

## Exit-Semantik (selbst-guardend)

- `0` — gesund oder nicht zuständig (dann still)
- `1` — `libvirtd` inaktiv oder mindestens ein Autostart-Netz down → `update-all.sh` warnt,
  bricht aber nicht ab

## Beispielausgabe

```
[check-libvirt] libvirtd: aktiv — OK
[check-libvirt] Netz "dev-vm-net": aktiv — OK
[check-libvirt] Netz "browser-vm-net": aktiv — OK
```

## Wenn es warnt

- **Daemon:** `systemctl status libvirtd`, Details mit `journalctl -u libvirtd -e`
- **Netz starten:** `sudo virsh net-start <name>`; Übersicht: `sudo virsh net-list --all --autostart`
- **VM-Netz kaputt oder Schema geändert?** Rezepte zum Neuanlegen stehen in
  `docs/README-deploy-dev-vm.md` bzw. `docs/README-deploy-browser-vm.md` (jeweils Abschnitt
  „Adress-Kopplung").
- **`default`-Netz existiert (Policy-Verstoß):** einfach den nächsten `deploy-*-vm.sh`-Lauf
  abwarten (räumt es selbstheilend weg) — oder sofort manuell:
  `sudo virsh net-destroy default; sudo virsh net-undefine default`.

> Stand: 2026-07-23. Bei Abweichungen gilt das Skript selbst (Kopf-Kommentar).
