/*
 *   Copyright (c) 2014
 *   Canonical, Ltd. (All rights reserved)
 *
 *   This program is free software; you can redistribute it and/or
 *   modify it under the terms of version 2 of the GNU General Public
 *   License published by the Free Software Foundation.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with this program; if not, contact Novell, Inc. or Canonical
 *   Ltd.
 */

#include <ctype.h>
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>
#include <sys/types.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <utime.h>

#include "lib.h"
#include "parser.h"
#include "policy_cache.h"

#define le16_to_cpu(x) ((uint16_t)(le16toh (*(uint16_t *) x)))

const char header_string[] = "\004\010\000version\000\002";
#define HEADER_STRING_SIZE 12
bool valid_cached_file_version(const char *cachename)
{
	char buffer[16];
	autofclose FILE *f;
	if (!(f = fopen(cachename, "r"))) {
		PERROR("Error: Could not read cache file '%s', skipping...\n", cachename);
		return false;
	}
	size_t res = fread(buffer, 1, 16, f);
	if (res < 16) {
		if (debug_cache)
			pwarn("%s: cache file '%s' invalid size\n", progname, cachename);
		return false;
	}

	/* 12 byte header that is always the same and then 4 byte version # */
	if (memcmp(buffer, header_string, HEADER_STRING_SIZE) != 0) {
		if (debug_cache)
			pwarn("%s: cache file '%s' has wrong header\n", progname, cachename);
		return false;
	}

	uint32_t version = cpu_to_le32(ENCODE_VERSION(force_complain,
						      policy_version,
						      parser_abi_version,
						      kernel_abi_version));
	if (memcmp(buffer + 12, &version, 4) != 0) {
		if (debug_cache)
			pwarn("%s: cache file '%s' has wrong version\n", progname, cachename);
		return false;
	}

	return true;
}


void set_cache_tstamp(struct timespec t)
{
	mru_skip_cache = 0;
	cache_tstamp = t;
}

void update_mru_tstamp(FILE *file, const char *name)
{
	struct stat stat_file;
	if (fstat(fileno(file), &stat_file))
		return;
	if (tstamp_cmp(mru_policy_tstamp, stat_file.st_mtim) < 0)
		/* keep track of the most recent policy tstamp */
		mru_policy_tstamp = stat_file.st_mtim;
	if (tstamp_is_null(cache_tstamp))
		return;
	if (tstamp_cmp(stat_file.st_mtim, cache_tstamp) > 0) {
		if (debug_cache)
			pwarn("%s: file '%s' is newer than cache file\n", progname, name);
		mru_skip_cache = 1;
	}
}

char *cache_filename(const char *cachedir, const char *basename)
{
	char *cachename;

	if (asprintf(&cachename, "%s/%s", cachedir, basename) < 0) {
		PERROR("Memory allocation error.");
		exit(1);
	}

	return cachename;
}

void valid_read_cache(const char *cachename)
{
	struct stat stat_bin;

	/* Load a binary cache if it exists and is newest */
	if (!skip_read_cache) {
		if (stat(cachename, &stat_bin) == 0 &&
		    stat_bin.st_size > 0) {
			if (valid_cached_file_version(cachename))
				set_cache_tstamp(stat_bin.st_mtim);
			else if (!cond_clear_cache)
				write_cache = 0;
		} else {
			if (!cond_clear_cache)
				write_cache = 0;
			if (debug_cache)
				pwarn("%s: Invalid or missing cache file '%s' (%s)\n", progname, cachename, strerror(errno));
		}
	}
}

int cache_hit(const char *cachename)
{
	if (!mru_skip_cache) {
		if (show_cache)
			PERROR("Cache hit: %s\n", cachename);
		return true;
	}

	return false;
}

int setup_cache_tmp(const char **cachetmpname, const char *cachename)
{
	char *tmpname;
	int cache_fd = -1;

	*cachetmpname = NULL;
	if (write_cache) {
		/* Otherwise, set up to save a cached copy */
		if (asprintf(&tmpname, "%s-XXXXXX", cachename)<0) {
			perror("asprintf");
			exit(1);
		}
		if ((cache_fd = mkstemp(tmpname)) < 0) {
			perror("mkstemp");
			exit(1);
		}
		*cachetmpname = tmpname;
	}

	return cache_fd;
}

void install_cache(const char *cachetmpname, const char *cachename)
{
	/* Only install the generate cache file if it parsed correctly
	   and did not have write/close errors */
	if (cachetmpname) {
		struct timeval t;
		/* set the mtime of the cache file to the most newest mtime
		 * of policy files used to generate it
		 */
		TIMESPEC_TO_TIMEVAL(&t, &mru_policy_tstamp);
		utimes(cachetmpname, &t);
		if (rename(cachetmpname, cachename) < 0) {
			pwarn("Warning failed to write cache: %s\n", cachename);
			unlink(cachetmpname);
		}
		else if (show_cache) {
			PERROR("Wrote cache: %s\n", cachename);
		}
	}
}
