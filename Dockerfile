FROM openwrt/sdk:x86_64-v23.05.5

RUN ./scripts/feeds update -a && ./scripts/feeds install luci-base && mkdir -p /builder/package/feeds/utilites/ && mkdir -p /builder/package/feeds/luci/

COPY ./podkop /builder/package/feeds/utilites/podkop
COPY ./luci-app-podkop /builder/package/feeds/luci/luci-app-podkop

RUN make defconfig && make package/podkop/compile && make package/luci-app-podkop/compile V=s -j4