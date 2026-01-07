### Ubuntu 代理上网配置

### 在可以上网的机器配置代理服务端
```shell
##测试网络
root@Al1Newalk:~# ping www.baidu.com
PING www.a.shifen.com (39.156.66.14) 56(84) bytes of data.
64 bytes from 39.156.66.14 (39.156.66.14): icmp_seq=1 ttl=45 time=4.82 ms
^C
##检查提供服务的网卡ip地址

##安装服务
root@Al1Newalk:~# apt install squid
root@Al1Newalk:~# apt install apache2-utils
root@Al1Newalk:~#
##创建测试代理用户名密码
root@Al1Newalk:~# mkdir /etc/squid3/
root@Al1Newalk:~# htpasswd -cd /etc/squid3/passwords xtao
New password:     #输入nasadmin
Re-type new password:     #再次输入密码nasadmin
Adding password for user xtao
root@Al1Newalk:~#
root@Al1Newalk:~# /usr/lib/squid/basic_ncsa_auth /etc/squid3/passwords   #用于验证用户名密码是否生效
xtao nasadmin     #显示是空白。手动输入用户名 空格 密码
OK                #显示ok 则代表用户密码正确。crtl + c 退出
##修改配置文件
vim /etc/squid/squid.conf
# 在最后添加
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid3/passwords
auth_param basic realm proxy
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
#*可以修改http_access deny all为http_access allow all
:wq
##启动服务
root@Al1Newalk:~# systemctl start squid
root@Al1Newalk:~# systemctl enable squid
root@Al1Newalk:~# systemctl restart squid
root@Al1Newalk:~# systemctl status squid

```

### 客户端配置
```shell
## 新建配置文件
root@Al1Cgris:~# vim /etc/profile.d/proxy.sh
#PROXY_URL="http://proxy_server_ip:3128/"
PROXY_URL="http://10.61.152.:3128/"

# 添加不需要走代理的地址
NO_PROXY_ADDR="127.0.0.1,localhost,.local,.cluster.local,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

# 添加的代理
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export no_proxy="$NO_PROXY_ADDR"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export NO_PROXY="$NO_PROXY_ADDR"
:wq

## 启用配置文件
root@Al1Cgris:~# source /etc/profile.d/proxy.sh

## 测试
root@Al1Cgris:~# curl www.baidu.com
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
<html><head>
<meta type="copyright" content="Copyright (C) 1996-2020 The Squid Software Foundation and contributors">
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<title>ERROR: The requested URL could not be retrieved</title>
<style type="text/css"><!--

```