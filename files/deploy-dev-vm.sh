#!/usr/bin/env bash
#
# deploy-dev-vm.sh — baut & deployt die dev-VM (near-stateless) reproduzierbar.
# Host-agnostisch: laeuft auf allen Hosts identisch (kein Hardware-Bezug).
#
# Ablauf: Ressourcen aufloesen + dev-vm.xml erzeugen -> dev-VM-Netz sicherstellen -> Image bauen -> bei
#   laufender VM stoppen -> Root frisch -> Persistenz-Volume sicherstellen/vergroessern ->
#   Domain neu definieren -> starten -> IP + known_hosts. Persistent: /home/dev.
#
# Aufruf (irgendwo im Repo):
#   bash deploy-dev-vm.sh [--cpu N] [--ram MiB] [--disk SIZE] [--autostart] [--no-start] [--dry-run]
#     --cpu N      vCPUs              (Default 4;    ohne Angabe gilt der zuletzt genutzte Wert)
#     --ram MiB    Arbeitsspeicher    (Default 4096; dito — gesetzte Werte "kleben")
#     --disk SIZE  Persistenz-Volume  (Default 20G;  waechst nur, schrumpft nie)
#     --autostart  VM beim Host-Boot automatisch starten (Default: AUS -> on-demand ueber das Zed-Icon)
#     --no-start   VM nach dem Deploy NICHT starten (Update-Pfad: update-all.sh, Abschnitt 3 —
#                  die VM war aus und bleibt aus; der naechste Icon-Start bootet das frische Image)
#     --dry-run    nur anzeigen, nichts veraendern
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Selbst-Bootstrap: fehlende Tools via nix-shell nachladen.
# WICHTIG: VOR dem Flag-Parsing — das while/shift unten verbraucht "$@"; danach waeren
# die Flags beim Re-Exec in der nix-shell verloren. Hier ist "$@" noch vollstaendig.
# ---------------------------------------------------------------------------
if ! command -v virsh >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1 \
   || ! command -v mkfs.ext4 >/dev/null 2>&1 || ! command -v resize2fs >/dev/null 2>&1; then
  if [ -z "${DEVVM_BOOTSTRAPPED:-}" ]; then
    export DEVVM_BOOTSTRAPPED=1
    exec nix-shell -p libvirt git e2fsprogs --run "bash $(printf '%q ' "$0" "$@")"
  fi
fi

# ---------------------------------------------------------------------------
# Flags  (CPU/RAM/Disk optional; ohne Angabe gilt der zuletzt genutzte Wert -> "kleben")
# ---------------------------------------------------------------------------
DRY_RUN=0; OPT_CPU=""; OPT_RAM=""; OPT_DISK=""; OPT_AUTOSTART=0; OPT_NOSTART=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --no-start)  OPT_NOSTART=1 ;;
    --cpu)       OPT_CPU="${2:?--cpu braucht einen Wert}"; shift ;;
    --cpu=*)     OPT_CPU="${1#*=}" ;;
    --ram)       OPT_RAM="${2:?--ram braucht einen Wert (MiB)}"; shift ;;
    --ram=*)     OPT_RAM="${1#*=}" ;;
    --disk)      OPT_DISK="${2:?--disk braucht einen Wert (z. B. 40G)}"; shift ;;
    --disk=*)    OPT_DISK="${1#*=}" ;;
    --autostart) OPT_AUTOSTART=1 ;;
    -h|--help)   sed -n '2,19p' "$0"; exit 0 ;;
    *) printf 'Unbekanntes Argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Feste Konfiguration (selten anzupassen)
# ---------------------------------------------------------------------------
VM_NAME="dev-vm"
FLAKE_ATTR=".#${VM_NAME}"                 # nixosConfigurations.dev-vm
IMG_DIR="/var/lib/libvirt/images"
ROOT_IMG="${IMG_DIR}/${VM_NAME}.qcow2"
DOMAIN_XML_REL="hosts/${VM_NAME}/dev-vm.xml"
VM_NET="dev-vm-net"                       # eigenes host-lokales NAT-Netz (das 'default'-Netz ist Policy-bedingt entfernt, s. 1b)
# Bridge-Name — MUSS mit modules/dev-vm-net.nix uebereinstimmen (dort host.devVm.bridge).
# Er ist der nftables-Anker der VM-Isolierung (modules/vm-net-isolation.nix): die
# Isolations-Regeln matchen per Interface-Name NUR auf dieser Bridge.
BRIDGE_NAME="virbr-dev"

# Persistenz-Volume (Stufe 2): /home/dev (Code, git-/Claude-Code-Auth) ueberlebt den frischen Root.
PERSIST_IMG="${IMG_DIR}/${VM_NAME}-persist.img"
PERSIST_LABEL="devvm-persist"
# Stand-Marker neben dem Image: "dieses Root-Image entspricht Repo-Stand X".
# update-all.sh (Abschnitt 3) vergleicht ihn und deployt nur bei Abweichung.
# Formel (cat flake.lock + Gast-Config | sha256sum) ist GESPIEGELT in
# deploy-browser-vm.sh und update-all.sh — Aenderungen an allen drei Stellen!
MARKER_FILE="${IMG_DIR}/${VM_NAME}.flake-rev"
NET_MAC="52:54:00:de:b0:01"               # feste MAC -> Anker der DHCP-Reservierung der dev-VM
# Adressierung — MUSS mit modules/dev-vm-net.nix uebereinstimmen (dort host.devVm.*).
# Aendert sich einer dieser Werte, hier UND dort anpassen.
NET_PREFIX="192.168.243"                   # /24-Netz; die Host-Bridge ist ${NET_PREFIX}.1 (Gateway)
VM_IP="${NET_PREFIX}.2"                     # feste dev-VM-IP (per Reservierung an NET_MAC gebunden)

# Defaults fuer CPU/RAM/Disk: greifen nur, wenn weder --flag noch eine vorhandene dev-vm.xml
# einen Wert liefern. CPU/RAM "kleben" (werden aus der erzeugten XML uebernommen);
# Disk waechst nur (Default schrumpft nie ein bereits groesseres Volume).
DEF_VCPUS=4
DEF_RAM_MB=4096
DEF_PERSIST_SIZE="20G"

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
  warn "Bei Aenderungen an dev-VM-Dateien vorher:  git add -A && git commit -m '...'"
fi

# ---------------------------------------------------------------------------
# 0a) Gast-SSH-Key sicherstellen (hosts/dev-vm/ssh.pub) — VOR dem Image-Build
# ---------------------------------------------------------------------------
# Die dev-VM BRAUCHT einen authorized key: Zed/waypipe laeuft ueber SSH, und
# die Gast-Config liest hosts/dev-vm/ssh.pub via builtins.readFile (fehlt die
# Datei, schlaegt der Image-Build ABSICHTLICH fehl — eine VM ohne Zugang waere
# nutzlos). Fehlt die Datei, wird sie hier EINMALIG aus dem Public Key des
# aufrufenden Nutzers geseedet (~/.ssh/id_ed25519.pub, sonst erste *.pub) und
# per git add sichtbar gemacht (untracked waere fuer den Flake unsichtbar!).
# Danach ist sie normaler, personen-eigener Repo-Bestand — der Payload selbst
# bleibt personalisierungsfrei. Key-Rotation: Datei ersetzen, git add, neu
# deployen (bewusste Grenze: der Stand-Marker erfasst nur flake.lock +
# Gast-Config — eine reine Key-Rotation deployt man von Hand).
# Bewusste ASYMMETRIE zur browser-vm: dort ist ssh-debug.pub optional und wird
# NIE geseedet (Zero-Trust-Default: kein SSH ohne explizite Entscheidung).
GUEST_KEY="hosts/${VM_NAME}/ssh.pub"
if [ ! -f "$GUEST_KEY" ]; then
  seed_src=""
  for c in "$HOME/.ssh/id_ed25519.pub" "$HOME"/.ssh/*.pub; do
    if [ -f "$c" ]; then seed_src="$c"; break; fi
  done
  if [ -z "$seed_src" ]; then
    die "Gast-Key fehlt: ${GUEST_KEY} existiert nicht und ~/.ssh enthaelt keinen *.pub. Erst 'ssh-keygen -t ed25519' oder die Datei selbst befuellen."
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    info "(dry-run) Wuerde ${GUEST_KEY} einmalig aus ${seed_src} seeden + git add."
  else
    install -D -m 0644 "$seed_src" "$GUEST_KEY"
    git add "$GUEST_KEY" 2>/dev/null || true
    ok "Gast-Key geseedet: ${GUEST_KEY}  <-  ${seed_src}  (einmalig; ab jetzt Repo-Bestand)"
  fi
fi
# Optionale Git-Identitaet des Gastes (hosts/dev-vm/git-identity.nix): einmalig
# aus der Host-Git-Config geseedet, damit Commits in der VM sofort die richtige
# Autorenschaft tragen — gleiche Mechanik wie ssh.pub, aber OHNE Abbruch-Pflicht:
# fehlt die Host-Identitaet, meldet sich git im Gast beim ersten Commit selbst
# verstaendlich (Datei dann von Hand anlegen oder in der VM konfigurieren).
GUEST_GITID="hosts/${VM_NAME}/git-identity.nix"
if [ ! -f "$GUEST_GITID" ]; then
  gi_name=$(git config --get user.name 2>/dev/null || true)
  gi_mail=$(git config --get user.email 2>/dev/null || true)
  if [ -n "$gi_name" ] && [ -n "$gi_mail" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      info "(dry-run) Wuerde ${GUEST_GITID} aus der Host-Git-Config seeden (${gi_name})."
    else
      {
        printf '# AUTO-GESEEDET von deploy-dev-vm.sh (Abschnitt 0a) aus der Host-Git-Config.\n'
        printf '# Personen-eigener Repo-Bestand, KEIN Payload — Aenderung: editieren,\n'
        printf '# git add, neu deployen (Stand-Marker-Grenze wie bei ssh.pub).\n'
        printf '{\n  name  = "%s";\n  email = "%s";\n}\n' "$gi_name" "$gi_mail"
      } > "$GUEST_GITID"
      git add "$GUEST_GITID" 2>/dev/null || true
      ok "Git-Identitaet geseedet: ${GUEST_GITID}  (${gi_name} <${gi_mail}>)"
    fi
  else
    info "Keine Host-Git-Identitaet gesetzt — ${GUEST_GITID} bleibt aus (git fragt im Gast beim ersten Commit)."
  fi
fi

# ---------------------------------------------------------------------------
# 0) Ressourcen aufloesen (Flag > vorhandene dev-vm.xml > Default) und dev-vm.xml erzeugen
# ---------------------------------------------------------------------------
# Werte pruefen (jetzt ist die() verfuegbar).
[ -z "$OPT_CPU" ]  || printf '%s' "$OPT_CPU"  | grep -qE '^[0-9]+$'        || die "--cpu erwartet eine Zahl, nicht '$OPT_CPU'."
[ -z "$OPT_RAM" ]  || printf '%s' "$OPT_RAM"  | grep -qE '^[0-9]+$'        || die "--ram erwartet MiB als Zahl, nicht '$OPT_RAM'."
[ -z "$OPT_DISK" ] || printf '%s' "$OPT_DISK" | grep -qE '^[0-9]+[KMGT]?$' || die "--disk erwartet z. B. 40G, nicht '$OPT_DISK'."

# "Kleben": aktuelle Werte aus vorhandener dev-vm.xml lesen (gesetzt bleibt gesetzt, Flag schlaegt sie).
xml_get() { [ -f "$DOMAIN_XML_REL" ] && sed -n "$1" "$DOMAIN_XML_REL" | head -n1 || true; }
CUR_VCPUS="$(xml_get 's:.*<vcpu>\([0-9]\{1,\}\)</vcpu>.*:\1:p')"
CUR_RAM="$(xml_get "s:.*<memory unit='MiB'>\([0-9]\{1,\}\)</memory>.*:\1:p")"

VCPUS="${OPT_CPU:-${CUR_VCPUS:-$DEF_VCPUS}}"
RAM_MB="${OPT_RAM:-${CUR_RAM:-$DEF_RAM_MB}}"
PERSIST_SIZE="${OPT_DISK:-$DEF_PERSIST_SIZE}"   # Disk waechst nur -> Default schrumpft kein groesseres Volume
info "Ressourcen: ${VCPUS} vCPU, ${RAM_MB} MiB RAM; Persistenz-Volume Ziel ${PERSIST_SIZE} (waechst nur)."

write_domain_xml() {
  mkdir -p "$(dirname "$DOMAIN_XML_REL")"
  cat > "$DOMAIN_XML_REL" <<EOF
<domain type='kvm'>
  <!-- AUTO-GENERIERT von deploy-dev-vm.sh - nicht von Hand editieren.
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
  <on_reboot>restart</on_reboot>
  <devices>
    <!-- Root: aus dem Flake gebautes qcow2 (near-stateless: jeder Deploy frisch). -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${ROOT_IMG}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <!-- Persistenz-Volume: /home/dev bleibt ueber Deploys (raw, vom Skript verwaltet). -->
    <disk type='file' device='disk'>
      <driver name='qemu' type='raw'/>
      <source file='${PERSIST_IMG}'/>
      <target dev='vdb' bus='virtio'/>
    </disk>
    <interface type='network'>
      <source network='${VM_NET}'/>
      <mac address='${NET_MAC}'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'><target type='isa-serial' port='0'/></serial>
    <console type='pty'><target type='serial' port='0'/></console>
    <graphics type='spice' autoport='yes'><listen type='address'/></graphics>
    <video><model type='virtio'/></video>
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

# Vorbedingung der Auto-Discovery (Baustein A) pruefen.
#
# FRUEHER stand hier ein 'grep -qF dev-vm flake.nix' plus ein Vorschlag, einen
# nixosConfigurations-Block von Hand zu ergaenzen. Beides ist seit Baustein A
# falsch: flake.nix nennt KEINEN Host mehr namentlich (readDir ueber hosts/), der
# grep haette also bei jedem Lauf Fehlalarm geschlagen — und ein manuell
# ergaenzter nixosConfigurations.${VM_NAME}-Block kollidiert heute mit lib.genAttrs.
#
# Geprueft wird deshalb, was die Auto-Discovery TATSAECHLICH braucht:
#   1. hosts/<VM_NAME>/configuration.nix existiert  -> sonst gibt es den Output nicht
#   2. git kennt die Datei                          -> sonst ist sie fuer die
#      Flake-Evaluation unsichtbar. Das ist der gefaehrlichere Fall: existiert eine
#      AELTERE getrackte Fassung, baut Nix stillschweigend die — der Deploy meldet
#      Erfolg, im Image steckt aber der alte Stand.
# Beides ist harte Vorbedingung (der Build scheitert sonst ohnehin) -> die, nicht warn.
# Die Pruefung laeuft bewusst VOR dem ersten sudo-Aufruf (Abschnitt 1).
GUEST_CFG="hosts/${VM_NAME}/configuration.nix"
[ -f "$GUEST_CFG" ] \
  || die "${GUEST_CFG} fehlt — die Auto-Discovery findet die VM nur mit dieser Datei (s. flake.nix, Konvention Baustein A)."
git ls-files --error-unmatch "$GUEST_CFG" >/dev/null 2>&1 \
  || die "${GUEST_CFG} ist nicht von git getrackt — 'git add -A' ausfuehren. Ungetrackte Dateien sind fuer die Flake-Evaluation unsichtbar."

# ---------------------------------------------------------------------------
# 1) Eigenes dev-VM-Netz (NAT) mit fester DHCP-Reservierung sicherstellen
# ---------------------------------------------------------------------------
# Bewusst ein EIGENES Netz statt des libvirt-'default': die feste MAC allein liefert KEINE
# feste IP (dnsmasq vergibt sonst aus dem Range). Hier binden wir NET_MAC -> VM_IP per
# Reservierung, sodass die VM auf jedem Host dieselbe Adresse bekommt.
# Die eigene Bridge ist zudem der nftables-Anker der VM-Isolierung; das 'default'-Netz
# selbst wird in Abschnitt 1b als toter Bestand entfernt.
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
  # Netz haengende, laufende VM stoeren). Schema in dev-vm-net.nix geaendert? -> Netz neu anlegen:
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
# 1b) libvirt-Default-Netz entsorgen (Policy seit 2026-07-21, s. README-deploy-dev-vm.md)
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
    warn "Policy: eigene Bridge je VM (s. README-deploy-dev-vm.md). Domain(s) umziehen, dann erneut deployen."
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
info "Baue dev-VM-Image (nixos-rebuild build-image, Variante qemu)…"
run nixos-rebuild build-image --image-variant qemu --flake "$FLAKE_ATTR"

QCOW_SRC=""
if [ "$DRY_RUN" -eq 0 ]; then
  QCOW_SRC="$(find -L result -type f -name '*.qcow2' 2>/dev/null | head -n1 || true)"
  [ -n "$QCOW_SRC" ] || die "Gebautes qcow2 nicht unter ./result gefunden — pruefe die build-image-Ausgabe."
  ok "Image gebaut: ${QCOW_SRC}"
fi

# ---------------------------------------------------------------------------
# 3) Bei laufender VM erst stoppen (Disk freigeben, bevor wir sie ueberschreiben)
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
# 4) Root-Image frisch platzieren (near-stateless: Root bei jedem Deploy neu)
# ---------------------------------------------------------------------------
info "Platziere Root-Image nach ${ROOT_IMG} (frischer Root)…"
run sudo install -d -m 0755 "$IMG_DIR"
run sudo cp --reflink=auto "${QCOW_SRC:-<gebautes-qcow2>}" "$ROOT_IMG"


# ---------------------------------------------------------------------------
# 4b) Persistenz-Volume: einmalig anlegen, sonst erhalten — auf Wunsch VERGROESSERN.
#     (VM ist hier gestoppt -> resize2fs auf der raw-Datei ist sicher.)
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  info "(dry-run) Wuerde Persistenz-Volume sicherstellen (${PERSIST_SIZE}, ext4, Label ${PERSIST_LABEL}); ggf. vergroessern."
elif sudo test -f "$PERSIST_IMG"; then
  # Existiert -> Daten bleiben. Nur VERGROESSERN: truncate '>' waechst, schrumpft NIE.
  before="$(sudo stat -c %s "$PERSIST_IMG")"
  sudo truncate -s ">${PERSIST_SIZE}" "$PERSIST_IMG"
  after="$(sudo stat -c %s "$PERSIST_IMG")"
  if [ "$after" -gt "$before" ]; then
    info "Persistenz-Volume waechst -> ${PERSIST_SIZE}; Dateisystem anpassen (VM ist gestoppt)…"
    sudo e2fsck -fy "$PERSIST_IMG" >/dev/null 2>&1 || true   # nach hartem VM-Stopp ggf. unclean
    sudo resize2fs "$PERSIST_IMG"
    ok "Persistenz-Volume vergroessert auf ${PERSIST_SIZE} (Daten erhalten)."
  else
    ok "Persistenz-Volume vorhanden (>= ${PERSIST_SIZE}) -> Daten bleiben unveraendert."
  fi
else
  info "Lege Persistenz-Volume an (${PERSIST_SIZE}, ext4, Label ${PERSIST_LABEL})…"
  TMP_P="$(mktemp --suffix=.img)"
  truncate -s "$PERSIST_SIZE" "$TMP_P"
  mkfs.ext4 -q -F -L "$PERSIST_LABEL" "$TMP_P"
  sudo install -o root -g root -m 0660 "$TMP_P" "$PERSIST_IMG"
  rm -f "$TMP_P"
  ok "Persistenz-Volume angelegt: ${PERSIST_IMG}"
fi

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
  # Boot-Autostart standardmaessig AUS: die VM kostet idle spuerbar Strom (CPU bleibt wach), das
  # Zed-Icon (zed-dev-vm-launch) faehrt sie on-demand hoch. Mit --autostart wird er gesetzt (z. B.
  # wenn die VM dauerhaft laufen soll). So oder so setzt der Deploy den Zustand EXPLIZIT -> kein
  # Verlass auf einen frueher gesetzten Wert. Den einmaligen Start nach dem Deploy behalten wir
  # (Verifikation, dass das frische Image bootet + known_hosts unten sieht den neuen Host-Key).
  if [ "$OPT_AUTOSTART" -eq 1 ]; then
    sudo virsh autostart "$VM_NAME"
    AUTOSTART_MSG="Boot-Autostart AKTIV (via --autostart)"
  else
    sudo virsh autostart --disable "$VM_NAME"
    AUTOSTART_MSG="KEIN Boot-Autostart — das Zed-Icon startet sie bei Bedarf"
  fi
  if [ "$OPT_NOSTART" -eq 1 ]; then
    # Update-Pfad: die VM war aus (update-all fasst laufende VMs nicht an) und
    # bleibt aus — on-demand-Prinzip. Boot-Verifikation uebernimmt der naechste
    # regulaere Start (Icon); ein manueller Deploy OHNE das Flag startet wie immer.
    ok "dev-VM aktualisiert, NICHT gestartet (--no-start; ${AUTOSTART_MSG})."
  else
    info "Starte ${VM_NAME}…"
    sudo virsh start "$VM_NAME"
    ok "dev-VM laeuft (${AUTOSTART_MSG})."
  fi
fi

# ---------------------------------------------------------------------------
# 6) known_hosts pflegen — die IP ist fest reserviert, kein Warten auf DHCP-Lease noetig
# ---------------------------------------------------------------------------
# Near-stateless: der SSH-Host-Key der VM aendert sich bei jedem Deploy -> veralteten
# known_hosts-Eintrag entfernen, sonst bricht 'ssh' mit 'HOST IDENTIFICATION CHANGED' ab.
# Beim naechsten Connect bestaetigst du den neuen Key einmal (yes).
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
  cat flake.lock "hosts/${VM_NAME}/configuration.nix" | sha256sum | cut -d' ' -f1 \
    | sudo tee "$MARKER_FILE" >/dev/null
  sudo chmod 0644 "$MARKER_FILE"
  ok "Stand-Marker geschrieben: ${MARKER_FILE}"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  ok "Dry-run fertig (nichts veraendert)."
elif [ "$OPT_NOSTART" -eq 1 ]; then
  cat <<EOF

dev-VM aktualisiert (nicht gestartet, --no-start). Naechster Start wie gewohnt
on-demand ueber das Zed-Icon — er bootet das frische Image und verifiziert es damit.
EOF
else
  cat <<EOF

dev-VM deployt. IP: ${VM_IP}  (fest reserviert ueber Netz '${VM_NET}')

Naechste Schritte:
  - Vom HOST in die VM:   ssh dev@${VM_IP}     (1x neuen Host-Key bestaetigen: yes)
  - Konsole (Debug):      sudo virsh console ${VM_NAME}      (raus: Strg-])

Hinweis: Der veraltete known_hosts-Eintrag wurde bereits automatisch entfernt — der
'HOST IDENTIFICATION CHANGED'-Abbruch passiert also nicht mehr.
EOF
fi
