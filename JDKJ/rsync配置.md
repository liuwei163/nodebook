### rsync配置

* 复制以下三个文件到smbd容器内

    docker cp rsync-3.0.9-15.el7.x86_64.rpm smbd:/root/

    docker cp rsyncd.conf smbd:/etc

    docker cp rsyncd.secrets smbd:/etc


* 进入容器内安装包，修改权限，创建目录

    docker exec -it smbd bash

    rpm -ivh rsync-3.0.9-15.el7.x86_64.rpm

    chmod 600 /etc/rsyncd.secrets

    mkdir /mnt/windows


* 复制以下内容到文件entrypoint.sh中
```sh
    #auto mount
    mount -t alamofs 127.0.0.1:vol1 /mnt/windows

    if [ $? -ne 0 ]; then
        echo "mount failed"
        sleep 100
        exit -1
    fi

    #start rsync daemon
    rm /var/run/rsyncd.pid
    rsync --daemon
```

* 测试rsync

    rsync -avz --password-file=/tmp/pass /tmp/testfile1 seqdata@127.0.0.1::Gene2000
    
    注意pass文件只包含下面rsyncd.secrets的密码部分，权限同样是600，seqdata是用户名，Gene2000是rsyncd的输出目录，见下面rsyncd.conf内容。
  
* rsyncd.secrets  

```sh
seqdata:DA@geneplus
```

* rsyncd.conf

```sh
# /etc/rsyncd: configuration file for rsync daemon mode

# See rsyncd.conf man page for more options.

# configuration example:

# uid = nobody
# gid = nobody
# use chroot = yes
# max connections = 4
# pid file = /var/run/rsyncd.pid
# exclude = lost+found/
# transfer logging = yes
# timeout = 900
# ignore nonreadable = yes
# dont compress   = *.gz *.tgz *.zip *.z *.Z *.rpm *.deb *.bz2

# [ftp]
#        path = /home/ftp
#        comment = ftp export area

# xtao config
uid = seqdata
gid = seqdata
pid file = /var/run/rsyncd.pid
log file = /var/run/rsyncd.log
secrets file = /etc/rsyncd.secrets
auth users = seqdata
# use chroot = yes
# max connections = 4
# exclude = lost+found/
# transfer logging = yes
# timeout = 900
# ignore nonreadable = yes

[Gene2000]
path = /mnt/windows/rawdata/Gene2000
read only = no

```

