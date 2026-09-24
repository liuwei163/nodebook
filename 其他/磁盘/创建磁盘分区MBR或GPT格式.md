1. 
# 创建 MBR 分区表
# 分区（交互命令依次输入 n - p - w）
fdisk /dev/vdb
# 格式化
mkfs.xfs /dev/vdb1
# 创建挂载点并挂载
mkdir /data
mount /dev/vdb1 /data
df -Th
# 查 UUID（注意：每台机器的 UUID 都不一样，不能用别人的）
blkid /dev/vdb1
# 写入 fstab 永久挂载（把 <UUID> 换成上面 blkid 输出的本机 UUID）
echo "UUID=<UUID> /data xfs defaults 0 2" >> /etc/fstab
mount -a && df -Th    # 验证 fstab 正确，避免重启挂不上

2. 
# 创建 GPT 分区表
parted /dev/vdc mklabel gpt
# 创建分区，占满全部磁盘空间
parted /dev/vdc mkpart primary xfs 0% 100%
# 格式化分区
mkfs.xfs /dev/vdc1
# 创建挂载点并临时挂载
mkdir /data
mount /dev/vdc1 /data
# 获取本机磁盘UUID，每台机器UUID各不相同，禁止直接复制示例UUID
blkid /dev/vdc1
# 将真实UUID替换下面<UUID>写入/etc/fstab
echo "UUID=<UUID> /data xfs defaults 0 0" >> /etc/fstab
# 重载验证挂载配置
mount -a && df -Th