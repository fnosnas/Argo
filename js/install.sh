#!/usr/bin/env bash
# 一键安装 node-ws（Komari 版）：拉取 index.js + package.json → npm install → 后台常驻
# 用法：变量写在命令前面，例如
#   UUID=xxx KOMARI_SERVER=https://km.example.com KOMARI_TOKEN=xxx PORT=3000 bash <(curl -Ls https://raw.githubusercontent.com/fnosnas/Argo/main/js/install.sh)
set -e
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/fnosnas/Argo/main/js}"
APP_DIR="${APP_DIR:-$HOME/node-ws}"
PM2_NAME="${PM2_NAME:-node-ws}"
ENV_KEYS="UUID DOMAIN PORT NAME SUB_PATH WSPATH AUTO_ACCESS KOMARI_SERVER KOMARI_TOKEN KOMARI_ARGS GH_PROXY FILE_PATH SHOW_LOG PM2_NAME"

command -v node >/dev/null 2>&1 || { echo "未找到 node，请先安装 Node.js 16+"; exit 1; }
command -v npm  >/dev/null 2>&1 || { echo "未找到 npm"; exit 1; }
dl() { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else wget -qO "$2" "$1"; fi; }

mkdir -p "$APP_DIR" && cd "$APP_DIR"
echo "[1/4] 拉取代码到 $APP_DIR"
dl "$REPO_RAW/index.js" index.js
dl "$REPO_RAW/package.json" package.json

echo "[2/4] 保存配置到 .env（重装时会覆盖传入的变量，没传的保留）"
touch .env
for k in $ENV_KEYS; do
  v="${!k}"
  if [ -n "$v" ]; then sed -i "/^$k=/d" .env; echo "$k=$v" >> .env; fi
done
chmod 600 .env

echo "[3/4] npm install"
npm install --omit=dev --no-audit --no-fund --silent >/dev/null 2>&1 || npm install --no-audit --no-fund

cat > start.sh <<'SH'
#!/usr/bin/env bash
cd "$(dirname "$0")"
set -a; [ -f .env ] && . ./.env; set +a
exec node index.js
SH
chmod +x start.sh

echo "[4/4] 启动"
if ! command -v pm2 >/dev/null 2>&1; then
  npm i -g pm2 --silent >/dev/null 2>&1 || true
fi
if command -v pm2 >/dev/null 2>&1; then
  pm2 delete "$PM2_NAME" >/dev/null 2>&1 || true
  pm2 start "$APP_DIR/start.sh" --name "$PM2_NAME" >/dev/null
  pm2 save >/dev/null 2>&1 || true
  pm2 startup >/dev/null 2>&1 || true   # root 下会设置开机自启
  echo "已用 pm2 常驻：pm2 status / pm2 restart $PM2_NAME / pm2 logs $PM2_NAME"
else
  pkill -f "$APP_DIR/index.js" >/dev/null 2>&1 || true
  nohup "$APP_DIR/start.sh" >/dev/null 2>&1 &
  echo "pm2 装不上，已用 nohup 后台运行（重启机器后需重新执行）"
fi
echo "完成。订阅地址：http(s)://你的域名或IP:端口/${SUB_PATH:-sub}"
