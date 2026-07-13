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

# Goggle access defaults (override via env or CLI flags).
GOGGLE_IP: str = "192.168.3.100"
GOGGLE_USER: str = "root"
GOGGLE_PASS: str = "artosyn"
