# modules/browser-vm-net.nix
# ─────────────────────────────────────────────────────────────────────────────
# DIE eine Quelle der browser-VM-Adressierung (geteilt, host-unabhaengig) —
# gleiches Muster wie modules/dev-vm-net.nix, eigenes Netz.
#
# Warum ein EIGENES Netz statt dev-vm-net mitzubenutzen: die browser-VM ist vom
# Host-LAN isoliert (nftables auf der Bridge — modules/vm-net-isolation.nix,
# umgesetzt 2026-07-21). Mit eigener Bridge (virbr-browser) treffen diese Regeln
# NUR die browser-VM; die dev-VM hat auf ihrer Bridge eine eigene, mildere Policy.
#
# Schema 192.168.244.0/24 bewusst gewaehlt: kollidiert weder mit dem Heimnetz
# typischen Heimnetzen noch mit privaten Cluster-Netzen, dem libvirt-Default
# (192.168.122.0/24) noch dem dev-VM-Netz (192.168.243.0/24). Die .1 ist immer
# die Host-Bridge (NAT-Gateway), die browser-VM bekommt die .2.
#
# Namespace unter host.* — konsistent mit modules/dev-vm-net.nix (host.devVm.*).
{ lib, ... }:
{
  options.host.browserVm = {
    netPrefix = lib.mkOption {
      type = lib.types.str;
      default = "192.168.244";
      description = ''
        Erste drei Oktette des host-lokalen, NAT-isolierten browser-VM-Netzes.
        Das Netz selbst (inkl. DHCP-Reservierung) legt deploy-browser-vm.sh an.
      '';
    };
    ip = lib.mkOption {
      type = lib.types.str;
      default = "192.168.244.2";
      description = ''
        Feste browser-VM-IP, per DHCP-Reservierung an host.browserVm.mac gebunden.
        Von der ssh-Config referenziert (Bauphasen-Debug). Die .1 ist die
        Host-Bridge (Gateway), daher startet die VM-Vergabe bei .2.
      '';
    };
    mac = lib.mkOption {
      type = lib.types.str;
      default = "52:54:00:de:b0:02";
      description = ''
        Feste browser-VM-MAC — Anker fuer die DHCP-Reservierung im browser-VM-Netz.
        deploy-browser-vm.sh schreibt sie in die browser-vm.xml UND ins Netz-XML.
        (:01 gehoert der dev-VM.)
      '';
    };
    bridge = lib.mkOption {
      type = lib.types.str;
      default = "virbr-browser";
      description = ''
        Name der Host-Bridge des browser-VM-Netzes (legt deploy-browser-vm.sh an;
        dort gespiegelt als BRIDGE_NAME — gleiche Kopplung wie netPrefix/ip/mac).
        Referenziert von modules/vm-net-isolation.nix als nftables-Anker: die
        Zero-Trust-Regeln (nur Internet-Egress) greifen NUR auf dieser Bridge.
      '';
    };
  };

  # Bewusst KEIN config-Block: dieses Modul stellt nur die Konstanten bereit.
  # Die Verdrahtung (ssh-Config, Netz) passiert in modules/browser-vm-host.nix
  # bzw. in deploy-browser-vm.sh.
}
