# Design Spec: Don't use FAKE IP (sniff-based routing mode)

## Problem

FakeIP в подкопе ломает сценарии, где на клиенте параллельно работает
корпоративный VPN-клиент, который **не может быть установлен на роутер**
(пример: FortiClient на macOS — нет порта под OpenWrt и невозможен Mixed
mode, потому что VPN-клиент перехватывает DNS/маршруты до того, как трафик
дойдёт до роутера).

В такой ситуации FakeIP-схема обрывается на стороне клиента: VPN-клиент
переопределяет DNS и/или routing, программы на устройстве получают для
доменов из списков **реальные** IP-адреса вместо `198.18.x.x`, и nft на
роутере ничего не ловит — маршрутизация подкопа фактически не работает.

Текущая документация предлагает два workaround'а (Mixed mode и перенос VPN
на роутер), но оба бессильны, когда корпоративный VPN существует только в
форме клиента под конкретную ОС.

Успех = пользователь ставит чекбокс **«Don't use FAKE IP»** в Additional
Settings → подкоп переключается в режим, где `198.18.0.0/15` нигде не
появляется, маршрутизация по доменным спискам продолжает работать, и
корпоративный VPN-клиент перестаёт конфликтовать с подкопом.

## Solution Overview

- В UI Additional Settings добавляется один глобальный чекбокс
  `disable_fakeip` (по умолчанию `0` — текущее поведение сохраняется).
- В режиме `disable_fakeip=1` подкоп отказывается от FakeIP-DNS-сервера и
  переключается на **sniff-based routing**: весь TCP/UDP-трафик с LAN
  направляется в sing-box через tproxy, а sing-box определяет «proxy /
  vpn / direct» по SNI/Host из самого пакета (sniff уже включён на
  `tproxy-inbound` и `dns-inbound` в текущем коде).
- DNS на клиентах работает «как обычно»: подкоп резолвит реальные IP, не
  подменяет их.
- nft-обвязка `daddr 198.18.0.0/15 → mark` снимается; вместо неё ставится
  правило «весь трафик с интерфейсов из `NFT_INTERFACE_SET_NAME`, не
  попадающий в localv4 и не от самого подкопа, → mark + tproxy на
  `127.0.0.1:1602`».
- Frontend-диагностика `runFakeIPCheck.ts` в этом режиме отображает
  плашку **«FakeIP disabled — N/A»** вместо красного крестика.

## Scope

**In scope**
- Глобальный UCI-флаг `settings.disable_fakeip` (`0|1`, default `0`).
- Чекбокс «Don't use FAKE IP» в Additional Settings (рядом с `Disable
  QUIC`, `Exclude NTP`).
- Условный пропуск `sing_box_cm_add_fakeip_dns_server` и связанных DNS
  rule-патчей при включённом флаге.
- Альтернативная nft-обвязка для tproxy без 198.18.0.0/15.
- Условный пропуск патча `fakeip-dns-rule-tag` во всех handler'ах
  community/local/remote/user-list (на routing'е по доменам это не
  сказывается — там работает route-rule с `rule_set`).
- Frontend: в `runFakeIPCheck.ts` детектировать режим и показывать
  «N/A»-плашку.
- Документация в README о новом режиме и его ограничениях.

**Out of scope**
- Возврат старой (v0.2.5) схемы dnsmasq+nftset как альтернативного
  пайплайна. Это отдельная фича на потом, если sniff-режим окажется
  недостаточным.
- Per-section настройка (один глобальный тумблер достаточно — DNS и
  route-секции sing-box общие на установку).
- Полноценный диагностический чек на корректность sniff-routing'а.
- IPv6-специфика (текущий fakeip-pipeline по факту IPv4-only —
  `198.18.0.0/15`; sniff-режим автоматически наследует то же ограничение).
- Поддержка ECH (Encrypted Client Hello). Если у клиента включён ECH —
  sniff не достанет SNI и домен не смэтчится. Это известное ограничение
  всех sniff-based решений (и оно явно фиксируется в документации
  фичи).

## Architecture Sketch

```
Текущий путь (FakeIP, default):
   client → DNS query → sing-box DNS → fakeip-server → 198.18.x.y
   client → TCP SYN to 198.18.x.y → nft (daddr 198.18/15 → mark) → tproxy → sing-box
                                                                              → match by rule_set → outbound

Новый путь (disable_fakeip=1):
   client → DNS query → sing-box DNS → real DNS → real IP
   client → TCP SYN to <real IP> → nft (iif @interfaces, !localv4 → mark) → tproxy → sing-box
                                                                                       → sniff (SNI/Host)
                                                                                       → match by rule_set → outbound
```

**Поинты внедрения в код:**

| Слой       | Файл                                            | Что меняется                                                                                         |
|------------|-------------------------------------------------|------------------------------------------------------------------------------------------------------|
| UCI schema | `podkop/files/etc/config/podkop`                | новая опция `disable_fakeip '0'` в `config settings 'settings'`                                      |
| LuCI UI    | `luci-app-podkop/.../view/podkop/settings.js`   | новый `form.Flag` `disable_fakeip` рядом с `disable_quic`/`exclude_ntp`                              |
| Backend    | `podkop/files/usr/bin/podkop` `sing_box_configure_dns` | условный пропуск add_fakeip_dns_server и patch_dns_route_rule, если `disable_fakeip=1`               |
| Backend    | `podkop/files/usr/bin/podkop` `configure_*_handler`    | условный пропуск патчей `fakeip-dns-rule-tag` под флагом                                             |
| Backend    | `podkop/files/usr/bin/podkop` `create_nft_rules`       | под флагом — другая ветка nft-правил (общий tproxy, без `198.18.0.0/15`)                            |
| Frontend   | `fe-app-podkop/src/podkop/tabs/diagnostic/checks/runFakeIPCheck.ts` | детект `disable_fakeip` через PodkopShellMethods (новый shell-call) и вывод «N/A»-state               |
| Locales    | `fe-app-podkop/locales/*.json`                  | новые ключи `FakeIP disabled`, `FakeIP is intentionally disabled in settings`                        |
| Docs       | `README.md` + новая страница в podkop.net (отдельный PR в docs)        | описать режим и его ограничения (ECH, оверхед на CPU, отсутствие точечной маршрутизации)             |

## Data Model

**UCI** (`/etc/config/podkop`, секция `settings`):
- `disable_fakeip` — boolean (`'0'`/`'1'`), default `'0'`. Глобальный.

**Sing-box config (производное состояние, не хранится в UCI):**
- При `disable_fakeip=0`: текущая структура без изменений.
- При `disable_fakeip=1`:
  - DNS-секция: только `bootstrap-server` + `dns-server`. Никаких
    `fakeip-server`, никаких rule'ов с `fakeip-dns-rule-tag`.
  - Route-секция: те же rule'ы с `rule_set`-матчингом, что и сейчас.
    Sniff на `tproxy-inbound`/`dns-inbound` уже стоит — это покрывает
    нужду нового режима.

**nft-set'ы:** без изменений (`localv4`, `common-set`, interface-set).
Меняется набор rule'ов в цепочках `mangle` / `mangle_output` /
`proxy`. Никаких новых set'ов не вводится.

**Frontend state (`runFakeIPCheck.ts`):**
- Новое поле в результате чекера: `mode: 'fakeip' | 'disabled'`.
- При `mode === 'disabled'` весь блок renders one informational item: title
  «FakeIP disabled», description «Disabled in Additional Settings».

## Screens / Flows (UI tasks)

**Screen: Additional Settings** (LuCI, `settings.js`)
- Новое поле `Don't use FAKE IP` (form.Flag) с описанием:
  «Disable FakeIP DNS resolution. Use sniff-based routing instead.
  Required for environments with corporate VPN clients that override DNS
  on the device (e.g., FortiClient on macOS). Note: domains with ECH
  enabled may not be matched.»
- Размещение: непосредственно после `Disable QUIC` или перед
  `Exclude NTP`.
- Default: unchecked.

**Screen: Diagnostic tab** (frontend)
- При `disable_fakeip=1` блок «FakeIP» в результатах диагностики
  отображается как одна нейтральная карточка с заголовком «FakeIP
  disabled» и подзаголовком «FakeIP is intentionally disabled in
  Additional Settings». Status icon — нейтральный (не зелёный, не
  красный).
- Никаких HTTP-запросов на `fakeip.podkop.fyi` в этом режиме не
  делается.

## Alternatives Considered

1. **Возрождение dnsmasq+nftset-схемы из v0.2.5** — точечная
   маршрутизация по реальным IP без оверхеда на CPU. Отклонено:
   ~400+ строк нового кода, требование `dnsmasq-full`, два разных
   набора nft-правил, дублирование пайплайна. Значимо больше работы при
   небольшом выигрыше для целевого юзкейса (роутеры пользователя — не
   слабое железо).
2. **Sniff-only без переделки nft (только пропуск fakeip-DNS)** —
   отклонено: текущие nft-правила матчат именно `198.18.0.0/15`, без
   этого диапазона ни один пакет не попадёт в sing-box. Работать не будет.
3. **Per-section toggle** — отклонено: DNS-сервер sing-box и
   tproxy-inbound — общие на всю установку, разделять fakeip по секциям
   архитектурно невозможно без полной переделки sing-box-конфига.
4. **Mixed mode / перенос VPN на роутер** (текущие рекомендации
   подкопа) — не решают проблему пользователя: FortiClient доступен
   только под macOS-клиентом, на роутер его не поставить, а Mixed
   mode не работает, потому что FortiClient перехватывает трафик до
   попадания на роутер.

## Open Questions

- **Backward-compat fakeip-mark в nft.** Сейчас имя константы
  `NFT_FAKEIP_MARK` используется в нескольких местах (`mangle_output`,
  `proxy` цепочка, ip rule, route table). В новом режиме сама марка
  концептуально становится «proxy mark», но переименовывать её — лишний
  диф; решение: оставить имя, использовать ту же марку. Подтвердить при
  планировании.
- **`exclude_ntp`** под новым режимом сейчас вставляет правило в начало
  цепочки `mangle` и работает как «return» по dport 123. Скорее всего
  продолжит работать без изменений, но проверить при импле.
- **`all_traffic_from_ip_enabled`, `routing_excluded_ips`,
  `fully_routed_ips`** — часть логики таки используют `NFT_COMMON_SET_NAME`
  (`include_source_ips_in_routing_handler` и пр.). Поведение при
  `disable_fakeip=1` нужно явно прогнать в плане:
  - в режиме без fakeip эти источниковые IP-маршруты должны попадать
    под общую sniff-tproxy-цепочку (и так и так трафик попадёт в
    sing-box и матчится по rule_set + sniff).
- **Discord-«fix» (rule с диапазоном UDP `50000-65535`, использует
  `NFT_FAKEIP_MARK`)** — нужно решить: оставлять как есть (марка
  «proxy mark» работает одинаково) или вырезать в новом режиме, потому
  что в sniff-режиме UDP/QUIC всё равно идёт через sing-box.
- **CHECK_PROXY_IP_DOMAIN / FAKEIP_TEST_DOMAIN.** В DNS-секции есть
  патч `service_domains` к `fakeip-dns-rule-tag`. В новом режиме этих
  доменов в fakeip нет — нужно либо отключить связанные функции
  (`runFakeIPCheck`, override domain port на 8443), либо переписать
  на тестирование через sniff. На стартовой итерации — отключить.

## Next Step

Hand this spec to `writing-plans` skill to produce a task-level plan.
Implementing agent: shell/OpenWrt backend (для `podkop` и UCI), LuCI
frontend (для `settings.js`), TypeScript/React (для
`runFakeIPCheck.ts` и локалей).
