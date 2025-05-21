FROM itdoginfo/openwrt-sdk:24.10.1

COPY ./podkop /builder/package/feeds/utilites/podkop
COPY ./luci-app-podkop /builder/package/feeds/luci/luci-app-podkop

RUN make defconfig && make package/podkop/compile && make package/luci-app-podkop/compile V=s -j4