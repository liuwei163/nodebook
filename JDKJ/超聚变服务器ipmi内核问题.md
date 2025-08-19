1. 超聚变服务器安装完系统推完服务后会发现ipmi内核没有自动启用的。执行查看ipmitool的，命令会失败.
```shell
[root@Al1Huadatest ~]# ipmitool lan print

Get Channel Info command failed
Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0: No such file or directory
Get Channel Info command failed
Invalid channel: 0
[root@Al1Huadatest ~]#
```

2. 在web界面查看 节点-》列表--》节点箭头  发现报错
```shell
"[SSHRemoteCmd] stderr: Failed to run ipmitool lan print: Could not open device at /dev/ipmi0 or /dev/ipmi/0 or /dev/ipmidev/0: No such file or 
....
: 0\n\n . commond run err: Process exited with status 1 ."
```

3. 解决方法- 手动启用内核.重启后会失效
```shell
[root@Al1Huadatest ~]# modprobe ipmi_devintf
[root@Al1Huadatest ~]# modprobe ipmi_si
[root@Al1Huadatest ~]# ipmitool lan print 1
Set in Progress         : Set Complete
IP Address Source       : Static Address
IP Address              : 10.61.52.184
Subnet Mask             : 255.255.255.0
MAC Address             : 34:73:79:11:0e:5f
SNMP Community String   :
IP Header               : TTL=0x40 Flags=0x40 Precedence=0x00 TOS=0x10
Default Gateway IP      : 10.61.52.254
802.1q VLAN ID          : Disabled
RMCP+ Cipher Suites     : 0,1,2,3,17
Cipher Suite Priv Max   : XuuaXXXXXXXXXXX
                        :     X=Cipher Suite Unused
                        :     c=CALLBACK
                        :     u=USER
                        :     o=OPERATOR
                        :     a=ADMIN
                        :     O=OEM
[root@Al1Huadatest ~]#
```

4. 解决方法-内核添加自启动
```shell
[root@Al1Huadatest ~]# vim /etc/modules-load.d/ipmi.conf
ipmi_devintf
ipmi_si
[root@Al1Huadatest ~]# reboot
```

