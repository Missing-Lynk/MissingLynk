"""
missinglynk: tools for the BetaFPV VR04 / Artosyn ArtLynk FPV goggle.

Cross-platform (Windows/macOS/Linux):
- framebuffer capture     (missinglynk screenshot)
- component framework     (missinglynk install / enable / disable / status / uninstall)
  with components: rtsp (RTSP server), menu (open libre-menu UI),
  indicator (on-screen HUD), dhcp (USB DHCP server), ecm (CDC-ECM gadget).

All device access goes over the goggle's USB-ethernet gadget via SSH (paramiko).
"""

__version__: str = "0.1.0"

# Device access. A connected unit is reached at one of two kinds of address, by slot:
#   - a stock / unflashed unit is always STOCK_IP, root / STOCK_PASS (the vendor Dropbear)
#   - a flashed unit runs the open stack (root / GOGGLE_PASS) at its own per-device address on the
#     shared subnet: index NN -> 192.168.3.(100+NN), so open devices start at .101 (goggle), .102
#     (air), and up.
# With no --ip the CLI auto-detects the connected unit: it probes STOCK_IP first (most commands
# act on the stock slot), then the open addresses .101 and up, and targets the first that answers.
# Override either with --ip / --password.
STOCK_IP: str = "192.168.3.100"
STOCK_PASS: str = "artosyn"
GOGGLE_IP: str = "192.168.3.101"   # first open-slot address (device index 1); the class default
GOGGLE_USER: str = "root"
GOGGLE_PASS: str = "libre"         # open-slot password (every flashed device)
