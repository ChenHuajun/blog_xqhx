## 概述

这类似Oracle的substrb的功能，需要将PostgreSQL的字符数据按字节长度截断，但又不允许出现一个中文字符被截了一半的情况。

## 解决方案

解决方法之一是安装orafce插件，里面会带兼容Oracle的substrb函数。但是这个方法有侵入性，不建议随便安装插件,特别是第3方插件。

那么能不能通过纯SQL实现这个功能呢？

首先看下UTF-8编码的规律。UTF-8是一种变长字节编码方式。对于某一个字符的UTF-8编码，如果只有一个字节则其最高二进制位为0；如果是多字节，其第一个字节从最高位开始，连续的二进制位值为1的个数决定了其编码的位数，其余各字节均以10开头。UTF-8理论上最多可用到6个字节，但是实际上最多也就用到3个字节。 （https://blog.csdn.net/urbanvice/article/details/39344343）

```
1字节 0xxxxxxx 
2字节 110xxxxx 10xxxxxx 
3字节 1110xxxx 10xxxxxx 10xxxxxx 
4字节 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx 
5字节 111110xx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 
6字节 1111110x 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 10xxxxxx 
```

从上可知，凡是'10'开头的字节都不是UTF-8字符的起始字节。根据这个规律，可以判断截断位置的字节是否是UTF-8字符中间字节，找到合适的截断位置。

示例如下，将字符串'中文'按最大长度4字节截断，返回结果为'中'。

```
SELECT
  CASE
    WHEN octet_length(a) > 4 THEN CASE
      WHEN get_byte(convert_to(a, 'UTF-8'), 4) :: bit(8) & B'11000000' <> B'10000000' THEN --截断位置的后一个字节是UTF8字符的起始字节
        convert_from(substring(convert_to(a, 'UTF-8'), 1, 4), 'UTF-8')
      ELSE CASE
        WHEN get_byte(convert_to(a, 'UTF-8'), 4 - 1) :: bit(8) & B'11000000' <> B'10000000' THEN --截断位置的前一个字节是UTF8字符的起始字节
          convert_from(substring(convert_to(a, 'UTF-8'), 1, 4 - 1), 'UTF-8')
        ELSE --当前UTF8字符最多3个字节，即最多2个10开头的字节
          convert_from(substring(convert_to(a, 'UTF-8'), 1, 4 - 2), 'UTF-8')
      END
    END
    ELSE a
  END
FROM
  (
    VALUES(('中文'::text))
  ) t(a);
```
