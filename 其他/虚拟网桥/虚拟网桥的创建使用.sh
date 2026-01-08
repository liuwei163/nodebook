准备
	确保系统虚拟化已打开
	系统iso 准备好
	# 使用次docker 镜像已经配置好了kvm
	docker  image: vmlauncher
	# 安装brctl
	brctl已安装（bridge-utils_1.6-2ubuntu1_amd64.deb），提示有没有需要重启的服务，直接esc退出
	# 安装命令
	sudo apt install ./bridge-utils_1.6-2ubuntu1_amd64.deb


1. 建网桥
	# 查看网桥是否桥接到物理网口
	brctl show
    # 建网桥
	brctl addbr vmarkbr0
    # 桥接虚拟网桥到物理网口
	brctl addif vmarkbr0 eno1.30
    # 去掉物理网口的IP地址
	ip addr del 192.168.12.200/23 dev eno1.30
    # 将IP地址添加到虚拟网桥上
	ip addr add 192.168.12.200/23 dev vmarkbr0

    # 启动虚拟网桥
	ip link set vmarkbr0 up
    # 不需要启动物理网口（但是此命令可用来启动）
	ip link set eno1.30 up

    # 如果有网关，可用将默认网关IP添加到虚拟网桥上
	ip route add default via 192.168.12.254 dev vmarkbr0

    
	iptables -t filter -A FORWARD -i vmarkbr0 -j ACCEPT
	iptables -t filter -A FORWARD -o vmarkbr0 -j ACCEPT
2. 起容器
	docker run -itd --name vm --privileged --cgroupns host --net host -v /root/test.iso:/ -v /var/log/vm:/var/log/vm --entrypoint=bash vmlauncher
3. 起虚拟机
	docker exec -it vm bash
	/usr/sbin/libvirtd -d
	/usr/sbin/virtlogd -d
	virt-install --name deploy --ram=10240 --vcpus=2 --os-variant=ubuntu22.04 --disk /var/log/vm/deploy.qcow2,size=100 --disk /root/test.iso,device=cdrom --network bridge=vmarkbr0 --graphics vnc,listen=0.0.0.0 --boot hd,cdrom
4. 使用vnclient 访问虚拟机
	vncvierwer 192.168.12.200:5900


# 1. 创建虚拟网桥设备，命名为 vmarkbr0
sudo brctl addbr vmarkbr0

# 2. 将物理网卡 eno1.30 接入此网桥（成为它的一个“端口”）
sudo brctl addif vmarkbr0 eno1.30

### 关键提示：执行完此步，eno1.30 将变成一个纯二层端口，不再持有IP地址，你的网络可能会暂时中断，请快速完成后续步骤。

# 3. 将物理网卡原有的IP地址“转移”给网桥
sudo ip addr del 192.168.12.200/23 dev eno1.30
sudo ip addr add 192.168.12.200/23 dev vmarkbr0

# 4. 启动网桥和物理网卡接口
sudo ip link set vmarkbr0 up
sudo ip link set eno1.30 up

### ip addr del 和 add 是关键操作，完成了网络身份的交接。

# 5. 为网桥设置默认网关（告诉数据包从哪个出口离开）需要则加，不需要则不用加默认网关
sudo ip route add default via 192.168.12.254 dev vmarkbr0

# 6. 配置Linux内核的包转发，允许流量经过网桥
sudo iptables -t filter -A FORWARD -i vmarkbr0 -j ACCEPT
sudo iptables -t filter -A FORWARD -o vmarkbr0 -j ACCEPT

# （可选但建议）启用系统的IP转发功能
echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

# 7. 验证
# 查看网桥信息及其连接的接口
brctl show
# 查看网桥的IP配置是否生效
ip addr show vmarkbr0
# 测试网络连通性
ping -c 4 192.168.12.254

### 持久化配置
持久化配置（重启后依然有效）
以上命令重启后会失效。在Ubuntu上，推荐使用 Netplan 进行持久化配置。

假设你的原始网络配置文件是 /etc/netplan/01-netcfg.yaml，将其修改为如下内容（注意根据你的实际环境修改物理网卡名和IP）：

```
network:
  version: 2
  renderer: networkd # 或 NetworkManager，取决于你的系统
  ethernets:
    eno1.30: # 你的物理网卡
      dhcp4: no # 不再通过此接口获取IP
  bridges:
    vmarkbr0: # 网桥配置
      interfaces: [eno1.30] # 绑定到此网桥的接口
      addresses: [192.168.12.200/23]
      gateway4: 192.168.12.254
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4] # 你的DNS服务器
      parameters:
        stp: false # 小型网络可关闭生成树协议，加快收敛
        forward-delay: 0
```

sudo netplan apply