#!/usr/bin/env python3
"""
Send a Wake-on-LAN magic packet to some or all Lab 312 machines.

Usage:
    python3 wake-lab.py                # wake all 24
    python3 wake-lab.py LAB312-03 LAB312-10   # wake specific ones

Sends a UDP magic packet as a directed broadcast to the Lab VLAN
(10.20.1.255, the broadcast address for the 10.20.0.0/23 subnet).
Whether this actually reaches the target machines depends on whether
the gateway forwards directed broadcasts onto that VLAN - normal
routed traffic (like Ansible/WinRM) working does NOT guarantee this
also works, since directed-broadcast forwarding is a separate,
commonly-disabled router setting. Test on one machine first.

If nothing wakes, the reliable fallback is the UniFi controller UI:
Clients -> select the machine -> ... menu -> Wake. That works
regardless, because the switch injects the packet at L2 using its own
knowledge of the port, rather than relying on broadcast forwarding.
"""
import socket
import sys

BROADCAST_ADDR = "10.20.1.255"
WOL_PORT = 9

# MAC addresses from docs/lab312-port-map.md
MACS = {
    "LAB312-01": "b0:4f:13:13:bf:bb",
    "LAB312-02": "b0:4f:13:0f:c4:59",
    "LAB312-03": "b0:4f:13:0f:c3:8c",
    "LAB312-04": "b0:4f:13:0f:cc:30",
    "LAB312-05": "b0:4f:13:15:39:d7",
    "LAB312-06": "b0:4f:13:14:ff:91",
    "LAB312-07": "b0:4f:13:0f:e7:c8",
    "LAB312-08": "b0:4f:13:15:39:c7",
    "LAB312-09": "b0:4f:13:15:00:e3",
    "LAB312-10": "b0:4f:13:10:2e:51",
    "LAB312-11": "b0:4f:13:0f:c3:32",
    "LAB312-12": "b0:4f:13:0f:c1:73",
    "LAB312-13": "b0:4f:13:0f:c9:dc",
    "LAB312-14": "00:0a:f7:93:cc:7a",
    "LAB312-15": "b0:4f:13:0f:cb:b9",
    "LAB312-16": "b0:4f:13:0f:ca:7a",
    "LAB312-17": "b0:4f:13:14:fc:4d",
    "LAB312-18": "b0:4f:13:10:33:d1",
    "LAB312-19": "b0:4f:13:15:38:e0",
    "LAB312-20": "b0:4f:13:0f:bb:c8",
    "LAB312-21": "b0:4f:13:0f:bb:c2",
    "LAB312-22": "00:0a:f7:69:6f:31",
    "LAB312-23": "b0:4f:13:15:37:27",
    "LAB312-24": "b0:4f:13:0f:c1:6c",
}


def send_magic_packet(mac: str, sock: socket.socket) -> None:
    mac_bytes = bytes.fromhex(mac.replace(":", "").replace("-", ""))
    packet = b"\xff" * 6 + mac_bytes * 16
    sock.sendto(packet, (BROADCAST_ADDR, WOL_PORT))


def main() -> None:
    targets = sys.argv[1:] or list(MACS.keys())
    unknown = [t for t in targets if t not in MACS]
    if unknown:
        print(f"Unknown host(s), skipping: {', '.join(unknown)}")
    targets = [t for t in targets if t in MACS]

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        for name in targets:
            send_magic_packet(MACS[name], sock)
            print(f"Sent magic packet to {name} ({MACS[name]})")
    finally:
        sock.close()

    print(
        "\nIf none of these actually wake, directed broadcast is probably "
        "being blocked - use the UniFi controller UI instead: Clients -> "
        "select the machine -> ... menu -> Wake."
    )


if __name__ == "__main__":
    main()
