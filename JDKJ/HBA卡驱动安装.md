### 针对 QLogic 的HBA网卡安装驱动

```shell
# 在服务器查找网卡信息
root@Node1:~# lspci -vvv |grep -i QLogic
3b:00.0 Fibre Channel: QLogic Corp. ISP8324-based 16Gb Fibre Channel to PCI Express Adapter (rev 02)
        Subsystem: QLogic Corp. ISP8324-based 16Gb Fibre Channel to PCI Express Adapter
                Product Name: QLogic QLE2662 Dual Port FC16 HBA
3b:00.1 Fibre Channel: QLogic Corp. ISP8324-based 16Gb Fibre Channel to PCI Express Adapter (rev 02)
        Subsystem: QLogic Corp. ISP8324-based 16Gb Fibre Channel to PCI Express Adapter
                Product Name: QLogic QLE2662 Dual Port FC16 HBA
root@Node1:~#
# 确认卡型号是 QLogic QLE2662
```

```shell
# 下载驱动
https://www.marvell.com/support/downloads.html#

选择 QLE2670的 #因为2662已经不支持
选择 OS是 linux； TYPE是 Drivers
选择 日期 老一点的2023年的版本。#老版本更加可能支持2662，同时不能太老，太老的与系统的本身匹配关系不好会导致安装失败
例如我最终选择的是： qla2xxx-src-v10.02.09.00-k.tar.gz
```

```shell
# 安装驱动程序
安装.tar.gz格式的源码包步骤 
a. 执行“tar –zxvf qla2xxx-src--.tar.gz命令解压源码包。 
b. 执行“cd qla2xxx-/”命令进入源码包目录。 
c. 在源代码解压后的根目录执行“./extras/build.sh initrd”命令进行编译安装 
d. 驱动安装完成后，重启系统
```

```shell
# 检查确认驱动版本
root@Node1:~# modinfo qla2xxx |grep version
version:        10.02.09.00-k
srcversion:     5B59590F48834B15BBB16A3
vermagic:       5.15.0-60-generic SMP mod_unload modversions
root@Node1:~#

```

```shell
查看当前port的状态
[root@localhost ~]#cat  /sys/class/fc_host/host*/port_state
Online

查看wwwn
root@Node1:~# more /sys/class/fc_host/host*/port_name
::::::::::::::
/sys/class/fc_host/host16/port_name
::::::::::::::
0x2001000e1ee97883
::::::::::::::
/sys/class/fc_host/host7/port_name
::::::::::::::
0x2001000e1ee97882
root@Node1:~#
```
