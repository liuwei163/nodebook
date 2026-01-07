cat  /usr/local/bin/lldp

#!/bin/bash

systemctl start lldpad.service
lldpad -d

# 初始化 LLDP 配置
for i in $(ifconfig | awk -F'[ :]+' '!NF{if(eth!=""&&ip=="")print eth;eth=ip4=""}/^[^ ]/{eth=$1}/inet addr:/{ip=$4}' | grep en); do
  lldptool set-lldp -i $i adminStatus=rxtx >/dev/null 2>&1
  lldptool -T -i $i -V $i sysName enableTx=yes >/dev/null 2>&1
  lldptool -T -i $i -V $i portDesc enableTx=yes >/dev/null 2>&1
  lldptool -T -i $i -V $i sysDesc enableTx=yes >/dev/null 2>&1
done

# 收集并显示 LLDP 信息
for i in $(ifconfig | awk -F'[ :]+' '!NF{if(eth!=""&&ip=="")print eth;eth=ip4=""}/^[^ ]/{eth=$1}/inet addr:/{ip=$4}' | grep en); do
  se_dev=$i
  ld_tool="lldptool -t -n -i $se_dev"
  
  # 提取交换机名称、IP、接口名
  sw_name=$($ld_tool | strings | grep 'System Name TLV' -A1 | tail -n1 | sed 's/\t//g')
  sw_ip=$($ld_tool | strings | grep 'Management Address TLV' -A1 | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tail -n1)
  sw_If=$($ld_tool | strings | grep 'Ifname:' | awk -F ': ' '{print $NF}')
  
  # 新增：提取 PVID（Port VLAN ID）
  sw_pvid=$($ld_tool | strings | grep 'Port VLAN ID TLV' -A1 | tail -n1 | awk '{print $2}' | tr -d '\n')

  # 输出结果
  echo "se_dev: $se_dev
sw_name: $sw_name
sw_ip: $sw_ip
sw_If: $sw_If
sw_pvid: $sw_pvid
"
done