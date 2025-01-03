#!/bin/bash
login=test.log
volumename=jdfswh3

echo "=============ipmi==========" >>  "${login}"
ipmitool -I open chassis status    >> "${login}"

echo "=============disk-number==========" >>  "${login}"
lsscsi -sw |grep dev | wc -l        >> "${login}"

echo "=============memory===============" >> "${login}"
free -g | sed '2!d'                >> "${login}"

echo "=============memory-number========="  >> "${login}"
dmidecode -t memory |grep -E "Locator:|Size:|Serial Number: "|grep -v Bank |grep -v DIMM |grep -v Module | grep Size  >> "${login}"

echo "=====================pool-status====================" >> "${login}"
alamocli pool list        >> "${login}"

echo "=====================volume-status===================="  >> "${login}"
alamocli volume status    >> "${login}"

echo "===================volume-Total================="  >> "${login}"
xd-alamo volume stat ${volumename} | grep Total  >> "${login}"

echo "===================volume-Free================="  >> "${login}"
xd-alamo volume stat ${volumename} | grep Free  >> "${login}"  
echo "==============nfs-client-number================"   >> "${login}"
alamo volume status ${volumename} nfs client |grep Clients  >> "${login}"
 
echo "=================smb-number====================="  >> "${login}"
pgrep smbd | wc -l      >> "${login}"
echo "==================Haagent-status=============" >> "${login}"
systemctl status Haagent     >> "${login}"

##meget使用情况     zpool  list -v
##是否使用ssd的cache     zpool  status
##配额 alamocli quota list  卷名