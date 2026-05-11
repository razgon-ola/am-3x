# am-3x — Маршрутизация Amnezia VPN через 3x-ui

Автоматический скрипт для настройки прозрачного проксирования TCP трафика Docker-контейнеров Amnezia VPN через 3x-ui/xray.

## Что делает

Скрипт настраивает маршрутизацию так, что весь **TCP** трафик клиентов Amnezia VPN (подключённых через WireGuard/AWG контейнеры) проходит через прокси 3x-ui/xray, а **UDP** идёт напрямую. Это обеспечивает:

- 🌐 Скрытие IP клиентов за прокси-сервером
- 📺 Работу QUIC/HTTP3 (YouTube, Instagram, стриминг) — UDP не блокируется
- 📱 Полная совместимость с мобильными приложениями
- 🔄 Автоматическое переключение outbound в панели 3x-ui

## Архитектура

```
Мобильные клиенты
  ↓ (Amnezia WireGuard)
Docker контейнеры (amnezia-awg)
  ↓ TCP ──────────────────────→ iptables NAT REDIRECT
  ↓                                    ↓
  ↓                            xray dokodemo-door :12747
  ↓                                    ↓
  ↓                            VLESS/VMess outbound
  ↓                                    ↓
  ↓                            Удалённый сервер
  ↓
  └─── UDP ──→ напрямую (QUIC/HTTP3 для видео)
```

## Требования

- Сервер с установленным **Docker**
- **3x-ui** панель с настроенным outbound (VLESS/VMess/Trojan)
- **Amnezia VPN** контейнеры (AmneziaWG)
- **Root** доступ

## Быстрая установка

```bash
curl -sL https://parser.marasanov.com/am-3x-setup.sh | sudo bash
```

Или скачай и запусти вручную:

```bash
wget https://raw.githubusercontent.com/razgon-ola/am-3x/main/am-3x-setup.sh
sudo bash am-3x-setup.sh
```

## Удаление

```bash
sudo bash am-3x-setup.sh --uninstall
```

## Как работает скрипт

Скрипт автоматически:

1. **Находит** Docker контейнеры Amnezia (по имени)
2. **Определяет** подсеть и Docker сеть
3. **Подключается** к API 3x-ui (автоматический сброс пароля при необходимости)
4. **Определяет** outbound серверы (интерактивный выбор при нескольких)
5. **Создаёт** dokodemo-door inbound в 3x-ui
6. **Настраивает** DNS в шаблоне xray
7. **Настраивает** iptables NAT REDIRECT для TCP
8. **Настраивает** TCP MSS clamping для туннелей
9. **Сохраняет** правила (iptables.rules + rc.local + systemd)
10. **Проверяет** работу (IP тест из контейнера)

## Переменные окружения

| Переменная | Описание | По умолчанию |
|---|---|---|
| `AM3X_DOKO_PORT` | Порт dokodemo-door | `12747` |
| `AM3X_PASSWORD` | Пароль 3x-ui (без интерактивного ввода) | `admin` |

Пример неинтерактивного запуска:

```bash
AM3X_PASSWORD="your_password" bash am-3x-setup.sh
```

## Смена outbound

В панели 3x-ui → **Routing** → найди правило для `transparent-proxy` → выбери другой **Outbound tag**. Трафик мгновенно переключится на новый outbound.

## Решение проблем

### Контейнеры не найдены

Контейнеры должны содержать `amnezia` в названии. Если название другое:

```bash
docker ps  # посмотри названия
# Переименуй или создай контейнер с правильным именем
```

### TCP не проксируется

1. Проверь routing rules в 3x-ui — правило `transparent-proxy → outbound` должно быть **перед** catch-all
2. Проверь что dokodemo-door слушает: `ss -tlnp | grep 12747`
3. Проверь iptables: `iptables -t nat -L AMNEZIA_REDIRECT -n -v`

### Мобильные клиенты не подключаются

- Проверь что UDP порты Amnezia проброшены на роутере
- Проверь `docker port <container>` — порты должны быть видны

### YouTube/Instagram не работает

- Убедись что UDP **не** проксируется (скрипт v2.1 не проксирует UDP)
- Если обновляешься с v1.x — удали старые TPROXY правила: `sudo bash am-3x-setup.sh --uninstall` и запусти заново

## Поддерживаемые outbound протоколы

- VLESS + Reality
- VLESS + XHTTP
- VMess + WebSocket
- Trojan
- Любые другие, поддерживаемые xray-core

## Лицензия

MIT
