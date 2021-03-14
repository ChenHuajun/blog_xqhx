# 基于Patroni的PostgreSQL高可用环境部署



## 1. 前言

PostgreSQL是一款功能，性能，可靠性都可以和高端的国外商业数据库相媲美的开源数据库。而且PostgreSQL的许可和生态完全开放，不被任何一个单一的公司或国家所操控，保证了使用者没有后顾之忧。国内越来越多的企业开始用PostgreSQL代替原来昂贵的国外商业数据库。 

在部署PostgreSQL到生产环境中时，选择适合的高可用方案是一项必不可少的工作。本文介绍基于Patroni的PostgreSQL高可用的部署方法，供大家参考。

PostgreSQL的开源HA工具有很多种，下面几种算是比较常用的

- PAF(PostgreSQL Automatic Failomianver)
- repmgr
- Patroni

它们的比较可以参考: https://scalegrid.io/blog/managing-high-availability-in-postgresql-part-1/



其中Patroni不仅简单易用而且功能非常强大。

- 支持自动failover和按需switchover
- 支持一个和多个备节点
- 支持级联复制
- 支持同步复制，异步复制
- 支持同步复制下备库故障时自动降级为异步复制（功效类似于MySQL的半同步，但是更加智能）
- 支持控制指定节点是否参与选主，是否参与负载均衡以及是否可以成为同步备机
- 支持通过`pg_rewind`自动修复旧主
- 支持多种方式初始化集群和重建备机，包括`pg_basebackup`和支持`wal_e`，`pgBackRest`，`barman`等备份工具的自定义脚本
- 支持自定义外部callback脚本
- 支持REST API
- 支持通过watchdog防止脑裂
- 支持k8s，docker等容器化环境部署
- 支持多种常见DCS(Distributed Configuration Store)存储元数据，包括etcd，ZooKeeper，Consul，Kubernetes


因此，除非只有2台机器没有多余机器部署DCS的情况，Patroni是一款非常值得推荐的PostgreSQL高可用工具。下面将详细介绍基于Patroni搭建PostgreSQL高可用环境的步骤。



## 2. 实验环境

**主要软件**

- CentOS 7.8
- PostgreSQL 12
- Patroni 1.6.5
- etcd 3.3.25



**机器和VIP资源**

- PostgreSQL
  - node1：192.168.234.201 
  - node2：192.168.234.202 
  - node3：192.168.234.203 

- etcd
  - node4：192.168.234.204

- VIP
  - 读写VIP：192.168.234.210
  - 只读VIP：192.168.234.211



**环境准备**

所有节点设置时钟同步

```
yum install -y ntpdate
ntpdate time.windows.com && hwclock -w
```

如果使用防火墙需要开放postgres，etcd和patroni的端口。

- postgres:5432
- patroni:8008
- etcd:2379/2380

更简单的做法是将防火墙关闭

```
setenforce 0
sed -i.bak "s/SELINUX=enforcing/SELINUX=permissive/g" /etc/selinux/config
systemctl disable firewalld.service
systemctl stop firewalld.service
iptables -F
```



## 3. etcd部署

因为本文的主题不是etcd的高可用，所以只在node4上部署单节点的etcd用于实验。生产环境至少需要部署3个节点，可以使用独立的机器也可以和数据库部署在一起。etcd的部署步骤如下


安装需要的包

```
yum install -y gcc python-devel epel-release
```

安装etcd

```
yum install -y etcd
```

编辑etcd配置文件`/etc/etcd/etcd.conf`, 参考配置如下

```
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://192.168.234.204:2380"
ETCD_LISTEN_CLIENT_URLS="http://localhost:2379,http://192.168.234.204:2379"
ETCD_NAME="etcd0"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://192.168.234.204:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://192.168.234.204:2379"
ETCD_INITIAL_CLUSTER="etcd0=http://192.168.234.204:2380"
ETCD_INITIAL_CLUSTER_TOKEN="cluster1"
ETCD_INITIAL_CLUSTER_STATE="new"
```

启动etcd

```
systemctl start etcd
```



设置etcd自启动

```
systemctl enable etcd
```



## 4. PostgreSQL + Patroni HA部署

在需要运行PostgreSQL的实例上安装相关软件



安装PostgreSQL 12

```
yum install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-7-x86_64/pgdg-redhat-repo-latest.noarch.rpm

yum install -y postgresql12-server postgresql12-contrib
```



安装Patroni 

```
yum install -y gcc epel-release
yum install -y python-pip python-psycopg2 python-devel

pip install --upgrade pip
pip install --upgrade setuptools
pip install patroni[etcd]
```



创建PostgreSQL数据目录

```
mkdir -p /pgsql/data
chown postgres:postgres -R /pgsql
chmod -R 700 /pgsql/data
```



创建Partoni service配置文件`/etc/systemd/system/patroni.service`

```
[Unit]
Description=Runners to orchestrate a high-availability PostgreSQL
After=syslog.target network.target
 
[Service]
Type=simple
User=postgres
Group=postgres
#StandardOutput=syslog
ExecStart=/usr/bin/patroni /etc/patroni.yml
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
TimeoutSec=30
Restart=no
 
[Install]
WantedBy=multi-user.target
```



创建Patroni配置文件`/etc/patroni.yml`，以下是node1的配置示例

```
scope: pgsql
namespace: /service/
name: pg1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.234.201:8008

etcd:
  host: 192.168.234.204:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    master_start_timeout: 300
    synchronous_mode: false
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        listen_addresses: "0.0.0.0"
        port: 5432
        wal_level: logical
        hot_standby: "on"
        wal_keep_segments: 100
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"

  initdb:
  - encoding: UTF8
  - locale: C
  - lc-ctype: zh_CN.UTF-8
  - data-checksums

  pg_hba:
  - host replication repl 0.0.0.0/0 md5
  - host all all 0.0.0.0/0 md5

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.234.201:5432
  data_dir: /pgsql/data
  bin_dir: /usr/pgsql-12/bin

  authentication:
    replication:
      username: repl
      password: "123456"
    superuser:
      username: postgres
      password: "123456"

  basebackup:
    max-rate: 100M
    checkpoint: fast

tags:
    nofailover: false
    noloadbalance: false
    clonefrom: false
    nosync: false
```

完整的参数含有可参考Patroni手册中的 [YAML Configuration Settings](https://patroni.readthedocs.io/en/latest/SETTINGS.html)，其中PostgreSQL参数可根据需要自行补充。

其他PG节点的patroni.yml需要相应修改下面3个参数

- name
  - `node1~node4`分别设置`pg1~pg4`
- restapi.connect_address
  - 根据各自节点IP设置
- postgresql.connect_address
  - 根据各自节点IP设置



启动Patroni

先在node1上启动Patroni。

```
systemctl start patroni
```

初次启动Patroni时，Patroni会初始创建PostgreSQL实例和用户。

```
[root@node1 ~]# systemctl status patroni
● patroni.service - Runners to orchestrate a high-availability PostgreSQL
   Loaded: loaded (/etc/systemd/system/patroni.service; disabled; vendor preset: disabled)
   Active: active (running) since Sat 2020-09-05 14:41:03 CST; 38min ago
 Main PID: 1673 (patroni)
   CGroup: /system.slice/patroni.service
           ├─1673 /usr/bin/python2 /usr/bin/patroni /etc/patroni.yml
           ├─1717 /usr/pgsql-12/bin/postgres -D /pgsql/data --config-file=/pgsql/data/postgresql.conf --listen_addresses=0.0.0.0 --max_worker_processe...
           ├─1719 postgres: pgsql: logger
           ├─1724 postgres: pgsql: checkpointer
           ├─1725 postgres: pgsql: background writer
           ├─1726 postgres: pgsql: walwriter
           ├─1727 postgres: pgsql: autovacuum launcher
           ├─1728 postgres: pgsql: stats collector
           ├─1729 postgres: pgsql: logical replication launcher
           └─1732 postgres: pgsql: postgres postgres 127.0.0.1(37154) idle
```

再在node2上启动Patroni。node2将作为replica加入集群，自动从leader拷贝数据并建立复制。

```
[root@node2 ~]# systemctl status patroni
● patroni.service - Runners to orchestrate a high-availability PostgreSQL
   Loaded: loaded (/etc/systemd/system/patroni.service; disabled; vendor preset: disabled)
   Active: active (running) since Sat 2020-09-05 16:09:06 CST; 3min 41s ago
 Main PID: 1882 (patroni)
   CGroup: /system.slice/patroni.service
           ├─1882 /usr/bin/python2 /usr/bin/patroni /etc/patroni.yml
           ├─1898 /usr/pgsql-12/bin/postgres -D /pgsql/data --config-file=/pgsql/data/postgresql.conf --listen_addresses=0.0.0.0 --max_worker_processe...
           ├─1900 postgres: pgsql: logger
           ├─1901 postgres: pgsql: startup   recovering 000000010000000000000003
           ├─1902 postgres: pgsql: checkpointer
           ├─1903 postgres: pgsql: background writer
           ├─1904 postgres: pgsql: stats collector
           ├─1912 postgres: pgsql: postgres postgres 127.0.0.1(35924) idle
           └─1916 postgres: pgsql: walreceiver   streaming 0/3000060
```



查看集群状态

```
[root@node2 ~]# patronictl -c /etc/patroni.yml list
+ Cluster: pgsql (6868912301204081018) -------+----+-----------+
| Member |       Host      |  Role  |  State  | TL | Lag in MB |
+--------+-----------------+--------+---------+----+-----------+
|  pg1   | 192.168.234.201 | Leader | running |  1 |           |
|  pg2   | 192.168.234.202 |        | running |  1 |       0.0 |
+--------+-----------------+--------+---------+----+-----------+
```



为了方便日常操作，设置全局环境变量`PATRONICTL_CONFIG_FILE`

```
echo 'export PATRONICTL_CONFIG_FILE=/etc/patroni.yml' >/etc/profile.d/patroni.sh
```

添加以下环境变量到`~postgres/.bash_profile`

```
export PGDATA=/pgsql/data
export PATH=/usr/pgsql-12/bin:$PATH
```

设置postgres拥有免密的sudoer权限

```
echo 'postgres        ALL=(ALL)       NOPASSWD: ALL'> /etc/sudoers.d/postgres
```



## 5. 自动切换和脑裂防护

Patroni在主库故障时会自动执行failover，确保服务的高可用。但是自动failover如果控制不当会有产生脑裂的风险。因此Patroni在保障服务的可用性和防止脑裂的双重目标下会在特定场景下执行一些自动化动作。

| 故障位置 | 场景                               | Patroni的动作                                                |
| -------- | ---------------------------------- | ------------------------------------------------------------ |
| 备库     | 备库PG停止                         | 停止备库PG                                                   |
| 备库     | 停止备库Patroni                    | 停止备库PG                                                   |
| 备库     | 强杀备库Patroni（或Patroni crash） | 无操作                                                       |
| 备库     | 备库无法连接etcd                   | 无操作                                                       |
| 备库     | 非Leader角色但是PG处于生产模式     | 重启PG并切换到恢复模式作为备库运行                           |
| 主库     | 主库PG停止                         | 重启PG，重启超过`master_start_timeout`设定时间，进行主备切换 |
| 主库     | 停止主库Patroni                    | 停止主库PG，并触发failover                                   |
| 主库     | 强杀主库Patroni（或Patroni crash） | 触发failover，此时出现"双主"                                 |
| 主库     | 主库无法连接etcd                   | 将主库降级为备库，并触发failover                             |
| -        | etcd集群故障                       | 将主库降级为备库，此时集群中全部都是备库。                   |
| -        | 同步模式下无可用同步备库           | 临时切换主库为异步复制，在恢复为同步复制之前自动failover暂不生效 |



### 5.1 Patroni如何防止脑裂

部署在数据库节点上的patroni进程会执行一些保护操作，确保不会出现多个“主库”

1. 非Leader节点的PG处于生产模式时，重启PG并切换到恢复模式作为备库运行
2. Leader节点的patroni无法连接etcd时，不能确保自己仍然是Leader，将本机的PG降级为备库
3. 正常停止patroni时，patroni会顺便把本机的PG进程也停掉

然而，当patroni进程自身无法正常工作时，以上的保护措施难以得到贯彻。比如patroni进程异常终止或主机临时hang等。

为了更可靠的防止脑裂，Patroni支持通过Linux的watchdog监视patroni进程的运行，当patroni进程无法正常往watchdog设备写入心跳时，由watchdog触发Linux重启。具体的配置方法如下



设置Patroni的systemd service配置文件`/etc/systemd/system/patroni.service`

```
[Unit]
Description=Runners to orchestrate a high-availability PostgreSQL
After=syslog.target network.target
 
[Service]
Type=simple
User=postgres
Group=postgres
#StandardOutput=syslog
ExecStartPre=-/usr/bin/sudo /sbin/modprobe softdog
ExecStartPre=-/usr/bin/sudo /bin/chown postgres /dev/watchdog
ExecStart=/usr/bin/patroni /etc/patroni.yml
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
TimeoutSec=30
Restart=no
 
[Install]
WantedBy=multi-user.target
```

设置Patroni自启动

```
systemctl enable patroni
```



修改Patroni配置文件`/etc/patroni.yml`，添加以下内容

```
watchdog:
  mode: automatic # Allowed values: off, automatic, required
  device: /dev/watchdog
  safety_margin: 5
```

`safety_margin`指如果Patroni没有及时更新watchdog，watchdog会在Leader key过期前多久触发重启。在本例的配置下(ttl=30，loop_wait=10，safety_margin=5)下，patroni进程每隔10秒（`loop_wait`）都会更新Leader key和watchdog。如果Leader节点异常导致patroni进程无法及时更新watchdog，会在Leader key过期的前5秒触发重启。重启如果在5秒之内完成，Leader节点有机会再次获得Leader锁，否则Leader key过期后，由备库通过选举选出新的Leader。

这套机制基本上可以保证不会出现"双主"，但是这个保证是依赖于watchdog的可靠性的，从生产实践上这个保证对绝大部分场景可能是足够的，但是从理论上难以证明它100%可靠。

另一方面，自动重启机器的方式会不会太暴力导致"误杀"呢？比如由于突发的业务访问导致机器负载过高，进而导致patroni进程不能及时分配到CPU资源，此时自动重启机器就未必是我们期望的行为。

那么，有没有其它更可靠的防止脑裂的手段呢？



### 5.2 利用PostgreSQL同步复制防止脑裂

防止脑裂的另一个手段是把PostgreSQL集群配置成同步复制模式。利用同步复制模式下的主库在没有同步备库应答日志时写入会阻塞的特点，在数据库内部确保即使出现“双主”也不会发生"双写"。采用这种方式防止脑裂是最可靠最安全的，代价是同步复制相对异步复制会降低一点性能。具体设置方法如下



初始运行Patroni时，在Patroni配置文件`/etc/patroni.yml`中设置同步模式

```
synchronous_mode:true
```

对于已部署的Patroni可以通过patronictl命令修改配置

```
patronictl edit-config -s 'synchronous_mode=true'
```

此配置下，如果同步备库临时不可用，Patroni会把主库的复制模式降级成了异步复制，确保服务不中断。效果类似于MySQL的半同步复制，但是相比MySQL使用固定的超时时间控制复制降级，这种方式更加智能，同时还具有防脑裂的功效。

在同步模式下，只有同步备库具有被提升为主库的资格。因此如果主库被降级为异步复制，由于没有同步备库作为候选主库failover不会被触发，也就不会出现“双主”。如果主库没有被降级为异步复制，那么即使出现“双主”，由于旧主处于同步复制模式，数据无法被写入，也不会出现“双写”。

Patroni通过动态调整PostgreSQL参数`synchronous_standby_names`控制同步异步复制的切换。并且Patroni会把同步的状态记录到etcd中，确保同步状态在Patroni集群中的一致性。

正常的同步模式的元数据示例如下：

```
[root@node4 ~]# etcdctl get /service/cn/sync
{"leader":"pg1","sync_standby":"pg2"}
```

备库故障导致主库临时降级为异步复制的元数据如下：

```
[root@node4 ~]# etcdctl get /service/cn/sync
{"leader":"pg1","sync_standby":null}
```



如果集群中包含3个以上的节点，还可以考虑采取更严格的同步策略，禁止Patroni把同步模式降级为异步。这样可以确保任何写入的数据至少存在于2个以上的节点。对数据安全要求极高的业务可以采用这种方式。

```
synchronous_mode:true
synchronous_mode_strict:true
```



如果集群包含异地的灾备节点，可以根据需要配置该节点为不参与选主，不参与负载均衡，也不作为同步备库。

```
tags:
    nofailover: true
    noloadbalance: true
    clonefrom: false
    nosync: true
```



### 5.3 etcd不可访问的影响

当Patroni无法访问etcd时，将不能确认自己所处的角色。为了防止这种状态下产生脑裂，如果本机的PG是主库，Patroni会把PG降级为备库。如果集群中所有Patroni节点都无法访问etcd，集群中将全部都是备库，业务无法写入数据。这就要求etcd集群具有非常高的可用性，特别是当我们用一套中心的etcd集群管理几百几千套PG集群的时候。

当我们使用集中式的一套etcd集群管理很多套PG集群时，为了预防etcd集群故障带来的严重影响，可以考虑设置超大的`retry_timeout`参数，比如1万天，同时通过同步复制模式防止脑裂。

```
retry_timeout:864000000
synchronous_mode:true
```

`retry_timeout`用于控制操作DCS和PostgreSQL的重试超时。Patroni对需要重试的操作，除了时间上的限制还有重试次数的限制。对于PostgreSQL操作，目前似乎只有调用`GET /patroni`的REST API时会重试，而且最多只重试1次，所以把`retry_timeout`调大不会带来其他副作用。



## 6. 日常操作

日常维护时可以通过`patronictl`命令控制Patroni和PostgreSQL，比如修改PotgreSQL参数。

```
[postgres@node2 ~]$ patronictl --help
Usage: patronictl [OPTIONS] COMMAND [ARGS]...

Options:
  -c, --config-file TEXT  Configuration file
  -d, --dcs TEXT          Use this DCS
  -k, --insecure          Allow connections to SSL sites without certs
  --help                  Show this message and exit.

Commands:
  configure    Create configuration file
  dsn          Generate a dsn for the provided member, defaults to a dsn of...
  edit-config  Edit cluster configuration
  failover     Failover to a replica
  flush        Discard scheduled events (restarts only currently)
  history      Show the history of failovers/switchovers
  list         List the Patroni members for a given Patroni
  pause        Disable auto failover
  query        Query a Patroni PostgreSQL member
  reinit       Reinitialize cluster member
  reload       Reload cluster member configuration
  remove       Remove cluster from DCS
  restart      Restart cluster member
  resume       Resume auto failover
  scaffold     Create a structure for the cluster in DCS
  show-config  Show cluster configuration
  switchover   Switchover to a replica
  version      Output version of patronictl command or a running Patroni...
```



### 6.1 修改PostgreSQL参数

修改个别节点的参数，可以执行`ALTER SYSTEM SET ...` SQL命令，比如临时打开某个节点的debug日志。对于需要统一配置的参数应该通过`patronictl edit-config`设置，确保全局一致，比如修改最大连接数。

```
patronictl edit-config -p 'max_connections=300'
```

修改最大连接数后需要重启才能生效，因此Patroni会在相关的节点状态中设置一个`Pending restart`标志。

```
[postgres@node2 ~]$ patronictl list
+ Cluster: pgsql (6868912301204081018) -------+----+-----------+-----------------+
| Member |       Host      |  Role  |  State  | TL | Lag in MB | Pending restart |
+--------+-----------------+--------+---------+----+-----------+-----------------+
|  pg1   | 192.168.234.201 | Leader | running | 25 |           |        *        |
|  pg2   | 192.168.234.202 |        | running | 25 |       0.0 |        *        |
+--------+-----------------+--------+---------+----+-----------+-----------------+
```

重启集群中所有PG实例后，参数生效。

```
 patronictl restart pgsql
```



### 6.2 查看Patroni节点状态

通常我们可以同`patronictl list`查看每个节点的状态。但是如果想要查看更详细的节点状态信息，需要调用REST API。比如在Leader锁过期时存活节点却无法成为Leader，查看详细的节点状态信息有助于调查原因。

```
curl -s http://127.0.0.1:8008/patroni | jq
```

输出示例如下：

```
[root@node2 ~]# curl -s http://127.0.0.1:8008/patroni | jq
{
  "database_system_identifier": "6870146304839171063",
  "postmaster_start_time": "2020-09-13 09:56:06.359 CST",
  "timeline": 23,
  "cluster_unlocked": true,
  "watchdog_failed": true,
  "patroni": {
    "scope": "cn",
    "version": "1.6.5"
  },
  "state": "running",
  "role": "replica",
  "xlog": {
    "received_location": 201326752,
    "replayed_timestamp": null,
    "paused": false,
    "replayed_location": 201326752
  },
  "server_version": 120004
}
```

上面的`"watchdog_failed": true`，代表使用了watchdog但是却无法访问watchdog设备，该节点无法被提升为Leader。



## 7. 客户端访问配置

HA集群的主节点是动态的，主备发生切换时，客户端对数据库的访问也需要能够动态连接到新主上。有下面几种常见的实现方式，下面分别介绍。

- 多主机URL

- vip
- haproxy



### 7.1 多主机URL

pgjdbc和libpq驱动可以在连接字符串中配置多个IP，由驱动识别数据库的主备角色，连接合适的节点。



**JDBC**

JDBC的多主机URL功能全面，支持failover，读写分离和负载均衡。可以通过参数配置不同的连接策略。

- jdbc:postgresql://192.168.234.201:5432,192.168.234.202:5432,192.168.234.203:5432/postgres?targetServerType=primary

  连接主节点(实际是可写的节点)。当出现"双主"甚至"多主"时驱动连接第一个它发现的可用的主节点

- jdbc:postgresql://192.168.234.201:5432,192.168.234.202:5432,192.168.234.203:5432/postgres?targetServerType=preferSecondary&loadBalanceHosts=true

  优先连接备节点，无可用备节点时连接主节点，有多个可用备节点时随机连接其中一个。

- jdbc:postgresql://192.168.234.201:5432,192.168.234.202:5432,192.168.234.203:5432/postgres?targetServerType=any&loadBalanceHosts=true

  随机连接任意一个可用的节点



**libpq**

libpq的多主机URL功能相对pgjdbc弱一点，只支持failover。

- postgres://192.168.234.201:5432,192.168.234.202:5432,192.168.234.203:5432/postgres?target_session_attrs=read-write

  连接主节点(实际是可写的节点)

- postgres://192.168.234.201:5432,192.168.234.202:5432,192.168.234.203:5432/postgres?target_session_attrs=any

  连接任一可用节点



基于libpq实现的其他语言的驱动相应地也可以支持多主机URL，比如python和php。下面是python程序使用多主机URL创建连接的例子

```
import psycopg2

conn=psycopg2.connect("postgres://192.168.234.201:5432,192.168.234.202:5432/postgres?target_session_attrs=read-write&password=123456")
```



### 7.2 VIP(通过Patroni回调脚本实现VIP漂移）

多主机URL的方式部署简单，但是不是每种语言的驱动都支持，而且如果数据库出现意外的“双主”，配置多主机URL的客户端在多个主上同时写入的概率比较高，而如果客户端通过VIP的方式访问则在VIP上又多了一层防护（这种风险一般在数据库的HA组件没防护好时发生，正如前面介绍的，如果我们配置的是Patroni的同步模式，基本上没有这个担忧）。

Patroni支持用户配置在特定事件发生时触发回调脚本。因此我们可以配置一个回调脚本，在主备切换后动态加载VIP。



准备加载VIP的回调脚本`/pgsql/loadvip.sh`

```
#!/bin/bash

VIP=192.168.234.210
GATEWAY=192.168.234.2
DEV=ens33

action=$1
role=$2
cluster=$3

log()
{
  echo "loadvip: $*"|logger
}

load_vip()
{
ip a|grep -w ${DEV}|grep -w ${VIP} >/dev/null
if [ $? -eq 0 ] ;then
  log "vip exists, skip load vip"
else
  sudo ip addr add ${VIP}/32 dev ${DEV} >/dev/null
  rc=$?
  if [ $rc -ne 0 ] ;then
    log "fail to add vip ${VIP} at dev ${DEV} rc=$rc"
    exit 1
  fi

  log "added vip ${VIP} at dev ${DEV}"

  arping -U -I ${DEV} -s ${VIP} ${GATEWAY} -c 5 >/dev/null
  rc=$?
  if [ $rc -ne 0 ] ;then
    log "fail to call arping to gateway ${GATEWAY} rc=$rc"
    exit 1
  fi
  
  log "called arping to gateway ${GATEWAY}"
fi
}

unload_vip()
{
ip a|grep -w ${DEV}|grep -w ${VIP} >/dev/null
if [ $? -eq 0 ] ;then
  sudo ip addr del ${VIP}/32 dev ${DEV} >/dev/null
  rc=$?
  if [ $rc -ne 0 ] ;then
    log "fail to delete vip ${VIP} at dev ${DEV} rc=$rc"
    exit 1
  fi

  log "deleted vip ${VIP} at dev ${DEV}"
else
  log "vip not exists, skip delete vip"
fi
}

log "loadvip start args:'$*'"

case $action in
  on_start|on_restart|on_role_change)
    case $role in
      master)
        load_vip
        ;;
      replica)
        unload_vip
        ;;
      *)
        log "wrong role '$role'"
        exit 1
        ;;
    esac
    ;;
  *)
    log "wrong action '$action'"
    exit 1
    ;;
esac
```



修改Patroni配置文件`/etc/patroni.yml`，配置回调函数

```
postgresql:
...
  callbacks:
    on_start: /bin/bash /pgsql/loadvip.sh
    on_restart: /bin/bash /pgsql/loadvip.sh
    on_role_change: /bin/bash /pgsql/loadvip.sh
```

所有节点的Patroni配置文件都修改后，重新加载Patroni配置文件

```
patronictl reload pgsql
```

执行switchover后，可以看到VIP发生了漂移

/var/log/messages:

```
Sep  5 21:32:24 localvm postgres: loadvip: loadvip start args:'on_role_change master pgsql'
Sep  5 21:32:24 localvm systemd: Started Session c7 of user root.
Sep  5 21:32:24 localvm postgres: loadvip: added vip 192.168.234.210 at dev ens33
Sep  5 21:32:25 localvm patroni: 2020-09-05 21:32:25,415 INFO: Lock owner: pg1; I am pg1
Sep  5 21:32:25 localvm patroni: 2020-09-05 21:32:25,431 INFO: no action.  i am the leader with the lock
Sep  5 21:32:28 localvm postgres: loadvip: called arping to gateway 192.168.234.2
```



注意，如果直接停止主库上的Patroni，上面的脚本不会摘除VIP。主库上的Patroni被停掉后会触发备库failover成为新主，此时新旧主2台机器上都有VIP，但是由于新主执行了arping，一般不会影响应用访问。尽管如此，操作上还是需要注意避免。



### 7.3 VIP(通过keepalived实现VIP漂移）

Patroni提供了用于健康检查的REST API，可以根据节点角色返回正常(**200**)和异常的HTTP状态码

- `GET /` 或 `GET /leader`

  运行中且是leader节点

- `GET /replica`

  运行中且是replica角色，且没有设置tag noloadbalance

- `GET /read-only`

  和`GET /replica`类似，但是包含leader节点

使用REST API，Patroni可以和外部组件搭配使用。比如可以配置keepalived动态在主库或备库上绑VIP。

关于Patroni的REST API接口详细，参考[Patroni REST API](https://patroni.readthedocs.io/en/latest/rest_api.html)。

下面的例子在一主一备集群(node1和node2)中动态在备节点上绑只读VIP（192.168.234.211），当备节点故障时则将只读VIP绑在主节点上。



安装keepalived

```
yum install -y keepalived
```



准备keepalived配置文件`/etc/keepalived/keepalived.conf`

```
global_defs {
    router_id LVS_DEVEL
}
vrrp_script check_leader {
    script "/usr/bin/curl -s http://127.0.0.1:8008/leader -v 2>&1|grep '200 OK' >/dev/null"
    interval 2
    weight 10
}
vrrp_script check_replica {
    script "/usr/bin/curl -s http://127.0.0.1:8008/replica -v 2>&1|grep '200 OK' >/dev/null"
    interval 2
    weight 5
}
vrrp_script check_can_read {
    script "/usr/bin/curl -s http://127.0.0.1:8008/read-only -v 2>&1|grep '200 OK' >/dev/null"
    interval 2
    weight 10
}
vrrp_instance VI_1 {
    state BACKUP
    interface ens33
    virtual_router_id 211
    priority 100
    advert_int 1
    track_script {
        check_can_read
        check_replica
    }
    virtual_ipaddress {
       192.168.234.211
    }
}
```

启动keepalived

```
systemctl start keepalived
```



上面的配置方法也可以用于读写vip的漂移，只要把`track_script`中的脚本换成`check_leader`即可。但是在网络抖动或其它临时故障时keepalived管理的VIP容易飘，因此个人更推荐使用Patroni回调脚本动态绑定读写VIP。如果有多个备库，也可以在keepalived中配置LVS对所有备库进行负载均衡，过程就不展开了。



### 7.4 haproxy

haproxy作为服务代理和Patroni配套使用可以很方便地支持failover，读写分离和负载均衡，也是Patroni社区作为Demo的方案。缺点是haproxy本身也会占用资源，所有数据流量都经过haproxy，性能上会有一定损耗。

下面配置通过haproxy访问一主两备PG集群的例子。



安装haproxy

```
yum install -y haproxy
```



编辑haproxy配置文件`/etc/haproxy/haproxy.cfg`

```
global
    maxconn 100
    log     127.0.0.1 local2

defaults
    log global
    mode tcp
    retries 2
    timeout client 30m
    timeout connect 4s
    timeout server 30m
    timeout check 5s

listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /

listen pgsql
    bind *:5000
    option httpchk
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server postgresql_192.168.234.201_5432 192.168.234.201:5432 maxconn 100 check port 8008
    server postgresql_192.168.234.202_5432 192.168.234.202:5432 maxconn 100 check port 8008
    server postgresql_192.168.234.203_5432 192.168.234.203:5432 maxconn 100 check port 8008

listen pgsql_read
    bind *:6000
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server postgresql_192.168.234.201_5432 192.168.234.201:5432 maxconn 100 check port 8008
    server postgresql_192.168.234.202_5432 192.168.234.202:5432 maxconn 100 check port 8008
    server postgresql_192.168.234.203_5432 192.168.234.203:5432 maxconn 100 check port 8008
```

如果只有2个节点，上面的`GET /replica `需要改成`GET /read-only`，否则备库故障时就无法提供只读访问了，但是这样配置主库也会参与读，不能完全分离主库的读负载。



启动haproxy

```
systemctl start haproxy
```



haproxy自身也需要高可用，可以把haproxy部署在node1和node2 2台机器上，通过keepalived控制VIP（192.168.234.210）在node1和node2上漂移。

准备keepalived配置文件`/etc/keepalived/keepalived.conf`

```
global_defs {
    router_id LVS_DEVEL
}
vrrp_script check_haproxy {
    script "pgrep -x haproxy"
    interval 2
    weight 10
}
vrrp_instance VI_1 {
    state BACKUP
    interface ens33
    virtual_router_id 210
    priority 100
    advert_int 1
    track_script {
        check_haproxy
    }
    virtual_ipaddress {
       192.168.234.210
    }
}
```



启动keepalived

```
systemctl start keepalived
```



下面做个简单的测试。从node4上通过haproxy的5000端口访问PG，会连到主库上

```
[postgres@node4 ~]$ psql "host=192.168.234.210 port=5000 password=123456" -c 'select inet_server_addr(),pg_is_in_recovery()'
 inet_server_addr | pg_is_in_recovery
------------------+-------------------
 192.168.234.201  | f
(1 row)
```

通过haproxy的6000端口访问PG，会轮询连接2个备库

```
[postgres@node4 ~]$ psql "host=192.168.234.210 port=6000 password=123456" -c 'select inet_server_addr(),pg_is_in_recovery()'
 inet_server_addr | pg_is_in_recovery
------------------+-------------------
 192.168.234.202  | t
(1 row)


[postgres@node4 ~]$ psql "host=192.168.234.210 port=6000 password=123456" -c 'select inet_server_addr(),pg_is_in_recovery()'
 inet_server_addr | pg_is_in_recovery
------------------+-------------------
 192.168.234.203  | t
(1 row)
```



haproxy部署后，可以通过它的web接口 http://192.168.234.210:7000/查看统计数据



## 8. 级联复制

通常集群中所有的备库都从主库复制数据，但是特定的场景下我们可能需要部署级联复制。基于Patroni搭建的PG集群支持2种形式的级联复制。



### 8. 1 集群内部的级联复制

可以指定某个备库优先从指定成员而不是Leader节点复制数据。相应的配置示例如下：

```
tags:
    replicatefrom: pg2
```

`replicatefrom`只对节点处于Replica角色时有效，并不影响该节点参与Leader选举并成为Leader。当`replicatefrom`指定的复制源节点故障时，Patroni会自动修改PG切换到从Leader节点复制。



### 8.2 集群间的级联复制

我们还可以创建一个只读的备集群，从另一个指定的PostgreSQL实例复制数据。这可以用于创建跨数据中心的灾备集群。相应的配置示例如下：

初始创建一个备集群，可以在Patroni配置文件`/etc/patroni.yml`中加入以下配置

```
bootstrap:
  dcs:
    standby_cluster:
      host: 192.168.234.210
      port: 5432
      primary_slot_name: slot1
      create_replica_methods:
      - basebackup
```

上面的`host`和`port`是上游复制源的主机和端口号，如果上游数据库是配置了读写VIP的PG集群，可以将读写VIP作为`host`避免主集群主备切换时影响备集群。

复制槽选项`primary_slot_name`是可选的，如果配置了复制槽，需要同时在主集群上配置持久slot，确保在新主上始终保持slot。

```
slots:
  slot1:
    type: physical
```



对于已配置好的级联集群，可以使用`patronictl edit-config`命令动态添加`standby_cluster`设置把主集群变成备集群；以及删除`standby_cluster`设置把备集群变成主集群。

```
standby_cluster:
  host: 192.168.234.210
  port: 5432
  primary_slot_name: slot1
  create_replica_methods:
  - basebackup
```



## 9. 参考

- https://patroni.readthedocs.io/en/latest/
- http://blogs.sungeek.net/unixwiz/2018/09/02/centos-7-postgresql-10-patroni/
- https://scalegrid.io/blog/managing-high-availability-in-postgresql-part-1/
- https://jdbc.postgresql.org/documentation/head/connect.html#connection-parameters
- https://www.percona.com/blog/2019/10/23/seamless-application-failover-using-libpq-features-in-postgresql/
