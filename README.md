【绿邮开发版 单端口版｜命令与说明】

脚本示例文件名：lvyou.sh
（如果你实际文件名不同，把下面的 lvyou.sh 替换成你的即可）

============================================================
一、命令总览
============================================================
- install     安装并启动（UI+API 单端口）
- scan        命令行触发扫描并添加设备（等价于页面“扫描添加”调用 /api/scan/start）
- status      查看服务状态
- restart     重启服务
- logs        查看服务日志
- uninstall   卸载（停止服务并删除安装目录）
- help        显示帮助

注意：
- install/scan/restart/uninstall 建议用 sudo 执行（需要写 /opt、/etc/systemd）
- 接口路径保持不变：/api/numbers  /api/sms/send-direct  /api/scan/start

============================================================
二、安装（install）
============================================================
安装默认配置：
sudo bash lvyou.sh install

常用参数：
--dir <路径>          安装目录（默认：/opt/board-manager）
--api-port <端口>     服务端口（默认：8000）
--user <用户名>       设备登录用户名（默认：admin）
--pass <密码>         设备登录密码（默认：admin）

示例：自定义端口与登录信息
sudo bash lvyou.sh install --api-port 9000 --user admin --pass 123456

============================================================
三、扫描（scan）
============================================================
默认扫描（脚本会自动建议/提示网段）：
sudo bash lvyou.sh scan

常用参数：
--cidr <网段>         指定扫描网段，例如：192.168.1.0/24
--user <用户名>       设备登录用户名（用于 Digest 探测/读取）
--pass <密码>         设备登录密码（用于 Digest 探测/读取）

示例：指定网段扫描
sudo bash lvyou.sh scan --cidr 192.168.1.0/24

示例：指定网段+账号密码
sudo bash lvyou.sh scan --cidr 192.168.1.0/24 --user admin --pass admin

============================================================
四、状态（status）
============================================================
sudo bash lvyou.sh status

（或直接 systemd）
sudo systemctl status board-manager.service --no-pager

============================================================
五、重启（restart）
============================================================
sudo bash lvyou.sh restart

（或直接 systemd）
sudo systemctl restart board-manager.service

============================================================
六、日志（logs）
============================================================
查看最近日志：
sudo bash lvyou.sh logs

实时追踪日志：
sudo journalctl -u board-manager.service -f

============================================================
七、卸载（uninstall）
============================================================
sudo bash lvyou.sh uninstall

说明：
- 会停止/禁用服务，并删除安装目录（默认 /opt/board-manager）

============================================================
八、访问地址（分享给使用者）
============================================================
假设服务端口为 8000（如你改了端口，把 8000 替换成你的端口）

UI（网页）：
http://<服务器IP>:8000/

API 健康检查：
http://<服务器IP>:8000/api/health

号码接口（保持不变）：
GET  http://<服务器IP>:8000/api/numbers

直发短信接口（保持不变）：
POST http://<服务器IP>:8000/api/sms/send-direct
JSON 示例：
{
  "deviceId": 1,
  "phone": "13800138000",
  "content": "hello",
  "slot": 1
}

扫描接口（保持不变）：
POST http://<服务器IP>:8000/api/scan/start
可选 query（不用也能扫）：cidr / user / password / group
示例：
POST http://<服务器IP>:8000/api/scan/start?cidr=192.168.1.0/24&user=admin&password=admin&group=auto

============================================================
九、快速排查（常用）
============================================================
1) 页面打不开/端口不通：
ss -lntp | grep 8000

2) API 是否正常：
curl -i http://127.0.0.1:8000/api/health

3) 扫描无结果：
- 确认服务器与设备在同一网段
- 确认设备 http://<设备IP>/mgr 有 Digest 认证特征（脚本用它识别设备）
- 看日志：
sudo journalctl -u board-manager.service -n 200 --no-pager

============================================================
（完）
============================================================
