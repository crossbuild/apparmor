# what happens with some bad portnumbers?
#
/tmp/tcp/tcp_client {
tcp_connect from 10.0.0.17/16:50-100 to 127.0.0.1 via eth1 ,
tcp_connect to 127.0.0.1:100000,
/lib/libc.so.6		r	,
/lib/ld-linux.so.2	r	,
/etc/ld.so.cache	r	,
/lib/libc-2.1.3.so	r	,
}
