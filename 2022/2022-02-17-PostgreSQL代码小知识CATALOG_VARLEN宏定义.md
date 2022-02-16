
PostgreSQL源码中，系统表的结构体定义的一般后半段的变长成员都会包含在`CATALOG_VARLEN`宏定义里。

比如`pg_authid`:

src/include/catalog/pg_authid.h
```
CATALOG(pg_authid,1260,AuthIdRelationId) BKI_SHARED_RELATION BKI_ROWTYPE_OID(2842,AuthIdRelation_Rowtype_Id) BKI_SCHEMA_MACRO
{
	Oid			oid;			/* oid */
	NameData	rolname;		/* name of role */
	bool		rolsuper;		/* read this field via superuser() only! */
	bool		rolinherit;		/* inherit privileges from other roles? */
	bool		rolcreaterole;	/* allowed to create more roles? */
	bool		rolcreatedb;	/* allowed to create databases? */
	bool		rolcanlogin;	/* allowed to log in as session user? */
	bool		rolreplication; /* role used for streaming replication */
	bool		rolbypassrls;	/* bypasses row level security? */
	int32		rolconnlimit;	/* max connections allowed (-1=no limit) */

	/* remaining fields may be null; use heap_getattr to read them! */
#ifdef CATALOG_VARLEN			/* variable-length fields start here */
	text		rolpassword;	/* password, if any */
	timestamptz rolvaliduntil;	/* password expiration time, if any */
#endif
} FormData_pg_authid;
```

这部分成员实际上是不会出现在C结构里的，因为宏`CATALOG_VARLEN`自始至终都不会被定义。
代码里要访问这些字段必须使用`heap_getattr`函数。

既然如此，那么这些成员是干什么的呢？

参考下面的引用点，可以看出catalog目录下的Perl脚本解析这些系统表头文件生成postgres.bki等文件时会用到。


src/backend/catalog/Catalog.pm
```
			$is_varlen = 1 if /^#ifdef\s+CATALOG_VARLEN/;
```

src/include/catalog/genbki.h
```
/*
 * Variable-length catalog fields (except possibly the first not nullable one)
 * should not be visible in C structures, so they are made invisible by #ifdefs
 * of an undefined symbol.  See also MARKNOTNULL in bootstrap.c for how this is
 * handled.
 */
#undef CATALOG_VARLEN
```
