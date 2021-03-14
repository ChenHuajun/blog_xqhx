#!/usr/bin/python
# -*- coding: UTF-8 -*-
#功能:输出所有博客文章列表

import os
import re
from urllib import parse

blogdir='.'
output='bloglist.md'

def find_blogs(file,bloglist):
    #print(type(file),file)
    if os.path.isdir(file):
        for f in os.listdir(file):
            filepath = os.path.join(file, f)
            find_blogs(filepath,bloglist)
    else:
        filename=os.path.basename(file)
        matchObj = re.match('^([0-9]{4}-[0-9]{2}-[0-9]{2})-(.*)\.md$', filename)
        if matchObj:
            bloglist.append((matchObj.group(1),matchObj.group(2),file))

def main():
    bloglist=[]
    find_blogs(blogdir,bloglist)
    bloglist.sort(key=lambda item:item[0], reverse=True)
    fout=open(output,"w",encoding='UTF-8')
    for blog in bloglist:
        date = blog[0]
        title = blog[1]
        path = (blog[2][len(blogdir)+1:]).replace('\\','/')
        link = 'https://github.com/ChenHuajun/blog_xqhx/blob/main/%s' % parse.quote(path)
        line = "- [{0}:{1}]({2})".format(date,title,link)
        print(line,file=fout)
    fout.close()

if __name__ == '__main__':
    main()