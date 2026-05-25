# OpenVPN Split Iplist

Интерактивный скрипт для настройки split tunneling в уже установленном OpenVPN.

Проект позволяет отправлять через VPN только сайты из списка `iplist.opencck.org`, а весь остальной трафик оставлять через обычное интернет-соединение клиента.

## Возможности

- split tunneling для OpenVPN;
- автоматическая генерация `push "route ..."` из CIDR-списка;
- автообновление маршрутов через systemd timer;
- настройка IPv4 forwarding;
- настройка NAT через iptables;
- диагностика текущей конфигурации;
- откат интеграции;
- интерактивное меню в терминале.

## Как это работает

Обычный OpenVPN часто отправляет весь трафик клиента через VPN с помощью:

```conf
push "redirect-gateway def1 bypass-dhcp"
```

Этот скрипт отключает такой режим и вместо него добавляет только нужные маршруты:

```conf
push "route 1.2.3.0 255.255.255.0"
push "route 4.5.6.0 255.255.255.0"
```

Список IP-сетей берётся из `iplist.opencck.org`.

## Требования

- Debian или Ubuntu;
- уже установленный и рабочий OpenVPN;
- root-доступ;
- systemd;
- iptables.

Протестировано на:

- Ubuntu 24.04;
- OpenVPN server с systemd;
- IPv4 split tunneling.

## Установка

```bash
git clone https://github.com/julfys/openvpn-split-iplist.git
cd openvpn-split-iplist
chmod +x openvpn-split-iplist.sh
sudo ./openvpn-split-iplist.sh
```

## Быстрая установка одной командой

```bash
git clone https://github.com/julfys/openvpn-split-iplist.git && cd openvpn-split-iplist && chmod +x openvpn-split-iplist.sh && sudo ./openvpn-split-iplist.sh
```

## Меню

```text
OpenVPN split tunneling via iplist
1) Установить/настроить всё
2) Обновить список маршрутов сейчас
3) Изменить URL списка
4) Диагностика
5) Откатить интеграцию с iplist
0) Выход
```

## Автообновление

Скрипт создаёт systemd timer:

```bash
openvpn-iplist-update.timer
```

Он ежедневно обновляет список маршрутов и перезапускает OpenVPN.

Проверить timer:

```bash
systemctl status openvpn-iplist-update.timer
```

Запустить обновление вручную:

```bash
sudo systemctl start openvpn-iplist-update.service
```

## Важно

После обновления маршрутов клиентам нужно переподключиться к OpenVPN.

OpenVPN отправляет маршруты клиенту при подключении. Уже подключённые клиенты не получат новый список до переподключения.

## Проверка на клиенте

После подключения к VPN проверь маршруты:

```bash
ip route
```

Default route не должен уходить через VPN, если split tunneling работает корректно.

## Откат

Запусти скрипт и выбери пункт:

```text
5) Откатить интеграцию с iplist
```

Скрипт уберёт подключение файла маршрутов из конфига OpenVPN и отключит systemd timer.

NAT-правило автоматически не удаляется, чтобы случайно не сломать рабочий VPN.

## License

MIT
