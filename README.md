# Podkop Evolution

> **Podkop's fork with HWID and Subscription URL support**
>
> Этот форк добавляет поддержку ссылок подписки (subscription URL) с кастомными заголовками (HWID, Device-OS, Device-Model) и автоматическим обновлением. Основан на [itdoginfo/podkop](https://github.com/itdoginfo/podkop).

---

# Вещи, которые вам нужно знать перед установкой

- Это бета-версия, которая находится в активной разработке. Из версии в версию что-то может меняться.
- При возникновении проблем, нужен технически грамотный фидбэк в чат. Ознакомьтесь с закрепом в топике.
- При обновлении **обязательно** [сбрасывайте кэш LuCI](https://podkop.net/docs/clear-browser-cache/).
- Также при обновлении всегда заходите в конфигурацию и проверяйте свои настройки. Конфигурация может измениться.
- Необходимо минимум 25МБ свободного места на роутере. Роутеры с флешками на 16МБ сразу мимо.
- При старте программы редактируется конфиг Dnsmasq.
- Podkop редактирует конфиг sing-box. Обязательно сохраните ваш конфиг sing-box перед установкой, если он вам нужен.
- Информация здесь может быть устаревшей. Все изменения фиксируются в [телеграм-чате](https://t.me/itdogchat/81758/420321).
- [Если у вас что-то не работает.](https://podkop.net/docs/diagnostics/)
- Если у вас установлен Getdomains, [его следует удалить](https://github.com/itdoginfo/domain-routing-openwrt?tab=readme-ov-file#%D1%81%D0%BA%D1%80%D0%B8%D0%BF%D1%82-%D0%B4%D0%BB%D1%8F-%D1%83%D0%B4%D0%B0%D0%BB%D0%B5%D0%BD%D0%B8%D1%8F).
- Требуется версия OpenWrt 24.10.
- Dashboard доступен, если вы заходите по http (из-за особенностей clash api). И не будет работать, если вы заходите по https и/или домену.

# Документация
https://podkop.net/

# Установка Podkop Evolution
Полная информация в [документации](https://podkop.net/docs/install/)

Вкратце, достаточно одного скрипта для установки и обновления:
```
sh <(wget -O - https://raw.githubusercontent.com/yandexru45/podkop-evolution/refs/heads/main/install.sh)
```

## Новое в этом форке: Подписки (Subscription)

Добавлена поддержка subscription URL — ссылки подписки от провайдера прокси. При выборе типа конфигурации **Subscription** в LuCI:

- Введите URL подписки от вашего провайдера
- Выберите интервал автообновления (от 30 минут до 1 дня)
- Все серверы из подписки автоматически появятся в дашборде
- Автоматический выбор лучшего сервера по задержке (URLTest)
- Ручное переключение между серверами через дашборд

При скачивании подписки отправляются заголовки:
- `User-Agent: singbox/<версия>`
- `X-HWID` — уникальный идентификатор роутера
- `X-Device-OS: OpenWrt Linux`
- `X-Device-Model` — модель роутера
- `X-Ver-OS` — версия ядра

Пример конфигурации через UCI:
```
uci set podkop.my_sub=section
uci set podkop.my_sub.connection_type='proxy'
uci set podkop.my_sub.proxy_config_type='subscription'
uci set podkop.my_sub.subscription_url='https://your-provider.com/api/sub'
uci set podkop.my_sub.subscription_update_interval='1h'
uci add_list podkop.my_sub.community_lists='russia_inside'
uci commit podkop
```

Ручное обновление подписки:
```
/usr/bin/podkop subscription_update
```

## Изменения 0.7.0
Начиная с версии 0.7.0 изменена структура конфига `/etc/config/podkop`. Старые значения несовместимы с новыми. Нужно заново настроить Podkop.

Скрипт установки обнаружит старую версию и предупредит вас об этом. Если вы согласитесь, то он сделает автоматически написанное ниже.

При обновлении вручную нужно:

0. Не ныть в issue и чатик.
1. Забэкапить старый конфиг:
```
mv /etc/config/podkop /etc/config/podkop-070
```
2. Стянуть новый дефолтный конфиг:
```
wget -O /etc/config/podkop https://raw.githubusercontent.com/yandexru45/podkop-evolution/refs/heads/main/podkop/files/etc/config/podkop
```
3. Настроить заново ваш Podkop через Luci или UCI.

# ToDo

> [!IMPORTANT]  
> PR принимаются только по согласованию с авторами в ТГ-чате. Остальные PR на данный момент не рассматриваются. Не тратьте зря своё время.

## Будущее
- [x] [Подписка](https://github.com/itdoginfo/podkop/issues/118) — **реализовано в этом форке!**
- [ ] Весь трафик в sing-box и маршрутизация полностью на его уровне.
- [ ] При успешном запуске переходит в фоновый режим и следит за состоянием sing-box. Если вдруг идёт exit 1, выполняется dnsmasq restore и снова следит за состоянием. [Issue](https://github.com/itdoginfo/podkop/issues/111)
- [ ] Галочка, которая режет доступ к doh серверам.
- [ ] IPv6. Только после наполнения Wiki.

## Тесты
- [ ] Unit тесты (BATS)
- [ ] Интеграционные тесты бекенда (OpenWrt rootfs + BATS)