#!/usr/bin/env bash
#
# deploy-browser-vm.sh — baut & deployt die browser-VM (VOLL wegwerfbar) reproduzierbar.
# Host-agnostisch: laeuft auf allen Hosts identisch (kein Hardware-Bezug).
#
# Ablauf: Ressourcen aufloesen + browser-vm.xml erzeugen -> browser-VM-Netz sicherstellen ->
#   Image bauen -> bei laufender VM stoppen -> Root frisch -> Domain neu definieren -> starten
#   -> known_hosts. NICHTS ist persistent: Root ist <transient/> (Session-Overlay wird beim
#   Shutdown verworfen), /home/browse ist tmpfs (nur RAM). Kein --disk-Flag — es gibt kein
#   Volume, das man vergroessern koennte.
#
# Aufruf (irgendwo im Repo):
#   bash deploy-browser-vm.sh [--cpu N] [--ram MiB] [--kbd LAYOUT] [--autostart] [--no-start] [--dry-run]
#     --cpu N      vCPUs              (Default 4;    ohne Angabe gilt der zuletzt genutzte Wert)
#     --ram MiB    Arbeitsspeicher    (Default 6144; dito — gesetzte Werte "kleben")
#     --kbd LAYOUT xkb-Layout des Gasts (Default "de"; kommagetrennt fuer mehrere, z.B.
#                  "de,gb" -> Umschalten per Alt+Shift, wie auf dem Host). Traeger ist
#                  hosts/browser-vm/keyboard.nix — gesetzte Werte "kleben" wie cpu/ram.
#                  Hinweis: "en" gibt es nicht; gemeint ist "us" (US) oder "gb" (UK).
#     --autostart  VM beim Host-Boot automatisch starten (Default: AUS -> on-demand ueber das Icon)
#     --no-start   VM nach dem Deploy NICHT starten (Update-Pfad: update-all.sh, Abschnitt 3 —
#                  die VM war aus und bleibt aus; der naechste Icon-Start bootet das frische Image)
#     --dry-run    nur anzeigen, nichts veraendern
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Selbst-Bootstrap: fehlende Tools via nix-shell nachladen.
# WICHTIG: VOR dem Flag-Parsing — das while/shift unten verbraucht "$@"; danach waeren
# die Flags beim Re-Exec in der nix-shell verloren. Hier ist "$@" noch vollstaendig.
# (Kein e2fsprogs mehr noetig — die dev-VM brauchte es fuers Persistenz-Volume, hier entfaellt es.)
# ---------------------------------------------------------------------------
if ! command -v virsh >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  if [ -z "${BROWSERVM_BOOTSTRAPPED:-}" ]; then
    export BROWSERVM_BOOTSTRAPPED=1
    exec nix-shell -p libvirt git --run "bash $(printf '%q ' "$0" "$@")"
  fi
fi

# ---------------------------------------------------------------------------
# Flags  (CPU/RAM optional; ohne Angabe gilt der zuletzt genutzte Wert -> "kleben")
# ---------------------------------------------------------------------------
DRY_RUN=0; OPT_CPU=""; OPT_RAM=""; OPT_KBD=""; OPT_AUTOSTART=0; OPT_NOSTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --no-start)  OPT_NOSTART=1 ;;
    --cpu)       OPT_CPU="${2:?--cpu braucht einen Wert}"; shift ;;
    --cpu=*)     OPT_CPU="${1#*=}" ;;
    --ram)       OPT_RAM="${2:?--ram braucht einen Wert (MiB)}"; shift ;;
    --ram=*)     OPT_RAM="${1#*=}" ;;
    --kbd)       OPT_KBD="${2:?--kbd braucht ein xkb-Layout, z.B. de oder de,gb}"; shift ;;
    --kbd=*)     OPT_KBD="${1#*=}" ;;
    --autostart) OPT_AUTOSTART=1 ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    *) printf 'Unbekanntes Argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Feste Konfiguration (selten anzupassen)
# ---------------------------------------------------------------------------
VM_NAME="browser-vm"
FLAKE_ATTR=".#${VM_NAME}"                 # nixosConfigurations.browser-vm
IMG_DIR="/var/lib/libvirt/images"
ROOT_IMG="${IMG_DIR}/${VM_NAME}.qcow2"
DOMAIN_XML_REL="hosts/${VM_NAME}/browser-vm.xml"
# Traeger einer vom Produkt-Default abweichenden Tastatur. Wird von --kbd geschrieben und
# von der Gast-Config gelesen (builtins.pathExists). KEIN Payload — Geraetezustand, wie
# ssh-debug.pub. Fehlt die Datei, gilt DEF_KBD_LAYOUT (identisch in der Gast-Config).
KBD_FILE_REL="hosts/${VM_NAME}/keyboard.nix"
# Stand-Marker neben dem Image: "dieses Root-Image entspricht Repo-Stand X".
# update-all.sh (Abschnitt 3) vergleicht ihn und deployt nur bei Abweichung.
# Formel: cat flake.lock + Gast-Config + (falls vorhanden) keyboard.nix | sha256sum.
# GESPIEGELT in update-all.sh — Aenderungen an BEIDEN Stellen! (deploy-dev-vm.sh nutzt
# dieselbe Formel; die dev-VM hat keine keyboard.nix, dort faellt der Zusatz weg.)
MARKER_FILE="${IMG_DIR}/${VM_NAME}.flake-rev"
VM_NET="browser-vm-net"                   # eigenes host-lokales NAT-Netz (parallel zum dev-vm-Netz; 'default' ist Policy-bedingt entfernt, s. 1b)
# Bridge-Name — MUSS mit modules/browser-vm-net.nix uebereinstimmen (dort host.browserVm.bridge).
# Er ist der nftables-Anker der VM-Isolierung (modules/vm-net-isolation.nix): die
# Zero-Trust-Regeln (nur Internet-Egress) matchen per Interface-Name NUR auf dieser Bridge.
BRIDGE_NAME="virbr-browser"

NET_MAC="52:54:00:de:b0:02"               # feste MAC -> Anker der DHCP-Reservierung (dev-VM hat :01)
# Adressierung — MUSS mit modules/browser-vm-net.nix uebereinstimmen (dort host.browserVm.*).
# Aendert sich einer dieser Werte, hier UND dort anpassen.
NET_PREFIX="192.168.244"                   # /24-Netz; die Host-Bridge ist ${NET_PREFIX}.1 (Gateway)
VM_IP="${NET_PREFIX}.2"                     # feste browser-VM-IP (per Reservierung an NET_MAC gebunden)

# Defaults fuer CPU/RAM: greifen nur, wenn weder --flag noch eine vorhandene browser-vm.xml
# einen Wert liefern. CPU/RAM "kleben" (werden aus der erzeugten XML uebernommen).
# 6144 MiB: Brave + Video-Decode (Software) + tmpfs-Home teilen sich den RAM.
DEF_VCPUS=4
DEF_RAM_MB=6144
# Produkt-Default der Tastatur. MUSS mit dem Fallback in hosts/browser-vm/configuration.nix
# (let-Block, kbdLayout) uebereinstimmen — dort gilt er, wenn keine keyboard.nix existiert.
DEF_KBD_LAYOUT="de"

# ---------------------------------------------------------------------------
# Ausgabe-Helfer
# ---------------------------------------------------------------------------
info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
# run: mutierende Befehle ausfuehren (bei --dry-run nur anzeigen)
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '   \033[2m(dry-run)\033[0m %s\n' "$*"; else "$@"; fi; }

# ---------------------------------------------------------------------------
# Ins Repo-Wurzelverzeichnis wechseln (Skript darf aus jedem Unterordner laufen)
# ---------------------------------------------------------------------------
if [ ! -f flake.nix ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] && cd "$root"
fi
[ -f flake.nix ]          || die "Keine flake.nix gefunden — bitte im Repo (oder Repo-Root) ausfuehren."
command -v nixos-rebuild >/dev/null 2>&1 || die "nixos-rebuild nicht gefunden."

# result-Symlinks (Nix-Build-Output) ignorieren — gehoeren nicht ins Git.
ensure_gitignore() {
  local f=".gitignore" l
  for l in "result" "result-*"; do
    if [ ! -f "$f" ] || ! grep -qxF "$l" "$f"; then
      if [ "$DRY_RUN" -eq 1 ]; then info "(dry-run) Wuerde '$l' zu .gitignore hinzufuegen."; continue; fi
      printf '%s\n' "$l" >> "$f"; ok ".gitignore: '$l' ergaenzt."
    fi
  done
}
ensure_gitignore

# Hinweis, falls der Arbeitsbaum schmutzig ist (Flake-Build sieht nur GETRACKTE Dateien).
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
  warn "Arbeitsbaum hat uncommittete Aenderungen — der Flake-Build nutzt nur getrackte Dateien."
  warn "Bei Aenderungen an browser-VM-Dateien vorher:  git add -A && git commit -m '...'"
fi

# ---------------------------------------------------------------------------
# 0) Ressourcen aufloesen (Flag > vorhandene browser-vm.xml > Default) und XML erzeugen
# ---------------------------------------------------------------------------
[ -z "$OPT_CPU" ] || printf '%s' "$OPT_CPU" | grep -qE '^[0-9]+$' || die "--cpu erwartet eine Zahl, nicht '$OPT_CPU'."
[ -z "$OPT_RAM" ] || printf '%s' "$OPT_RAM" | grep -qE '^[0-9]+$' || die "--ram erwartet MiB als Zahl, nicht '$OPT_RAM'."
# --kbd HIER mitpruefen, nicht erst in 0b: ab der naechsten Zeile wird geschrieben
# (browser-vm.xml + git add). Ein Abbruch spaeter wuerde sonst z.B. ein '--cpu 8' schon
# in der XML hinterlassen, wo es beim naechsten Lauf klebt — obwohl der Lauf scheiterte.
if [ -n "$OPT_KBD" ]; then
  printf '%s' "$OPT_KBD" | grep -qE '^[a-z]{2,6}(,[a-z]{2,6})*$' \
    || die "--kbd erwartet kommagetrennte xkb-Layouts (z.B. 'de', 'de,gb', 'us') — nicht '$OPT_KBD'."
  # Haeufige Verwechslungen LAUT abfangen statt still umzudeuten: 'en'/'uk' sind keine
  # xkb-Layouts. Der Format-Check oben laesst sie durch — X11 wuerde sie spaeter
  # kommentarlos auf 'us' zurueckfallen lassen, und der Fehler faellt erst in der VM auf.
  while IFS= read -r part; do
    case "$part" in
      en|eng) die "'${part}' ist kein xkb-Layout. Gemeint ist 'us' (US-QWERTY, @ auf Shift+2) oder 'gb' (UK-QWERTY, @ auf Shift+')." ;;
      uk)     die "'uk' ist kein xkb-Layout — das britische Layout heisst 'gb'." ;;
      ger|deu) die "'${part}' ist kein xkb-Layout — das deutsche heisst 'de'." ;;
    esac
  done < <(printf '%s\n' "$OPT_KBD" | tr ',' '\n')
fi

# "Kleben": aktuelle Werte aus vorhandener browser-vm.xml lesen (gesetzt bleibt gesetzt, Flag schlaegt sie).
xml_get() { [ -f "$DOMAIN_XML_REL" ] && sed -n "$1" "$DOMAIN_XML_REL" | head -n1 || true; }
CUR_VCPUS="$(xml_get 's:.*<vcpu>\([0-9]\{1,\}\)</vcpu>.*:\1:p')"
CUR_RAM="$(xml_get "s:.*<memory unit='MiB'>\([0-9]\{1,\}\)</memory>.*:\1:p")"

VCPUS="${OPT_CPU:-${CUR_VCPUS:-$DEF_VCPUS}}"
RAM_MB="${OPT_RAM:-${CUR_RAM:-$DEF_RAM_MB}}"
info "Ressourcen: ${VCPUS} vCPU, ${RAM_MB} MiB RAM (kein Volume — die VM ist voll wegwerfbar)."

write_domain_xml() {
  mkdir -p "$(dirname "$DOMAIN_XML_REL")"
  cat > "$DOMAIN_XML_REL" <<EOF
<domain type='kvm'>
  <!-- AUTO-GENERIERT von deploy-browser-vm.sh - nicht von Hand editieren.
       CPU/RAM kommen aus den Flags (cpu/ram); gesetzte Werte bleiben erhalten ("kleben"). -->
  <name>${VM_NAME}</name>
  <memory unit='MiB'>${RAM_MB}</memory>
  <vcpu>${VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'/>
  <!-- destroy statt restart: ein GAST-initiierter Reboot behielte denselben QEMU-Prozess und
       damit das transient-Overlay — die Session waere nicht mehr jungfraeulich. So beendet
       JEDES Ende (poweroff UND reboot) die Session; der naechste Start ist garantiert frisch. -->
  <on_reboot>destroy</on_reboot>
  <devices>
    <!-- Root: aus dem Flake gebautes qcow2. <transient/> = alle Schreibzugriffe landen in
         einem Overlay, das libvirt beim Shutdown VERWIRFT -> jede Session bootet exakt das
         gebaute Image (wegwerfbar pro SESSION, nicht nur pro Deploy). Kein zweites Volume. -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${ROOT_IMG}'/>
      <target dev='vda' bus='virtio'/>
      <transient/>
    </disk>
    <interface type='network'>
      <source network='${VM_NET}'/>
      <mac address='${NET_MAC}'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'><target type='isa-serial' port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <!-- SPICE-Stack: Grafik + Audio + Agent-Kanal (Clipboard/Auto-Resize) + USB-Redirection.
         Die Webcam wird NICHT fest durchgereicht: virt-viewer leitet sie zur Laufzeit um
         (Menue "File -> USB device selection") — nur waehrend des Keystone-Signierens drin. -->
    <graphics type='spice' autoport='yes'><listen type='address'/></graphics>
    <video><model type='virtio'/></video>
    <sound model='ich9'/>
    <audio id='1' type='spice'/>
    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
    </channel>
    <controller type='usb' model='qemu-xhci' ports='8'/>
    <redirdev bus='usb' type='spicevmc'/>
    <redirdev bus='usb' type='spicevmc'/>
    <memballoon model='virtio'/>
  </devices>
</domain>
EOF
}
if [ "$DRY_RUN" -eq 1 ]; then
  info "(dry-run) Wuerde ${DOMAIN_XML_REL} mit diesen Werten erzeugen."
else
  write_domain_xml
  git add "$DOMAIN_XML_REL" >/dev/null 2>&1 || true
  ok "Domain-XML erzeugt: ${DOMAIN_XML_REL}."
fi

# ---------------------------------------------------------------------------
# 0b) Tastaturlayout aufloesen und hosts/browser-vm/keyboard.nix schreiben
# ---------------------------------------------------------------------------
# Warum eine eigene Datei statt eines Eintrags in der browser-vm.xml: das Layout ist
# KEIN libvirt-Parameter, sondern Teil des gebauten Images — es kann dort nicht "kleben".
# Die Gast-Config liest diese Datei ueber builtins.pathExists und faellt sonst auf
# DEF_KBD_LAYOUT zurueck. Muster: ssh-debug.pub (Geraetezustand, bewusst KEIN Payload).
# (Die Validierung von --kbd steht bewusst weiter oben bei den cpu/ram-Checks — vor der
#  ersten schreibenden Aktion; hier wird nur noch aufgeloest und geschrieben.)

# "Kleben": vorhandene keyboard.nix lesen (ein Flag schlaegt sie). Bewusst per sed statt
# per Nix-Eval — das Format schreibt dieses Skript selbst, ein nix-Aufruf waere hier
# unnoetiger Ballast (und im Bootstrap-Pfad nicht garantiert verfuegbar).
kbd_file_layout() {
  [ -f "$KBD_FILE_REL" ] || return 0
  sed -n 's/^[[:space:]]*layout[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$KBD_FILE_REL" | head -n1
}
CUR_KBD="$(kbd_file_layout)"
KBD_LAYOUT="${OPT_KBD:-${CUR_KBD:-$DEF_KBD_LAYOUT}}"

# Umschalttaste nur bei MEHREREN Gruppen. grp:alt_shift_toggle ist bewusst dieselbe
# Kombination wie auf dem Host (modules/desktop.nix): SPICE reicht Scancodes durch, also
# schalten Host und Gast gemeinsam um — genau das ist beim Tippen auf einer physisch
# anderen Tastatur gewollt. Bei EINER Gruppe bleibt options leer (nichts umzuschalten).
case "$KBD_LAYOUT" in
  *,*) KBD_OPTIONS="grp:alt_shift_toggle" ;;
  *)   KBD_OPTIONS="" ;;
esac

write_kbd_nix() {
  mkdir -p "$(dirname "$KBD_FILE_REL")"
  cat > "$KBD_FILE_REL" <<EOF
# hosts/browser-vm/keyboard.nix — AUTO-GENERIERT von deploy-browser-vm.sh (--kbd).
# Nicht von Hand editieren; der naechste Deploy ueberschreibt die Datei.
# Geraetezustand, KEIN Payload (nicht in payload-vm.list) — steht aber im Git, sonst
# sieht der Flake-Build sie nicht und baut still mit dem Default "${DEF_KBD_LAYOUT}".
{
  layout  = "${KBD_LAYOUT}";
  options = "${KBD_OPTIONS}";
}
EOF
}
# Datei nur anlegen, wenn ein Flag sie verlangt oder sie schon existiert (dann neu
# schreiben = idempotent). Im reinen Default-Betrieb bleibt der Host-Ordner unberuehrt.
if [ -n "$OPT_KBD" ] || [ -f "$KBD_FILE_REL" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    info "(dry-run) Wuerde ${KBD_FILE_REL} mit layout='${KBD_LAYOUT}' schreiben und tracken."
  else
    write_kbd_nix
    # git add MUSS hier passieren: der Flake-Build sieht nur GETRACKTE Dateien. Eine
    # untrackte keyboard.nix wuerde still ignoriert -> Image mit Default, ohne Fehler.
    git add "$KBD_FILE_REL" >/dev/null 2>&1 || warn "git add ${KBD_FILE_REL} fehlgeschlagen — der Build ignoriert die Datei dann still!"
    ok "Tastatur: ${KBD_LAYOUT}${KBD_OPTIONS:+ (${KBD_OPTIONS})} — ${KBD_FILE_REL} geschrieben."
  fi
else
  info "Tastatur: ${KBD_LAYOUT} (Produkt-Default; abweichend setzen mit --kbd, z.B. --kbd de,gb)."
fi

# Flake-Output vorhanden? (auf einem frischen Host evtl. noch nicht angelegt)
if ! grep -qF 'browser-vm' flake.nix; then
  warn "In flake.nix fehlt der 'browser-vm'-Output. Ergaenze unter outputs … nixosConfigurations:"
  cat <<'SNIP'
      nixosConfigurations.browser-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./hosts/browser-vm/configuration.nix ];
      };
SNIP
fi

# ---------------------------------------------------------------------------
# 1) Eigenes browser-VM-Netz (NAT) mit fester DHCP-Reservierung sicherstellen
# ---------------------------------------------------------------------------
# Bewusst ein EIGENES Netz (eigene Bridge ${BRIDGE_NAME}): die feste MAC allein liefert KEINE
# feste IP (dnsmasq vergibt sonst aus dem Range) — hier binden wir NET_MAC -> VM_IP per
# Reservierung. Die eigene Bridge ist zudem der nftables-Anker der LAN-Isolation
# (modules/vm-net-isolation.nix, seit 2026-07-21) — die Zero-Trust-Regeln treffen so
# NUR diese VM; das 'default'-Netz selbst wird in Abschnitt 1b als toter Bestand entfernt.
write_net_xml() {
  cat > "$1" <<EOF
<network>
  <name>${VM_NET}</name>
  <bridge name='${BRIDGE_NAME}' stp='on' delay='0'/>
  <forward mode='nat'/>
  <ip address='${NET_PREFIX}.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='${VM_IP}' end='${VM_IP}'/>
      <host mac='${NET_MAC}' name='${VM_NAME}' ip='${VM_IP}'/>
    </dhcp>
  </ip>
</network>
EOF
}
info "Pruefe libvirt-Netz '${VM_NET}' (${BRIDGE_NAME}, NAT, Reservierung ${NET_MAC} -> ${VM_IP})…"
if [ "$DRY_RUN" -eq 1 ]; then
  info "(dry-run) Wuerde Netz '${VM_NET}' sicherstellen (anlegen falls noetig, sonst aktiv halten)."
elif sudo virsh net-info "$VM_NET" >/dev/null 2>&1; then
  # Existiert -> nur aktiv/autostart sicherstellen. NICHT neu definieren (koennte eine an diesem
  # Netz haengende, laufende VM stoeren). Schema in browser-vm-net.nix geaendert? -> Netz neu anlegen:
  #   sudo virsh net-destroy ${VM_NET}; sudo virsh net-undefine ${VM_NET}; dann erneut deployen.
  if ! sudo virsh net-list --name 2>/dev/null | grep -qx "$VM_NET"; then
    info "Netz '${VM_NET}' ist definiert, aber inaktiv — starte es…"
    sudo virsh net-start "$VM_NET"
  fi
  sudo virsh net-autostart "$VM_NET" >/dev/null 2>&1 || true
  ok "Netz '${VM_NET}' aktiv."
else
  info "Netz '${VM_NET}' existiert nicht — lege es an (NAT, feste Reservierung)…"
  netxml="$(mktemp --suffix=.xml)"
  write_net_xml "$netxml"
  sudo virsh net-define "$netxml"
  sudo virsh net-start "$VM_NET"
  sudo virsh net-autostart "$VM_NET" >/dev/null 2>&1 || true
  rm -f "$netxml"
  ok "Netz '${VM_NET}' angelegt und aktiv (${NET_MAC} -> ${VM_IP})."
fi

# ---------------------------------------------------------------------------
# 1b) libvirt-Default-Netz entsorgen (Policy seit 2026-07-21, s. README-deploy-browser-vm.md)
# ---------------------------------------------------------------------------
# Jede VM dieses Repos hat ihre EIGENE Bridge (nftables-Anker der VM-Isolierung);
# das mitgelieferte 'default'-Netz (virbr0, 192.168.122.0/24) ist damit toter
# Bestand und faellt weg. Der Check laeuft in JEDEM deploy-*-vm.sh-Lauf — so ist
# das Netz auch nach einer Neuinstallation, oder falls ein libvirt-Update es je
# wiederbelebt, von selbst wieder verschwunden (kein Merkposten noetig).
# Schutzgitter: referenziert eine definierte Domain das Netz noch (fremde, von
# Hand angelegte VM), wird NICHT geloescht, nur gewarnt.
remove_default_net() {
  sudo virsh net-info default >/dev/null 2>&1 || return 0   # nicht vorhanden -> nichts zu tun
  local users=""
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if sudo virsh dumpxml "$d" 2>/dev/null | grep -q "source network='default'"; then
      users="${users} ${d}"
    fi
  done < <(sudo virsh list --all --name 2>/dev/null)
  if [ -n "$users" ]; then
    warn "libvirt-Default-Netz wird noch von Domain(s)${users} referenziert — bleibt bestehen."
    warn "Policy: eigene Bridge je VM (s. README-deploy-browser-vm.md). Domain(s) umziehen, dann erneut deployen."
    return 0
  fi
  info "Entferne ungenutztes libvirt-Default-Netz (Policy: eigene Bridge je VM)…"
  sudo virsh net-destroy default >/dev/null 2>&1 || true    # nur noetig, falls aktiv
  sudo virsh net-undefine default
  ok "libvirt-Default-Netz entfernt (virbr0 weg; kuenftige Deploys halten das so)."
}
if [ "$DRY_RUN" -eq 1 ]; then
  info "(dry-run) Wuerde ein vorhandenes, ungenutztes libvirt-Default-Netz entfernen."
else
  remove_default_net
fi

# ---------------------------------------------------------------------------
# 2) Image aus dem Flake bauen (nixpkgs-eingebaut, kein Extra-Input)
# ---------------------------------------------------------------------------
info "Baue browser-VM-Image (nixos-rebuild build-image, Variante qemu)…"
run nixos-rebuild build-image --image-variant qemu --flake "$FLAKE_ATTR"

QCOW_SRC=""
if [ "$DRY_RUN" -eq 0 ]; then
  QCOW_SRC="$(find -L result -type f -name '*.qcow2' 2>/dev/null | head -n1 || true)"
  [ -n "$QCOW_SRC" ] || die "Gebautes qcow2 nicht unter ./result gefunden — pruefe die build-image-Ausgabe."
  ok "Image gebaut: ${QCOW_SRC}"
fi

# ---------------------------------------------------------------------------
# 3) Bei laufender VM erst stoppen (Disk freigeben, bevor wir sie ueberschreiben)
#    (Das <transient/>-Overlay der laufenden Session wird dabei verworfen — gewollt.)
# ---------------------------------------------------------------------------
VM_EXISTS=0
if [ "$DRY_RUN" -eq 0 ] && sudo virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  VM_EXISTS=1
  if sudo virsh domstate "$VM_NAME" 2>/dev/null | grep -q running; then
    warn "Domain ${VM_NAME} laeuft — wird gestoppt (frischer Root folgt)."
    sudo virsh destroy "$VM_NAME"
  fi
fi

# ---------------------------------------------------------------------------
# 4) Root-Image frisch platzieren (jeder Deploy = neue Basis; jede Session = frisches Overlay)
# ---------------------------------------------------------------------------
info "Platziere Root-Image nach ${ROOT_IMG} (frischer Root)…"
run sudo install -d -m 0755 "$IMG_DIR"
run sudo cp --reflink=auto "${QCOW_SRC:-<gebautes-qcow2>}" "$ROOT_IMG"


# ---------------------------------------------------------------------------
# 5) Domain (neu) definieren + starten  (Redeploy: stop -> undefine -> define -> start)
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$OPT_AUTOSTART" -eq 1 ]; then
    info "(dry-run) Wuerde ${VM_NAME} aus ${DOMAIN_XML_REL} neu definieren, Boot-Autostart AKTIVIEREN und starten."
  else
    info "(dry-run) Wuerde ${VM_NAME} aus ${DOMAIN_XML_REL} neu definieren, Boot-Autostart deaktivieren und einmalig starten."
  fi
else
  [ "$VM_EXISTS" -eq 1 ] && { info "Entferne alte Definition…"; sudo virsh undefine "$VM_NAME"; }
  info "Definiere ${VM_NAME} aus ${DOMAIN_XML_REL}…"
  sudo virsh define "$DOMAIN_XML_REL"
  # Boot-Autostart standardmaessig AUS: das Desktop-Icon (browser-vm-launch) faehrt die VM
  # on-demand hoch. Der Deploy setzt den Zustand EXPLIZIT -> kein Verlass auf frueher Gesetztes.
  # Der einmalige Start bleibt (Verifikation, dass das frische Image bootet; known_hosts unten
  # sieht den neuen Host-Key).
  if [ "$OPT_AUTOSTART" -eq 1 ]; then
    sudo virsh autostart "$VM_NAME"
    AUTOSTART_MSG="Boot-Autostart AKTIV (via --autostart)"
  else
    sudo virsh autostart --disable "$VM_NAME"
    AUTOSTART_MSG="KEIN Boot-Autostart — das Desktop-Icon startet sie bei Bedarf"
  fi
  if [ "$OPT_NOSTART" -eq 1 ]; then
    # Update-Pfad: die VM war aus (update-all fasst laufende VMs nicht an) und
    # bleibt aus — die Wegwerf-Session startet ohnehin erst per Icon. Die
    # Boot-Verifikation uebernimmt dieser naechste regulaere Start.
    ok "browser-VM aktualisiert, NICHT gestartet (--no-start; ${AUTOSTART_MSG})."
  else
    info "Starte ${VM_NAME}…"
    sudo virsh start "$VM_NAME"
    ok "browser-VM laeuft (${AUTOSTART_MSG})."
  fi
fi

# ---------------------------------------------------------------------------
# 6) known_hosts pflegen — die IP ist fest reserviert, kein Warten auf DHCP-Lease noetig
# ---------------------------------------------------------------------------
# Wegwerf-VM: der SSH-Host-Key aendert sich MIT JEDEM BOOT (transient Root -> Key wird jede
# Session neu erzeugt). Alte Eintraege aus frueheren Zugaengen hier ausraeumen; das laufende
# Handling uebernimmt die Host-ssh-Config (UserKnownHostsFile /dev/null fuer diese IP).
# SSH ist ohnehin nur Bauphasen-Debug; der Alltag laeuft komplett ueber SPICE (virt-viewer).
if [ "$DRY_RUN" -eq 0 ] && command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -R "$VM_IP" >/dev/null 2>&1 || true
  ok "Veralteten known_hosts-Eintrag fuer ${VM_IP} entfernt."
fi

# ---------------------------------------------------------------------------
# Abschluss
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Stand-Marker schreiben — bewusst als LETZTER Schritt: der Marker bedeutet
# "Deploy auf diesem Repo-Stand ERFOLGREICH ABGESCHLOSSEN", nicht "Root-Image
# kopiert". Bricht irgendein frueherer Schritt ab (set -e), bleibt der alte
# Marker stehen und update-all haelt die VM sichtbar faellig — genau richtig.
# Formel-Spiegel s. Konstanten oben; 0644: update-all liest ihn ohne sudo.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  info "(dry-run) Wuerde zum Abschluss den Stand-Marker ${MARKER_FILE} schreiben."
else
  # keyboard.nix geht MIT ein, wenn sie existiert — sonst bliebe ein reiner
  # Layout-Wechsel fuer update-all.sh unsichtbar und die VM nie faellig.
  marker_inputs=( flake.lock "hosts/${VM_NAME}/configuration.nix" )
  if [ -f "$KBD_FILE_REL" ]; then marker_inputs+=( "$KBD_FILE_REL" ); fi
  cat "${marker_inputs[@]}" | sha256sum | cut -d' ' -f1 \
    | sudo tee "$MARKER_FILE" >/dev/null
  sudo chmod 0644 "$MARKER_FILE"
  ok "Stand-Marker geschrieben: ${MARKER_FILE}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  ok "Dry-run fertig (nichts veraendert)."
elif [ "$OPT_NOSTART" -eq 1 ]; then
  cat <<EOF

browser-VM aktualisiert (nicht gestartet, --no-start). Die naechste Session ueber das
Desktop-Icon "Brave (browser-VM)" bootet das frische Image und verifiziert es damit.
EOF
else
  cat <<EOF

browser-VM deployt. IP: ${VM_IP}  (fest reserviert ueber Netz '${VM_NET}')

Naechste Schritte:
  - Anzeige (SPICE):      Desktop-Icon "Brave (browser-VM)"  oder  browser-vm-launch
                          (Brave schliessen = VM faehrt herunter; naechster Start = frische Session)
  - Webcam fuers Signing: im virt-viewer-Fenster: File -> USB device selection -> Kamera waehlen
  - Debug (Bauphase):     ssh browse@${VM_IP}   bzw.  sudo virsh console ${VM_NAME}  (raus: Strg-])

Hinweis: Der SSH-Host-Key wechselt bei JEDEM Boot (transient Root). Die Host-ssh-Config
prueft ihn fuer diese Wegwerf-IP deshalb bewusst nicht (StrictHostKeyChecking no +
UserKnownHostsFile /dev/null in modules/browser-vm-host.nix) — 'accept-new' allein wuerde
ab der zweiten Session mit 'HOST IDENTIFICATION CHANGED' abbrechen.
EOF
fi
