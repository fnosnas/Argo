一键安装命令
Bash
```
KOMARI_SERVER=https://你的komari域名 KOMARI_TOKEN=你的token PORT=3000 DOMAIN=你的域名 \
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
订阅节点改为 security=tls，加了 allowInsecure=1（ss 原本就带 skip-cert-verify     
有正式证书的话可以用 TLS_CERT、TLS_KEY 指定，填文件路径或 PEM 内容都行，这时不会加跳过验证的参数      
要知道的   

自签证书能加密，但客户端会跳过证书验证，安全性比正式证书低一点    
想要正式证书又不改代码的话，可以用 Cloudflare：域名开橙云解析到 分配的IP，SSL 设为 Flexible，再加一条 Origin Rule 把端口改写成 分配的端口，然后 DOMAIN 填这个域名、不开 TLS。这样节点就是域名:443 加正式证书，还能把 IP 藏起来   

Cloudflare 回源到 部署平台   
下面用 nos.indevs.in 举例，子域名可以随便取。   

1. DNS   

添加 A 记录：名称 nos，IPv4 (分配的IP)，打开橙色云朵（已代理）   
2. 源服务器规则     
  
规则名随便填   
自定义筛选表达式：字段选「主机名」，运算符选「等于」，值填 nos.indevs.in    
下面「目标端口」选「重写为」，填 分配的端口    
部署   
3. 配置规则（同一个创建规则菜单里）   

筛选条件和上一步一样：主机名等于 nos.indevs.in    
找到「SSL」，添加后选「灵活」   
部署   
这样只有这个子域名用灵活模式，不影响你域名下的其他站    
4. 平台变量   
 
DOMAIN=nos.indevs.in   
把 TLS=true 去掉（证书由 Cloudflare 提供，本程序不需要再做加密）   
重启后用 nos.indevs.in/sub 取订阅，节点会变成 nos.indevs.in:443，走 tls   
注意  

在「网络」设置里确认 WebSockets 是打开的（默认就是开的）   
节点里的地址可以换成优选 IP或优选域名，SNI 和 host 保持 nos.indevs.in 就行   


cloudflare Workers 反代
```
export default {
    async fetch(request, env) {
        let url = new URL(request.url);
        if (url.pathname.startsWith('/')) {
            var arrStr = [
                '', // 此处单引号里填写你的节点伪装域名
            ];
            url.protocol = 'https:'
            url.hostname = getRandomArray(arrStr)
            let new_request = new Request(url, request);
            return fetch(new_request);
        }
        return env.ASSETS.fetch(request);
    },
};
function getRandomArray(array) {
  const randomIndex = Math.floor(Math.random() * array.length);
  return array[randomIndex];
}
```
