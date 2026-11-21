一键安装命令
Bash
```
UUID=你的UUID KOMARI_SERVER=https://你的komari域名 KOMARI_TOKEN=你的token PORT=3000 DOMAIN=你的域名 \
bash <(curl -Ls https://raw.githubusercontent.com/fnosnas/Argo/main/js/install.sh)
```

# 变量会保存在 ~/node-ws/.env，以后重装或更新代码直接再跑一遍下面这行即可（只改传入的变量）
```
bash <(curl -Ls https://raw.githubusercontent.com/fnosnas/Argo/main/js/install.sh)
```


TLS 开关说明
怎么用

变量加 TLS=true，DOMAIN 不填（或者填你解析到这个 IP 的域名）
订阅地址不变，把前面的 http 换成 https 也能打开，原来的 http 地址照样可用
代码改了什么

同一个端口同时支持 http 和 https，自动区分，平台健康检查和保活不受影响
没有证书时自动生成自签证书，纯 JS 实现，不需要 openssl，也不用装新依赖；证书存在 .tls 目录，重启后继续使用同一张
订阅节点改为 security=tls，加了 allowInsecure=1（ss 原本就带 skip-cert-verify）
有正式证书的话可以用 TLS_CERT、TLS_KEY 指定，填文件路径或 PEM 内容都行，这时不会加跳过验证的参数
要知道的

自签证书能加密，但客户端会跳过证书验证，安全性比正式证书低一点
想要正式证书又不改代码的话，可以用 Cloudflare：域名开橙云解析到 分配的IP，SSL 设为 Flexible，再加一条 Origin Rule 把端口改写成 分配的端口，然后 DOMAIN 填这个域名、不开 TLS。这样节点就是域名:443 加正式证书，还能把 IP 藏起来
