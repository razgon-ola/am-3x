# am-3x — Amnezia VPN → 3x-ui transparent proxy

Автоматическая настройка маршрутизации **всего TCP трафика** из Docker контейнеров AmneziaVPN через outbound 3x-ui (xray).

## Как работает

```
Телефон/ПК → AmneziaWG (Docker) → iptables NAT REDIRECT → xray dokodemo-door → VLESS/VMess outbound → Интернет
```

- **TCP** → проксируется через выбранный outbound (VLESS, VMess, Trojan и т.д.)
- **QUIC (UDP:443)** → заблокирован в xray routing (приложения автоматически переходят на TCP)
- **Остальной UDP** → идёт напрямую

## Результат

✅ YouTube, Instagram, стриминг — всё работает через прокси
✅ Автоматический интерактивный скрипт настройки
✅ Поддержка нескольких контейнеров Amnezia и нескольких outbound'ов

## Требования

- Linux сервер с root доступом
- Docker + Docker Compose
- 3x-ui панель (с настроенным outbound)
- Контейнеры AmneziaVPN (AmneziaWG)

## Установка

```bash
# Скачать и запустить
curl -fsSL https://parser.marasanov.com/am-3x-setup.sh | sudo bash

# Или вручную
wget https://parser.marasanov.com/am-3x-setup.sh
sudo bash am-3x-setup.sh
```

Скрипт автоматически:
1. Найдёт контейнеры Amnezia и их подсеть
2. Подключится к 3x-ui API
3. Предложит выбрать outbound
4. Создаст dokodemo-door inbound
5. Настроит routing rules (QUIC block + proxy)
6. Настроит iptables (NAT REDIRECT)
7. Сохранит правила для перезагрузки

## Удаление

```bash
sudo bash am-3x-setup.sh --uninstall
```

## Переменные окружения

| Переменная | Описание | По умолчанию |
|---|---|---|
| `AM3X_DOKO_PORT` | Порт dokodemo-door | 12747 |
| `AM3X_PASSWORD` | Пароль 3x-ui (без запроса) | — |

## Важно

Routing rules в 3x-ui должны быть в таком порядке:
1. **QUIC block** (UDP:443 → blocked) — ДО общего правила!
2. **dokodemo-door → outbound**
3. **Private IP → blocked**

Если QUIC block стоит после прокси-правила — YouTube/Instagram видео работать не будут!

## Версии

### v2.2 (текущая)
- TCP через NAT REDIRECT → xray → outbound
- QUIC (UDP:443) заблокирован в xray routing
- Остальной UDP напрямую
- YouTube, Instagram, стриминг работают ✅

### v2.1
- TCP через NAT REDIRECT (UDP напрямую, не проксируется)

## Лицензия

MIT
