# dnsonlien — фикс картинок в Roblox

> **English:** This tool fixes broken Roblox images (avatars, thumbnails, marketplace) in Russia.
> The ISP spoils plain DNS answers for `*.rbxcdn.com`, so a tiny local service on `127.0.0.1:53`
> resolves everything over **DNS-over-HTTPS** (Cloudflare, fallback Google), bypassing the ISP.
> Install once, forget it — works in the background like zapret.

**Проблема:** провайдер перехватывает и «портит» обычный DNS-ответ для доменов `*.rbxcdn.com`
(серверов, с которых Roblox грузит все картинки: аватарки, миниатюры игр, маркетплейс).
`tr.rbxcdn.com` не резолвится → картинки не грузятся. Запрет (zapret) не помогает, потому что
проблема не в DPI, а в подмене DNS.

**Решение:** этот инструмент ставит маленький локальный DNS-сервис на `127.0.0.1:53`,
который резолвит все домены через **DNS-over-HTTPS** (`cloudflare-dns.com`, запасной `dns.google`) —
в обход подмены провайдера. Работает в фоне, как zapret: запустил один раз — забыл.

Никаких правок в файл `hosts` и никаких скачиваний — всё компилируется локально.

## Структура проекта

```
dnsonlien/
│
├── install.bat              ← УСТАНОВКА (двойной клик, от админа)
├── uninstall.bat            ← УДАЛЕНИЕ / откат (двойной клик, от админа)
├── check.bat                ← ПРОВЕРКА статуса (двойной клик, от админа)
├── README.md                ← эта инструкция
│
├── src\                     ← исходный код
│   └── dnsonlien-dns.cs     ←   DNS-прокси (C#)
│
├── scripts\                 ← служебные скрипты
│   ├── install-fix.ps1
│   ├── uninstall-fix.ps1
│   └── check.ps1
│
├── bin\                     ← готовый исполняемый файл
│   └── dnsonlien-dns.exe    ←   его запускает служба
│
├── logs\                    ← журналы
│   ├── dnsonlien.log        ←   журнал установки
│   ├── install-progress.txt ←   шаги установки (для отладки)
│   └── dnsonlien-dns.log    ←   журнал работы службы
│
└── backup\                  ← бэкап ваших DNS-настроек
    └── dns-backup.json
```

## Установка

1. Нажмите правой кнопкой на **`install.bat`** → **«Запуск от имени администратора»**
   (или просто двойной клик — спросит разрешение само).
2. Дождитесь сообщения `FIX APPLIED SUCCESSFULLY`.
3. Закройте и заново запустите Roblox — картинки должны появиться.

## Что происходит при установке

- компилируется `bin\dnsonlien-dns.exe` из `src\dnsonlien-dns.cs`;
- ставится служба Windows `dnsonlien-dns` с автозапуском (переживает перезагрузку);
- системный DNS активного адаптера переключается на `127.0.0.1` (и `::1`);
- прежние DNS-настройки сохраняются в `backup\dns-backup.json`;
- делается самопроверка: резолв `tr.rbxcdn.com` + загрузка тестовой картинки.

## Проверка

Запустите **`check.bat`** — покажет статус службы, текущие DNS-серверы,
резолвится ли `tr.rbxcdn.com`, и скачивается ли тестовая картинка.

## Удаление (полный откат)

Запустите **`uninstall.bat`** — служба удалится, DNS восстановится из бэкапа
(или сбросится на DHCP). Всё вернётся к исходному состоянию.

## Если снова перестало грузиться

Иногда CloudFront меняет свои IP. Просто запустите `install.bat` ещё раз —
он сам возьмёт актуальные адреса и обновит службу.

## Как это работает изнутри

```
Roblox / Windows ──DNS-запрос──▶ 127.0.0.1:53 (dnsonlien-dns.exe)
                                      │  HTTPS POST (application/dns-message)
                                      ▼
                          cloudflare-dns.com  (запасной: dns.google)
                                      │
                                      ▼
                        честный ответ (IP картинок Roblox)
```
