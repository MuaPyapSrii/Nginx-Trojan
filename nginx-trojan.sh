#!/bin/sh

if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: This script must be run as root!" 1>&2
    exit 1
fi

timedatectl set-timezone Asia/Taipei
v2path=$(cat /dev/urandom | head -1 | md5sum | head -c 12)
v2uuid=$(cat /proc/sys/kernel/random/uuid)

install_precheck(){
    echo "====Input trojan domain===="
    read domain
    echo "=====Input web domain======"
    read domainn
    
    if [ -f "/usr/bin/apt-get" ]; then
        apt-get update -y
        apt-get install -y net-tools curl
    else
        yum update -y
        yum install -y epel-release
        yum install -y net-tools curl
    fi

    sleep 3
    isPort=`netstat -ntlp| grep -E ':80 |:443 '`
    if [ "$isPort" != "" ];then
        clear
        echo " ================================================== "
        echo " 80 or 443 port is occupied"
        echo
        echo " info："
        echo $isPort
        echo " ================================================== "
        exit 1
    fi
}

install_nginx(){
    if [ -f "/usr/bin/apt-get" ];then
        apt-get install -y nginx
    else
        yum install -y nginx
    fi

cat >/etc/nginx/nginx.conf<<EOF
user www-data;
pid /var/run/nginx.pid;
worker_processes auto;
worker_rlimit_nofile 51200;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    multi_accept on;
    use epoll;
}
stream { 
# 这里就是 SNI 识别，将域名映射成一个配置名
  map \$ssl_preread_server_name \$backend_name { 
    $domainn web;
# Trojan 流量直接转发到中间层：proxy_trojan
    $domain trojan; 
# 域名都不匹配情况下的默认值 
    default web; 
  } 
# web，配置转发详情
#  upstream proxy_web {
#    server 127.0.0.1:10250;
#  } 
#  server {
#    listen 10250 proxy_protocol;
#    proxy_pass  web;
#  }   
  upstream web { 
    server 127.0.0.1:10240; 
  } 
# 这里的 server 就是用来帮 Trojan 卸载代理协议的中间层
#  upstream proxy_trojan {
#    server 127.0.0.1:10249;
#  } 
#  server {
#    listen 10249 proxy_protocol;
#    proxy_pass  trojan;
#  }  
# trojan，配置转发详情
  upstream trojan { 
    server 127.0.0.1:10241;
  } 

# 监听 443 并开启 ssl_preread
  server { 
    listen 443 reuseport; 
    listen [::]:443 reuseport; 
    proxy_pass \$backend_name;
#    proxy_protocol on; 
    ssl_preread on; 
  }
}
http {
server {
    listen 10240 ssl http2;
    server_name $domainn;  
    
    ssl_certificate       /etc/letsencrypt/live/$domainn/server.crt; 
    ssl_certificate_key   /etc/letsencrypt/live/$domainn/server.key;
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_session_tickets off;

    ssl_protocols         TLSv1.2 TLSv1.3;
    ssl_ciphers           ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;

    gzip on;
    gzip_http_version 1.1;
    gzip_vary on;
    gzip_comp_level 6;
    gzip_proxied any;
    gzip_types text/plain text/css application/json application/javascript application/x-javascript text/javascript;
    
    location / {
        proxy_pass https://www.bing.com; #伪装网址
        proxy_ssl_server_name on;
        proxy_redirect off;
        sub_filter_once off;
        sub_filter "www.bing.com" \$server_name;
        proxy_set_header Host "www.bing.com";
        proxy_set_header Referer \$http_referer;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header User-Agent \$http_user_agent;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Accept-Encoding "";
        proxy_set_header Accept-Language "zh-CN";
    }
    
    location = /$v2path  {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}

server {
    listen 80;
    server_name $domainn;    
    rewrite ^(.*)$ https://\${server_name}\$1 permanent;
}
}
EOF
}

acme_ssl(){    
    apt-get -y install cron socat || yum -y install cronie socat
    curl https://get.acme.sh | sh
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    mkdir -p /etc/letsencrypt/live/$domain
    mkdir -p /etc/letsencrypt/live/$domainn
    ~/.acme.sh/acme.sh --issue -d $domain --standalone --keylength ec-256 --pre-hook "systemctl stop nginx" --post-hook "~/.acme.sh/acme.sh --installcert -d $domain --ecc --fullchain-file /etc/letsencrypt/live/$domain/server.crt --key-file /etc/letsencrypt/live/$domain/server.key --reloadcmd \"systemctl restart nginx\""
    ~/.acme.sh/acme.sh --issue -d $domainn --standalone --keylength ec-256 --pre-hook "systemctl stop nginx" --post-hook "~/.acme.sh/acme.sh --installcert -d $domainn --ecc --fullchain-file /etc/letsencrypt/live/$domainn/server.crt --key-file /etc/letsencrypt/live/$domainn/server.key --reloadcmd \"systemctl restart nginx\""
}

install_v2ray(){
    bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh) 
    
cat >/usr/local/etc/v2ray/config.json<<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/v2ray/access.log", 
    "error": "/var/log/v2ray/error.log"
  },
  "inbounds": [
    {
      "port": 8388, 
      "protocol": "vmess",    
      "settings": {
        "clients": [
          {
            "id": "$v2uuid",  
            "alterId": 0
          }
        ]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",  
      "settings": {}
    }
  ]
}
EOF

    systemctl enable v2ray.service && systemctl restart v2ray.service
    rm -f nginx-trojan.sh install-release.sh

    clear
}


client_V2ray(){
    echo
    echo "Completed"
    echo
    echo "===========V2ray============"
    echo "UUID：${v2uuid}"
    echo
}




client_Trojan(){
    echo
    echo "Completed"
    echo
    echo "===========Trojan+Nginx============"
    echo "Trojan Domain：${domainn}"
    echo "Trojan Pass：${pass}"
    echo "Nginx WS Path：${v2path}"
    echo
}



install_trojan-go(){
    wget https://github.com/p4gefau1t/trojan-go/releases/download/v0.10.6/trojan-go-linux-amd64.zip
    apt install unzip
    unzip -o trojan-go-linux-amd64.zip -d /usr/local/bin/trojan-go
    rm trojan-go-linux-amd64.zip
    pass=$(openssl rand -base64 16)

    

cat >/usr/local/bin/trojan-go/config.json<<EOF
{
    "run_type": "server",
    "local_addr": "127.0.0.1",
    "local_port": 10241,
    "remote_addr": "127.0.0.1",
    "remote_port": 80,
    "log_level": 1,
    "log_file": "/usr/local/bin/trojan-go/trojan-go.log",
    "password": [
        "$pass"
    ],
    "ssl": {
        "cert": "/etc/letsencrypt/live/$domain/server.crt",
        "key": "/etc/letsencrypt/live/$domain/server.key"
    }
}
EOF

cat >/etc/systemd/system/trojan-go.service<<EOF

[Unit]
Description=Trojan-Go - An unidentifiable mechanism that helps you bypass GFW
Documentation=https://github.com/p4gefau1t/trojan-go
After=network.target nss-lookup.target
[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin/trojan-go
ExecStart=/usr/local/bin/trojan-go/trojan-go -config /usr/local/bin/trojan-go/config.json
Restart=on-failure
RestartSec=10
RestartPreventExitStatus=23
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable trojan-go.service && systemctl restart trojan-go.service
    cd ..
    rm -f nginx-trojan.sh install-release.sh
    
    clear
}

client_Tuic(){
    echo
    echo "Completed"
    echo
    echo "===========Tuic============"
    echo "Token：${pass}"
    echo
}

install_tuic(){
    mkdir /usr/local/bin/tuic && cd /usr/local/bin/tuic
    wget https://github.com/EAimTY/tuic/releases/download/0.8.5/tuic-server-0.8.5-x86_64-linux-gnu
    chmod +x tuic-server-0.8.5-x86_64-linux-gnu
    pass=$(openssl rand -base64 16)
    
cat >/usr/local/bin/tuic/config.json<<EOF
{
    "port": 443,
    "token": ["$pass"],
    "certificate": "/etc/letsencrypt/live/$domain/server.crt",
    "private_key": "/etc/letsencrypt/live/$domain/server.key",
    "ip": "0.0.0.0",
    "congestion_controller": "bbr",
    "alpn": ["h3"]
}
EOF

cat >/etc/systemd/system/tuic.service<<EOF
[Unit]
Description=Delicately-TUICed high-performance proxy built on top of the QUIC protocol
Documentation=https://github.com/EAimTY/tuic
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin/tuic
ExecStart=/usr/local/bin/tuic/tuic-server-0.8.5-x86_64-linux-gnu -c config.json
Restart=on-failure
RestartPreventExitStatus=1
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable tuic.service && systemctl restart tuic.service
    cd ..
    rm -f nginx-trojan.sh install-release.sh
}


start_menu(){
    clear
    echo " ================================================== "
    echo "     Install Nginx+Trojan sni Stream or V2ray       "
    echo " ================================================== "
    echo
    echo " 1. nginx+trojan"
    echo " 2. v2ray"
    echo " 3. tuic"
    echo " 0. Exit"
    echo
    read -p "Please Input:" num
    case "$num" in
    1)
    install_precheck
    install_nginx
    acme_ssl
    install_trojan-go
    client_Trojan
    ;;
    2)
    install_v2ray
    client_V2ray
    ;;
    3)
    install_tuic
    client_Tuic
    ;;
    0)
    exit 1
    ;;
    *)
    clear
    echo "Please Input Num"
    sleep 2s
    start_menu
    ;;
    esac
}

start_menu
