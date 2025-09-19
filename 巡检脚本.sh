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

#!/bin/bash
set +e

# Log_Path=/root/inspection
Time_Stmp=$(date +"%Y%m%d_%H%M%S")
Log_File=/root/ins_${Time_Stmp}.log



read -p  "volume-name: "       vol_name1
vol_name=$vol_name1
read -p  "start_node_number: " start
read -p  "start_node_count: " ending

echo "###############memory###################" > "${Log_File}"
for i in {${start}..${ending}};do 
    echo node$i
    ssh node$i free -h
done >> "${Log_File}" 2>&1

# free -h >> "${Log_File}" 2>&1

echo "###############volume-capacity###################" >> "${Log_File}" 2>&1
# 卷总容量和使用量
alamocli volume stat ${vol_name} >> "${Log_File}" 2>&1
xd-alamo volume stat ${vol_name} >> "${Log_File}" 2>&1

echo "###############ipmi###################" >> "${Log_File}" 2>&1

# 系统是否健康
ipmitool -I open chassis status >> "${Log_File}" 2>&1

echo "###############pool###################"  >> "${Log_File}" 2>&1

zpool status  >> "${Log_File}" 2>&1

# pool是否健康
# echo "###############zpool_status###########" >> "${Log_File}" 2>&1
for i in {${start}..${ending}};do 
    echo node$i
    ssh node$i zpool status -x
done >> "${Log_File}" 2>&1

# for i in {1..6};do echo node$i;ssh node$i zpool status -x;done 
echo "###############volume###################"  >> "${Log_File}" 2>&1

# 卷是否健康
alamocli volume status  >> "${Log_File}" 2>&1
 
echo "###############metadata###################"  >> "${Log_File}" 2>&1

# metaclass的容量和使用情况
zpool get metadata_size,metadata_used $(HOSTNAME)_pool1 -H  >> "${Log_File}" 2>&1

echo "###############NFS_NUMBER###################"  >> "${Log_File}" 2>&1

# NFS客户端的个数

alamo volume status ${vol_name} nfs client |grep Clients  >> "${Log_File}" 2>&1

gluster  volume status ${vol_name} nfs client |grep Clients >> "${Log_File}" 2>&1

echo "###############smb###################"  >> "${Log_File}" 2>&1

docker ps  >> "${Log_File}" 2>&1

echo "###############quota###################"  >> "${Log_File}" 2>&1
# 系统配额使用情况
stdbuf -o0 alamocli quota list  ${vol_name} >> "${Log_File}" 2>&1

echo "###############Haagent###################"  >> "${Log_File}" 2>&1
# Haagent服务是否正常
systemctl status Haagent >> "${Log_File}" 2>&1

echo "###############ntpd###################"  >> "${Log_File}" 2>&1
# ntpd服务是否正常
systemctl status ntpd >> "${Log_File}" 2>&1

echo "###############disk-number###################"  >> "${Log_File}" 2>&1
# 硬盘数量
for i in {${start}..${ending}};do 
    echo node$i
    ssh node$i alamocli enclosure list
done >> "${Log_File}" 2>&1
