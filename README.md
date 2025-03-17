# Вещи, которые вам нужно знать перед установкой

- Это альфа версия, которая находится в активной разработке. Из версии в версию что-то может меняться.
- Основной функционал работает, но побочные штуки сейчас могут сбоить.
- При обновлении **обязательно** сбрасывайте кэш LuCI.
- Также при обновлении всегда заходите в конфигурацию и проверяйте свои настройки. Конфигурация может измениться.
- Необходимо минимум 15МБ свободного места на роутере. Роутерами с флешками на 16МБ сразу мимо.
- При старте программы редактируется конфиг Dnsmasq.
- Podkop редактирует конфиг sing-box. Обязательно сохраните ваш конфиг sing-box перед установкой, если он вам нужен.
- Информация здесь может быть устаревшей. Все изменения фиксируются в телеграм-чате https://t.me/itdogchat - топик **Podkop**.
- Если у вас не что-то не работает, то следуюет сходить в телеграм чат, прочитать закрепы и выполнить что там написано..
- Если у вас установлен Getdomains, его следует удалить.

# Удаление GetDomains скриптом
```
sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/domain-routing-openwrt/refs/heads/master/getdomains-uninstall.sh)
```

Оставляет туннели, зоны, forwarding. А также stubby и dnscrypt. Они не помешают. Конфиг sing-box будет перезаписан в podkop.

# Установка Podkop
Пакет работает на всех архитектурах.
Тестировался на **ванильной** OpenWrt 23.05 и OpenWrt 24.10.
На FriendlyWrt 23.05 присуствуют зависимости от iptables, которые ломают tproxy. Если у вас появляется warning про это в логах, следуйте инструкции по приведённой там ссылке.

Поддержки APK на данный момент нет. APK будет сделан после того как разгребу основное.

## Автоматическая
```
sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)
```

Скрипт также предложит выбрать, какой туннель будет использоваться. Для выбранного туннеля будут установлены нужные пакеты, а для Wireguard и AmneziaWG также будет предложена автоматическая настройка - прямо в консоли скрипт запросит данные конфига. Для AmneziaWG можно также выбрать вариант с использованием конфига обычного Wireguard и автоматической обфускацией до AmneziaWG.

Для AmneziaWG скрипт проверяет наличие пакетов под вашу платформу в [стороннем репозитории](https://github.com/Slava-Shchipunov/awg-openwrt/releases), так как в официальном репозитории OpenWRT они отсутствуют, и автоматически их устанавливает.

## Вручную
Сделать `opkg update`, чтоб установились зависимости.
Скачать пакеты `podkop_*.ipk` и `luci-app-podkop_*.ipk` из релиза. `opkg install` сначала первый, потом второй.

# Обновление
Та же самая команда, что для установки. Скрипт обнаружит уже установленный podkop и предложит обновиться.
```
sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)
```

# Удаление
```
opkg remove luci-i18n-podkop-ru luci-app-podkop podkop
```

# Использование
Конфиг: /etc/config/podkop

Luci: Services/podkop

## Режимы

### Proxy
Для VLESS и Shadowsocks. Другие протоколы тоже будут, кидайте в чат примеры строк без чувствительных данных.

В этом режиме просто копируйте строку в **Proxy String** и из неё автоматически настроится sing-box.

### VPN
Здесь у вас должен быть уже настроен WG/OpenVPN/OpenConnect etc, зона Zone и Forwarding не обязательны.

Просто выбрать интерфейс из списка.

## Настройка доменов и подсетей
**Community Lists** - Включить списки комьюнити

**Custom domains enable** - Добавить свои домены

**Custom subnets enable** - Добавить подсети или IP-адреса. Для подсетей задать маску.

# Известные баги
- [x] Не отрабатывает service podkop stop, если podkop запущен и не может, к пример, зарезолвить домен с сломанным DNS
- [x] Update list из remote url domain не удаляет старые домены. А добавляет новые. Для подсетей тоже самое скорее всего. Пересоздавать ruleset?

# ToDo
Этот раздел не означает задачи, которые нужно брать и делать. Это общий список хотелок. Если вы хотите помочь, пожалуйста, спросите сначала в телеграмме.

- [ ] Сделать галку запрещающую подкопу редачить dhcp. Допилить в исключение вместе с пустыми полями proxy и vpn (нужно wiki)
- [ ] Рестарт сервиса без рестарта dnsmasq
- [ ] `ash: can't kill pid 9848: No such process` при обновлении

Низкий приоритет
- [ ] Галочка, которая режет доступ к doh серверам
- [ ] IPv6. Только после наполнения Wiki

Рефактор
- [ ] Handle для sing-box
- [ ] Handle для dnsmasq
- [ ] Unit тесты (BATS)
- [ ] Интеграционые тесты бекенда (OpenWrt rootfs + BATS)

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

## Примеры строк
https://github.com/itdoginfo/podkop/blob/main/String-example.md

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
