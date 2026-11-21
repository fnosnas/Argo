一键安装命令
Bash

UUID=你的UUID KOMARI_SERVER=https://你的komari域名 KOMARI_TOKEN=你的token PORT=3000 DOMAIN=你的域名 \
bash <(curl -Ls https://raw.githubusercontent.com/fnosnas/Argo/main/js/install.sh)

# 变量会保存在 ~/node-ws/.env，以后重装或更新代码直接再跑一遍下面这行即可（只改传入的变量）
# bash <(curl -Ls https://raw.githubusercontent.com/fnosnas/Argo/main/js/install.sh)
