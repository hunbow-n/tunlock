"""Creates a real utun interface for tests/pf-live.sh (CI only, needs root).

Prints the interface name, then keeps it alive for N seconds. Nothing reads
from it, so traffic into it goes nowhere: enough for the guard to see a TUN
interface appear and disappear.
"""
import fcntl
import socket
import struct
import sys
import time

CTLIOCGINFO = 0xC0644E03
UTUN_OPT_IFNAME = 2

s = socket.socket(socket.PF_SYSTEM, socket.SOCK_DGRAM, socket.SYSPROTO_CONTROL)
info = fcntl.ioctl(s, CTLIOCGINFO, struct.pack("I96s", 0, b"com.apple.net.utun_control"))
ctl_id = struct.unpack("I96s", info)[0]
s.connect((ctl_id, 0))  # unit 0: the kernel picks the next free utunN
name = s.getsockopt(socket.SYSPROTO_CONTROL, UTUN_OPT_IFNAME, 32).rstrip(b"\0").decode()
print(name, flush=True)
time.sleep(int(sys.argv[1]) if len(sys.argv) > 1 else 60)
