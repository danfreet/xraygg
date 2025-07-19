#!/bin/bash

# === Принудительно очистить DOS-символы (CRLF) при запуске ===
if file "$0" | grep -q CRLF; then
  echo "🔧 Исправление CRLF → LF (Windows → Unix)"
  sed -i 's/\r\$//' "$0"
  exec bash "$0" "$@"
fi

# === Проверка зависимостей ===
for cmd in curl unzip; do
  if ! command -v "$cmd" &> /dev/null; then
    echo "❌ Требуется установить: $cmd"
    echo "👉 Пример: sudo apt install $cmd"
    MISSING=true
  fi
done
if [[ "$MISSING" == true ]]; then
  exit 1
fi

# === Значения по умолчанию ===
PORT=443
SNI="www.google.com"
MY_IP=$(curl -s https://api.ipify.org)
CLIENTS=()
INSTALL_SERVICE=false

# === Парсинг аргументов ===
print_help() {
  echo "\nUsage: bash xraygg-installer.sh [OPTIONS]\n"
  echo "Options:"
  echo "  --port <port>             Указать порт (по умолчанию 443)"
  echo "  --sni <domain>            Указать SNI домен (по умолчанию www.google.com)"
  echo "  --ip <your_ip>            Внешний IP адрес сервера (по умолчанию autodetect)"
  echo "  --client <name>           Добавить клиента (можно указывать несколько раз)"
  echo "  --install-service         Установить systemd-сервис для автозапуска"
  echo "  -h, --help                Показать эту справку\n"
  exit 0
}

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --port) PORT="$2"; shift 2;;
    --sni) SNI="$2"; shift 2;;
    --ip) MY_IP="$2"; shift 2;;
    --client) CLIENTS+=("$2"); shift 2;;
    --install-service) INSTALL_SERVICE=true; shift;;
    -h|--help) print_help;;
    *) echo "Неизвестный параметр: $1"; print_help;;
  esac
done

if [[ -z "$MY_IP" ]]; then
  echo "❌ Не удалось определить внешний IP. Укажите вручную через --ip"
  exit 1
fi


# === Скачивание Xray ===
echo "📥 Проверка Xray..."
if [ ! -f "./xray" ]; then
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) ARCH_DL="64";;
    aarch64) ARCH_DL="arm64-v8a";;
    *) echo "❌ Неподдерживаемая архитектура: $ARCH"; exit 1;;
  esac
  mkdir -p ./xray-tmp
  curl -L -o xray.zip https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${ARCH_DL}.zip
  unzip xray.zip -d ./xray-tmp || { echo "❌ Не удалось распаковать xray.zip"; exit 1; }
  mv ./xray-tmp/xray ./xray && chmod +x ./xray || { echo "❌ Не удалось переместить Xray"; exit 1; }
  mv ./xray-tmp/geo* .
  rm -rf xray.zip xray-tmp
fi

if [ ! -f "./xray" ]; then
  echo "❌ Не удалось скачать и распаковать Xray."
  exit 1
fi

# === Генерация Reality ключей ===
KEYS=$(./xray x25519 2>/dev/null)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
SHORT_ID="12345678"

echo "🔑 Reality ключи сгенерированы:"
echo "   Private: $PRIVATE_KEY"
echo "   Public : $PUBLIC_KEY"

# === Генерация клиентов ===
CLIENTS_JSON=""
LINKS=""

for NAME in "${CLIENTS[@]}"; do
  UUID=$(cat /proc/sys/kernel/random/uuid)
  CLIENTS_JSON+="
          { \"id\": \"$UUID\", \"flow\": \"\", \"email\": \"$NAME\" },"
  LINKS+=$'\n'"vless://$UUID@$MY_IP:$PORT?encryption=none&security=reality&type=tcp&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&sni=$SNI&alpn=h2#$NAME"
done
CLIENTS_JSON=$(echo "$CLIENTS_JSON" | sed '$ s/},/}/')

# === Генерация config.json ===
cat > config.json <<EOF
{
  "log": { "loglevel": "warning" },
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
          "serverNames": [ "$SNI" ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [ "$SHORT_ID" ]
        }
      }
    }
  ],
  "outbounds": [ { "protocol": "freedom" } ]
}
EOF

# === Вывод ссылок ===
echo "\n✅ Конфигурация сохранена в config.json"
echo "\n📌 VLESS Reality ссылки для клиентов:" && echo "$LINKS"

# === Установка systemd-сервиса ===
if [[ "$INSTALL_SERVICE" == true ]]; then
  echo "\n🛠️ Установка systemd-сервиса..."
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

  sudo systemctl daemon-reload
  sudo systemctl enable xray
  sudo systemctl start xray
  echo "✅ systemd-сервис установлен и запущен."
else
  echo "⏭️ Пропущено создание systemd-сервиса."
fi
