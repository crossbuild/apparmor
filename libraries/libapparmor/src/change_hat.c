/*
 * Copyright (c) 2003-2008 Novell, Inc. (All rights reserved)
 * Copyright 2009-2010 Canonical Ltd.
 *
 * The libapparmor library is licensed under the terms of the GNU
 * Lesser General Public License, version 2.1. Please see the file
 * COPYING.LGPL.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>

#define symbol_version(real, name, version) \
		__asm__ (".symver " #real "," #name "@" #version)
#define default_symbol_version(real, name, version) \
		__asm__ (".symver " #real "," #name "@@" #version)

static int setprocattr(const char *path, const char *buf, int len)
{
	int rc = -1;
	int fd, ret, ctlerr = 0;
	char *ctl = NULL;
	pid_t tid = syscall(SYS_gettid);

	if (!buf) {
		errno = EINVAL;
		goto out;
	}

	ctlerr = asprintf(&ctl, path, tid);
	if (ctlerr < 0) {
		goto out;
	}

	fd = open(ctl, O_WRONLY);
	if (fd == -1) {
		goto out;
	}

	ret = write(fd, buf, len);
	if (ret != len) {
		int saved;
		if (ret != -1) {
			errno = EPROTO;
		}
		saved = errno;
		(void)close(fd);
		errno = saved;
		goto out;
	}

	rc = 0;
	(void)close(fd);

out:
	if (ctl) {
		free(ctl);
	}
	return rc;
}

int aa_change_hat(const char *subprofile, unsigned long token)
{
	int rc = -1;
	int len = 0;
	char *buf = NULL;
	const char *fmt = "changehat %016x^%s";

	/* both may not be null */
	if (!(token || subprofile)) {
		errno = EINVAL;
		goto out;
	}

	if (subprofile && strnlen(subprofile, PATH_MAX + 1) > PATH_MAX) {
		errno = EPROTO;
		goto out;
	}

	len = asprintf(&buf, fmt, token, subprofile ? subprofile : "");
	if (len < 0) {
		goto out;
	}

	rc = setprocattr("/proc/%d/attr/current", buf, len);
out:
	if (buf) {
		/* clear local copy of magic token before freeing */
		memset(buf, '\0', len);
		free(buf);
	}
	return rc;
}

/* original change_hat interface */
int __change_hat(char *subprofile, unsigned int token)
{
	return aa_change_hat(subprofile, (unsigned long) token);
}

int aa_change_profile(const char *profile)
{
	char *buf = NULL;
	int len;
	int rc;

	if (!profile) {
		errno = EINVAL;
		return -1;
	}

	len = asprintf(&buf, "changeprofile %s", profile);
	if (len < 0)
		return -1;

	rc = setprocattr("/proc/%d/attr/current", buf, len);

	free(buf);
	return rc;
}

int aa_change_onexec(const char *profile)
{
	char *buf = NULL;
	int len;
	int rc;

	if (!profile) {
		errno = EINVAL;
		return -1;
	}

	len = asprintf(&buf, "exec %s", profile);
	if (len < 0)
		return -1;

	rc = setprocattr("/proc/%d/attr/exec", buf, len);

	free(buf);
	return rc;
}

/* create an alias for the old change_hat@IMMUNIX_1.0 symbol */
extern typeof((__change_hat)) __old_change_hat __attribute__((alias ("__change_hat")));
symbol_version(__old_change_hat, change_hat, IMMUNIX_1.0);
default_symbol_version(__change_hat, change_hat, APPARMOR_1.0);


int aa_change_hatv(const char *subprofiles[], unsigned long token)
{
	int size, totallen = 0, hatcount = 0;
	int rc = -1;
	const char **hats;
	char *pos, *buf = NULL;
	const char *cmd = "changehat";

	/* both may not be null */
	if (!token && !(subprofiles && *subprofiles)) {
		errno = EINVAL;
                goto out;
        }

	/* validate hat lengths and while we are at it count how many and
	 * mem required */
	if (subprofiles) {
		for (hats = subprofiles; *hats; hats++) {
			int len = strnlen(*hats, PATH_MAX + 1);
			if (len > PATH_MAX) {
				errno = EPROTO;
				goto out;
			}
			totallen += len + 1;
			hatcount++;
                }
	}

	/* allocate size of cmd + space + token + ^ + vector of hats */
	size = strlen(cmd) + 18 + totallen + 1;
	buf = malloc(size);
	if (!buf) {
                goto out;
        }

	/* setup command string which is of the form
	 * changehat <token>^hat1\0hat2\0hat3\0..\0
	 */
	sprintf(buf, "%s %016lx^", cmd, token);
	pos = buf + strlen(buf);
	if (subprofiles) {
		for (hats = subprofiles; *hats; hats++) {
			strcpy(pos, *hats);
			pos += strlen(*hats) + 1;
		}
	} else
		/* step pos past trailing \0 */
		pos++;

	rc = setprocattr("/proc/%d/attr/current", buf, pos - buf);

out:
	if (buf) {
		/* clear local copy of magic token before freeing */
		memset(buf, '\0', size);
		free(buf);
	}

	return rc;
}

/**
 * change_hat_vargs - change_hatv but passing the hats as fn arguments
 * @token: the magic token
 * @nhat: the number of hats being passed in the arguments
 * ...: a argument list of const char * being passed
 *
 * change_hat_vargs can be called directly but it is meant to be called
 * through its macro wrapper of the same name.  Which automatically
 * fills in the nhats arguments based on the number of parameters
 * passed.
 * to call change_hat_vargs direction do
 * (change_hat_vargs)(token, nhats, hat1, hat2...)
 */
int (aa_change_hat_vargs)(unsigned long token, int nhats, ...)
{
	va_list ap;
	const char *argv[nhats+1];
	int i;

	va_start(ap, nhats);
	for (i = 0; i < nhats ; i++) {
		argv[i] = va_arg(ap, char *);
	}
	argv[nhats] = NULL;
	va_end(ap);
	return aa_change_hatv(argv, token);
}
