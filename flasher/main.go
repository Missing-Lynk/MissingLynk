// Command ml-flasher flashes the MissingLynk open firmware onto a stock BetaFPV
// VR04 goggle over its USB gadget link. It is a GUI tool with no command line:
// launch it, it finds the device, you pick an image, it flashes. (For scripted /
// terminal workflows, use the missinglynk CLI and the glue/ scripts instead.)
package main

import "github.com/Missing-Lynk/MissingLynk/flasher/internal/gui"

func main() {
	gui.Run()
}
