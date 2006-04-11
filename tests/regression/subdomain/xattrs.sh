#! /bin/bash
# $Id:$

#	Copyright (C) 2002-2005 Novell/SUSE
#
#	This program is free software; you can redistribute it and/or
#	modify it under the terms of the GNU General Public License as
#	published by the Free Software Foundation, version 2 of the
#	License.

#=NAME xattrs
#=DESCRIPTION 
# This test verifies setting getting and removing xattrs on a file or symlink.
# The test is run for each namespace supported by xattrs since its namespace 
# has its own security constraints (see man 5 attr for full details). 
# security: get r, set w + CAP_SYS_ADMIN
# system: (acl's etc.) fs and kernel dependent (CAP_SYS_ADMIN)
# trusted: CAP_SYS_ADMIN
# user: for subdomain the relevent file must be in the profile, with r perm 
#       to get xattr, w perm to set or remove xattr. The appriate cap must be 
#       present in the profile as well
#=END

# User xattrs are not allowed on symlinks and special files system namespace 
# tests are going to take some work, have todo with acls or caps all system 
# tests are currently commented until new tests can be developed, then they 
# can be removed

xattrtest()
{
    runchecktest "$3 xattrs in namespace \"$4\" on $1 with perms=$2" $5 $1 $4 $3
}

pwd=`dirname $0`
pwd=`cd $pwd ; /bin/pwd`

bin=$pwd

. $bin/prologue.inc

file=$tmpdir/testfile
link=$tmpdir/testlink
dir=$tmpdir/testdir
perm=rw
badperm=r

touch $file
ln -s $file $link
mkdir $dir

for var in $file $link $dir ; do
#write xattr
    genprofile $var:$badperm
    xattrtest $var $badperm write security fail
    #xattrtest $var $badperm write system fail
    xattrtest $var $badperm write trusted fail
    if [ $var != $link ] ; then xattrtest $var $badperm write user fail ; fi

    genprofile $var:$badperm capability:sys_admin
    xattrtest $var "$badperm+cap SYS_ADMIN" write security fail
    #xattrtest $var "$badperm+cap SYS_ADMIN" write system fail
    xattrtest $var "$badperm+cap SYS_ADMIN" write trusted fail
    if [ $var != $link ] ; then xattrtest $var "$badperm+cap SYS_ADMIN" write user fail ; fi

    genprofile $var:$perm
    xattrtest $var $perm write security pass
    #xattrtest $var $perm write system fail
    xattrtest $var $perm write trusted fail
    if [ $var != $link ] ; then xattrtest $var $perm write user pass ; fi

    genprofile $var:$perm capability:sys_admin
    xattrtest $var "$perm+cap SYS_ADMIN" write security pass
    #xattrtest $var "$perm+cap SYS_ADMIN" write system pass
    xattrtest $var "$perm+cap SYS_ADMIN" write trusted pass
    if [ $var != $link ] ; then xattrtest $var "$perm+cap SYS_ADMIN" write user pass ; fi


#read xattr
    genprofile $var:$badperm
    xattrtest $var $badperm read security pass
    #xattrtest $var $badperm read system fail
    xattrtest $var $badperm read trusted fail
    if [ $var != $link ] ; then xattrtest $var $badperm read user pass ; fi

    genprofile $var:$badperm capability:sys_admin
    xattrtest $var "$badperm+cap SYS_ADMIN" read security pass
    #xattrtest $var "$badperm+cap SYS_ADMIN" read system pass
    xattrtest $var "$badperm+cap SYS_ADMIN" read trusted pass
    if [ $var != $link ] ; then xattrtest $var "$badperm+cap SYS_ADMIN" read user pass ; fi


#remove xattr
    genprofile $var:$badperm
    xattrtest $var $badperm remove security fail
    #xattrtest $var $badperm remove system fail
    xattrtest $var $badperm remove trusted fail
    if [ $var != $link ] ; then xattrtest $var $badperm remove user fail ; fi

    genprofile $var:$badperm capability:sys_admin
    xattrtest $var "$badperm+cap SYS_ADMIN" remove security fail
    #xattrtest $var "$badperm+cap SYS_ADMIN" remove system fail
    xattrtest $var "$badperm+cap SYS_ADMIN" remove trusted fail
    if [ $var != $link ] ; then xattrtest $var "$badperm+cap SYS_ADMIN" remove user fail ; fi

    genprofile $var:$perm
    xattrtest $var $perm remove security pass
    #xattrtest $var $perm remove system fail
    xattrtest $var $perm remove trusted fail
    if [ $var != $link ] ; then xattrtest $var $perm remove user pass ; fi

    #set the xattr for thos that passed above again so we can test removing it
    setfattr -h -n security.sdtest -v hello $var
    if [ $var != $link ] ; then setfattr -h -n user.sdtest -v hello $var ; fi

    genprofile $var:$perm capability:sys_admin
    xattrtest $var "$perm+cap SYS_ADMIN" remove security pass
    #xattrtest $var "$perm+cap SYS_ADMIN" remove system pass
    xattrtest $var "$perm+cap SYS_ADMIN" remove trusted pass
    if [ $var != $link ] ; then xattrtest $var "$perm+cap SYS_ADMIN" remove user pass ; fi

done

