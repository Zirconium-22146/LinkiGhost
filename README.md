# LinkiGhost

Ghost mode для официального Telegram на iOS: приложение не отправляет
«печатает», «прочитано» и статус «в сети». Интерфейс не меняется — всё
скрывается только на уровне сети.

## Что именно блокируется

| Запрос | Что скрывает |
|---|---|
| `messages.setTyping` | «печатает…» |
| `messages.setEncryptedTyping` | «печатает…» в секретных чатах |
| `messages.readHistory` | «прочитано» в личке и группах |
| `channels.readHistory` | «прочитано» в каналах |
| `messages.readEncryptedHistory` | «просмотрено» в секретных чатах |
| `account.updateStatus` | статус «в сети» |

## Поддерживаемые приложения

| Приложение | Bundle ID |
|---|---|
| Telegram (App Store) | `ph.telegra.Telegraph` |
| Telegram (сборка из исходников) | `org.telegram.Telegram` |
| Swiftgram (App Store) | `app.swiftgram.ios` |

Хук висит на класс `MTRequestMessageService` из MtProtoKit, общий для всех
форков Telegram-iOS, поэтому работает в любом из них — нужен только
правильный bundle id в фильтре.

## Требования

- iOS 15.0–16.6.1, arm64 (iPhone 7 подходит)
- palera1n / rootless джейлбрейк, ElleKit
- Telegram из App Store **или Swiftgram** (`app.swiftgram.ios`)
- `iphoneos-arm64` (rootless) пакет

## Установка из «Загрузок»

1. Скачай `bond.linkigram.ghost_0.1.0_iphoneos-arm64.deb`.
2. Открой файл в «Файлах» → он откроется в Sileo.
3. Sileo → Install → Respring.
4. Запусти Telegram.

Если Sileo не открывает `.deb` из «Файлов»: положи файл в
`/var/mobile/Documents` через Filza и открой его оттуда.

## Сборка без Mac

`.github/workflows/build.yml` собирает пакет на `ubuntu-latest` через Theos.
Нужен только GitHub-аккаунт: форк → Actions → Run workflow → скачать
артефакт `linkighost-deb`.

## Откат

Sileo → LinkiGhost → Remove, либо удалить
`/var/jb/Library/MobileSubstrate/DynamicLibraries/LinkiGhost.dylib`.
