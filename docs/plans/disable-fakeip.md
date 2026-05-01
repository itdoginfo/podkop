# Implementation Plan: Don't use FAKE IP

## Description
Глобальный чекбокс **«Don't use FAKE IP»** в Additional Settings (LuCI),
переключающий подкоп в режим sniff-based routing (без FakeIP-DNS-сервера и
без диапазона `198.18.0.0/15` в nft-цепочках). Цель — снять конфликт с
корпоративным VPN-клиентом FortiClient на macOS, который перехватывает
DNS/routing на устройстве и ломает FakeIP-схему.

Спецификация: `docs/design-specs/disable-fakeip.md`

Stack: shell (OpenWrt) + LuCI/JS (LuCI Form API) + TypeScript (frontend
diagnostic).

## Architecture

### Затрагиваемые слои

| Слой       | Файл                                                          | Что меняется                                                           |
|------------|---------------------------------------------------------------|------------------------------------------------------------------------|
| UCI schema | `podkop/files/etc/config/podkop`                              | новая опция `disable_fakeip '0'` в секции `settings`                   |
| LuCI UI    | `luci-app-podkop/htdocs/luci-static/resources/view/podkop/settings.js` | новый `form.Flag` `disable_fakeip`                                     |
| Backend    | `podkop/files/usr/bin/podkop`                                 | условные ветки в DNS/route/nft-конфигурации                            |
| Frontend   | `fe-app-podkop/src/podkop/tabs/diagnostic/checks/runFakeIPCheck.ts` | детект `disable_fakeip` и показ «N/A»-плашки                           |
| Frontend   | `fe-app-podkop/src/podkop/methods/custom/getDisableFakeip.ts` (новый) | helper-метод, читающий UCI-флаг                                        |
| Locales    | `fe-app-podkop/locales/calls.json`                            | новые ключи (генерируются автоматически после `extract-calls.js`)      |
| Docs       | `README.md`                                                   | секция о новом режиме и его ограничениях                               |

### UCI Schema

Файл: `podkop/files/etc/config/podkop`

В секции `config settings 'settings'` добавить строку (рядом с `exclude_ntp`):

```
option disable_fakeip '0'
```

### Backend: бинарник `podkop` (`/usr/bin/podkop`)

**Точки изменений (4 функции):**

1. **`sing_box_configure_dns()`** (строки ~764–793).
   - Прочитать флаг: `config_get_bool disable_fakeip "settings" "disable_fakeip" 0`.
   - Обернуть условием: `if [ "$disable_fakeip" -eq 0 ]; then ... fi` следующие вызовы:
     - `sing_box_cm_add_fakeip_dns_server`
     - `sing_box_cm_add_dns_route_rule "$SB_FAKEIP_DNS_SERVER_TAG" "$SB_FAKEIP_DNS_RULE_TAG"`
     - `sing_box_cm_patch_dns_route_rule "$SB_FAKEIP_DNS_RULE_TAG" "rewrite_ttl" "$rewrite_ttl"`
     - `service_domains=...; sing_box_cm_patch_dns_route_rule "$SB_FAKEIP_DNS_RULE_TAG" "domain" "$service_domains"`

2. **`sing_box_configure_route()`** (строки ~795–838).
   - При `disable_fakeip=1` пропустить вызов `sing_box_cf_override_domain_port "$FAKEIP_TEST_DOMAIN" 8443` — без fakeip override-port на тестовом домене не нужен.

3. **`configure_community_list_handler()`, `prepare_source_ruleset()`,
   `configure_remote_domain_or_subnet_list_handler()`** (строки ~987–1150).
   - Все три места вызывают `sing_box_cm_patch_dns_route_rule "$SB_FAKEIP_DNS_RULE_TAG" "rule_set" "$ruleset_tag"`.
   - Этот вызов нужно дополнительно обернуть проверкой `disable_fakeip`:
     ```
     if [ "$disable_fakeip" -eq 0 ] && [ "$route_rule_tag" != "$SB_EXCLUSION_RULE_TAG" ]; then
         config=$(sing_box_cm_patch_dns_route_rule ...)
     fi
     ```
   - Прочитать `disable_fakeip` один раз в начале каждой функции (или в shared helper, см. п.5).

4. **`create_nft_rules()`** (строки ~282–335).
   - Прочитать флаг.
   - При `disable_fakeip=0`: оставить текущие правила без изменений.
   - При `disable_fakeip=1`: убрать правила про `$SB_FAKEIP_INET4_RANGE` и
     заменить ветку tproxy-маркировки. Целевая структура для нового режима:
     ```
     # mangle (prerouting)
     nft add rule inet $TBL mangle iifname @$IFSET ip daddr @$NFT_LOCALV4_SET_NAME return
     nft add rule inet $TBL mangle iifname @$IFSET ip daddr @$NFT_COMMON_SET_NAME meta l4proto tcp meta mark set $NFT_FAKEIP_MARK counter
     nft add rule inet $TBL mangle iifname @$IFSET ip daddr @$NFT_COMMON_SET_NAME meta l4proto udp meta mark set $NFT_FAKEIP_MARK counter
     nft add rule inet $TBL mangle iifname @$IFSET meta l4proto tcp meta mark set $NFT_FAKEIP_MARK counter
     nft add rule inet $TBL mangle iifname @$IFSET meta l4proto udp meta mark set $NFT_FAKEIP_MARK counter

     # mangle_output (output) — без правил для $SB_FAKEIP_INET4_RANGE
     nft add rule inet $TBL mangle_output ip daddr @$NFT_LOCALV4_SET_NAME return
     nft add rule inet $TBL mangle_output meta mark $NFT_OUTBOUND_MARK counter return
     nft add rule inet $TBL mangle_output ip daddr @$NFT_COMMON_SET_NAME meta l4proto tcp meta mark set $NFT_FAKEIP_MARK counter
     nft add rule inet $TBL mangle_output ip daddr @$NFT_COMMON_SET_NAME meta l4proto udp meta mark set $NFT_FAKEIP_MARK counter

     # proxy chain — без изменений; mark уже стоит, tproxy сработает
     ```
   - Имя константы `NFT_FAKEIP_MARK` оставить как есть (см. Open Question #1
     в спеке) — переименование не входит в scope, марка играет роль
     «proxy mark» в новом режиме.

5. **(опционально, мелкий рефакторинг)**: ввести функцию-getter
   `is_fakeip_disabled()` на верхнем уровне `podkop` бинарника, чтобы
   избежать дублирования `config_get_bool ...` в 4 местах. Нестрого
   обязательно; можно сделать после первой реализации.

### Backend: «Discord-fix» rule (если применим)

Файл: `podkop/files/usr/bin/podkop`, строка ~1319 — правило для UDP-диапазона
50000-65535 c использованием `$NFT_FAKEIP_MARK`. В новом режиме оно
безвредно (марка та же, но цепочка proxy продолжает tproxy'ить эту марку).
Никаких изменений не требуется. **Только проверить ручным тестированием**,
что в режиме `disable_fakeip=1` это правило не дублирует общую LAN-обвязку
из п.4 (если дублирует — добавить `if [ "$disable_fakeip" -eq 0 ]; then`).

### Backend: hotplug / runtime restart

Изменение `disable_fakeip` в UCI должно требовать перезапуска подкопа
(перегенерация sing-box-конфига и nft-правил). Уточнить во время
реализации, нужен ли явный `o.write` callback в `settings.js`, или достаточно
ручного «Save & Apply» → подкоп подхватит при следующем старте. По аналогии
с `disable_quic` (который тоже требует перезапуска) — ничего особенного
не нужно.

### LuCI UI

Файл: `luci-app-podkop/htdocs/luci-static/resources/view/podkop/settings.js`

Добавить после блока `disable_quic` (строки ~262–271):

```js
o = section.option(
  form.Flag,
  "disable_fakeip",
  _("Don't use FAKE IP"),
  _(
    "Disable FakeIP DNS resolution and use sniff-based routing. " +
    "Required for environments where a corporate VPN client " +
    "(e.g., FortiClient on macOS) overrides DNS on the device. " +
    "Note: domains with ECH (Encrypted Client Hello) enabled may not be matched.",
  ),
);
o.default = "0";
o.rmempty = false;
```

### Frontend: диагностика

#### Новый helper-метод

Файл: `fe-app-podkop/src/podkop/methods/custom/getDisableFakeip.ts` (создать).

```ts
import { getConfigSections } from './getConfigSections';

export async function getDisableFakeip(): Promise<boolean> {
  const sections = await getConfigSections();
  const settings = sections.find(s => s['.type'] === 'settings');
  return settings?.disable_fakeip === '1';
}
```

Зарегистрировать в `fe-app-podkop/src/podkop/methods/custom/index.ts`.

#### Изменение `runFakeIPCheck.ts`

Файл: `fe-app-podkop/src/podkop/tabs/diagnostic/checks/runFakeIPCheck.ts`

В начале функции, после `updateCheckStore({ ..., state: 'loading' })`,
добавить ранний выход:

```ts
const disabled = await CustomMethods.getDisableFakeip();
if (disabled) {
  updateCheckStore({
    order, code, title,
    description: _('FakeIP is intentionally disabled in Additional Settings'),
    state: 'info',
    items: [{
      state: 'info',
      key: _('FakeIP disabled'),
      value: '',
    }],
  });
  return;
}
// ... существующая логика
```

(Если в `IDiagnosticsChecksItem` нет state `'info'` — использовать
ближайший нейтральный, например `'warning'` с правильной формулировкой.
Уточнить при импле.)

### Локализация

Новые ключи (английские исходники, локализация генерится через
`extract-calls.js`):

- `Don't use FAKE IP`
- `Disable FakeIP DNS resolution and use sniff-based routing. Required for environments where a corporate VPN client (e.g., FortiClient on macOS) overrides DNS on the device. Note: domains with ECH (Encrypted Client Hello) enabled may not be matched.`
- `FakeIP disabled`
- `FakeIP is intentionally disabled in Additional Settings`

После реализации запустить `node fe-app-podkop/extract-calls.js` (если так
устроен пайплайн) — проверить во время импла.

### README

Добавить в `README.md` секцию (или подсекцию в Settings) о режиме
«Don't use FAKE IP» с описанием:
- Когда это нужно (FortiClient-like сценарии).
- Что меняется (sniff-based routing, нет 198.18/15).
- Ограничения: ECH, выше CPU-нагрузка на роутере, диагностика «FakeIP» отключена.

## Tasks

### Task 1: Добавить UCI-опцию `disable_fakeip` в дефолтный конфиг
**Stack:** shell
**Tests:** skip

**Files:**
- `podkop/files/etc/config/podkop` (modify)

**Description:** В секции `config settings 'settings'` добавить
`option disable_fakeip '0'` после `option exclude_ntp '0'`.

**Verification:**
- `grep "disable_fakeip" podkop/files/etc/config/podkop` → находит строку.
- Файл валидный UCI (визуальная проверка).

---

### Task 2: Условный пропуск FakeIP DNS-сервера и DNS-rule в `sing_box_configure_dns`
**Stack:** shell
**Tests:** skip (manual integration test)

**Files:**
- `podkop/files/usr/bin/podkop` (modify, function `sing_box_configure_dns`, ~764–793)

**Description:**
- Прочитать `disable_fakeip` через `config_get_bool` в начале функции.
- Обернуть условием `if [ "$disable_fakeip" -eq 0 ]; then ... fi` все четыре строки, относящиеся к fakeip:
  - `sing_box_cm_add_fakeip_dns_server`
  - `sing_box_cm_add_dns_route_rule ... "$SB_FAKEIP_DNS_SERVER_TAG" "$SB_FAKEIP_DNS_RULE_TAG"`
  - `sing_box_cm_patch_dns_route_rule ... "$SB_FAKEIP_DNS_RULE_TAG" "rewrite_ttl" ...`
  - `service_domains=...; sing_box_cm_patch_dns_route_rule ... "$SB_FAKEIP_DNS_RULE_TAG" "domain" ...`

**Verification:**
- `bash -n podkop/files/usr/bin/podkop` (синтаксис ok).
- При `disable_fakeip=1` `jq '.dns.servers[].type'` в сгенерированном конфиге не возвращает `"fakeip"`.

---

### Task 3: Условный пропуск `override-fakeip-port` в `sing_box_configure_route`
**Stack:** shell
**Tests:** skip

**Files:**
- `podkop/files/usr/bin/podkop` (modify, function `sing_box_configure_route`, строка ~823)

**Description:**
- При `disable_fakeip=1` не вызывать `sing_box_cf_override_domain_port "$FAKEIP_TEST_DOMAIN" 8443`.

**Verification:**
- `bash -n podkop/files/usr/bin/podkop`.
- При `disable_fakeip=1` в `route.rules` нет упоминания `$FAKEIP_TEST_DOMAIN` (`fakeip.podkop.fyi`).

---

### Task 4: Условный пропуск патчей `fakeip-dns-rule-tag` в handlers рулсетов
**Stack:** shell
**Tests:** skip

**Files:**
- `podkop/files/usr/bin/podkop` (modify, функции `configure_community_list_handler` ~987, `prepare_source_ruleset` ~1006, `configure_remote_domain_or_subnet_list_handler` ~1117)

**Description:**
- В каждой из трёх функций обернуть существующий вызов
  `sing_box_cm_patch_dns_route_rule ... "$SB_FAKEIP_DNS_RULE_TAG" "rule_set" "$ruleset_tag"` дополнительной проверкой `disable_fakeip=0`:
  ```
  if [ "$disable_fakeip" -eq 0 ] && [ "$route_rule_tag" != "$SB_EXCLUSION_RULE_TAG" ]; then
      config=$(sing_box_cm_patch_dns_route_rule ...)
  fi
  ```
- Прочитать `disable_fakeip` локально в каждой функции (или ввести
  helper-функцию — на усмотрение разработчика, не блокер).

**Verification:**
- `bash -n podkop/files/usr/bin/podkop`.
- При `disable_fakeip=1` в `dns.rules` нет правил с `rule_set` для
  community/local/remote-доменных списков.

---

### Task 5: Альтернативная nft-обвязка для sniff-режима
**Stack:** shell
**Tests:** skip (требует ручного integration-теста на роутере)

**Files:**
- `podkop/files/usr/bin/podkop` (modify, function `create_nft_rules`, ~282–335)

**Description:**
- Прочитать `disable_fakeip`.
- Обернуть в `if [ "$disable_fakeip" -eq 0 ]; then ... else ... fi`:
  - **Then-ветка**: текущие правила без изменений.
  - **Else-ветка**:
    - Удалить правила, ссылающиеся на `$SB_FAKEIP_INET4_RANGE`.
    - Добавить правило раннего выхода для localv4: `iifname @$IFSET ip daddr @$NFT_LOCALV4_SET_NAME return`.
    - Добавить общие правила «mark всё с интерфейсов»:
      `iifname @$IFSET meta l4proto tcp meta mark set $NFT_FAKEIP_MARK counter`
      `iifname @$IFSET meta l4proto udp meta mark set $NFT_FAKEIP_MARK counter`
    - В `mangle_output`: оставить только правила для `@$NFT_LOCALV4_SET_NAME` (return), `$NFT_OUTBOUND_MARK` (return), `@$NFT_COMMON_SET_NAME` (mark).
    - Цепочка `proxy` не меняется (tproxy на любую `NFT_FAKEIP_MARK` работает одинаково).

**Verification:**
- `bash -n podkop/files/usr/bin/podkop`.
- На роутере при `disable_fakeip=1`: `nft list table inet PodkopTable` не содержит ссылок на `198.18.0.0/15`.
- Manual: с клиента `curl https://example.com` (если домен в проксируемом списке) → трафик уходит через outbound (проверить логи sing-box).

---

### Task 6: Чекбокс «Don't use FAKE IP» в LuCI Settings UI
**Stack:** luci-js
**Tests:** skip

**Files:**
- `luci-app-podkop/htdocs/luci-static/resources/view/podkop/settings.js` (modify, после блока `disable_quic`)

**Description:**
- Добавить `form.Flag` `disable_fakeip` со строками-локалями (см.
  раздел Localization).
- Default: `"0"`, `rmempty: false`.

**Verification:**
- На роутере: после установки в LuCI на странице «Additional Settings» виден чекбокс «Don't use FAKE IP» с описанием.
- Включить/выключить → `uci show podkop.settings.disable_fakeip` отражает выбор.

---

### Task 7: Frontend helper `getDisableFakeip`
**Stack:** typescript
**Tests:** skip

**Files:**
- `fe-app-podkop/src/podkop/methods/custom/getDisableFakeip.ts` (create)
- `fe-app-podkop/src/podkop/methods/custom/index.ts` (modify — экспортировать новую функцию)

**Description:**
- Реализовать `getDisableFakeip(): Promise<boolean>` (см. раздел Frontend).

**Verification:**
- TypeScript-сборка `fe-app-podkop` проходит (`npm run build` или эквивалент).

---

### Task 8: Условный «N/A»-режим в `runFakeIPCheck`
**Stack:** typescript
**Tests:** skip

**Files:**
- `fe-app-podkop/src/podkop/tabs/diagnostic/checks/runFakeIPCheck.ts` (modify)

**Description:**
- В начале функции вызвать `getDisableFakeip()`.
- Если `true` — обновить store с `state: 'info'` (или ближайший нейтральный) и сообщением «FakeIP is intentionally disabled in Additional Settings», без вызовов `PodkopShellMethods.checkFakeIP` / `RemoteFakeIPMethods.*` и `return`.
- Иначе — текущая логика без изменений.

**Verification:**
- TypeScript-сборка проходит.
- На роутере при `disable_fakeip=1` диагностика показывает плашку «FakeIP disabled» без сетевых вызовов.

---

### Task 9: Регенерация локалей и проверка ключей
**Stack:** typescript
**Tests:** skip

**Files:**
- `fe-app-podkop/locales/calls.json` (auto-regenerated)

**Description:**
- Запустить `node fe-app-podkop/extract-calls.js` (или эквивалентный pipeline,
  уточнить из README/package.json).
- Убедиться, что новые ключи `Don't use FAKE IP`, `FakeIP disabled`,
  `FakeIP is intentionally disabled in Additional Settings` появились в `calls.json`.

**Verification:**
- `grep "FakeIP disabled" fe-app-podkop/locales/calls.json` → найдено.

---

### Task 10: Документация в README
**Stack:** docs
**Tests:** skip

**Files:**
- `README.md` (modify)

**Description:**
- Добавить подсекцию о режиме «Don't use FAKE IP» (см. раздел README в спеке).
- Перекрёстная ссылка на `docs/workvpn/` страницу podkop.net (опционально).

**Verification:**
- README рендерится корректно (визуальная проверка).

---

## Implementation Order

1. **Task 1** — UCI schema (нулевой риск, основа всего остального).
2. **Task 2** → **Task 3** → **Task 4** — backend DNS/route правки (чистая правка sing-box-конфига; тестируется генерацией конфига локально).
3. **Task 5** — nft-обвязка (самый рискованный шаг; требует тестирования на роутере).
4. **Task 6** — UI чекбокс.
5. **Task 7** → **Task 8** → **Task 9** — frontend.
6. **Task 10** — документация.

После каждой backend-таски рекомендуется прогнать `bash -n` и (если есть)
визуально проверить сгенерированный sing-box-конфиг через
`PodkopShellMethods.showSingBoxConfig` или ручной запуск секций.

## Manual Integration Tests (на роутере)

1. **Базовый сценарий (включение).** На AX3000T:
   - Включить чекбокс «Don't use FAKE IP» → Save & Apply.
   - `uci show podkop.settings.disable_fakeip` → `'1'`.
   - `service podkop restart` (или эквивалент).
   - `nft list table inet PodkopTable | grep "198.18"` → пусто.
   - `cat /etc/sing-box/config.json | jq '.dns.servers[].type'` → нет `"fakeip"`.
   - С клиента `nslookup example.com 192.168.1.1` (если `example.com` в проксируемом списке) → реальный IP, не 198.18.x.x.
   - С клиента `curl -v https://<домен из списка>/` → трафик идёт через outbound (проверить через `cat /tmp/sing-box.log` или CLI).

2. **Сценарий с FortiClient.** На macOS-клиенте включить FortiClient VPN, удостовериться, что трафик к проксируемым доменам корректно роутится через подкоп (не блокируется и не идёт мимо).

3. **Возврат в FakeIP-режим.** Снять чекбокс → перезапуск → `nft list table` снова содержит `198.18.0.0/15`, поведение прежнее.

4. **Edge case с exclusion-секцией.** Если есть exclusion-секция с
   доменами — убедиться, что `disable_fakeip=1` не ломает её (она и так
   не использовала fakeip-DNS-rule из-за `route_rule_tag != EXCLUSION_RULE_TAG`).

5. **Тест на Blume 2** — повторить пункты 1, 3.

## Dependencies

- Никаких новых внешних пакетов (sing-box, dnsmasq, nft уже есть).
- Никаких новых внутренних подсистем — только новый UCI-флаг и условные ветки.

## Open Questions / TODOs

1. **Discord UDP-fix rule (~1319).** Подтвердить ручным тестом, что в
   режиме `disable_fakeip=1` правило не вредит. Если вредит — обернуть в
   `if disable_fakeip=0; then`.
2. **`exclude_ntp` interaction.** Сейчас `exclude_ntp` вставляет правило
   в начало цепочки `mangle`. После реализации Task 5 проверить, что
   порядок правил остаётся корректным (`return udp dport 123` должно идти
   ДО общего «mark всё»).
3. **`fully_routed_ips` / `routing_excluded_ips`.** Эти опции сейчас
   меняют sing-box `route.rules` и nft. В sniff-режиме их семантика
   должна сохраниться «по строилу» (sing-box matchит по source_ip), но
   стоит прогнать E2E-сценарий с заполненными списками.
4. **state `'info'` vs `'warning'` в `IDiagnosticsChecksItem`.**
   Уточнить типы при импле task 8; если `'info'` нет — использовать
   `'warning'` или ввести новый state.
5. **Документация на podkop.net** — потребует отдельный PR в репозиторий
   docs (вне scope этой ветки).
