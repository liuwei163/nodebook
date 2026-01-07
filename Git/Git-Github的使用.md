# Git/Github的使用

1、常用命令

```sh
git --version                          # 查看git版本
git config  --global user.name  用户名  # 设置用户签名
git config  --global user.email 邮箱    # 设置用户签名
# 用户签名是否设置成功，windows中查看 C:\Users\用户目录\.gitconfig 文件中是否有设置的用户签名

git init        # 初始化本地库
git status      # 查看本地库状态
git add 文件名   # 添加到暂存区
git commit -m "日志信息"  文件名  # 提交文件到本地库，并添加日志信息
git reflog      # 查看版本信息的历史记录
git log			# 查看版本详细信息
git reset --hard  版本号         # 版本穿梭
```

2、分支的操作

```sh
git  branch  分支名      # 创建分支
git  branch  -v         # 查看分支
git  checkout  分支名    # 切换分支
git  merge   分支名      # 把指定的分支合并到当前分支上

# 合并分支时，两个分支在 “同一个文件的同一个位置” 有两套完全不同的修改稿。Git无法替我们决定使用那一个。必须人为决定新代码内容
# 手动合并分支后，需要再次进行提交到暂存区然后进行commit提交。“commit提交不可以加上提交的文件名”。

```

3、创建远程仓库别名

```sh
git  remote  -v  # 查看当前所有远程地址别名
git  remote add 别名  远程地址 # 设置仓库远程地址别名

####################实例#####################
xtao@LAPTOP-3GEKEQS5 MINGW64 /d/git/git-dome (master)
$ git remote -v

xtao@LAPTOP-3GEKEQS5 MINGW64 /d/git/git-dome (master)
$ git remote add git-dome https://github.com/liuwei163/git-demo.git

xtao@LAPTOP-3GEKEQS5 MINGW64 /d/git/git-dome (master)
$ git remote -v
git-dome        https://github.com/liuwei163/git-demo.git (fetch)
git-dome        https://github.com/liuwei163/git-demo.git (push)

```

4、推送本地仓库到远程仓库

```sh
git  push  别名  分支名

################### 实例 #########################

xtao@LAPTOP-3GEKEQS5 MINGW64 /d/git/git-dome (master)
$ git  push git-demo master
Enumerating objects: 15, done.
Counting objects: 100% (15/15), done.
Delta compression using up to 8 threads
Compressing objects: 100% (10/10), done.
Writing objects: 100% (15/15), 1.08 KiB | 277.00 KiB/s, done.
Total 15 (delta 4), reused 0 (delta 0), pack-reused 0
remote: Resolving deltas: 100% (4/4), done.
To https://github.com/liuwei163/git-demo.git
 * [new branch]      master -> master
# 会弹出窗口验证账号密码
```

5、从远程仓库拉取到本地仓库

```sh
xtao@LAPTOP-3GEKEQS5 MINGW64 /d/git/git-dome (master)
$ git pull git-dome master
remote: Enumerating objects: 5, done.
remote: Counting objects: 100% (5/5), done.
remote: Compressing objects: 100% (2/2), done.
remote: Total 3 (delta 1), reused 0 (delta 0), pack-reused 0
Unpacking objects: 100% (3/3), 924 bytes | 77.00 KiB/s, done.
From https://github.com/liuwei163/git-demo
 * branch            master     -> FETCH_HEAD
   109c1d7..e7b26cc  master     -> git-dome/master
Updating 109c1d7..e7b26cc
Fast-forward
 hello.txt | 1 +
 1 file changed, 1 insertion(+)

```

6、克隆远程仓库到本地（公共仓库）

```sh
git clone  https://github.com/liuwei163/git-demo.git

# clone会做如下操作：1、拉取代码。2、初始化本地库。3、创建别名
```

7、配置ssh免密登录

```sh
1)生成非对称密钥
ssh-keygen -t rsa -C 2031260394@qq.com
2)将生成的公钥文件(id_rsa.pub)内容添加到github的ssh密钥中即可
```

