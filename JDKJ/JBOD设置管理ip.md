### 修改jbod的管理ip

1. 查询jbod的Device "wddcs show"
2. 修改对应的管理ip "wddcs /dev/sg3 iom oobm=A,10.49.34.67,255.255.255.0,10.49.34.247"
3. 查询修改结果 "wddcs iom oobm"


示例：
```shell
[root@Al5Jdfshg102 ~]# wddcs show
wddcs v3.0.5.0
Copyright (c) 2019-2022 Western Digital Corporation or its affiliates

Device: /dev/sg3
    product : H4060-J
    serial  : THCCT02423EZ0029
    firmware: 4008-020
    name    : Ultrastar Data60

Device: /dev/sg61
    product : H4060-J
    serial  : THCCT02423EZ0016
    firmware: 4008-020
    name    : Ultrastar Data60

[root@Al5Jdfshg102 ~]# wddcs /dev/sg3 iom oobm=A,10.49.34.67,255.255.255.0,10.49.34.247
wddcs v3.0.5.0
Copyright (c) 2019-2022 Western Digital Corporation or its affiliates

Device: /dev/sg3
Command to set new OOBM values was successful

[root@Al5Jdfshg102 ~]# wddcs /dev/sg3 iom oobm=B,10.49.34.68,255.255.255.0,10.49.34.247
wddcs v3.0.5.0
Copyright (c) 2019-2022 Western Digital Corporation or its affiliates

Device: /dev/sg3
Command to set new OOBM values was successful

[root@Al5Jdfshg102 ~]# wddcs /dev/sg61 iom oobm=A,10.49.34.69,255.255.255.0,10.49.34.247
wddcs v3.0.5.0
Copyright (c) 2019-2022 Western Digital Corporation or its affiliates

Device: /dev/sg61
Command to set new OOBM values was successful

[root@Al5Jdfshg102 ~]# wddcs /dev/sg61 iom oobm=B,10.49.34.70,255.255.255.0,10.49.34.247
wddcs v3.0.5.0
Copyright (c) 2019-2022 Western Digital Corporation or its affiliates

Device: /dev/sg61
Command to set new OOBM values was successful

[root@Al5Jdfshg102 ~]# 
[root@Al5Jdfshg102 ~]# 
[root@Al5Jdfshg102 ~]# 
[root@Al1Jdfshg102 ~]#wddcs iom oobm
wddcs v3.0.5.0
Copyright (c) 2019-2022 Western Digital Corporation or its affiliates

Device: /dev/sg3
    IOM A   : static (0)
    IP      : 10.49.34.67
    Netmask : 255.255.255.0
    Gateway : 10.49.34.247
    OOBM FW : 4.0.31
    MAC     : 00:0C:CA:08:21:2B

Device: /dev/sg61
    IOM A   : static (0)
    IP      : 10.49.34.69
    Netmask : 255.255.255.0
    Gateway : 10.49.34.247
    OOBM FW : 4.0.31
    MAC     : 00:0C:CA:08:21:29

[root@Al1Jdfshg102 ~]#
```
