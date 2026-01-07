### 安装系统报错

发现有一个USB0的网卡，自动获取地址 导致 pxe系统失败

![alt text](26be1878a13aead53e8491007591e6e.png)


### 解决方法

登录web  ipmi
configuration ==》 BMC Settings ==> Host Interface  ==> enable
关闭这个功能，选择 OFF

![alt text](3c743d24bb7127d646d47b6bc737504.jpg)

