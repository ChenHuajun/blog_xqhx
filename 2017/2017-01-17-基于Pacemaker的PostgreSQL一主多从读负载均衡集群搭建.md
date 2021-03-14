
# 基于Pacemaker的PostgreSQL一主多从读负载均衡集群搭建

## 简介
PostgreSQL的HA方案有很多种，本文演示基于Pacemaker的PostgreSQL一主多从读负载均衡集群搭建。
搭建过程并不是使用原始的Pacemaker pgsql RA脚本，而使用以下我修改和包装的脚本集pha4pgsql。

* [https://github.com/ChenHuajun/pha4pgsql](https://github.com/ChenHuajun/pha4pgsql)

###目标集群特性
1. 秒级自动failover
2. failover零数据丢失(防脑裂)
3. 支持在线主从切换
4. 支持读写分离
5. 支持读负载均衡
6. 支持动态增加和删除只读节点


###环境

- OS:CentOS 7.3
- 节点1:node1(192.168.0.231)
- 节点2:node2(192.168.0.232)
- 节点2:node3(192.168.0.233)
- writer_vip:192.168.0.236
- reader_vip:192.168.0.237

### 依赖软件
- pacemaker
- corosync
- pcs
- ipvsadm

## 安装与配置
### 环境准备
1. 所有节点设置时钟同步

		cp /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
		ntpdate time.windows.com && hwclock -w  

2. 所有节点设置独立的主机名(node1，node2，node3)

		hostnamectl set-hostname node1

3. 设置对所有节点的域名解析

		$ vi /etc/hosts
		...
		192.168.0.231 node1
		192.168.0.232 node2
		192.168.0.233 node3

4. 在所有节点上禁用SELINUX 
	
		$ setenforce 0
		$ vi /etc/selinux/config
		...
		SELINUX=disabled

5. 在所有节点上禁用防火墙 

		systemctl disable firewalld.service
		systemctl stop firewalld.service
	
	如果开启防火墙需要开放postgres，pcsd和corosync的端口。参考[CentOS 7防火墙设置示例](http://blog.chinaunix.net/uid-20726500-id-5748864.html)
	
	* postgres:5432/tcp
	* pcsd:2224/tcp
	* corosync:5405/udp

### 安装和配置Pacemaker+Corosync集群软件

#### 安装Pacemaker和Corosync及相关软件包
在所有节点执行：

    yum install -y pacemaker corosync pcs ipvsadm

#### 启用pcsd服务
在所有节点执行：

	systemctl start pcsd.service
	systemctl enable pcsd.service

#### 设置hacluster用户密码
在所有节点执行：

	echo hacluster | passwd hacluster --stdin

#### 集群认证
在任何一个节点上执行:

	pcs cluster auth -u hacluster -p hacluster node1 node2 node3

#### 同步配置
在任何一个节点上执行:

    pcs cluster setup --last_man_standing=1 --name pgcluster node1 node2 node3

#### 启动集群
在任何一个节点上执行:

    pcs cluster start --all
	
### 安装和配置PostgreSQL

#### 安装PostgreSQL
安装9.2以上的PostgreSQL，本文通过PostgreSQL官方yum源安装CentOS 7.3对应的PostgreSQL 9.6

* [https://yum.postgresql.org/](https://yum.postgresql.org/)

在所有节点执行：

	yum install -y https://yum.postgresql.org/9.6/redhat/rhel-7.3-x86_64/pgdg-centos96-9.6-3.noarch.rpm

	yum install -y postgresql96 postgresql96-contrib postgresql96-libs postgresql96-server postgresql96-devel

	ln -sf /usr/pgsql-9.6 /usr/pgsql
	echo 'export PATH=/usr/pgsql/bin:$PATH' >>~postgres/.bash_profile


#### 创建Master数据库
在node1节点执行：

1. 创建数据目录

		mkdir -p /pgsql/data
		chown -R postgres:postgres /pgsql/
		chmod 0700 /pgsql/data

2. 初始化db
	
		su - postgres
		initdb -D /pgsql/data/

3. 修改postgresql.conf  

		listen_addresses = '*'
		wal_level = hot_standby
		wal_log_hints = on
		synchronous_commit = on
		max_wal_senders=5
		wal_keep_segments = 32
		hot_standby = on
		wal_sender_timeout = 5000
		wal_receiver_status_interval = 2
		max_standby_streaming_delay = -1
		max_standby_archive_delay = -1
		restart_after_crash = off
		hot_standby_feedback = on

    注：设置"`wal_log_hints = on`"可以使用`pg_rewind`修复旧Master。


4. 修改`pg_hba.conf`
 
		local   all                 all                              trust
		host    all                 all     192.168.0.0/24           md5
		host    replication         all     192.168.0.0/24           md5

5. 启动postgres

		pg_ctl -D /pgsql/data/ start

6. 创建复制用户

		createuser --login --replication replication -P -s

    注:加上“-s”选项可支持`pg_rewind`。

#### 创建Slave数据库
在node2和node3节点执行：

1. 创建数据目录

		mkdir -p /pgsql/data
		chown -R postgres:postgres /pgsql/
		chmod 0700 /pgsql/data

2. 创建基础备份

		su - postgres
		pg_basebackup -h node1 -U replication -D /pgsql/data/ -X stream -P


#### 停止PostgreSQL服务
在node1上执行:
		pg_ctl -D /pgsql/data/ stop


### 安装和配置pha4pgsql
在任意一个节点上执行:

1. 下载pha4pgsql

		cd /opt
		git clone git://github.com/Chenhuajun/pha4pgsql.git

2. 拷贝config.ini

		cd /opt/pha4pgsql
		cp template/config_muti_with_lvs.ini.sample  config.ini

注:如果不需要配置基于LVS的负载均衡，可使用模板`config_muti.ini.sample`  

3. 修改config.ini

		pcs_template=muti_with_lvs.pcs.template
		OCF_ROOT=/usr/lib/ocf
		RESOURCE_LIST="msPostgresql vip-master vip-slave"
		pha4pgsql_dir=/opt/pha4pgsql
		writer_vip=192.168.0.236
		reader_vip=192.168.0.237
		node1=node1
		node2=node2
		node3=node3
		othernodes=""
		vip_nic=ens37
		vip_cidr_netmask=24
		pgsql_pgctl=/usr/pgsql/bin/pg_ctl
		pgsql_psql=/usr/pgsql/bin/psql
		pgsql_pgdata=/pgsql/data
		pgsql_pgport=5432
		pgsql_restore_command=""
		pgsql_rep_mode=sync
		pgsql_repuser=replication
		pgsql_reppassord=replication


4. 安装pha4pgsql

		sh install.sh
		./setup.sh

    执行install.sh使用了scp拷贝文件，中途会多次要求输入其它节点的root账号。
    install.sh执行会生成Pacemaker的配置脚本/opt/pha4pgsql/config.pcs，可以根据情况对其中的参数进行调优后再执行setup.sh。


5. 设置环境变量

        export PATH=/opt/pha4pgsql/bin:$PATH
		echo 'export PATH=/opt/pha4pgsql/bin:$PATH' >>/root/.bash_profile

6. 启动集群

        cls_start

7. 确认集群状态
       
        cls_status

    cls_status的输出如下：

		[root@node1 pha4pgsql]# cls_status
		Stack: corosync
		Current DC: node1 (version 1.1.15-11.el7_3.2-e174ec8) - partition with quorum
		Last updated: Wed Jan 11 00:53:58 2017		Last change: Wed Jan 11 00:45:54 2017 by root via crm_attribute on node1
		
		3 nodes and 9 resources configured
		
		Online: [ node1 node2 node3 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node1
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node2
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node1 ]
		     Slaves: [ node2 node3 ]
		 lvsdr	(ocf::heartbeat:lvsdr):	Started node2
		 Clone Set: lvsdr-realsvr-clone [lvsdr-realsvr]
		     Started: [ node2 node3 ]
		     Stopped: [ node1 ]
		
		Node Attributes:
		* Node node1:
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 00000000050001B0
		    + pgsql-status                    	: PRI       
		* Node node2:
		    + master-pgsql                    	: 100       
		    + pgsql-data-status               	: STREAMING|SYNC
		    + pgsql-status                    	: HS:sync   
		* Node node3:
		    + master-pgsql                    	: -INFINITY 
		    + pgsql-data-status               	: STREAMING|ASYNC
		    + pgsql-status                    	: HS:async  
		
		Migration Summary:
		* Node node2:
		* Node node3:
		* Node node1:
		
		pgsql_REPL_INFO:node1|1|00000000050001B0

	检查集群的健康状态。完全健康的集群需要满足以下条件：
	
	1. msPostgresql在每个节点上都已启动
	2. 在其中一个节点上msPostgresql处于Master状态，其它的为Salve状态
	3. Salve节点的data-status值是以下中的一个   
		- STREAMING|SYNC   
		   同步复制Slave
		- STREAMING|POTENTIAL   
		   候选同步复制Slave
		- STREAMING|ASYNC   
		   异步复制Slave

	`pgsql_REPL_INFO`的3段内容分别指当前master，上次提升前的时间线和xlog位置。

		pgsql_REPL_INFO:node1|1|00000000050001B0


	LVS配置在node2上

		[root@node2 ~]#  ipvsadm -L
		IP Virtual Server version 1.2.1 (size=4096)
		Prot LocalAddress:Port Scheduler Flags
		  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
		TCP  node2:postgres rr
		  -> node2:postgres               Route   1      0          0         
		  -> node3:postgres               Route   1      0          0

## 故障测试

### Master故障

1. 停止Master上的网卡模拟故障

		[root@node1 pha4pgsql]# ifconfig ens37 down


2. 检查集群状态

	Pacemaker已经将Master和写VIP切换到node2上

		[root@node2 ~]# cls_status
		resource msPostgresql is NOT running
		Stack: corosync
		Current DC: node2 (version 1.1.15-11.el7_3.2-e174ec8) - partition with quorum
		Last updated: Wed Jan 11 01:25:08 2017		Last change: Wed Jan 11 01:21:26 2017 by root via crm_attribute on node2
		
		3 nodes and 9 resources configured
		
		Online: [ node2 node3 ]
		OFFLINE: [ node1 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node2
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node3
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node2 ]
		     Slaves: [ node3 ]
		     Stopped: [ node1 ]
		 lvsdr	(ocf::heartbeat:lvsdr):	Started node3
		 Clone Set: lvsdr-realsvr-clone [lvsdr-realsvr]
		     Started: [ node3 ]
		     Stopped: [ node1 node2 ]
		
		Node Attributes:
		* Node node2:
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 00000000050008E0
		    + pgsql-status                    	: PRI       
		* Node node3:
		    + master-pgsql                    	: 100       
		    + pgsql-data-status               	: STREAMING|SYNC
		    + pgsql-status                    	: HS:sync   
		
		Migration Summary:
		* Node node2:
		* Node node3:
		
		pgsql_REPL_INFO:node2|2|00000000050008E0


	LVS和读VIP被移到了node3上

		[root@node3 ~]# ipvsadm -L
		IP Virtual Server version 1.2.1 (size=4096)
		Prot LocalAddress:Port Scheduler Flags
		  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
		TCP  node3:postgres rr
		  -> node3:postgres               Route   1      0          0


3. 修复旧Master的网卡

	在旧Master node1上，postgres进程还在（注1）。但是由于配置的是同步复制，数据无法写入不会导致脑裂。
	
		[root@node1 pha4pgsql]# ps -ef|grep postgres
		root      20295   2269  0 01:35 pts/0    00:00:00 grep --color=auto postgres
		postgres  20556      1  0 00:45 ?        00:00:01 /usr/pgsql-9.6/bin/postgres -D /pgsql/data -c config_file=/pgsql/data/postgresql.conf
		postgres  20566  20556  0 00:45 ?        00:00:00 postgres: logger process   
		postgres  20574  20556  0 00:45 ?        00:00:00 postgres: checkpointer process   
		postgres  20575  20556  0 00:45 ?        00:00:00 postgres: writer process   
		postgres  20576  20556  0 00:45 ?        00:00:00 postgres: stats collector process   
		postgres  22390  20556  0 00:45 ?        00:00:00 postgres: wal writer process   
		postgres  22391  20556  0 00:45 ?        00:00:00 postgres: autovacuum launcher process 

	启动网卡后，postgres进程被停止
	
		[root@node1 pha4pgsql]# ifconfig ens37 up
		[root@node1 pha4pgsql]# ps -ef|grep postgres
		root      21360   2269  0 01:36 pts/0    00:00:00 grep --color=auto postgres
		[root@node1 pha4pgsql]# cls_status
		resource msPostgresql is NOT running
		Stack: corosync
		Current DC: node2 (version 1.1.15-11.el7_3.2-e174ec8) - partition with quorum
		Last updated: Wed Jan 11 01:36:20 2017		Last change: Wed Jan 11 01:36:00 2017 by hacluster via crmd on node2
		
		3 nodes and 9 resources configured
		
		Online: [ node1 node2 node3 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node2
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node3
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node2 ]
		     Slaves: [ node3 ]
		     Stopped: [ node1 ]
		 lvsdr	(ocf::heartbeat:lvsdr):	Started node3
		 Clone Set: lvsdr-realsvr-clone [lvsdr-realsvr]
		     Started: [ node3 ]
		     Stopped: [ node1 node2 ]
		
		Node Attributes:
		* Node node1:
		    + master-pgsql                    	: -INFINITY 
		    + pgsql-data-status               	: DISCONNECT
		    + pgsql-status                    	: STOP      
		* Node node2:
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 00000000050008E0
		    + pgsql-status                    	: PRI       
		* Node node3:
		    + master-pgsql                    	: 100       
		    + pgsql-data-status               	: STREAMING|SYNC
		    + pgsql-status                    	: HS:sync   
		
		Migration Summary:
		* Node node2:
		* Node node3:
		* Node node1:
		   pgsql: migration-threshold=3 fail-count=1000000 last-failure='Wed Jan 11 01:36:08 2017'
		
		Failed Actions:
		* pgsql_start_0 on node1 'unknown error' (1): call=278, status=complete, exitreason='The master's timeline forked off current database system timeline 2 before latest checkpoint location 0000000005000B80, REPL_INF',
		    last-rc-change='Wed Jan 11 01:36:07 2017', queued=0ms, exec=745ms
		
		
		pgsql_REPL_INFO:node2|2|00000000050008E0
	
		
	注1：这是通过`ifconfig ens37 down`停止网卡模拟故障的特殊现象（或者说是corosync的bug），Pacemkaer的日志中不停的输出以下警告。在实际的物理机宕机或网卡故障时，故障节点会由于失去quorum，postgres进程会被Pacemaker主动停止。
	
		[43260] node3 corosyncwarning [MAIN  ] Totem is unable to form a cluster because of an operating system or network fault. The most common cause of this message is that the local firewall is configured improperly.

4. 修复旧Master(node1)并作为Slave加入集群

	通过pg_rewind修复旧Master

		[root@node1 pha4pgsql]# cls_repair_by_pg_rewind 
		resource msPostgresql is NOT running
		resource msPostgresql is NOT running
		resource msPostgresql is NOT running
		connected to server
		servers diverged at WAL position 0/50008E0 on timeline 2
		rewinding from last common checkpoint at 0/5000838 on timeline 2
		reading source file list
		reading target file list
		reading WAL in target
		need to copy 99 MB (total source directory size is 117 MB)
		102359/102359 kB (100%) copied
		creating backup label and updating control file
		syncing target data directory
		Done!
		pg_rewind complete!
		resource msPostgresql is NOT running
		resource msPostgresql is NOT running
		Waiting for 1 replies from the CRMd. OK
		wait for recovery complete
		.....
		slave recovery of node1 successed

	检查集群状态

		[root@node1 pha4pgsql]# cls_status
		Stack: corosync
		Current DC: node2 (version 1.1.15-11.el7_3.2-e174ec8) - partition with quorum
		Last updated: Wed Jan 11 01:39:30 2017		Last change: Wed Jan 11 01:37:35 2017 by root via crm_attribute on node2
		
		3 nodes and 9 resources configured
		
		Online: [ node1 node2 node3 ]
		
		Full list of resources:
		
		 vip-master	(ocf::heartbeat:IPaddr2):	Started node2
		 vip-slave	(ocf::heartbeat:IPaddr2):	Started node3
		 Master/Slave Set: msPostgresql [pgsql]
		     Masters: [ node2 ]
		     Slaves: [ node1 node3 ]
		 lvsdr	(ocf::heartbeat:lvsdr):	Started node3
		 Clone Set: lvsdr-realsvr-clone [lvsdr-realsvr]
		     Started: [ node1 node3 ]
		     Stopped: [ node2 ]
		
		Node Attributes:
		* Node node1:
		    + master-pgsql                    	: -INFINITY 
		    + pgsql-data-status               	: STREAMING|ASYNC
		    + pgsql-status                    	: HS:async  
		* Node node2:
		    + master-pgsql                    	: 1000      
		    + pgsql-data-status               	: LATEST    
		    + pgsql-master-baseline           	: 00000000050008E0
		    + pgsql-status                    	: PRI       
		* Node node3:
		    + master-pgsql                    	: 100       
		    + pgsql-data-status               	: STREAMING|SYNC
		    + pgsql-status                    	: HS:sync   
		    + pgsql-xlog-loc                  	: 000000000501F118
		
		Migration Summary:
		* Node node2:
		* Node node3:
		* Node node1:
		
		pgsql_REPL_INFO:node2|2|00000000050008E0


### Slave故障

LVS配置在node3上，2个real server

	[root@node3 ~]# ipvsadm -L
	IP Virtual Server version 1.2.1 (size=4096)
	Prot LocalAddress:Port Scheduler Flags
	  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
	TCP  node3:postgres rr
	  -> node1:postgres               Route   1      0          0         
	  -> node3:postgres               Route   1      0          0

在其中一个Slave(node1)上停止网卡

	[root@node1 pha4pgsql]# ifconfig ens37 down

Pacemaker已自动修改LVS的real server配置

	[root@node3 ~]# ipvsadm -L
	IP Virtual Server version 1.2.1 (size=4096)
	Prot LocalAddress:Port Scheduler Flags
	  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
	TCP  node3:postgres rr
	  -> node3:postgres               Route   1      0          0 


## 添加Slave扩容读负载均衡

目前配置的是1主2从集群，2个Slave通过读VIP+LVS做读负载均衡，如果读负载很高可以添加额外的Slave扩展读性能。
把更多的Slave直接添加到Pacemaker集群中可以达到这个目的，但过多的节点数会增加Pacemaker+Corosync集群的复杂性和通信负担（Corosync的通信是一个环路，节点数越多，时延越大）。所以不把额外的Slave加入Pacemaker集群，仅仅加到LVS的real server中，并让lvsdr监视Slave的健康状况，动态更新LVS的real server列表。方法如下：


### 创建额外的Slave数据库
准备第4台机器node4(192.168.0.234),并在该机器上执行以下命令创建新的Slave

1. 禁用SELINUX 
	
		$ setenforce 0
		$ vi /etc/selinux/config
		...
		SELINUX=disabled

2. 禁用防火墙 

		systemctl disable firewalld.service
		systemctl stop firewalld.service

3. 安装PostgreSQL

		yum install -y https://yum.postgresql.org/9.6/redhat/rhel-7.3-x86_64/pgdg-centos96-9.6-3.noarch.rpm
	
		yum install -y postgresql96 postgresql96-contrib postgresql96-libs postgresql96-server postgresql96-devel
	
		ln -sf /usr/pgsql-9.6 /usr/pgsql
		echo 'export PATH=/usr/pgsql/bin:$PATH' >>~postgres/.bash_profile

4. 创建数据目录

		mkdir -p /pgsql/data
		chown -R postgres:postgres /pgsql/
		chmod 0700 /pgsql/data

5. 创建Salve备份

	从当前的Master节点(即写VIP 192.168.0.236)拉取备份创建Slave

		su - postgres
		pg_basebackup -h 192.168.0.236 -U replication -D /pgsql/data/ -X stream -P


6. 编辑postgresql.conf

	将postgresql.conf中的下面一行删掉

		￥vi /pgsql/data/postgresql.conf
		...
		#include '/var/lib/pgsql/tmp/rep_mode.conf' # added by pgsql RA

7. 编辑recovery.conf

		$vi /pgsql/data/recovery.conf
		standby_mode = 'on'
		primary_conninfo = 'host=192.168.0.236 port=5432 application_name=192.168.0.234 user=replication password=replication keepalives_idle=60 keepalives_interval=5 keepalives_count=5'
		restore_command = ''
		recovery_target_timeline = 'latest'


	上面的`application_name`设置为本节点的IP地址192.168.0.234

8. 启动Slave

		pg_ctl -D /pgsql/data/ start
	
	在Master上检查postgres wal sender进程，新建的Slave(192.168.0.234)已经和Master建立了流复制。
	
		[root@node1 pha4pgsql]# ps -ef|grep '[w]al sender'
		postgres  32387 111175  0 12:15 ?        00:00:00 postgres: wal sender process replication 192.168.0.234(47894) streaming 0/7000220
		postgres 116675 111175  0 12:01 ?        00:00:00 postgres: wal sender process replication 192.168.0.233(33652) streaming 0/7000220
		postgres 117079 111175  0 12:01 ?        00:00:00 postgres: wal sender process replication 192.168.0.232(40088) streaming 0/7000220

### 配置LVS real server

1. 设置系统参数

	    echo 1 > /proc/sys/net/ipv4/conf/lo/arp_ignore
	    echo 2 > /proc/sys/net/ipv4/conf/lo/arp_announce
	    echo 1 > /proc/sys/net/ipv4/conf/all/arp_ignore
	    echo 2 > /proc/sys/net/ipv4/conf/all/arp_announce

2. 在lo网卡上添加读VIP

		ip a add 192.168.0.237/32 dev lo:0

### 将新建的Slave加入到LVS中

现在LVS的配置中还没有把新的Slave作为real server加入

	[root@node3 ~]# ipvsadm
	IP Virtual Server version 1.2.1 (size=4096)
	Prot LocalAddress:Port Scheduler Flags
	  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
	TCP  node3:postgres rr
	  -> node2:postgres               Route   1      0          0         
	  -> node3:postgres               Route   1      0          0 

在Pacemaker集群的任意一个节点(node1,node2或node3)上，修改lvsdr RA的配置，加入新的real server。

	[root@node2 ~]# pcs resource update lvsdr realserver_get_real_servers_script="/opt/pha4pgsql/tools/get_active_slaves /usr/pgsql/bin/psql \"host=192.168.0.236 port=5432 dbname=postgres user=replication password=replication connect_timeout=5\""

设置`realserver_get_real_servers_script`参数后，lvsdr会通过脚本获取LVS的real server列表，这里的`get_active_slaves`会通过写VIP连接到Master节点获取所有以连接到Master的Slave的`application_name`作为real server。设置后新的Slave 192.168.0.234已经被加入到real server 列表中了。

	[root@node2 ~]# ipvsadm
	IP Virtual Server version 1.2.1 (size=4096)
	Prot LocalAddress:Port Scheduler Flags
	  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
	TCP  node2:postgres rr
	  -> node2:postgres               Route   1      0          0         
	  -> node3:postgres               Route   1      0          0         
	  -> 192.168.0.234:postgres       Route   1      0          0


###测试读负载均衡
在当前的Master节点(node1)上通过读VIP访问postgres,可以看到psql会轮询连接到3个不同的Slave上。

	[root@node1 pha4pgsql]# psql "host=192.168.0.237 port=5432 dbname=postgres user=replication password=replication" -tAc "select pg_postmaster_start_time()"
	2017-01-14 12:01:48.068455+08
	[root@node1 pha4pgsql]# psql "host=192.168.0.237 port=5432 dbname=postgres user=replication password=replication" -tAc "select pg_postmaster_start_time()"
	2017-01-14 12:01:12.222412+08
	[root@node1 pha4pgsql]# psql "host=192.168.0.237 port=5432 dbname=postgres user=replication password=replication" -tAc "select pg_postmaster_start_time()"
	2017-01-14 12:15:19.614782+08
	[root@node1 pha4pgsql]# psql "host=192.168.0.237 port=5432 dbname=postgres user=replication password=replication" -tAc "select pg_postmaster_start_time()"
	2017-01-14 12:01:48.068455+08
	[root@node1 pha4pgsql]# psql "host=192.168.0.237 port=5432 dbname=postgres user=replication password=replication" -tAc "select pg_postmaster_start_time()"
	2017-01-14 12:01:12.222412+08
	[root@node1 pha4pgsql]# psql "host=192.168.0.237 port=5432 dbname=postgres user=replication password=replication" -tAc "select pg_postmaster_start_time()"
	2017-01-14 12:15:19.614782+08

下面测试Salve节点发生故障的场景。
先连接到其中一台Slave

	[root@node1 pha4pgsql]# psql "host=192.168.0.237 port=5432 dbname=postgres user=replication password=replication"
	psql (9.6.1)
	Type "help" for help.

当前连接在node4上

	[root@node4 ~]# ps -ef|grep postgres
	postgres  11911      1  0 12:15 pts/0    00:00:00 /usr/pgsql-9.6/bin/postgres -D /pgsql/data
	postgres  11912  11911  0 12:15 ?        00:00:00 postgres: logger process   
	postgres  11913  11911  0 12:15 ?        00:00:00 postgres: startup process   recovering 000000090000000000000007
	postgres  11917  11911  0 12:15 ?        00:00:00 postgres: checkpointer process   
	postgres  11918  11911  0 12:15 ?        00:00:00 postgres: writer process   
	postgres  11920  11911  0 12:15 ?        00:00:00 postgres: stats collector process   
	postgres  11921  11911  0 12:15 ?        00:00:04 postgres: wal receiver process   streaming 0/7000CA0
	postgres  12004  11911  0 13:19 ?        00:00:00 postgres: replication postgres 192.168.0.231(42116) idle
	root      12006   2230  0 13:19 pts/0    00:00:00 grep --color=auto postgres

强制杀死node4上的postgres进程

	[root@node4 ~]# killall postgres

lvsdr探测到node4挂了后会自动将其从real server列表中摘除

	[root@node2 ~]# ipvsadm
	IP Virtual Server version 1.2.1 (size=4096)
	Prot LocalAddress:Port Scheduler Flags
	  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
	TCP  node2:postgres rr
	  -> node2:postgres               Route   1      0          0         
	  -> node3:postgres               Route   1      0          0


psql执行下一条SQL时就会自动连接到其它Slave上。

	postgres=# select pg_postmaster_start_time();
	FATAL:  terminating connection due to administrator command
	server closed the connection unexpectedly
		This probably means the server terminated abnormally
		before or while processing the request.
	The connection to the server was lost. Attempting reset: Succeeded.
	postgres=# select pg_postmaster_start_time();
	   pg_postmaster_start_time    
	-------------------------------
	 2017-01-14 12:01:48.068455+08
	(1 row)


### 指定静态的real server列表

有时候不希望将所有连接到Master的Slave都加入到LVS的real server中，比如某个`Slave`可能实际上是`pg_receivexlog`。
这时可以在lvsdr上指定静态的real server列表作为白名单。

#### 方法1:

通过`default_weight`和`weight_of_realservers`指定各个real server的权重，将不想参与到负载均衡的Slave的权重设置为0。
并且还是通过在Master上查询Slave一览的方式监视Slave健康状态。

下面在Pacemaker集群的任意一个节点(node1,node2或node3)上，修改lvsdr RA的配置，设置有效的real server列表为node,node2和node3。

	pcs resource update lvsdr default_weight="0"
	pcs resource update lvsdr weight_of_realservers="node1,1 node2,1 node3,1"
	pcs resource update lvsdr realserver_get_real_servers_script="/opt/pha4pgsql/tools/get_active_slaves /usr/pgsql/bin/psql \"host=192.168.0.236 port=5432 dbname=postgres user=replication password=replication connect_timeout=5\""

在lvsdr所在节点上检查LVS的状态，此时node4(192.168.0.234)的权重为0，LVS不会往node4上转发请求。

	[root@node2 ~]# ipvsadm
	IP Virtual Server version 1.2.1 (size=4096)
	Prot LocalAddress:Port Scheduler Flags
	  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
	
	TCP  node2:postgres rr
	  -> node2:postgres               Route   1      0          0         
	  -> node3:postgres               Route   1      0          0         
	  -> 192.168.0.234:postgres       Route   0      0          0

####方法2:

通过`default_weight`和`weight_of_realservers`指定real server一览，并通过调用`check_active_slave`脚本，依次连接到real server中的每个节点上检查其是否可以连接并且是Slave。

	pcs resource update lvsdr default_weight="1"
	pcs resource update lvsdr weight_of_realservers="node1 node2 node3 192.168.0.234"
	pcs resource update lvsdr realserver_dependent_resource=""
	pcs resource update lvsdr realserver_get_real_servers_script=""
	pcs resource update lvsdr realserver_check_active_real_server_script="/opt/pha4pgsql/tools/check_active_slave /usr/pgsql/bin/psql \"port=5432 dbname=postgres user=replication password=replication connect_timeout=5\" -h"

推荐采用方法1，因为每次健康检查只需要1次连接。


## 参考
- [Pacemaker High Availability for PostgreSQL](https://github.com/ChenHuajun/pha4pgsql)
- [PostgreSQL流复制高可用的原理与实践](http://www.postgres.cn/news/viewone/1/124)
- [PgSQL Replicated Cluster](http://clusterlabs.org/wiki/PgSQL_Replicated_Cluster)
- [Pacemaker+Corosync搭建PostgreSQL集群](http://my.oschina.net/aven92/blog/518928)
