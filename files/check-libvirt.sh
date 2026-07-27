#!/usr/bin/env bash
#
# check-libvirt.sh — Smoke-Check fuer update-all.sh (Abschnitt 2b):
# Ist libvirtd nach dem Update aktiv, und laufen alle Netze, die auf Autostart
# stehen? Autostart heisst "soll nach Boot/Update von selbst laufen" — genau die
# Invariante, die ein Update brechen kann. On-Demand-Netze ohne Autostart sind
# Sache der deploy-*-vm.sh und hier bewusst KEIN Kriterium.
# Zusaetzlich Policy-Check (eigene Bridge je VM, s. README-deploy-*-vm.md):
# das libvirt-Default-Netz darf nicht
# (wieder) existieren — warnt nur; entfernt wird es von den deploy-*-vm.sh.
#
# Selbst-guardend: kein libvirtd auf diesem Host -> still Exit 0 (nicht zustaendig).
# Exit 1 = Warnung; update-all.sh sammelt und warnt, bricht nicht ab.
# virsh laeuft wie ueberall im Repo als 'sudo virsh' (System-URI, unabhaengig von
# Gruppenmitgliedschaft); der sudo-Timestamp ist vom switch in Abschnitt 2 noch warm.
set -euo pipefail

command -v virsh >/dev/null 2>&1 || exit 0
systemctl cat libvirtd.service >/dev/null 2>&1 || exit 0   # Unit existiert nicht -> Host ohne libvirt

if ! systemctl is-active --quiet libvirtd; then
  printf '[check-libvirt] WARNUNG: libvirtd ist nicht aktiv (Details: systemctl status libvirtd).\n'
  exit 1   # ohne Daemon sind Netz-Abfragen sinnlos
fi
printf '[check-libvirt] libvirtd: aktiv — OK\n'

rc=0

# Policy-Check: das libvirt-Default-Netz ('default'/virbr0) soll
# NICHT existieren — jede VM hat ihre eigene Bridge (nftables-Anker der
# VM-Isolierung); die deploy-*-vm.sh raeumen es weg. Taucht es wieder auf (z. B.
# nach einem libvirt-Update), hier nur WARNEN — Smoke-Checks sind read-only.
if sudo virsh net-info default >/dev/null 2>&1; then
  printf '[check-libvirt] WARNUNG: libvirt-Default-Netz existiert (Policy: eigene Bridge je VM, s. README-deploy-*-vm.md).\n'
  printf '[check-libvirt]          Entfernen: naechster deploy-*-vm.sh-Lauf — oder manuell:\n'
  printf '[check-libvirt]          sudo virsh net-destroy default; sudo virsh net-undefine default\n'
  rc=1
fi

expected=$(sudo virsh net-list --all --autostart --name 2>/dev/null | sed '/^$/d' || true)
active=$(sudo virsh net-list --name 2>/dev/null | sed '/^$/d' || true)
if [ -z "$expected" ]; then
  printf '[check-libvirt] keine Autostart-Netze definiert — nichts weiter zu pruefen.\n'
  exit "$rc"
fi
while IFS= read -r net; do
  # 'default' steht (falls vorhanden) meist auf Autostart, ist aber Policy-Verstoss
  # (Warnung oben) — hier ueberspringen, sonst empfoehle die Inaktiv-Warnung
  # widersinnig, es zu STARTEN.
  [ "$net" = "default" ] && continue
  if printf '%s\n' "$active" | grep -qx -- "$net"; then
    printf '[check-libvirt] Netz "%s": aktiv — OK\n' "$net"
  else
    printf '[check-libvirt] WARNUNG: Autostart-Netz "%s" ist inaktiv (Start: sudo virsh net-start %s).\n' \
      "$net" "$net"
    rc=1
  fi
done <<<"$expected"
exit "$rc"
