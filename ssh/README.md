# WebSSH Worker 使用说明
部署

Cloudflare 控制台 → Workers & Pages → 创建 → 从 Hello World 开始
编辑代码，全选删掉，贴入文件全部内容 → Deploy
打开 Worker 的 workers.dev 地址就是登录页
换背景图
Worker → 设置 → 变量和机密 → 添加文本变量 BG_URL，值填图片直链 → 部署。不填就用默认风景图。

主机地址：IPv4、IPv6（带不带方括号都行）、域名
端口 / 用户名 / 密码

私钥（可选）：Ed25519、RSA、ECDSA，OpenSSH 或 PEM 格式

初始命令：登录后自动执行     
生成链接：把主机/端口/用户名/初始命令做成链接复制，不含密码和私钥
终端里

鼠标选中即复制，右键粘贴      
Ctrl+Shift+C / Ctrl+Shift+V，或顶栏「复制」「粘贴」按钮    
窗口缩放自动同步终端大小     
关页即清 Worker 没有任何存储，页面也不用 Cookie 和本地存储。页面一关连接就断，密码和私钥只在内存里，跟着消失。

要知道的

填 VPS 的真实 IP。开了 Cloudflare 小黄云的域名连不上，这是 Workers 的限制
带口令的私钥暂不支持，所以去掉了 PIN 框；可先用 ssh-keygen -p -f 私钥文件 去掉口令
为了精简，没做主机指纹校验

