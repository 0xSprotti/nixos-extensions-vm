# modules/dev-vm-host.nix
# ─────────────────────────────────────────────────────────────────────────────
# Geteilte Host-seitige Anbindung der dev-VM (hardware-agnostisch -> identisch auf
# auf allen Hosts identisch):
#   - libvirt/KVM (Daemon, swtpm, virt-manager)
#   - GUI-Zugang: waypipe + Zed-Desktop-Icon (echtes Logo aus dem zed-editor-Paket)
#   - ssh-Config fuers Agent-Forwarding in die VM (git in Zed ohne Key in der VM)
#
# Die dev-VM-Adresse kommt aus modules/dev-vm-net.nix (host.devVm.ip), das dieses Modul
# selbst importiert. Das eigene libvirt-Netz mit DHCP-Reservierung (MAC -> diese IP) legt
# deploy-dev-vm.sh an. Den User in die libvirtd-Gruppe setzt die jeweilige Host-Config.
# Die Update-Erinnerung (Icon + Timer) liegt generisch in modules/host-updates.nix.
{ config, lib, pkgs, ... }:
let
  # dev-VM-Adresse aus der zentralen Konstante — fuer das Desktop-Icon & die ssh-Config.
  vmIp = config.host.devVm.ip;

  # Echtes Zed-Logo fuers Desktop-Icon: NUR die PNG aus dem zed-editor-Paket ziehen
  # (kein zed-editor in der Host-Laufzeit-Closure -- die PNG enthaelt keine Store-Pfade,
  # also keine Referenz). Das Logo folgt damit automatisch jedem Zed-Update. Der Pfad ist
  # fuer nixos-26.05 verifiziert; aendert Zed ihn mal, bricht der Build laut & klar (kein
  # stilles Fallback aufs falsche Icon). zed-editor liegt ohnehin im Store (die dev-VM nutzt es).
  zed-icon = pkgs.runCommandLocal "zed-icon" { } ''
    install -Dm644 ${pkgs.zed-editor}/share/icons/hicolor/512x512/apps/zed.png "$out/zed.png"
  '';

  # Host-Wrapper fuers Zed-Icon: faehrt die dev-VM bei Bedarf hoch, wartet auf SSH, startet dann
  # Zed via waypipe. So braucht die VM KEINEN Boot-Autostart (spart Strom) — das Icon startet sie
  # on-demand. Laeuft sie schon, wird der Start uebersprungen (dann nur warten + Zed).
  zed-launch = pkgs.writeShellScriptBin "zed-dev-vm-launch" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.libvirt pkgs.waypipe pkgs.openssh pkgs.coreutils pkgs.gnugrep ]}:$PATH
    VM=dev-vm
    IP=${vmIp}
    VIRSH="virsh -c qemu:///system"

    # VM starten, falls sie nicht laeuft (sprachneutral ueber den Namen pruefen).
    if ! $VIRSH list --state-running --name | grep -qx "$VM"; then
      echo "dev-VM startet…"
      $VIRSH start "$VM" >/dev/null
    fi

    # Auf SSH warten (Port 22 erreichbar), bis ~60s — danach Abbruch mit Hinweis.
    echo "Warte auf SSH ($IP)…"
    ready=0
    for _ in $(seq 1 60); do
      if (echo >/dev/tcp/$IP/22) 2>/dev/null; then ready=1; break; fi
      sleep 1
    done
    [ "$ready" = 1 ] || { echo "SSH auf $IP nicht erreichbar (Timeout)." >&2; exit 1; }

    # Zed via waypipe (Agent-Forwarding: Key muss im Host-Agent sein -> vorher ssh-add).
    echo "Starte Zed…"
    exec waypipe ssh -A "dev@$IP" zed-dev
  '';
in
{
  # Selbsttragend: zieht die Adressierungs-Konstante (host.devVm.*) selbst mit, statt sich darauf
  # zu verlassen, dass die Host-Config sie listet — ein Host kann sie so nicht mehr "vergessen".
  # NixOS dedupliziert imports nach Pfad: importiert ein Host dev-vm-net.nix zusaetzlich, wird es
  # trotzdem nur einmal ausgewertet (kein "option defined multiple times").
  imports = [ ./dev-vm-net.nix ];

  # ===== Virtualisierung: libvirt/KVM =====
  virtualisation.libvirtd = {
    enable = true;
    # on-demand-Workflow absichern: der libvirt-guests-Dienst darf die VM beim Host-Boot NICHT
    # wiederbeleben. Default waere onBoot="start" -> startet ALLE vor dem Shutdown laufenden Gaeste,
    # UNABHAENGIG vom Per-VM-autostart-Flag (genau die Falle: 'autostart: disable', VM trotzdem an).
    # onBoot="ignore" schaltet nur dieses formerly-running-Restore ab; ein als autostart markierter
    # Gast (deploy-dev-vm.sh --autostart) wird von libvirtd weiterhin gestartet -> --autostart wirkt.
    onBoot = "ignore";
    # onShutdown="shutdown": beim Host-Shutdown sauber per ACPI herunterfahren statt managedsave.
    # So bootet die VM beim naechsten Icon-Start frisch (kein RAM-Snapshot, kein Konflikt mit dem
    # near-stateless Redeploy, der das Root-Image neu baut).
    onShutdown = "shutdown";
    qemu.swtpm.enable = true;            # virtueller TPM fuer Gaeste
  };
  programs.virt-manager.enable = true;   # GUI-Verwaltung
  programs.ssh.startAgent = true;        # SSH-Key-Passphrase nur 1x pro Sitzung (git-Agent-Forwarding)

  # waypipe: Anzeige-Client fuer GUI-VMs (Wayland-Weiterleitung Host<-VM, Stufe 3).
  # (vim/git stehen host-uebergreifend in modules/desktop.nix.)
  environment.systemPackages = with pkgs; [
    virt-viewer pciutils usbutils waypipe
    zed-launch                             # Host-Wrapper: VM on-demand starten -> warten -> Zed
    # Desktop-Icon: Klick -> faehrt die dev-VM bei Bedarf hoch und zeigt Zed via waypipe.
    # Ruft den zed-launch-Wrapper (oben): VM starten falls gestoppt, auf SSH warten, dann
    # 'waypipe ssh -A dev@<ip> zed-dev'. 'ssh -A' reicht den Host-SSH-Agent in die VM -> git
    # push/clone in Zed OHNE Key in der VM. Voraussetzung: ssh-add, sonst fragt ksshaskpass grafisch.
    (makeDesktopItem {
      name = "zed-dev-vm";
      desktopName = "Zed (dev-VM)";
      comment = "dev-VM bei Bedarf starten und Zed via waypipe anzeigen";
      exec = "zed-dev-vm-launch";
      icon = "${zed-icon}/zed.png";        # echtes Zed-Logo (oben aus dem Paket extrahiert)
      categories = [ "Development" "TextEditor" ];
      terminal = false;
    })
  ];

  # Bequemer & sicherer Zugang zur dev-VM:
  #  - AddKeysToAgent: Key beim ersten Connect in den laufenden ssh-agent laden -> Passphrase nur
  #    1x pro Login statt bei jedem ssh. Gilt global (steht vor jedem Host-Block). Voraussetzung
  #    fuers Agent-Forwarding: ohne Key im Agent gibt es nichts weiterzureichen.
  #  - ForwardAgent: Host-SSH-Agent in die VM -> git in Zed nutzt den Host-Key (keiner in der VM).
  #  - accept-new: kein "yes" nach jedem Redeploy (frischer Host-Key; deploy-dev-vm.sh entfernt den
  #    alten via ssh-keygen -R, sodass der neue als 'new' akzeptiert wird).
  programs.ssh.extraConfig = ''
    AddKeysToAgent yes

    Host ${vmIp}
      ForwardAgent yes
      StrictHostKeyChecking accept-new
  '';
}
