# modules/dev-vm-net.nix
# ─────────────────────────────────────────────────────────────────────────────
# DIE eine Quelle der dev-VM-Adressierung (geteilt, host-unabhaengig).
#
# Frueher lag die IP "192.168.122.234" verstreut in der Host-Config (ssh-Config +
# BEIDE Desktop-Icons), die MAC zusaetzlich im deploy-Skript. Das war fragil: die
# feste MAC allein garantiert KEINE feste IP — libvirts dnsmasq vergibt aus dem
# Range, nicht deterministisch. Auf einer zweiten Maschine bekaeme die
# VM evtl. eine andere Adresse, und Icons/ssh-Config zeigten ins Leere.
#
# Jetzt: EIN Satz Konstanten, den alle Nix-Stellen referenzieren (Icons, ssh-Config)
# und aus dem deploy-dev-vm.sh das eigene libvirt-Netz MIT DHCP-Reservierung baut
# (MAC -> feste IP). Damit ist die Adresse deterministisch und auf allen Hosts
# identisch (beides host-lokale, NAT-isolierte Netze — sie sehen sich nie, gleiche
# IP ist gewollt).
#
# Schema 192.168.243.0/24 bewusst gewaehlt: kollidiert weder mit dem Heimnetz
# typischen Heimnetzen noch mit privaten Cluster-Netzen noch mit libvirts
# Default-Netz (192.168.122.0/24). Die .1 ist immer die Host-Bridge (NAT-Gateway),
# die dev-VM bekommt die .2.
#
# Namespace unter host.* — konsistent mit modules/vfio.nix (host.passthroughIds).
{ lib, ... }:
{
  options.host.devVm = {
    netPrefix = lib.mkOption {
      type = lib.types.str;
      default = "192.168.243";
      description = ''
        Erste drei Oktette des host-lokalen, NAT-isolierten dev-VM-Netzes.
        Das Netz selbst (inkl. DHCP-Reservierung) legt deploy-dev-vm.sh an.
      '';
    };
    ip = lib.mkOption {
      type = lib.types.str;
      default = "192.168.243.2";
      description = ''
        Feste dev-VM-IP, per DHCP-Reservierung an host.devVm.mac gebunden.
        Von den Desktop-Icons und der ssh-Config referenziert. Die .1 ist die
        Host-Bridge (Gateway), daher startet die VM-Vergabe bei .2.
      '';
    };
    mac = lib.mkOption {
      type = lib.types.str;
      default = "52:54:00:de:b0:01";
      description = ''
        Feste dev-VM-MAC — Anker fuer die DHCP-Reservierung im dev-VM-Netz.
        deploy-dev-vm.sh schreibt sie in die dev-vm.xml UND ins Netz-XML.
      '';
    };
    bridge = lib.mkOption {
      type = lib.types.str;
      default = "virbr-dev";
      description = ''
        Name der Host-Bridge des dev-VM-Netzes (legt deploy-dev-vm.sh an; dort
        gespiegelt als BRIDGE_NAME — gleiche Kopplung wie netPrefix/ip/mac).
        Referenziert von modules/vm-net-isolation.nix als nftables-Anker:
        die Isolations-Regeln greifen per Interface-Match NUR auf dieser Bridge.
      '';
    };
  };

  # Bewusst KEIN config-Block: dieses Modul stellt nur die Konstanten bereit.
  # Die Verdrahtung (Icons, ssh-Config, Netz) passiert in modules/dev-vm-host.nix
  # bzw. in deploy-dev-vm.sh.
}
