#基于Pacemkaer Resource Agent的LVS负载均衡

##前言
对于有主从状态的集群，实现读负载均衡需要将读请求分发到各Slave上，并且主从发生切换后，要自动调整分发策略。然而，当前主流的LVS监控方案，keepalived或Pacemaker + ldirectord并不能很好的支持这一点，它们需要在发生failover后修改相应的配置文件，这并不是非常方便。为了把LVS更好集成到Pacemaker集群里，将LVS相关的控制操作包装成资源代理，并提供多种灵活的方式动态配置real server。当前只支持工作在LVS的DR模式。

##功能
1. Director Server和Real Server上内核参数的自动设置
2. 负载均衡策略等LVS参数的配置
3. Real Server权重的配置
4. 多种Real Server列表配置方式
    * a)静态列表
    * b)根据资源依赖动态设置
    * c)根据节点属性动态设置
    * d)以上a,b,c 3种的组合
    * e)根据外部脚本动态获取
5. 多种Real Server的健康检查方式
    * 由Real Server对应的RA(如pgsql)检查
    * 由外部脚本动态检查
6. 在线动态调整Real Server  
    Real Server列表发生变更时，已建立的到非故障Real Server的连接不受影响。


##配置参数
* vip

	虚拟服务的VIP.

* port

    虚拟服务的端口号

* `virtual_service_options`

	传递给ipvsadm的虚拟服务的选项，比如"-s rr".

* `default_weight`

	Real Server的缺省权重，默认为1.

* `weight_of_realservers`

    Real Server的host和权重组合的列表，设置形式为"node1,weight1 node2,weight2 ..."。
	如果省略权重，则使用`default_weight`。使用了`realserver_dependent_resource`，
    `realserver_dependent_attribute_name`或`realserver_dependent_attribute_value`参数时，
	host必须是节点的主机名。

* `realserver_dependent_resource`

	Real Server依赖的资源，只有被分配了该资源的节点会被加入到LVS的real server列表中。
	如果`realserver_get_real_servers_script`不为空，该参数将失效。

* `realserver_dependent_attribute_name`

	Real Server依赖的节点属性名。
	如果`realserver_get_real_servers_script`或`realserver_check_active_slave_script`不为空，该参数将失效。

* `realserver_dependent_attribute_value`

	Real Server依赖的节点属性值的正则表达式，比如对于pgsql RA的从节点，可以设置为"HS:sync|HS:potential|HS:async"
	如果`realserver_get_real_servers_script`或`realserver_check_active_slave_script`不为空，该参数将失效。

* `realserver_get_real_servers_script`

	动态获取Real Server列表的脚本。该脚本输出空格分隔得Real Server列表。


* `realserver_check_active_real_server_script`
	动态检查Real Server健康的脚本。该脚本接收节点名作为参数。
	如果`realserver_get_real_servers_script`或`realserver_check_active_slave_script`不为空，该参数将失效。


##安装

##前提需求
* Pacemaker
* Corosync
* ipvsadm

###获取RA脚本
    
    wget https://raw.githubusercontent.com/ChenHuajun/pha4pgsql/master/ra/lvsdr
    wget https://raw.githubusercontent.com/ChenHuajun/pha4pgsql/master/ra/lvsdr-realsvr

###安装RA脚本

    cp lvsdr lvsdr-realsvr /usr/lib/ocf/resource.d/heartbeat/
    chmod +x  /usr/lib/ocf/resource.d/heartbeat/lvsdr 
    chmod +x  /usr/lib/ocf/resource.d/heartbeat/lvsdr-realsvr


##使用示例

以下是PostgreSQL主从集群中读负载均衡的配置示例，读请求通过LVS的RR负载均衡策略平均分散到2个Slave节点上。

##示例1:通过资源依赖和节点属性动态设置Real Server列表

配置`lvsdr-realsvr`和每个expgsql的Slave资源部署在一起

	pcs -f pgsql_cfg resource create lvsdr-realsvr lvsdr-realsvr \
	   vip="192.168.0.237" \
	   nic_lo="lo:0" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="30s" interval="60s" on-fail="restart" \
	   op stop    timeout="60s" interval="0s"  on-fail="block"
	
	pcs -f pgsql_cfg resource clone lvsdr-realsvr clone-node-max=1 notify=false
	
	pcs -f pgsql_cfg constraint colocation add lvsdr with vip-slave INFINITY
	pcs -f pgsql_cfg constraint colocation add lvsdr-realsvr-clone with Slave msPostgresql INFINITY

配值lvsdr的real server列表依赖于`lvsdr-realsvr-clone`资源和节点的`pgsql-status`特定属性值

	pcs -f pgsql_cfg resource create lvsdr lvsdr \
	   vip="192.168.0.237" \
	   port="5432" \
	   realserver_dependent_resource="lvsdr-realsvr-clone" \
	   realserver_dependent_attribute_name="pgsql-status" \
	   realserver_dependent_attribute_value="HS:sync|HS:potential|HS:async" \
	   virtual_service_options="-s rr" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="30s" interval="5s" on-fail="restart" \
	   op stop    timeout="60s" interval="0s"  on-fail="block"


完整的配置如下:

	pcs cluster cib pgsql_cfg
	
	pcs -f pgsql_cfg property set no-quorum-policy="stop"
	pcs -f pgsql_cfg property set stonith-enabled="false"
	pcs -f pgsql_cfg resource defaults resource-stickiness="1"
	pcs -f pgsql_cfg resource defaults migration-threshold="10"
	
	pcs -f pgsql_cfg resource create vip-master IPaddr2 \
	   ip="192.168.0.236" \
	   nic="eno16777736" \
	   cidr_netmask="24" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="60s" interval="10s" on-fail="restart" \
	   op stop    timeout="60s" interval="0s"  on-fail="block"
	
	pcs -f pgsql_cfg resource create vip-slave IPaddr2 \
	   ip="192.168.0.237" \
	   nic="eno16777736" \
	   cidr_netmask="24" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="60s" interval="10s" on-fail="restart" \
	   op stop    timeout="60s" interval="0s"  on-fail="block"
	
	pcs -f pgsql_cfg resource create pgsql expgsql \
	   pgctl="/usr/pgsql-9.5/bin/pg_ctl" \
	   psql="/usr/pgsql-9.5/bin/psql" \
	   pgdata="/data/postgresql/data" \
	   pgport="5432" \
	   rep_mode="sync" \
	   node_list="node1 node2 node3 " \
	   restore_command="" \
	   primary_conninfo_opt="user=replication password=replication keepalives_idle=60 keepalives_interval=5 keepalives_count=5" \
	   master_ip="192.168.0.236" \
	   restart_on_promote="false" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="60s" interval="4s" on-fail="restart" \
	   op monitor timeout="60s" interval="3s"  on-fail="restart" role="Master" \
	   op promote timeout="60s" interval="0s"  on-fail="restart" \
	   op demote  timeout="60s" interval="0s"  on-fail="stop" \
	   op stop    timeout="60s" interval="0s"  on-fail="block" \
	   op notify  timeout="60s" interval="0s"
	
	pcs -f pgsql_cfg resource master msPostgresql pgsql \
	   master-max=1 master-node-max=1 clone-node-max=1 notify=true \
	   migration-threshold="3" target-role="Master"
	
	pcs -f pgsql_cfg constraint colocation add vip-master with Master msPostgresql INFINITY
	pcs -f pgsql_cfg constraint order promote msPostgresql then start vip-master symmetrical=false score=INFINITY
	pcs -f pgsql_cfg constraint order demote  msPostgresql then stop  vip-master symmetrical=false score=0
	
	pcs -f pgsql_cfg constraint colocation add vip-slave with Slave msPostgresql INFINITY
	pcs -f pgsql_cfg constraint order promote  msPostgresql then start vip-slave symmetrical=false score=INFINITY
	pcs -f pgsql_cfg constraint order stop msPostgresql then stop vip-slave symmetrical=false score=0
	
	pcs -f pgsql_cfg resource create lvsdr lvsdr \
	   vip="192.168.0.237" \
	   port="5432" \
	   realserver_dependent_resource="lvsdr-realsvr-clone" \
	   realserver_dependent_attribute_name="pgsql-status" \
	   realserver_dependent_attribute_value="HS:sync|HS:potential|HS:async" \
	   virtual_service_options="-s rr" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="30s" interval="5s" on-fail="restart" \
	   op stop    timeout="60s" interval="0s"  on-fail="block"
	
	pcs -f pgsql_cfg resource create lvsdr-realsvr lvsdr-realsvr \
	   vip="192.168.0.237" \
	   nic_lo="lo:0" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="30s" interval="60s" on-fail="restart" \
	   op stop    timeout="60s" interval="0s"  on-fail="block"
	
	pcs -f pgsql_cfg resource clone lvsdr-realsvr clone-node-max=1 notify=false
	
	pcs -f pgsql_cfg constraint colocation add lvsdr with vip-slave INFINITY
	pcs -f pgsql_cfg constraint colocation add lvsdr-realsvr-clone with Slave msPostgresql INFINITY
	
	pcs -f pgsql_cfg constraint order stop vip-slave then start vip-slave symmetrical=false score=0
	pcs -f pgsql_cfg constraint order stop vip-master then start vip-master symmetrical=false score=0
	pcs -f pgsql_cfg constraint order start lvsdr-realsvr-clone then start lvsdr symmetrical=false score=0
	pcs -f pgsql_cfg constraint order start lvsdr then start vip-slave symmetrical=false score=0
	
	pcs cluster cib-push pgsql_cfg

###示例2:从Master节点查询Slave节点

配值lvsdr的real server列表通过`get_active_slaves`脚本在Master上动态查询Slave节点。

	pcs -f pgsql_cfg resource create lvsdr lvsdr \
	   vip="192.168.0.237" \
	   port="5432" \
	   default_weight="0" \
	   weight_of_realservers="node1,1 node2,1 node3,1 192.168.0.234,1" \
	   realserver_get_real_servers_script="/opt/pha4pgsql/tools/get_active_slaves /usr/pgsql/bin/psql \"host=192.168.0.236 port=5432 dbname=postgres user=replication password=replication connect_timeout=5\"" \
	   virtual_service_options="-s rr" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="30s" interval="5s" on-fail="restart" \
	   op stop    timeout="60s" interval="0s"  on-fail="block"

采用这种方式可以将Pacemaker集群以外的Slave作为real server加入到LVS。对这样的节点需要进行下面的设置

1. 设置作为LVS real server的系统参数

	    echo 1 > /proc/sys/net/ipv4/conf/lo/arp_ignore
	    echo 2 > /proc/sys/net/ipv4/conf/lo/arp_announce
	    echo 1 > /proc/sys/net/ipv4/conf/all/arp_ignore
	    echo 2 > /proc/sys/net/ipv4/conf/all/arp_announce

2. 在lo网卡上添加读VIP

		ip a add 192.168.0.237/32 dev lo:0

3. 设置Slave节点连接信息中`application_name`为该节点的主机名或ip地址。

	[root@node4 pha4pgsql]# cat /data/postgresql/data/recovery.conf 
	standby_mode = 'on'
	primary_conninfo = 'host=192.168.0.236 port=5432 application_name=192.168.0.234 user=replication password=replication keepalives_idle=60 keepalives_interval=5 keepalives_count=5'
	restore_command = ''
	recovery_target_timeline = 'latest'


###示例3:直接连接Slave检查节点健康状况

通过`default_weight`和`weight_of_realservers`指定real server一览，并通过调用`check_active_slave`脚本，依次连接到real server中的每个节点上检查其是否可以连接并且是Slave。

	pcs -f pgsql_cfg resource create lvsdr lvsdr \
	   vip="192.168.0.237" \
	   port="5432" \
	   default_weight="1" \
	   weight_of_realservers="node1 node2 node3 192.168.0.234" \
	   realserver_check_active_real_server_script="/opt/pha4pgsql/tools/check_active_slave /usr/pgsql/bin/psql \"port=5432 dbname=postgres user=replication password=replication connect_timeout=5\" -h" \
	   virtual_service_options="-s rr" \
	   op start   timeout="60s" interval="0s"  on-fail="restart" \
	   op monitor timeout="30s" interval="5s" on-fail="restart" \
	   op stop    timeout="60s" interval="0s"  on-fail="block"

	pcs resource update lvsdr default_weight="1"
	pcs resource update lvsdr weight_of_realservers="node1 node2 node3 192.168.0.234"
	pcs resource update lvsdr realserver_dependent_resource=""
	pcs resource update lvsdr realserver_get_real_servers_script=""
	pcs resource update lvsdr realserver_check_active_real_server_script="/opt/pha4pgsql/tools/check_active_slave /usr/pgsql/bin/psql \"port=5432 dbname=postgres user=replication password=replication connect_timeout=5\" -h"

