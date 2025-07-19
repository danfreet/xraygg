#!/bin/bash

# === Автоустановка Xray ===
if [ ! -f "./xray" ]; then
  echo "📥 Xray не найден, скачиваем последнюю версию..."
  ARCH=$(uname -m)

  case "$ARCH" in
    x86_64) ARCH_DL="64";;
    aarch64) ARCH_DL="arm64-v8a";;
    *) echo "❌ Неподдерживаемая архитектура: $ARCH"; exit 1;;
  esac

  curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_DL}.zip
  unzip xray.zip xray geo* -d ./xray-tmp
  mv ./xray-tmp/xray ./xray
  chmod +x ./xray
  mv ./xray-tmp/geo* ./
  rm -rf xray.zip xray-tmp
  echo "✅ Xray установлен"
fi

# === Ввод основных параметров ===
read -p "Введите порт для сервера (по умолчанию 443): " PORT
PORT=${PORT:-443}

read -p "Введите SNI-домен (например, www.cloudflare.com): " SNI
SNI=${SNI:-www.cloudflare.com}

read -p "Введите внешний IP сервера: " MY_IP

# === Генерация Reality-ключей ===
REALITY_KEYS=$(./xray x25519)
PRIVATE_KEY=$(echo "$REALITY_KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$REALITY_KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID="12345678"

echo "🔑 Reality ключи сгенерированы:"
echo "   Private: $PRIVATE_KEY"
echo "   Public : $PUBLIC_KEY"
echo ""

# === Ввод клиентов ===
CLIENTS_JSON=""
LINKS=""

while true; do
  read -p "Введите имя клиента (или оставьте пустым для завершения): " NAME
  [ -z "$NAME" ] && break

  UUID=$(cat /proc/sys/kernel/random/uuid)
  CLIENTS_JSON="$CLIENTS_JSON
          {
            \"id\": \"$UUID\",
            \"flow\": \"\",
            \"email\": \"$NAME\"
          },"
  VLESS_LINK="vless://$UUID@$MY_IP:$PORT?encryption=none&flow=&type=tcp&security=reality&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&sni=$SNI&alpn=h2#$NAME"
  LINKS="$LINKS
$VLESS_LINK"
done

# Удаляем последнюю запятую
CLIENTS_JSON=$(echo "$CLIENTS_JSON" | sed '$ s/},/}/')

# === Генерация config.json ===
cat > config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
$CLIENTS_JSON
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# === Вывод ссылок ===
echo ""
echo "✅ Конфигурация сохранена в config.json"
echo ""
echo "📌 VLESS Reality ссылки для клиентов:"
echo "$LINKS"

# === Установка Xray как systemd-сервис ===
read -p "Создать systemd-сервис для автозапуска Xray? (y/n): " ENABLE_SERVICE

if [[ "$ENABLE_SERVICE" == "y" || "$ENABLE_SERVICE" == "Y" ]]; then
  echo "🛠️ Устанавливаем systemd-сервис..."

  sudo mkdir -p /etc/xray
  sudo cp ./xray /etc/xray/xray
  sudo cp ./geo* /etc/xray/
  sudo cp ./config.json /etc/xray/config.json
  sudo chmod +x /etc/xray/xray

  sudo tee /etc/systemd/system/xray.service > /dev/null <<EOF
[Unit]
Description=Xray Service
After=network.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/etc/xray/xray -config /etc/xray/config.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reexec
  sudo systemctl daemon-reload
  sudo systemctl enable xray
  sudo systemctl start xray

  echo "✅ Сервис 'xray' установлен и запущен!"
  echo "ℹ️ Управление: sudo systemctl [start|stop|restart|status] xray"
else
  echo "⏭️ Пропущено создание systemd-сервиса."
fi