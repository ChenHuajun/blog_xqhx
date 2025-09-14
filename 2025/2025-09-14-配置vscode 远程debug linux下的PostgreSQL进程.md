# 如何配置vscode 远程debug linux下的PostgreSQL进程

## 1. 远程环境配置

### 1.1 编译‌debug版‌PostgreSQL
```
CFLAGS="-O0 -g3 -gdwarf-2" ./configure --enable-debug --prefix=/usr/pg18
make -j4
sudo make install
```

### 1.2 初始化并启动postgres
```
export PATH=/usr/pg18/bin:$PATH
initdb data
pg_ctl -D data start -l logfile
```

## 2. 本地环境vs code环境配置

### 2.1 安装C/C++ 编译调试插件
- C/C++
- Remote-SSH
- C/C++ Debugger(gdb)

### 2.2 SSH连接远程主机
Ctl + Shit + P 或菜单 View->Command Palette.. ->Remote-SSH:Connect to Host... 连接到远程主机
打开远程代码目录作为项目目录

### 2.3 ‌编辑调试配置文件‌
在PostgreSQL源码目录的.vscode文件夹中创建launch.json：

```
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "C/C++ Debug (gdb Attach to PostgreSQL)",
      "type": "cppdbg",
      "request": "attach",
      "program": "/usr/pg18/bin/postgres",
      "processId": "${command:pickProcess}",
      "MIMode": "gdb",
      "setupCommands": [
        {
          "description": "Enable pretty-printing for gdb",
          "text": "-enable-pretty-printing",
          "ignoreFailures": true
        }
      ]
    }
}
```

## 3  进行debug

### 3.1 远程启动postgres会话
```
psql postgres 
```

查询进程号
```
postgres=# select pg_backend_pid();
 pg_backend_pid
----------------
          46956
(1 row)
```

### 3.2 vscode上进行代码调试
1. 打开代码
2. 设置断点
3. 启用调试
   - F5启动launch.json中第一个配置项或上次使用的配置项。
   - 启动其他配置项，打开View，选择Run and Debug

**注意事项**

调试需关闭Linux的ptrace_scope限制，‌否则又权限问题‌。执行
```
echo 0 | sudo tee /proc/sys/kernel/yama/ptrace_scope
```
如需永久生效，编码配置文件/etc/sysctl.d/10-ptrace.conf

