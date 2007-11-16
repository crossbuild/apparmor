/*
 *	Copyright (c) 1999, 2000, 2001, 2002, 2004, 2005, 2006, 2007
 *	NOVELL (All rights reserved)
 *
 *	Immunix AppArmor LSM
 *
 *	This program is free software; you can redistribute it and/or
 *	modify it under the terms of the GNU General Public License as
 *	published by the Free Software Foundation, version 2 of the
 *	License.
 *
 *	This program is distributed in the hope that it will be useful,
 *	but WITHOUT ANY WARRANTY; without even the implied warranty of
 *	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *	GNU General Public License for more details.
 *
 *	You should have received a copy of the GNU General Public License
 *	along with this program; if not, contact Novell, Inc.
 */

#ifndef _IMMUNIX_H
#define _IMMUNIX_H

/*
 * Modeled after MAY_READ, MAY_WRITE, MAY_EXEC in the kernel. The value of
 * AA_MAY_EXEC must be identical to MAY_EXEC, etc.
 */
#define AA_MAY_EXEC			(1 << 0)
#define AA_MAY_WRITE			(1 << 1)
#define AA_MAY_READ			(1 << 2)
#define AA_MAY_APPEND			(1 << 3)
#define AA_MAY_LINK			(1 << 4)
#define AA_MAY_LOCK			(1 << 5)
#define AA_EXEC_MMAP			(1 << 6)
#define AA_EXEC_UNSAFE			(1 << 7)
#define AA_EXEC_MOD_0			(1 << 8)
#define AA_EXEC_MOD_1			(1 << 9)

#define AA_BASE_PERMS			(AA_MAY_EXEC | AA_MAY_WRITE | \
					 AA_MAY_READ | AA_MAY_APPEND | \
					 AA_MAY_LINK | AA_MAY_LOCK | \
					 AA_EXEC_MMAP | AA_EXEC_UNSAFE | \
					 AA_EXEC_MOD_0 | AA_EXEC_MOD_1)
#define AA_USER_SHIFT			0
#define AA_GROUP_SHIFT			10
#define AA_OTHER_SHIFT			20

#define AA_USER_PERMS			(AA_BASE_PERMS << AA_USER_SHIFT)
#define AA_GROUP_PERMS			(AA_BASE_PERMS << AA_GROUP_SHIFT)
#define AA_OTHER_PERMS			(AA_BASE_PERMS << AA_OTHER_SHIFT)

#define AA_FILE_PERMS			(AA_USER_PERMS | AA_GROUP_PERMS | \
					 AA_OTHER_PERMS)

#define AA_CHANGE_PROFILE		(1 << 30)
#define AA_ERROR_BIT			(1 << 31)
#define AA_SHARED_PERMS			(AA_CHANGE_PROFILE | AA_ERROR_BIT)


#define AA_EXEC_MODIFIERS		(AA_EXEC_MOD_0 | AA_EXEC_MOD_1)
#define AA_EXEC_TYPE			(AA_MAY_EXEC | AA_EXEC_UNSAFE | \
					 AA_EXEC_MODIFIERS)

#define AA_EXEC_UNCONFINED		0
#define AA_EXEC_INHERIT			(AA_EXEC_MOD_0)
#define AA_EXEC_PROFILE			(AA_EXEC_MOD_1)
#define AA_EXEC_PROFILE_OR_INHERIT	(AA_EXEC_MOD_0 | AA_EXEC_MOD_1)

#define AA_VALID_PERMS			(AA_FILE_PERMS | AA_CHANGE_PROFILE)

#define AA_EXEC_BITS			((AA_MAY_EXEC << AA_USER_SHIFT) | \
					 (AA_MAY_EXEC << AA_GROUP_SHIFT) | \
					 (AA_MAY_EXEC << AA_OTHER_SHIFT))

#define ALL_AA_EXEC_UNSAFE		((AA_EXEC_UNSAFE << AA_USER_SHIFT) | \
					 (AA_EXEC_UNSAFE << AA_GROUP_SHIFT) | \
					 (AA_EXEC_UNSAFE << AA_OTHER_SHIFT))

#define AA_USER_EXEC_TYPE		(AA_EXEC_TYPE << AA_USER_SHIFT)
#define AA_GROUP_EXEC_TYPE		(AA_EXEC_TYPE << AA_GROUP_SHIFT)
#define AA_OTHER_EXEC_TYPE		(AA_EXEC_TYPE << AA_OTHER_SHIFT)

#define SHIFT_MODE(MODE, SHIFT)		((((MODE) & AA_BASE_PERMS) << (SHIFT))\
					 | ((MODE) & ~AA_FILE_PERMS))
#define SHIFT_TO_BASE(MODE, SHIFT)	((((MODE) & AA_FILE_PERMS) >> (SHIFT))\
					 | ((MODE) & ~AA_FILE_PERMS))

#define AA_HAT_SIZE	975	/* Maximum size of a subdomain
					 * ident (hat) */
#define AA_IP_TCP			0x0001
#define AA_IP_UDP			0x0002
#define AA_IP_RDP			0x0004
#define AA_IP_RAW			0x0008
#define AA_IPV6_TCP			0x0010
#define AA_IPV6_UDP			0x0020
#define AA_NETLINK			0x0040

enum pattern_t {
	ePatternBasic,
	ePatternTailGlob,
	ePatternRegex,
	ePatternInvalid,
};

#define HAS_MAY_READ(mode)		((mode) & AA_MAY_READ)
#define HAS_MAY_WRITE(mode)		((mode) & AA_MAY_WRITE)
#define HAS_MAY_APPEND(mode)		((mode) & AA_MAY_APPEND)
#define HAS_MAY_EXEC(mode)		((mode) & AA_MAY_EXEC)
#define HAS_MAY_LINK(mode)		((mode) & AA_MAY_LINK)
#define HAS_MAY_LOCK(mode)		((mode) & AA_MAY_LOCK)
#define HAS_EXEC_MMAP(mode) 		((mode) & AA_EXEC_MMAP)
#define HAS_EXEC_INHERIT(mode)		(((mode) & AA_EXEC_MODIFIERS) == \
					 AA_EXEC_INHERIT)
#define HAS_EXEC_PROFILE(mode)		(((mode) & AA_EXEC_MODIFIERS) == \
					 AA_EXEC_PROFILE)
#define HAS_EXEC_UNCONFINED(mode)	(((mode) & AA_EXEC_MODIFIERS) == \
					 AA_EXEC_UNCONFINED)
#define HAS_EXEC_PROFILE_OR_INHERIT(mode) (((mode) & AA_EXEC_MODIFIERS) == \
					   AA_EXEC_PROFILE_OR_INHERIT)
#define HAS_EXEC_UNSAFE(mode) 		((mode) & AA_EXEC_UNSAFE)
#define HAS_CHANGE_PROFILE(mode)	((mode) & AA_CHANGE_PROFILE)

static inline int is_merged_x_consistent(int a, int b)
{
	if ((a & AA_USER_EXEC_TYPE) && (b & AA_USER_EXEC_TYPE) &&
	    ((a & AA_USER_EXEC_TYPE) != (b & AA_USER_EXEC_TYPE)))
		return 0;
	if ((a & AA_GROUP_EXEC_TYPE) && (b & AA_GROUP_EXEC_TYPE) &&
	    ((a & AA_GROUP_EXEC_TYPE) != (b & AA_GROUP_EXEC_TYPE)))
		return 0;
	if ((a & AA_OTHER_EXEC_TYPE) && (b & AA_OTHER_EXEC_TYPE) &&
	    ((a & AA_OTHER_EXEC_TYPE) != (b & AA_OTHER_EXEC_TYPE)))
		return 0;

	return 1;
}

#endif				/* ! _IMMUNIX_H */
