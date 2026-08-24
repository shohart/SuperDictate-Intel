# Спецификация: тосты состояния коррекции/рерайта + хоткеи рерайта

**Ветка:** `feat/llm-postproc-gec` · **Дата:** 2026-08-24
**Основание:** запрос пользователя от 2026-08-24 — «тяжело уследить, включена ли коррекция/рерайт; уведомлять тостами о включении/выключении и о режиме рерайта; минимум слов, цветовое кодирование; переключение будет вешаться на хоткеи».

## 1. Решения

1. **Тосты состояния** для трёх событий, по визуальному языку
   VocabularyLearnedToast (пилюля, палитра HUD, позиционирование над
   целью/в правом нижнем углу, анимации входа/выхода), но БЕЗ
   интерактивности: ни кнопок, ни event tap'ов, ни захвата клавиш.
2. **Цветовое кодирование** (акцентная кайма + цвет текста-статуса):
   - включено → `systemGreen`;
   - выключено → нейтральный серый;
   - смена режима рерайта → акцентный цвет HUD (recordingColor).
3. **Тексты — минимум слов** (RU/EN):
   - `Коррекция · вкл` / `Коррекция · выкл`
   - `Рерайт · вкл · <стиль>` / `Рерайт · выкл` (стиль — только при вкл.)
   - `Режим · <стиль>` (Причесать / Задача / Официальный)
4. **Автоскрытие 2 с**, без кнопок. Панель неактивирующая — фокус ввода
   пользователя не крадётся никогда.
5. **Два новых глобальных хоткея** (зеркала correction-хоткея, того же
   класса «restart-free» переключений):
   - «Рерайт вкл/выкл», дефолт **F13**;
   - «Режим рерайта» (цикл по 3 стилям; если рерайт выключен — включает),
     дефолт **F14**.
   Настраиваются в Настройках → «Коррекция» (те же HotkeyRecorder-строки,
   что у остальных хоткеев).
   **Почему не модификаторные базы** (зафиксировано тестами): LCmd занят
   коррекцией — её дефолт «голый LCmd» срабатывает на самом нажатии LCmd,
   поэтому любой chord LCmd+X двойного срабатывания; RCmd занят диктовкой
   — «голый RCmd» стартует запись на RCmd-down, а отпускание
   дополнительного модификатора внутри chord'а даёт dictation-press.
   F13/F14 не печатаются, не заняты и ожидают перебиндинга пользователем
   (он сам планирует повесить их на удобные сочетания).
6. **Хост-менеджмент**: переключение рерайта хоткеем управляет
   отложенной выгрузкой хостов так же, как переключение коррекции
   (`cancelScheduledUnload` при включении / `scheduleDelayedUnload` при
   выключении) — без рестарта сервиса.
7. **Цикл стиля включает рерайт**: если рерайт выключен, нажатие хоткея
   режима сначала включает его (и тост отражает «вкл» + режим).

## 2. Тексты и тона (единственный источник — эта спека)

| Событие | Текст RU | Текст EN | Тон |
|---|---|---|---|
| Коррекция включена | `Коррекция · вкл` | `Correction · on` | on (зелёный) |
| Коррекция выключена | `Коррекция · выкл` | `Correction · off` | off (серый) |
| Рерайт включён | `Рерайт · вкл · <стиль>` | `Rewrite · on · <style>` | on |
| Рерайт выключен | `Рерайт · выкл` | `Rewrite · off` | off |
| Смена режима | `Режим · <стиль>` | `Style · <style>` | neutral (акцент) |

`<стиль>` — короткие имена: Причесать / Задача / Официальный (Polish /
Task / Official).

## 3. Настройки (UserDefaults, suite com.local.superdictate)

- `rewrite_toggle_hotkey_keycode` / `rewrite_toggle_hotkey_modifiers`
  → `configuredRewriteToggleHotkey` (дефолт F13, без модификаторов).
- `rewrite_style_hotkey_keycode` / `rewrite_style_hotkey_modifiers`
  → `configuredRewriteStyleHotkey` (дефолт F14, без модификаторов).
- Существующие `rewrite_enabled_v1` / `rewrite_style_v1` — источник
  состояния; хоткей пишет в них напрямую (без draft/Save — тот же
  restart-free контракт, что у коррекционного хоткея).

## 4. Пайплайн и процессы

- `toggleRewriteMode()` (ParakeyApp): инвертирует `settings.rewriteEnabled`,
  логирует, звук (как коррекция), тост, host-unload
  (`cancelScheduledUnload` вкл / `scheduleDelayedUnload` выкл —
  `neededHostIdentities` уже учитывает рерайт).
- `cycleRewriteStyle()`: следующий элемент `RewriteStyle.allCases`;
  если `rewriteEnabled == false` — сначала включить; тост «Режим · X».
- Коррекционный хоткей (`toggleTextCorrectionMode`) дополняется тостом
  «Коррекция · вкл/выкл» (логика не меняется).

## 5. UI

Вкладка «Коррекция»: две новые HotkeyRecorder-строки после строки
«Переключить коррекцию» — «Переключить рерайт» (kind `.rewriteToggle`)
и «Режим рерайта» (kind `.rewriteStyle`). Draft-поля, recorder-заголовки,
save — зеркально correction.

## 6. Тесты

- SelfTest (hotkey): press на rewrite-хоткее → `.toggleRewrite`; press на
  style-хоткее → `.cycleRewriteStyle`; pass для посторонних клавиш;
  дефолты (LCmd+Shift / LCmd+Opt).
- SelfTest (settings): roundtrip `configuredRewriteToggleHotkey` /
  `configuredRewriteStyleHotkey`.
- Ручная проверка: тосты на реальных переключениях, цвет/текст/автоскрытие.

## 7. Сборки

Тест-бандл: `scripts/build-test-app.sh` → `dist/SuperDictate-test.app`
(стабильная подпись, `-dev` версия). Боевой бандл не трогается.

## 8. План внедрения (задачи с критериями приёмки)

| # | Задача | Файлы | Критерий приёмки |
|---|---|---|---|
| T1 | Хоткей-сантехника: actions `.toggleRewrite`/`.cycleRewriteStyle`, shortcut-состояния, transition-параметры/методы, свойства/setters/колбэки listener'а, dispatch | Hotkeys.swift | `swift build` OK; старые хоткей-тесты проходят |
| T2 | Настройки: ключи + `configuredRewriteToggleHotkey`/`configuredRewriteStyleHotkey` + сеттеры | Settings.swift | roundtrip в SelfTest |
| T3 | `StateToastController` — цветной автотост | StateToast.swift (новый) | build; тон/текст по таблице §2 |
| T4 | ParakeyApp: установка хоткеев, колбэки, `toggleRewriteMode()`/`cycleRewriteStyle()` + тосты + хост-менеджмент; тост в `toggleTextCorrectionMode` | ParakeyApp.swift | build; хост-логика зеркалит коррекцию |
| T5 | ControlPanel: kinds `.rewriteToggle`/`.rewriteStyle`, draft-поля, recorder-заголовки, строки во вкладке, save | ControlPanel.swift | build; запись хоткеев в draft/save |
| T6 | SelfTest: transition rewrite/style + settings roundtrip | SelfTest.swift | `--self-test all` PASS |
| T7 | Интеграция: build + `--self-test all` + тест-бандл; коммит | — | all PASS; бандл собран |

Порядок: T2 → T3 → T4 → T5 → T6 → T7 (T1 выполнен). Ревью после каждой
задачи — сверка с этой спекой.
