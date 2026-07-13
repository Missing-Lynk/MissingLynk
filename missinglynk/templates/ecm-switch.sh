# @NAME@ component: re-present the USB gadget as CDC-ECM. RNDIS has no Android host
# driver; CDC-ECM binds natively (cdc_ether). Runs after the stock body brought up the
# RNDIS gadget: swap config function f1 rndis->ecm, move @GOGGLE_IP@ onto the ecm netdev,
# tear down the old rndis netdev so the address is not dual-homed. A BACK-held boot has
# @NAME@=off, so the gadget stays stock RNDIS (recovery path).
if [ "$@NAME@" = on ]; then
    udc=$(ls /sys/class/udc 2>/dev/null | head -1)
    echo "" > @GADGET@/UDC 2>/dev/null
    sleep 1

    rm -f @GADGET@/configs/b.1/f1
    mkdir -p @GADGET@/functions/ecm.usb0
    echo @ECM_DEV_ADDR@ > @GADGET@/functions/ecm.usb0/dev_addr 2>/dev/null
    echo @ECM_HOST_ADDR@ > @GADGET@/functions/ecm.usb0/host_addr 2>/dev/null
    ln -sf @GADGET@/functions/ecm.usb0 @GADGET@/configs/b.1/f1
    echo "$udc" > @GADGET@/UDC 2>/dev/null
    sleep 2

    ecmif=$(cat @GADGET@/functions/ecm.usb0/ifname 2>/dev/null)
    rndisif=$(cat @GADGET@/functions/rndis.usb0/ifname 2>/dev/null)
    [ -n "$rndisif" ] && { ifconfig "$rndisif" 0.0.0.0 2>/dev/null; ifconfig "$rndisif" down 2>/dev/null; }
    [ -n "$ecmif" ] && ifconfig "$ecmif" @GOGGLE_IP@ netmask @GOGGLE_MASK@ up 2>/dev/null
    echo "boot: gadget switched to ECM (ifname=$ecmif)" >> "$ML/lastboot.log"
fi
