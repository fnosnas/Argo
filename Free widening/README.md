# 运行前要做的事:  
1. 域名的 A 记录要先指向 VPS 的 IP。
2. VPS 必须是 KVM 并开启 TUN，云厂商安全组要放行 TCP 80 和 443。Caddy 申请证书需要用到 80。
3. 如果域名在 Cloudflare 上开了小云朵，SSL/TLS 模式要选 Full，不要选 Flexible。第一次申请证书时，建议先把它设成灰云（仅 DNS），等装好再开。



 VPS 上的一键命令（root 用户，把域名换成你自己的）：  
```
DOMAIN=你的域名 bash <(curl -Ls "https://raw.githubusercontent.com/fnosnas/Argo/main/Free%20widening/install.sh")
```
