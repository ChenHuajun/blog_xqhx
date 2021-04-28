# PostgreSQL对象的依赖关系解析

## 1. 前言

在PostgreSQL中我们可以定义各种对象，比如表，字段，序列，索引等等。这些对象互相关联，如果我们要删除某个对象，那么引用这个对象的其他对象将会受到影响。此时，要么阻止这种删除行为，要么同时删除那些依赖被删目标对象的对象。PostgreSQL为了识别对象之间的依赖，把对象的依赖关系记录在`pg_depend`系统表里。



## 2. `pg_depend`系统表

关于`pg_depend`系统表的说明可以参考下面的PG手册

http://postgres.cn/docs/12/catalog-pg-depend.html

-----

**表 51.18. `pg_depend`的列**

| 名称          | 类型   | 引用           | 描述                                                         |
| ------------- | ------ | -------------- | ------------------------------------------------------------ |
| `classid`     | `oid`  | `pg_class.oid` | 依赖对象所在的系统目录OID                                    |
| `objid`       | `oid`  | 任意OID列      | 指定依赖对象的OID                                            |
| `objsubid`    | `int4` |                | 对于一个表列，这里是列号（`objid`和`classid`指表本身）。对于所有其他对象类型，此列为0。 |
| `refclassid`  | `oid`  | `pg_class.oid` | 被引用对象所在的系统目录的OID                                |
| `refobjid`    | `oid`  | 任意OID列      | 指定被引用对象的OID                                          |
| `refobjsubid` | `int4` |                | 对于一个表列，这里是列号（`refobjid`和`refclassid`指表本身）。对于所有其他对象类型，此列为0。 |
| `deptype`     | `char` |                | 定义此依赖关系语义的一个代码，见文本                         |



在所有情况下，一个`pg_depend`项表明被引用对象不能在没有删除其依赖对象的情况下被删除。但是，其中也有多种依赖类型，由`deptype`标识：

- `DEPENDENCY_NORMAL` (`n`)

  在独立创建的对象之间的一个普通关系。依赖对象可以在不影响被依赖对象的情况下被删除。被引用对象只能通过指定`CASCADE`被删除，在这种情况下依赖对象也会被删除。 例子：一个表列对于其数据类型有一个普通依赖。

- `DEPENDENCY_AUTO` (`a`)

  依赖对象可以被独立于被依赖对象删除，且应该在被引用对象被删除时自动被删除（不管在`RESTRICT`或`CASCADE`模式）。例子：一个表上的一个命名约束应该被设置为自动依赖于表，这样在表被删除后它也会消失。

- `DEPENDENCY_INTERNAL` (`i`)

  依赖对象作为被引用对象创建过程的一部分被创建，并且只是其内部实现的一部分。不允许直接`DROP`所依赖的对象（而是告诉用户对引用对象发出`DROP`操作）。无论是否指定了`CASCADE`，`DROP`被引用的对象都将导致自动删除从属对象。如果由于删除了对某些其他对象的依赖关系而不得不删除依赖对象，则其删除将转换为对所引用对象的删除，因此依赖对象的`NORMAL`和`AUTO`依赖关系的行为就像它们是所引用对象的依赖关系。示例：视图的`ON SELECT`规则使其在内部依赖于视图，以防止在视图保留时将其删除。规则的依赖关系（例如它引用的表）就好像他们是视图的依赖关系。

- `DEPENDENCY_PARTITION_PRI` (`P`) `DEPENDENCY_PARTITION_SEC` (`S`)

  依赖对象被作为被引用对象创建过程的一部分创建，并且确实是其内部实现的一部分。但是，不像`INTERNAL`，有多个这样的引用对象。除非删除了这些引用对象中的至少一个对象，否则不得删除依赖对象；如果其中任何一个被删除，则不管是否指定了`CASCADE`，都应删除依赖对象。也不像`INTERNAL`，依赖对象所依赖的某些其他对象的删除不会导致任何分区引用的对象的自动删除。因此，如果删除没有通过其他路径级联到这些对象中的至少一个，它会被拒绝。（大多数情况下，依赖对象与至少一个分区引用对象共享所有非分区的依赖关系，因此此限制不会导致阻止任何级联的删除。）主分区和辅助分区的依赖关系表现相同，除了主分区依赖关系倾向用于错误消息；因此，分区相关的对象应该有一个主分区依赖关系和一个或多个辅助分区依赖关系。注意到分区依赖关系是任何对象所正常拥有的依赖关系的补充，而不是替代。这简化了`ATTACH/DETACH PARTITION`操作：只要添加或删除分区的依赖关系。例如：子分区索引与其所基于的分区表和父分区索引是分区相关的，因此只要其中一个删除，则子分区索引就消失，否则，就不消失。父索引上的依赖关系是主要的，故如果用户试图删除子分区索引，错误消息反而会建议删除父索引（不是表）。

- `DEPENDENCY_EXTENSION` (`e`)

  依赖对象是作为*扩展*的被引用对象的一个成员（参见[`pg_extension`](http://postgres.cn/docs/12/catalog-pg-extension.html)）。依赖对象可以通过被引用对象上的`DROP EXTENSION`来删除。在功能上，这种依赖类型和一个`INTERNAL`依赖的作用相同，其存在只是为了清晰和简化pg_dump。

- `DEPENDENCY_AUTO_EXTENSION` (`x`)

  依赖对象不是作为被引用对象的扩展的成员（因此不应该被pg_dump忽略），但是没有该扩展它又无法工作，因此如果删除了扩展，则该依赖对象应自动删除。该依赖对象也可以独立删除。功能上，该依赖关系类型与`AUTO`依赖相同，但是为了清晰起见和简化pg_dump，将其分开。

- `DEPENDENCY_PIN` (`p`)

  没有依赖对象，这种类型的项是一个信号，用于说明系统本身依赖于被引用对象，并且该对象永远不能被删除。这种类型的项只能被`initdb`创建。而此种项的依赖对象的列都为0。

----

为了更直观的说明不同的依赖类型，下面举几个例子

- `DEPENDENCY_NORMAL` (`n`)
  - 表，视图，函数等对象 依赖 与自己所在的schema
  - 继承表的子表依赖主表
  - 视图的内置rule依赖视图对象
  - 视图的内置rule依赖引用的表字段
  - 外键约束依赖被外键参考的表的表字段
  - 触发器依赖其执行函数
  - policy依赖其对应的表的表字段

- `DEPENDENCY_AUTO` (`a`)
  - 索引依赖其对应的表字段
  - 主键约束依赖其对应的表字段
  - 外键约束依赖其所在表的表字段
  - 分区子表依赖分区主表
  - serial类型产生的序列依赖其对应的表字段
  - 触发器依赖其对应的表
  - policy依赖其对应的表
  - statistics依赖其对应的表字段
  - publication relation依赖其对应的publication
- publication relation依赖该publication包含的表 
  
- `DEPENDENCY_INTERNAL` (`i`)
  - 视图的内置rule依赖视图对象
  - 表和视图的同名type依赖其对应的表和视图
  - toast表依赖主表
  - generated identity类型表字段的内置序列依赖与其对应的表列 

- `DEPENDENCY_PARTITION_PRI` (`P`) 
  - 分区表的子表的索引依赖主表的索引
  - 分区表的子表的主键约束依赖主表的主键约束

- `DEPENDENCY_PARTITION_SEC` (`S`)
  - 分区表的子表的索引依赖于其对应的子表
  - 分区表的子表的主键约束依赖于其对应的子表

- `DEPENDENCY_EXTENSION` (`e`)
  - 扩展的成员依赖扩展对象

- `DEPENDENCY_AUTO_EXTENSION` (`x`)
  - 通过`ALTER OBJECT(包括TRIGGER/FUNCTION/PROCDEDURE/INDEX/MATERIALIZED VIEW) DEPENDS ON EXTENSION`设置的依赖于某个扩展又不是这个扩展的成员的对象
- `DEPENDENCY_PIN` (`p`)
  -   全局（类和对象id用0代替）依赖各个系统表



## 3. DROP一个对象时如何处理依赖关系

当我们删除一个表或其他对象时，需要找到与被删对象存在依赖关系的其他对象，或把这些对象一起删除，或报错。以DROP TABLE为例，相关处理逻辑如下

```
performMultipleDeletions()
  ->foreach thisobj in objects(DROP对象列表)
  	->findDependentObjects(thisobj,
							 DEPFLAG_ORIGINAL,
							 flags,
							 NULL,	/* empty stack */
							 targetObjects,/* 找到的所有依赖对象存在这个表里 */
							 objects,
							 &depRel);
  ->reportDependentObjects(targetObjects) /* 检查是否允许删除，输出错误或通知 */
  ->deleteObjectsInList(targetObjects)
```

通过解析代码，依赖处理的规则可以概括如下：

findDependentObjects()从原始目标删除对象入手，递归搜索所有需要同时删除的对象，并给这些对象打上以下flag

- DEPFLAG_ORIGINAL
  - 出现的DROP列表中的原始目标删除对象
- DEPFLAG_REVERSE：
  - 目标删除对象的owner，即目标删除对象i依赖或e依赖的对象。这个依赖和常规依赖相比，是反向的。
  - 存在对反向依赖时，对目标删除对象的删除，需要转换成对其owner对象的删除动作。
  - 如果目标删除对象是顶层对象，但其owner不是顶层的被删除对象，报错。
  - 如果目标删除对象不是顶层对象，但其owner不能通过findDependentObjects()的递归调用加入到被删对象列表，报错
- DEPFLAG_NORMAL
  - 对目标删除对象有普通依赖(n)的对象

- DEPFLAG_SUBOBJECT
  - 目标删除对象作为子对象（字段）先加入删除列表，其主对象（表）后加入时，该子对象（字段）被设置为此flag
- DEPFLAG_IS_PART
  - 如果目标删除对象（子表索引）P或S依赖与其他对象（分区主表索引或表），该对象上被设置为此flag
- DEPFLAG_AUTO
  - 对目标删除对象有自动依赖（a）的对象
- DEPFLAG_INTERNAL
  - 对目标删除对象有内置依赖（i）的对象
- DEPFLAG_PARTITION
  - 对目标删除对象（如子表索引）有分区依赖（P或S）的对象（如分区主表索引或子表）
- DEPFLAG_EXTENSION
  - 对目标删除对象（比如表，视图，函数等）有扩展依赖（e）的对象（如扩展的成员）



reportDependentObjects（）遍历所有需要删除的对像，判断是否允许删除，如不允许报错

- 如果DEPFLAG_IS_PART &&!DEPFLAG_PARTITION报错
  - 含义是允许删除存在P或S依赖其他对象（比如主表索引或子表）的对象（子表索引）的必要条件是，至少一个它依赖的其他对象同时也是目标删除对象。 
- 包含以下6个flag中的任意一个则允许（表和表的列可能会牵出同一个依赖对象，这个对象会被打上多个flag）
  - DEPFLAG_ORIGINAL
  - DEPFLAG_SUBOBJECT
  - DEPFLAG_AUTO
  - DEPFLAG_INTERNAL
  - DEPFLAG_PARTITION
  - DEPFLAG_EXTENSION
- 其他（即DEPFLAG_REVERSE或DEPFLAG_NORMAL）
  - 不允许



## 4. findDependentObjects()的内部处理流程

参考PG12代码，findDependentObjects()的内部处理流程如下

1. 遍历本对象依赖的其他对象，识别owner对象，将对本对象的删除转变成对其owner的删除。
   1. 跳过本对象的子对象，防止无限递归
   2. 跳过 n,a,x依赖
   3. 跳过设置了`PERFORM_DELETION_SKIP_EXTENSIONS`标志位的e依赖(用于清空临时schema)
   4. 跳过create extension脚本中执行的delete本扩展成员的e依赖
   5. 对于i依赖或e依赖
      - 本对象是顶层对象（即DROP列表中的对象）
        - 其依赖其它出现在DROP列表中的对象，退出函数跳过本对象的处理（即后续通过它依赖的对象进行级联删除）
        - 如果owningObject未设置或是e依赖，设置owningObject为其依赖的对象，然后跳过
      - 本对象非顶层对象
        - 对otherObject（即owner）以`DEPFLAG_REVERSE` flag递归调用findDependentObjects()
        - 如果otherObject（即owner）未被加入到targetObjects作为删除对象，报错；否则跳出本函数跳过本对象的处理
   6. 对于P或S依赖，设置`DEPFLAG_IS_PART`标志和partitionObject（主分区优先）

2. 如果owningObject被设置（即本对象是DROP顶层对象且是其他对象的扩展成员或内置对象）报错

3. 遍历依赖本对象的对象
   - 跳过本对象的子对象
   - 设置subflags

   - 填充dependentObjects

   4.排序dependentObjects，确保被依赖的对象先被删除

4. 遍历dependentObjects

   - 递归调用findDependentObjects()将dependentObjects及其依赖的对象填充到targetObjects

5. 设置本对象依赖的对象，对于partitionObject有效的场景（P/S依赖分区主表）其为分区主表，其他为其依赖的上一层对象

6. 将本对象加入到targetObjects

 





