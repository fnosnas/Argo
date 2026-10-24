```
NODE_PORT=20001 SUB_PORT=20002 PUB_NODE_PORT=50001 PUB_SUB_PORT=50002 sh -c "$(curl -fsSL 'https://raw.githubusercontent.com/fnosnas/Argo/main/mini/install.sh')"
```

如果端口映射是一一对应的（内外一样），可以省掉 PUB_* 两项。  

可选变量：COUNTRIES="JP,KR"、ONLY_RESIDENTIAL=1、ROTATE_MINUTES=60（定时换出口）、HOST=（自动探测 IP 不对时手填）。

小鸡没有 curl 的话，Alpine 用 apk add curl，Debian 和 Ubuntu 用 apt install curl。

开启 TUN/TAP，没有就用不了。脚本会自检，缺 TUN 或缺 NET_ADMIN 权限会直接告诉你原因。

在端口映射里添加 TCP：节点端口和订阅端口各一条，内外端口对应你填的值。

装完等 1 到 2 分钟再更新订阅，返回 503 表示出口还没选好。

