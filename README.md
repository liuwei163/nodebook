## 命令行创建新存储库

echo "# -learngit" >> README.md
git init
git add README.md
git commit -m "first commit"
git branch -M master
git remote add origin git@github.com:liuwei163/-learngit.git
git push -u origin master

## 命令行推送现有存储库

git remote add origin git@github.com:liuwei163/-learngit.git
git branch -M master
git push -u origin master