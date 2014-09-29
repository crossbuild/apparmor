/*
 * Copyright (C) 2013 Canonical, Ltd.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of version 2 of the GNU General Public
 * License published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, contact Canonical Ltd.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

#define MSG_BUF_MAX	1024

#define SUN_PATH_SUFFIX		".client"
#define SUN_PATH_SUFFIX_LEN	strlen(SUN_PATH_SUFFIX)

static int connection_based_messaging(int sock)
{
	char msg_buf[MSG_BUF_MAX];
	int rc;

	rc = read(sock, msg_buf, MSG_BUF_MAX);
	if (rc < 0) {
		perror("FAIL CLIENT - read");
		return 1;
	}

	rc = write(sock, msg_buf, rc);
	if (rc < 0) {
		perror("FAIL CLIENT - write");
		return 1;
	}

	return 0;
}

static int connectionless_messaging(int sock, struct sockaddr_un *peer_addr,
				    socklen_t peer_addr_len)
{
	struct sockaddr_un addr;
	size_t peer_path_len = peer_addr_len - sizeof(addr.sun_family);
	size_t path_len = peer_path_len + SUN_PATH_SUFFIX_LEN;
	char msg_buf[MSG_BUF_MAX];
	int rc;

	if (path_len > sizeof(addr.sun_path)) {
		fprintf(stderr, "FAIL CLIENT - path_len too big\n");
		return 1;
	}

	/**
	 * Subtract 1 to get rid of nul-terminator in pathname address types.
	 * We're essentially moving the nul char so path_len stays the same.
	 */
	if (peer_addr->sun_path[0])
		peer_path_len--;

	addr.sun_family = AF_UNIX;
	memcpy(addr.sun_path, peer_addr->sun_path, peer_path_len);
	strcpy(addr.sun_path + peer_path_len, SUN_PATH_SUFFIX);

	rc = bind(sock, (struct sockaddr *)&addr,
		  path_len + sizeof(addr.sun_family));
	if (rc < 0) {
		perror("FAIL CLIENT - bind");
		return 1;
	}

	rc = write(sock, NULL, 0);
	if (rc < 0) {
		perror("FAIL CLIENT - write");
		return 1;
	}

	rc = read(sock, msg_buf, MSG_BUF_MAX);
	if (rc < 0) {
		perror("FAIL CLIENT - read");
		return 1;
	}

	rc = write(sock, msg_buf, rc);
	if (rc < 0) {
		perror("FAIL CLIENT - write");
		return 1;
	}

	return 0;
}

static int get_set_sock_io_timeo(int sock)
{
	struct timeval tv;
	socklen_t tv_len = sizeof(tv);
	int rc;

	rc = getsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, &tv_len);
	if (rc == -1) {
		perror("FAIL - getsockopt");
		return 1;
	}

	tv.tv_sec = 1;
	tv.tv_usec = 0;

	rc = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, tv_len);
	if (rc == -1) {
		perror("FAIL - setsockopt (SO_RCVTIMEO)");
		return 1;
	}

	rc = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, tv_len);
	if (rc == -1) {
		perror("FAIL - setsockopt (SO_SNDTIMEO)");
		return 1;
	}

	return 0;
}

int main(int argc, char *argv[])
{
	struct sockaddr_un peer_addr;
	const char *sun_path;
	size_t sun_path_len;
	int sock, type, rc;

	if (argc != 3) {
		fprintf(stderr, "Usage: %s <socket> <type>\n\n"
			"  type\t\tstream, dgram, or seqpacket\n",
			argv[0]);
		exit(1);
	}

	peer_addr.sun_family = AF_UNIX;
	memset(peer_addr.sun_path, 0, sizeof(peer_addr.sun_path));

	sun_path = argv[1];
	sun_path_len = strlen(sun_path);
	if (sun_path[0] == '@') {
		if (sun_path_len > sizeof(peer_addr.sun_path)) {
			fprintf(stderr, "FAIL CLIENT - socket addr too big\n");
			exit(1);
		}
		memcpy(peer_addr.sun_path, sun_path, sun_path_len);
		peer_addr.sun_path[0] = '\0';
	} else {
		/* include the nul terminator for pathname addr types */
		sun_path_len++;
		if (sun_path_len > sizeof(peer_addr.sun_path)) {
			fprintf(stderr, "FAIL CLIENT - socket addr too big\n");
			exit(1);
		}
		memcpy(peer_addr.sun_path, sun_path, sun_path_len);
	}

	if (!strcmp(argv[2], "stream")) {
		type = SOCK_STREAM;
	} else if (!strcmp(argv[2], "dgram")) {
		type = SOCK_DGRAM;
	} else if (!strcmp(argv[2], "seqpacket")) {
		type = SOCK_SEQPACKET;
	} else {
		fprintf(stderr, "FAIL CLIENT - bad socket type: %s\n", argv[2]);
		exit(1);
	}

	sock = socket(AF_UNIX, type, 0);
	if (sock < 0) {
		perror("FAIL CLIENT - socket");
		exit(1);
	}

	rc = get_set_sock_io_timeo(sock);
	if (rc)
		exit(1);

	rc = connect(sock, (struct sockaddr *)&peer_addr,
		     sun_path_len + sizeof(peer_addr.sun_family));
	if (rc < 0) {
		perror("FAIL CLIENT - connect");
		exit(1);
	}

	rc = (type == SOCK_STREAM || type == SOCK_SEQPACKET) ?
		connection_based_messaging(sock) :
		connectionless_messaging(sock, &peer_addr,
				sun_path_len + sizeof(peer_addr.sun_family));
	if (rc)
		exit(1);

	exit(0);
}
