### 西数
#### Centos系统
1. 安装升级工具
```
[root@Al1Dst ~]# rpm -ivh hugo-7.4.5.x86_64.rpm
Preparing...                          ################################# [100%]
Updating / installing...
   1:hugo-7.4.5-1                     ################################# [100%]
[root@Al1Dst ~]#
```
2. 通过lsscsi -sg 命令获取磁盘型号，第四列是磁盘的型号
```
[2:0:177:0]  disk    WDC      WUH721816AL5204  C240  /dev/sdfq  /dev/sg179  16.0TB
```
3. 根据常用BOM 表中，找到上面磁盘型号的FW版本，然后找到对应的FW 文件

4. 使用命令hugo 进行升级。双控在磁盘init之前，可以在pair 其中一个节点上进行升级，如果init完成了，需要在pair两个节点上升级，因为非owner节点的磁盘，升级会失败，单控需要在所有节点上进行升级

5. 批量升级
   ```
   hugo update -m  WUH721816AL5204 -f PCGSC240.bin
   ```
   * 确认所有磁盘升级成功，然后重启机器，新版本FW生效  重启JBOD
    [root@Al1Dst ~]# wddcs /dev/sg4 diag reset-enc

6. 单块磁盘升级
   * 通过smarctl 获取需要升级磁盘的SN码
   ```
   [root@Al1Dst ~]# smartctl -a /dev/sdfu|grep "Serial number"
   Serial number:        2CHN6MEL
   [root@Al1Dst ~]#
   ```
   * 进行升级
 
   ```
   hugo update -s 2CHN6MEL -f PCGSC240.bin
   ```
   * 升级成功后，可以尝试重新插拔当前磁盘，新版本FW生效


#### ubuntu统下使用新工具
   ```shell
     单盘升级
     root@Al1Xtao:~# wdckit update /dev/sdbd -f V8GNC460.bin
     wdckit Version 2.16.0.0
     Copyright (C) 2019-2023 Western Digital Technologies, Inc.
     Western Digital ATA/SCSI/NVMe command line utility.
     02/27/2024 11:26:51

     Update on 1 device(s) started...
     Progress: 100%
     Success: Update completed on: VYH465MM
     Device     Serial Number  FW File       Update Status
     ---------  -------------  ------------  ------------------------
     /dev/sdbd  VYH465MM       V8GNC460.bin  Download was successful.

     root@Al1Xtao:~#
     批量升级硬盘
     wdckit update --model HUS728T8TAL5204 -f V8GNC460.bin
     wdckit update all -f V8GNC460.bin   #对所有硬盘进行固件升级（正如该网友所说的，“不支持的盘是刷不进去的，不必担心刷错变砖”，其他盘会报 Failure 不升级，所以直接 all 就行）
     wdckit show  #就能看到固件已经顺利更新了

     重启JBOD 
     wddcs /dev/sg4 diag reset-enc
   ```




   ### 东芝
8. 安装升级工具
      ```
      su root
      chmod +x install-lin-toshiba-01_rel-tsbdrv-13.00.5671.x64.bin
      ./ install-lin-toshiba-01_rel-tsbdrv-13.00.5671.x64.bin
      A
      Y
      1
      N
      ```
9.  通过lsscsi -sg 命令获取磁盘型号，第六列是磁盘的编号
     ```
    [2:0:177:0]  disk    TOSHIBA      MG08SCA16TE  C0105  /dev/sdP  /dev/sg179  16.0TB
    ```
10. 单块磁盘升级
   ```
   tsbdrv firmware download  /dev/sdp ra010120.ftd
   Y
   ```
11. 重新插拔硬盘，使新FW版本生效。



