# 关于PostgreSQL流复制的延迟

## 问题
MySQL的复制存在一个回放延迟的问题，即备机回放的速度赶不上主机SQL执行的速度，导致延迟越来越厉害。原因在于MySQL的binlog回放是单线程，主机的SQL执行是多线程，单线程的回放速度跟不上。这个问题在新版本的MySQL上应该已经解决了，解决办法就是让备机回放也使用多线程。这个问题，BAT的工程师们在公开场合讲过N次了，印象很深刻。
PostgreSQL流复制的备机也是单线程(进程)的，那么有没有类似的问题呢？
实际上不会，因为PostgreSQL的流复制是基于块的物理复制，回放的代价小。下面看看实际的测试结果。

## 测试环境
主机和备机都是以下配置的虚拟机

  CPU：2 core   
  MEM: 2G   
  OS:CentOS release 6.5 (Final)   
  PostgreSQL:9.4.2(shared_buffers = 512MB)   

## 测试数据

	chenhj=# create table tb1(id serial,c1 int);  
	CREATE TABLE
	
	[chenhj@node1 ~]$ cat test.sql 
	insert into tb1(c1) values(1);


## 测试结果

在主机上执行pgbench。


	[chenhj@node1 ~]$ pgbench -n -f test.sql -T 50 -c 20 
	transaction type: Custom query
	scaling factor: 1
	query mode: simple
	number of clients: 20
	number of threads: 1
	duration: 50 s
	number of transactions actually processed: 95324
	latency average: 10.491 ms
	tps = 1905.733296 (including connections establishing)
	tps = 1910.579339 (excluding connections establishing)


pgbench执行过程中，在备机不断执行下面的语句，发现偶尔会出现100个字节左右的回放延迟，但延迟没有积累，即没有出现备机跟不上主机的情况。

	SELECT pg_last_xlog_receive_location() - pg_last_xlog_replay_location();

## 资源占用
根据下面的top资源占用情况可知，主机上WAL发送进程(18374)占用CPU最高为21.6%。备机上WAL接受进程（8181）最高为17.3%，其次是Startup进程，也即是恢复进程(5012)，占用CPU 8.0%。

**主机**

	[root@node1 ~]# top
	top - 12:37:28 up  3:18,  3 users,  load average: 0.02, 0.01, 0.01
	Tasks: 156 total,   5 running, 151 sleeping,   0 stopped,   0 zombie
	Cpu(s): 24.9%us, 43.9%sy,  0.0%ni, 21.4%id,  5.4%wa,  3.1%hi,  1.3%si,  0.0%st
	Mem:   1922268k total,  1718824k used,   203444k free,    10072k buffers
	Swap:  2064376k total,   394032k used,  1670344k free,   463376k cached
	
	  PID USER      PR  NI  VIRT  RES  SHR S %CPU %MEM    TIME+  COMMAND                                               
	18374 chenhj    20   0  663m 2280 1432 R 21.6  0.1   0:10.99 postgres                                               
	18965 chenhj    20   0 13848 1176  812 R 10.0  0.1   0:00.74 pgbench                                                
	18967 chenhj    20   0  663m 5688 4688 S  8.3  0.3   0:00.59 postgres                                               
	18969 chenhj    20   0  663m 5660 4660 S  7.3  0.3   0:00.50 postgres                                               
	18968 chenhj    20   0  663m 5660 4660 S  7.0  0.3   0:00.50 postgres                                               
	18970 chenhj    20   0  663m 5664 4664 S  7.0  0.3   0:00.47 postgres                                               
	18971 chenhj    20   0  663m 5676 4676 S  6.6  0.3   0:00.47 postgres                                               
	18972 chenhj    20   0  663m 5648 4648 S  6.3  0.3   0:00.43 postgres                                               
	18975 chenhj    20   0  663m 5628 4636 S  6.3  0.3   0:00.37 postgres                                               
	18973 chenhj    20   0  663m 5636 4636 S  6.0  0.3   0:00.39 postgres                                               
	18982 chenhj    20   0  663m 5632 4636 S  6.0  0.3   0:00.38 postgres                                               
	18984 chenhj    20   0  663m 5652 4656 S  6.0  0.3   0:00.38 postgres                                               
	18974 chenhj    20   0  663m 5648 4648 R  5.6  0.3   0:00.40 postgres                                               
	18976 chenhj    20   0  663m 5632 4640 S  5.6  0.3   0:00.38 postgres                                               
	18978 chenhj    20   0  663m 5656 4664 S  5.6  0.3   0:00.37 postgres                                               
	18979 chenhj    20   0  663m 5644 4648 S  5.6  0.3   0:00.37 postgres                                               
	18983 chenhj    20   0  663m 5636 4640 S  5.6  0.3   0:00.37 postgres                                               
	18986 chenhj    20   0  663m 5624 4628 S  5.6  0.3   0:00.38 postgres                                               
	18977 chenhj    20   0  663m 5656 4664 S  5.3  0.3   0:00.36 postgres                                               
	18980 chenhj    20   0  663m 5636 4640 S  5.3  0.3   0:00.35 postgres                                               
	18981 chenhj    20   0  663m 5636 4640 S  5.3  0.3   0:00.36 postgres                                               
	18985 chenhj    20   0  663m 5656 4660 S  5.0  0.3   0:00.34 postgres  
	
	[root@node1 ~]# ps -ef|grep postgres
	chenhj   18367     1  0 12:31 pts/1    00:00:00 /usr/local/pgsql/bin/postgres -D data
	chenhj   18369 18367  0 12:31 ?        00:00:00 postgres: checkpointer process       
	chenhj   18370 18367  0 12:31 ?        00:00:00 postgres: writer process             
	chenhj   18371 18367  0 12:31 ?        00:00:00 postgres: wal writer process         
	chenhj   18372 18367  0 12:31 ?        00:00:00 postgres: autovacuum launcher process   
	chenhj   18373 18367  0 12:31 ?        00:00:00 postgres: stats collector process    
	chenhj   18374 18367  0 12:31 ?        00:00:00 postgres: wal sender process chenhj 192.168.150.201(34998) streaming 0/A5734050


**备机**

	[root@node1 ~]# top
	top - 12:37:36 up  3:11,  4 users,  load average: 0.19, 0.06, 0.02
	Tasks: 138 total,   1 running, 137 sleeping,   0 stopped,   0 zombie
	Cpu(s):  0.7%us,  8.6%sy,  0.0%ni, 58.4%id, 32.0%wa,  0.2%hi,  0.2%si,  0.0%st
	Mem:   1922268k total,  1851180k used,    71088k free,     4816k buffers
	Swap:  2064376k total,   660616k used,  1403760k free,   459252k cached
	
	  PID USER      PR  NI  VIRT  RES  SHR S %CPU %MEM    TIME+  COMMAND                                               
	 8181 chenhj    20   0  667m 2148 1332 D 17.3  0.1   0:15.65 postgres                                               
	 5012 chenhj    20   0  662m 172m 171m S  8.0  9.2   0:30.94 postgres                                               
	   23 root      20   0     0    0    0 S  1.0  0.0   0:06.64 kblockd/1                                              
	   11 root      20   0     0    0    0 S  0.3  0.0   0:08.91 events/0                                               
	   12 root      20   0     0    0    0 S  0.3  0.0   0:10.60 events/1                                               
	 1263 root      -2   0 2574m 1.2g 1540 S  0.3 65.5   0:52.81 corosync                                               
	 2195 root      -2   0  4900  452  420 S  0.3  0.0   0:00.56 iscsid                                                 
	 8188 root      20   0 15036 1216  908 R  0.3  0.1   0:00.32 top          
	
	[chenhj@node2 ~]$ ps -ef|grep postgres
	chenhj    5011     1  0 11:08 ?        00:00:00 /usr/local/pgsql/bin/postgres -D data
	chenhj    5012  5011  0 11:08 ?        00:00:35 postgres: startup process   recovering 0000000100000000000000A6
	chenhj    5014  5011  0 11:08 ?        00:00:04 postgres: checkpointer process       
	chenhj    5015  5011  0 11:08 ?        00:00:00 postgres: writer process             
	chenhj    5016  5011  0 11:08 ?        00:00:02 postgres: stats collector process    
	chenhj    8124  5011  0 12:13 ?        00:00:00 postgres: chenhj chenhj [local] idle 
	chenhj    8181  5011  4 12:31 ?        00:00:24 postgres: wal receiver process   streaming 0/A644EE20
	chenhj    9477  8239  0 12:40 pts/3    00:00:00 grep postgres



