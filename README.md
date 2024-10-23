Это альфа версия, может не работать. Обсуждение https://t.me/itdogchat - топик Podkop dev

# Выпил getdomains
По минимуму
```
rm /etc/hotplug.d/iface/30-vpnroute
sed -i '/getdomains start/d' /etc/crontabs/root
rm /tmp/dnsmasq.d/domains.lst
service getdomains disable
rm /etc/init.d/getdomains
ip route del default scope link table vpn
```

Может потребоваться удалить правила фаервола касающиеся vpn_subnet, internal итд.

# Установка
Пакет работает на всех архитектурах.
Будет точно работать только на OpenWrt 23.05.

Нужен dnsmasq-full. В автоматическом режиме ставится сам. Вручную надо поставить [самостоятельно](https://github.com/itdoginfo/podkop/blob/952dd6215a2a83d65937cf9e33534c42809091ed/install.sh#L20).

## Вручную
Сделать `opkg update`, чтоб установились зависимости.
Скачать пакеты `podkop_*.ipk` и `luci-app-podkop_*.ipk` из релиза. `opkg install` сначала первый, потом второй.

```
/etc/init.d/ucitrack restart
```

## Автоматическая
```
sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)
```

# Удаление
```
opkg remove luci-app-podkop podkop
```

# Использование
Конфиг: /etc/config/podkop

Luci: Services/podkop

## Режимы

### Proxy
Для VLESS и Shadowsocks. Другие протоколы тоже будут, кидайте в чат примеры строк без чувствительных данных.
Для использования этого режима нужен sing-box:
```
opkg update && opkg install sing-box
```

В этом режиме просто копируйте строку в **Proxy String** и из неё автоматически настроится sing-box.

### VPN
Здесь у вас должен быть уже настроен WG/OpenVPN/OpenConnect etc, создана Zone и Forwarding.

Просто выбрать интерфейс из списка.

## Настройка доменов и подсетей
**Domain list enable** - Включить общий список.

**Delist domains from main list enable** - Выключение заданных доменов из общего списка. Задавать списком.

**Subnets list enable** - Включить подсети из общего списка, выбрать из предложенных.

**Custom domains enable** - Добавить свои домены. Задавать списком.

**Custom subnets enable** - Добавить подсети или IP-адреса. Для подсетей задать маску.

# Известные баги
1. Не работает proxy при режимах main vpn, second proxy
2. Не всегда отрабатывает ucitrack (применение настроек из luci)

# ToDo
- [x] Скрипт для автоматической установки.
- [x] Подсети дискорда.
- [ ] Удаление getdomains через скрипт. Кроме туннеля и sing-box.
- [х] Дополнительная вкладка для ещё одного туннеля. Домены, подсети.
- [ ] Зависимость от dnsmasq-full
- [ ] Wiki
- [ ] IPv6
- [ ] Весь трафик для устойства пускать в туннель\прокси
- [ ] Исключение для IP, не ходить в туннель\прокси совсем 0x0
- [ ] Придумать автонастройку DNS через stubby итд. Как лучше это реализовать.
- [ ] Кнопка обновления списка доменов и подсетей
- [ ] Unit тесты (BATS)
- [ ] Интеграционые тесты бекенда (OpenWrt rootfs + BATS)
- [ ] Добавить label от конфига vless\ss\etc в luci. Хз как
- [ ] Удаление подсетей CF из domain sets раз в N часов
- [ ] Врубать галочкой yacd в sing-box
- [ ] Свои списки. Вопрос форматирования
- [ ] В скрипт автоустановки добавить установку AWG по примеру getdomains
- [ ] Галочка, которая режет доступ к doh серверам
- [ ] Рефактор dnsmasq restart
- [ ] Открытый прокси порт на роутере для браузеров

# Разработка
Есть два варианта:
- Просто поставить пакет на роутер или виртуалку и прям редактировать через SFTP (opkg install openssh-sftp-server)
- SDK, чтоб собирать пакеты

Для сборки пакетов нужен SDK, один из вариантов скачать прям файл и разархивировать
https://downloads.openwrt.org/releases/23.05.5/targets/x86/64/
Нужен файл с SDK в имени

```
wget https://downloads.openwrt.org/releases/23.05.5/targets/x86/64/openwrt-sdk-23.05.5-x86-64_gcc-12.3.0_musl.Linux-x86_64.tar.xz
tar xf openwrt-sdk-23.05.5-x86-64_gcc-12.3.0_musl.Linux-x86_64.tar.xz
mv openwrt-sdk-23.05.5-x86-64_gcc-12.3.0_musl.Linux-x86_64 SDK
```
Последнее для удобства.

Создаём директорию для пакета
```
mkdir package/utilites
```

Симлинк из репозитория
```
ln -s ~/podkop/podkop package/utilites/podkop
ln -s ~/podkop/luci-app-podkop package/luci-app-podkop
```

В первый раз для сборки luci-app необходимо обновить пакеты
```
./scripts/feeds update -a
```

Для make можно добавить флаг -j N, где N - количество ядер для сборки. Первый раз пройдёт быстрее.

При первом make выводится менюшка, можно просто save, exit и всё. Первый раз долго грузит зависимости.

Сборка пакета. Сами пакеты собираются быстро.
```
make package/podkop/{clean,compile} V=s
```

Также для luci
```
make package/luci-app-podkop/{clean,compile} V=s
```

.ipk лежат в `bin/packages/x86_64/base/`

## Ошибки
```
Makefile:17: /SDK/feeds/luci/luci.mk: No such file or directory
make[2]: *** No rule to make target '/SDK/feeds/luci/luci.mk'.  Stop.
time: package/luci/luci-app-podkop/clean#0.00#0.00#0.00
    ERROR: package/luci/luci-app-podkop failed to build.
make[1]: *** [package/Makefile:129: package/luci/luci-app-podkop/clean] Error 1
make[1]: Leaving directory '/SDK'
make: *** [/SDK/include/toplevel.mk:226: package/luci-app-podkop/clean] Error 2
```

Не загружены пакеты для luci

## make зависимости
https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem

Ubuntu
```
sudo apt update
sudo apt install build-essential clang flex bison g++ gawk \
gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
python3-distutils rsync unzip zlib1g-dev file wget
```