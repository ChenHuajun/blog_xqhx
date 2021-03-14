-- clean
drop schema if exists scale_test CASCADE;

-- create table
create schema scale_test;
create table scale_test.tb_dist(id int primary key, c1 int);
create table scale_test.tb_dist2(id int primary key, c1 int);
create table scale_test.tb_ref(id int primary key, c1 int);

set citus.shard_count=16;
select create_distributed_table('scale_test.tb_dist','id');
select create_distributed_table('scale_test.tb_dist2','id');
select create_reference_table('scale_test.tb_ref');

-- insert test data
insert into scale_test.tb_dist select generate_series(1,10),1;
insert into scale_test.tb_dist2 select generate_series(1,10),2;
insert into scale_test.tb_ref select generate_series(1,10),3;

select a.*,b.c1 from scale_test.tb_dist a, scale_test.tb_dist2 b where a.id=b.id;
select a.*,b.c1 from scale_test.tb_dist a, scale_test.tb_dist2 b where a.id=b.id and a.id=1;
select a.*,b.c1 from scale_test.tb_dist a, scale_test.tb_ref b where a.id=b.id;

explain select a.* from scale_test.tb_dist a ,scale_test.tb_dist2 b where a.id=b.id;
explain select a.* from scale_test.tb_dist a ,scale_test.tb_ref b where a.id=b.id;

-- move shards
select citus_move_shard_placement(s.shardid,'cituswk1',5432,'cituswk2',5432)
from pg_dist_shard s, pg_dist_shard_placement p 
where s.shardid=p.shardid and logicalrelid='scale_test.tb_dist'::regclass and nodename='cituswk1'
limit 1;

select citus_move_shard_placement(s.shardid,'cituswk1',5432,'cituswk2',5432,'rename')
from pg_dist_shard s, pg_dist_shard_placement p 
where s.shardid=p.shardid and logicalrelid='scale_test.tb_dist'::regclass and nodename='cituswk1'
limit 1;

select citus_move_shard_placement(s.shardid,'cituswk1',5432,'cituswk2',5432,'drop')
from pg_dist_shard s, pg_dist_shard_placement p 
where s.shardid=p.shardid and logicalrelid='scale_test.tb_dist'::regclass and nodename='cituswk1'
limit 1;

-- cleanup old shards
select count(*) from citus.citus_move_shard_placement_remained_old_shard;
select pg_catalog.citus_move_shard_placement_cleanup();

-- check result
select a.*,b.c1 from scale_test.tb_dist a, scale_test.tb_dist2 b where a.id=b.id;
select a.*,b.c1 from scale_test.tb_dist a, scale_test.tb_dist2 b where a.id=b.id and a.id=1;
select a.*,b.c1 from scale_test.tb_dist a, scale_test.tb_ref b where a.id=b.id;

explain select a.* from scale_test.tb_dist a ,scale_test.tb_dist2 b where a.id=b.id;
explain select a.* from scale_test.tb_dist a ,scale_test.tb_ref b where a.id=b.id;