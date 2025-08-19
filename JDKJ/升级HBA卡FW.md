
### 查看HBA卡的ctl号
```shell
[root@Al1Jidaofshg1 ~]# /opt/MegaRAID/storcli/storcli64 show
CLI Version = 007.2405.0000.0000 Sep 28, 2022
Operating system = Linux 3.10.0-514.26.2.el7.x86_64
Status Code = 0
Status = Success
Description = None

Number of Controllers = 1
Host Name = Al1Jidaofshg1
Operating System  = Linux 3.10.0-514.26.2.el7.x86_64
StoreLib IT Version = 07.2403.0200.0000
StoreLib IR3 Version = 16.14-0

IT System Overview :
==================

--------------------------------------------------------------------------
Ctl Model       AdapterType   VendId DevId SubVendId SubDevId PCI Address 
--------------------------------------------------------------------------
  0 HBA 9500-8e   SAS3808(A0) 0x1000  0xE6    0x1000   0x4080 00:8a:00:00 
--------------------------------------------------------------------------
```

### 检查FW版本
```shell
[root@Al1Jidaofshg1 ~]# /opt/MegaRAID/storcli/storcli64 /c0 show|grep FW
FW Package Build = 14.00.00.00
FW Version = 14.00.00.00
[root@Al1Jidaofshg1 ~]#
#/c0 代表Ctl号为0的HBA卡
```

### 指定FW文件进行升级
```shell
[root@Al1Jidaofshg1 ~]# /opt/MegaRAID/storcli/storcli64 /c0 download file=HBA_9500-8e_Mixed_Profile.bin 
Downloading image.Please wait...

CLI Version = 007.2405.0000.0000 Sep 28, 2022
Operating system = Linux 3.10.0-514.26.2.el7.x86_64
Controller = 0
Status = Success
Description = CRITICAL! Flash successful. Please power cycle the system for the changes to take effect
[root@Al1Jidaofshg1 ~]# 
```