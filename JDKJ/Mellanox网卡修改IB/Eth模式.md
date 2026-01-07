
### 修改网卡模式的简单命令

```shell
apt update
apt-get install mft kernel-mft-modules
mst start
mst status
ip add   #确定修改哪个网口
mlxconfig -d /dev/mst/mt4123_pciconf0  q|grep LINK      #查看网口状态
mlxconfig -d /dev/mst/mt4123_pciconf0 set LINK_TYPE_P1=2       #P1=1 是IB模式；P1=2是以太网模式
y
sync
reboot
重启生效

```



### 实际修改过程
```shell


root@zhwh-gpu02:~# apt-get install mft kernel-mft-modules
root@zhwh-gpu02:~# mst start
Starting MST (Mellanox Software Tools) driver set
Loading MST PCI module - Success
Loading MST PCI configuration module - Success
Create devices
Unloading MST PCI module (unused) - Success
root@zhwh-gpu02:~#
root@zhwh-gpu02:~#
root@zhwh-gpu02:~# mst status
MST modules:
------------
    MST PCI module is not loaded
    MST PCI configuration module loaded

MST devices:
------------
/dev/mst/mt4123_pciconf0         - PCI configuration cycles access.
                                   domain:bus:dev.fn=0000:10:00.0 addr.reg=88 data.reg=92 cr_bar.gw_offset=-1
                                   Chip revision is: 00
/dev/mst/mt4123_pciconf1         - PCI configuration cycles access.
                                   domain:bus:dev.fn=0000:82:00.0 addr.reg=88 data.reg=92 cr_bar.gw_offset=-1
                                   Chip revision is: 00
/dev/mst/mt4123_pciconf2         - PCI configuration cycles access.
                                   domain:bus:dev.fn=0000:d1:00.0 addr.reg=88 data.reg=92 cr_bar.gw_offset=-1
                                   Chip revision is: 00

root@zhwh-gpu02:~#
root@zhwh-gpu02:~# ip addr
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000
    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
    inet 127.0.0.1/8 scope host lo
       valid_lft forever preferred_lft forever
    inet6 ::1/128 scope host
       valid_lft forever preferred_lft forever
2: enp97s0f0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether e8:61:1f:5c:9b:8c brd ff:ff:ff:ff:ff:ff
    inet 10.30.23.25/24 brd 10.30.23.255 scope global enp97s0f0
       valid_lft forever preferred_lft forever
    inet6 fe80::ea61:1fff:fe5c:9b8c/64 scope link
       valid_lft forever preferred_lft forever
3: enp97s0f1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc mq state UP group default qlen 1000
    link/ether e8:61:1f:5c:9b:8d brd ff:ff:ff:ff:ff:ff
    inet6 fe80::ea61:1fff:fe5c:9b8d/64 scope link
       valid_lft forever preferred_lft forever
4: ibp16s0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 4092 qdisc mq state DOWN group default qlen 256
    link/infiniband 00:00:01:46:fe:80:00:00:00:00:00:00:58:a2:e1:03:00:44:0a:88 brd 00:ff:ff:ff:ff:12:40:1b:ff:ff:00:00:00:00:00:00:ff:ff:ff:ff
5: ibp130s0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 4092 qdisc mq state DOWN group default qlen 256
    link/infiniband 00:00:03:82:fe:80:00:00:00:00:00:00:58:a2:e1:03:00:44:08:64 brd 00:ff:ff:ff:ff:12:40:1b:ff:ff:00:00:00:00:00:00:ff:ff:ff:ff
6: ibs38: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 4092 qdisc mq state DOWN group default qlen 256
    link/infiniband 00:00:0b:a2:fe:80:00:00:00:00:00:00:58:a2:e1:03:00:44:01:fc brd 00:ff:ff:ff:ff:12:40:1b:ff:ff:00:00:00:00:00:00:ff:ff:ff:ff
    altname ibp209s0
7: docker0: <NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc noqueue state DOWN group default
    link/ether 02:42:8a:a0:5b:23 brd ff:ff:ff:ff:ff:ff
    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0
       valid_lft forever preferred_lft forever


root@zhwh-gpu02:~#
root@zhwh-gpu02:~# mst status
MST modules:
------------
    MST PCI module is not loaded
    MST PCI configuration module loaded

MST devices:
------------
/dev/mst/mt4123_pciconf0         - PCI configuration cycles access.
                                   domain:bus:dev.fn=0000:10:00.0 addr.reg=88 data.reg=92 cr_bar.gw_offset=-1
                                   Chip revision is: 00
/dev/mst/mt4123_pciconf1         - PCI configuration cycles access.
                                   domain:bus:dev.fn=0000:82:00.0 addr.reg=88 data.reg=92 cr_bar.gw_offset=-1
                                   Chip revision is: 00
/dev/mst/mt4123_pciconf2         - PCI configuration cycles access.
                                   domain:bus:dev.fn=0000:d1:00.0 addr.reg=88 data.reg=92 cr_bar.gw_offset=-1
                                   Chip revision is: 00


root@zhwh-gpu02:~# mlxconfig -d /dev/mst/mt4123_pciconf0  q|grep LINK
         PHY_COUNT_LINK_UP_DELAY             DELAY_NONE(0)
         LINK_TYPE_P1                        IB(1)
         KEEP_ETH_LINK_UP_P1                 True(1)
         KEEP_IB_LINK_UP_P1                  False(0)
         KEEP_LINK_UP_ON_BOOT_P1             False(0)
         KEEP_LINK_UP_ON_STANDBY_P1          False(0)
         AUTO_POWER_SAVE_LINK_DOWN_P1        False(0)
         UNKNOWN_UPLINK_MAC_FLOOD_P1         False(0)
root@zhwh-gpu02:~# mlxconfig -d /dev/mst/mt4123_pciconf0 set LINK_TYPE_P1=2

Device #1:
----------

Device type:    ConnectX6
Name:           MCX653105A-ECA_Ax
Description:    ConnectX-6 VPI adapter card; 100Gb/s (HDR100; EDR IB and 100GbE); single-port QSFP56; PCIe3.0 x16; tall bracket; ROHS R6
Device:         /dev/mst/mt4123_pciconf0

Configurations:                              Next Boot       New
         LINK_TYPE_P1                        IB(1)           ETH(2)

 Apply new Configuration? (y/n) [n] : y
Applying... Done!
-I- Please reboot machine to load new configurations.


root@zhwh-gpu02:~# mlxconfig -d /dev/mst/mt4123_pciconf1 set LINK_TYPE_P1=2

Device #1:
----------

Device type:    ConnectX6
Name:           MCX653105A-ECA_Ax
Description:    ConnectX-6 VPI adapter card; 100Gb/s (HDR100; EDR IB and 100GbE); single-port QSFP56; PCIe3.0 x16; tall bracket; ROHS R6
Device:         /dev/mst/mt4123_pciconf1

Configurations:                              Next Boot       New
         LINK_TYPE_P1                        IB(1)           ETH(2)

 Apply new Configuration? (y/n) [n] : y
Applying... Done!
-I- Please reboot machine to load new configurations.


root@zhwh-gpu02:~# mlxconfig -d /dev/mst/mt4123_pciconf2 set LINK_TYPE_P1=2

Device #1:
----------

Device type:    ConnectX6
Name:           MCX653105A-ECA_Ax
Description:    ConnectX-6 VPI adapter card; 100Gb/s (HDR100; EDR IB and 100GbE); single-port QSFP56; PCIe3.0 x16; tall bracket; ROHS R6
Device:         /dev/mst/mt4123_pciconf2

Configurations:                              Next Boot       New
         LINK_TYPE_P1                        IB(1)           ETH(2)

 Apply new Configuration? (y/n) [n] : y
Applying... Done!
-I- Please reboot machine to load new configurations.
root@zhwh-gpu02:~# sync
root@zhwh-gpu02:~# reboot
root@zhwh-mg01:~#
===========================================

```