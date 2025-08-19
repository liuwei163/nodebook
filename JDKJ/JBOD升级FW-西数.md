wddcs iom oobm    #查看IO主控板
wddcs show        #查看JBOD的型号SN，固件版本。


### 检查JBOD是否正常连接
 sg_scan -i | grep -i 4060 -B 1



### 日志收集
 wddcs getlog all


### 下载固件
 https://portal.wdc.com/Support/s/



### 查看控制器固件以及OOBM的版本
 wddcs <device> rcli "show enc"



## 升级固件
 ##如果SEP的FW版本是 pre-4xxx-0xx 之前的版本则需要升级过度版本。
 #在FW包括 2024之前的版本升级到最新版本都要先升级到4008-020版本。
 #一次只能升级一个机柜
 #注意：固件升级大约需要一个小时
 #执行升级
  ./Ultrastar_Data60_102_FWUpdate -f HGST_Ultrastar-DATA60-DATA102-Server60-8_SEP_bundle_<FW Version>.tar.gz
  wddcs rcli "show enc"



### 固件同步
 #固件版本3000-058引入了自动同步功能
 #单个IOM更换
  从已通电的机柜中卸下一个IOM，或仅用一个IOM启动机柜后，已安装IOM上的固件（如果是v3或更高版本）将占主导地位。如果第二个IOM具有不同的固件机柜将检测到不匹配，并升级或降级其上的固件，使第二个IOM与第一个个IOM匹配。
 #双IOM更换
  在启动装有两个IOM的机柜后，IOM固件的最高版本将变为主节点地位，另一个IOM上的固件将升级为主节点版本。
  功能要求
   主要IOM必须运行SEP固件版本3xxx或更高版本，以及OOBM固件3.x.x或更高。此固件捆绑包统称为“v3”。
 #检查自动同步是否开启 
   sg_modes <dev> --page=0x20 --llbaa
   粗体 08 代表启用了

### 使用wwdcs 升级FW
1. wddcs /dev/sg7 fw download_activate HGST_Ultrastar-DATA60-DATA102-Server60-8_SEP_bundle_3010-007_3.1.11.tar.gz 
升级完成后，需要等待15分钟然后输入Y ，JBOD 会自动重启。


## HGST JBOD 兼容KIOXIA SAS SSD
### 升级FW 版本，从3010先升级到4T16，然后再升级到4008
1. wddcs /dev/sg4 fw download_activate HGST_Ultrastar-DATA60-DATA102-Server60-8_SEP_bundle_4T16-017_3.1.12.tar.gz
2.  wddcs /dev/sg4 fw download_activate HGST_Ultrastar-DATA60-DATA102-Server60-8_SEP_bundle_4008-020_4.0.31.tar.gz
3. 升级sg3_utils 到1.44
### 设置JBOD bit
4. sg_wr_mode /dev/sg4 --dbd -s --page=0x20 --contents=A0,0E,01,00,00,00,00,00,00,00,00,00,00,00,04,00 --mask=A0,0E,01,00,00,00,00,00,00,00,00,00,00,00,04,00
### 查看设置信息
5. sg_wr_mode /dev/sg4 --dbd -s --page=0x20
### 重启JBOD
6. wddcs /dev/sg4 diag reset-enc



### 升级过程
1. 停止服务
     过程和更换JBOD一样
     
2. 获取enclosure 对应的sg 设备
    lsscsi -sg|grep en 

3. 执行升级
    wddcs /dev/sg4 fw download_activate HGST_Ultrastar-DATA60-DATA102-Server60-8_SEP_bundle_3010-007_3.1.11.tar.gz
  * 双控节点 只需要在其中一个节点执行就可以
  * 如果有多个jbod 需要 开启多个窗口 同时升级
  * 大概需要几分钟 需要y 确认 ，然后等待15分钟后，jbod 自动重启
4. 确认fw 是否正确
    wddcs show
