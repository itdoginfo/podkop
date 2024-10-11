FROM openwrt/sdk:x86_64-v23.05.5

RUN mkdir -p /builder/package/feeds/utilites/

COPY ./podkop /builder/package/feeds/utilites/podkop

RUN make defconfig && make package/podkop/compile V=s -j4