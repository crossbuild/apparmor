#!/bin/bash
#
#   Copyright (c) 2013
#   Canonical, Ltd. (All rights reserved)
#
#   This program is free software; you can redistribute it and/or
#   modify it under the terms of version 2 of the GNU General Public
#   License published by the Free Software Foundation.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program; if not, contact Canonical Ltd.
#

# Tests for post-parser equality among multiple profiles. These tests are
# useful to verify that keyword aliases, formatting differences, etc., all
# result in the same parser output.

set -o pipefail

_SCRIPTDIR=$(dirname "${BASH_SOURCE[0]}" )

APPARMOR_PARSER="${APPARMOR_PARSER:-${_SCRIPTDIR}/../apparmor_parser}"
fails=0
errors=0
verbose="${VERBOSE:-}"

hash_binary_policy()
{
	printf %s "$1" | ${APPARMOR_PARSER} --features-file ${_SCRIPTDIR}/features_files/features.all -qS 2>/dev/null| md5sum | cut -d ' ' -f 1
	return $?
}

# verify_binary - compares the binary policy of multiple profiles
# $1: Test type (equality or inequality)
# $2: A short description of the test
# $3: The known-good profile
# $4..$n: The profiles to compare against $3
#
# Upon failure/error, prints out the test description and profiles that failed
# and increments $fails or $errors for each failure and error, respectively
verify_binary()
{
	local t=$1
	local desc=$2
	local good_profile=$3
	local good_hash
	local ret=0

	shift
	shift
	shift

	if [ "$t" != "equality" ] && [ "$t" != "inequality" ]
	then
		printf "\nERROR: Unknown test mode:\n%s\n\n" "$t" 1>&2
		((errors++))
		return $((ret + 1))
	fi

	if [ -n "$verbose" ] ; then printf "Binary %s %s" "$t" "$desc" ; fi
	good_hash=$(hash_binary_policy "$good_profile")
	if [ $? -ne 0 ]
	then
		if [ -z "$verbose" ] ; then printf "Binary %s %s" "$t" "$desc" ; fi
		printf "\nERROR: Error hashing the following \"known-good\" profile:\n%s\n\n" \
		       "$good_profile" 1>&2
		((errors++))
		return $((ret + 1))
	fi

	for profile in "$@"
	do
		hash=$(hash_binary_policy "$profile")
		if [ $? -ne 0 ]
		then
			if [ -z "$verbose" ] ; then printf "Binary %s %s" "$t" "$desc" ; fi
			printf "\nERROR: Error hashing the following profile:\n%s\n\n" \
			       "$profile" 1>&2
			((errors++))
			((ret++))
		elif [ "$t" == "equality" ] && [ "$hash" != "$good_hash" ]
		then
			if [ -z "$verbose" ] ; then printf "Binary %s %s" "$t" "$desc" ; fi
			printf "\nFAIL: Hash values do not match\n" 2>&1
			printf "known-good (%s) != profile-under-test (%s) for the following profile:\n%s\n\n" \
				"$good_hash" "$hash" "$profile" 1>&2
			((fails++))
			((ret++))
		elif [ "$t" == "inequality" ] && [ "$hash" == "$good_hash" ]
		then
			if [ -z "$verbose" ] ; then printf "Binary %s %s" "$t" "$desc" ; fi
			printf "\nFAIL: Hash values match\n" 2>&1
			printf "known-good (%s) == profile-under-test (%s) for the following profile:\n%s\n\n" \
				"$good_hash" "$hash" "$profile" 1>&2
			((fails++))
			((ret++))
		fi
	done

	if [ $ret -eq 0 ]
	then
		if [ -z "$verbose" ] ; then
			printf "."
		else
			printf " ok\n"

		fi
	fi
	return $ret
}

verify_binary_equality()
{
	verify_binary "equality" "$@"
}

verify_binary_inequality()
{
	verify_binary "inequality" "$@"
}

printf "Equality Tests:\n"

verify_binary_equality "dbus send" \
	"/t { dbus send, }" \
	"/t { dbus write, }" \
	"/t { dbus w, }"

verify_binary_equality "dbus receive" \
	"/t { dbus receive, }" \
	"/t { dbus read, }" \
	"/t { dbus r, }"

verify_binary_equality "dbus send + receive" \
	"/t { dbus (send, receive), }" \
	"/t { dbus (read, write), }" \
	"/t { dbus (r, w), }" \
	"/t { dbus (rw), }" \
	"/t { dbus rw, }" \

verify_binary_equality "dbus all accesses" \
	"/t { dbus (send, receive, bind, eavesdrop), }" \
	"/t { dbus (read, write, bind, eavesdrop), }" \
	"/t { dbus (r, w, bind, eavesdrop), }" \
	"/t { dbus (rw, bind, eavesdrop), }" \
	"/t { dbus (), }" \
	"/t { dbus, }" \

verify_binary_equality "dbus implied accesses with a bus conditional" \
	"/t { dbus (send, receive, bind, eavesdrop) bus=session, }" \
	"/t { dbus (read, write, bind, eavesdrop) bus=session, }" \
	"/t { dbus (r, w, bind, eavesdrop) bus=session, }" \
	"/t { dbus (rw, bind, eavesdrop) bus=session, }" \
	"/t { dbus () bus=session, }" \
	"/t { dbus bus=session, }" \

verify_binary_equality "dbus implied accesses for services" \
	"/t { dbus bind name=com.foo, }" \
	"/t { dbus name=com.foo, }"

verify_binary_equality "dbus implied accesses for messages" \
	"/t { dbus (send, receive) path=/com/foo interface=org.foo, }" \
	"/t { dbus path=/com/foo interface=org.foo, }"

verify_binary_equality "dbus implied accesses for messages with peer names" \
	"/t { dbus (send, receive) path=/com/foo interface=org.foo peer=(name=com.foo), }" \
	"/t { dbus path=/com/foo interface=org.foo peer=(name=com.foo), }" \
	"/t { dbus (send, receive) path=/com/foo interface=org.foo peer=(name=(com.foo)), }" \
	"/t { dbus path=/com/foo interface=org.foo peer=(name=(com.foo)), }"

verify_binary_equality "dbus implied accesses for messages with peer labels" \
	"/t { dbus (send, receive) path=/com/foo interface=org.foo peer=(label=/usr/bin/app), }" \
	"/t { dbus path=/com/foo interface=org.foo peer=(label=/usr/bin/app), }"

verify_binary_equality "dbus element parsing" \
	"/t { dbus bus=b path=/ interface=i member=m peer=(name=n label=l), }" \
	"/t { dbus bus=\"b\" path=\"/\" interface=\"i\" member=\"m\" peer=(name=\"n\" label=\"l\"), }" \
	"/t { dbus bus=(b) path=(/) interface=(i) member=(m) peer=(name=(n) label=(l)), }" \
	"/t { dbus bus=(\"b\") path=(\"/\") interface=(\"i\") member=(\"m\") peer=(name=(\"n\") label=(\"l\")), }" \
	"/t { dbus bus =b path =/ interface =i member =m peer =(name =n label =l), }" \
	"/t { dbus bus= b path= / interface= i member= m peer= (name= n label= l), }" \
	"/t { dbus bus = b path = / interface = i member = m peer = ( name = n label = l ), }"

verify_binary_equality "dbus access parsing" \
	"/t { dbus, }" \
	"/t { dbus (), }" \
	"/t { dbus (send, receive, bind, eavesdrop), }" \
	"/t { dbus (send receive bind eavesdrop), }" \
	"/t { dbus (send,	receive                  bind,  eavesdrop), }" \
	"/t { dbus (send,receive,bind,eavesdrop), }" \
	"/t { dbus (send,receive,,,,,,,,,,,,,,,,bind,eavesdrop), }" \
	"/t { dbus (send,send,send,send send receive,bind	eavesdrop), }" \

verify_binary_equality "dbus variable expansion" \
	"/t { dbus (send, receive) path=/com/foo member=spork interface=org.foo peer=(name=com.foo label=/com/foo), }" \
	"@{FOO}=foo
	    /t { dbus (send, receive) path=/com/@{FOO} member=spork interface=org.@{FOO} peer=(name=com.@{FOO} label=/com/@{FOO}), }" \
	"@{FOO}=foo
	 @{SPORK}=spork
	    /t { dbus (send, receive) path=/com/@{FOO} member=@{SPORK} interface=org.@{FOO} peer=(name=com.@{FOO} label=/com/@{FOO}), }" \
	"@{FOO}=/com/foo
            /t { dbus (send, receive) path=@{FOO} member=spork interface=org.foo peer=(name=com.foo label=@{FOO}), }" \
	"@{FOO}=com
            /t { dbus (send, receive) path=/@{FOO}/foo member=spork interface=org.foo peer=(name=@{FOO}.foo label=/@{FOO}/foo), }"

verify_binary_equality "dbus variable expansion, multiple values/rules" \
	"/t { dbus (send, receive) path=/com/foo, dbus (send, receive) path=/com/bar, }" \
	"/t { dbus (send, receive) path=/com/{foo,bar}, }" \
	"/t { dbus (send, receive) path={/com/foo,/com/bar}, }" \
	"@{FOO}=foo
	    /t { dbus (send, receive) path=/com/@{FOO}, dbus (send, receive) path=/com/bar, }" \
	"@{FOO}=foo bar
	    /t { dbus (send, receive) path=/com/@{FOO}, }" \
	"@{FOO}=bar foo
	    /t { dbus (send, receive) path=/com/@{FOO}, }" \
	"@{FOO}={bar,foo}
	    /t { dbus (send, receive) path=/com/@{FOO}, }" \
	"@{FOO}=foo
	 @{BAR}=bar
	    /t { dbus (send, receive) path=/com/{@{FOO},@{BAR}}, }" \

verify_binary_equality "dbus variable expansion, ensure rule de-duping occurs" \
	"/t { dbus (send, receive) path=/com/foo, dbus (send, receive) path=/com/bar, }" \
	"/t { dbus (send, receive) path=/com/foo, dbus (send, receive) path=/com/bar, dbus (send, receive) path=/com/bar, }" \
	"@{FOO}=bar foo bar foo
	    /t { dbus (send, receive) path=/com/@{FOO}, }" \
	"@{FOO}=bar foo bar foo
	    /t { dbus (send, receive) path=/com/@{FOO}, dbus (send, receive) path=/com/@{FOO}, }"

verify_binary_equality "dbus minimization with all perms" \
	"/t { dbus, }" \
	"/t { dbus bus=session, dbus, }" \
	"/t { dbus (send, receive, bind, eavesdrop), dbus, }"

verify_binary_equality "dbus minimization with bind" \
	"/t { dbus bind, }" \
	"/t { dbus bind bus=session, dbus bind, }" \
	"/t { dbus bind bus=system name=com.foo, dbus bind, }"

verify_binary_equality "dbus minimization with send and a bus conditional" \
	"/t { dbus send bus=system, }" \
	"/t { dbus send bus=system path=/com/foo interface=com.foo member=bar, dbus send bus=system, }" \
	"/t { dbus send bus=system peer=(label=/usr/bin/foo), dbus send bus=system, }"

verify_binary_equality "dbus minimization with an audit modifier" \
	"/t { audit dbus eavesdrop, }" \
	"/t { audit dbus eavesdrop bus=session, audit dbus eavesdrop, }"

verify_binary_equality "dbus minimization with a deny modifier" \
	"/t { deny dbus send bus=system peer=(name=com.foo), }" \
	"/t { deny dbus send bus=system peer=(name=com.foo label=/usr/bin/foo), deny dbus send bus=system peer=(name=com.foo), }" \

verify_binary_equality "dbus minimization found in dbus abstractions" \
	"/t { dbus send bus=session, }" \
	"/t { dbus send
                   bus=session
                   path=/org/freedesktop/DBus
                   interface=org.freedesktop.DBus
                   member={Hello,AddMatch,RemoveMatch,GetNameOwner,NameHasOwner,StartServiceByName}
                   peer=(name=org.freedesktop.DBus),
	      dbus send bus=session, }"

# Rules compatible with audit, deny, and audit deny
# note: change_profile does not support audit/allow/deny atm
for rule in "capability" "capability mac_admin" \
	"network" "network tcp" "network inet6 tcp"\
	"mount" "mount /a" "mount /a -> /b" "mount options in (ro) /a -> b" \
	"remount" "remount /a" \
	"umount" "umount /a" \
	"pivot_root" "pivot_root /a" "pivot_root oldroot=/" \
	 "pivot_root oldroot=/ /a" "pivot_root oldroot=/ /a -> foo" \
	"ptrace" "ptrace trace" "ptrace (readby,tracedby) peer=unconfined" \
	"signal" "signal (send,receive)" "signal peer=unconfined" \
	 "signal receive set=(kill)" \
	"dbus" "dbus send" "dbus bus=system" "dbus bind name=foo" \
	 "dbus peer=(label=foo)" "dbus eavesdrop" \
	"unix" "unix (create, listen, accept)" "unix addr=@*" "unix addr=none" \
	 "unix peer=(label=foo)" \
	"/f r" "/f w" "/f rwmlk" "/** r" "/**/ w" \
	"file /f r" "file /f w" "file /f rwmlk" \
	"link /a -> /b" "link subset /a -> /b" \
	"l /a -> /b" "l subset /a -> /b" \
	"file l /a -> /b" "l subset /a -> /b"
do
	verify_binary_equality "allow modifier for \"${rule}\"" \
		"/t { ${rule}, }" \
		"/t { allow ${rule}, }"

	verify_binary_inequality "audit, deny, and audit deny modifiers for \"${rule}\"" \
		"/t { ${rule}, }" \
		"/t { audit ${rule}, }" \
		"/t { audit allow ${rule}, }" \
		"/t { deny ${rule}, }" \
		"/t { audit deny ${rule}, }"
done

# Rules that need special treatment for the deny modifier
for rule in "/f ux" "/f Ux" "/f px" "/f Px" "/f cx" "/f Cx" "/f ix" \
            "/f pux" "/f Pux" "/f pix" "/f Pix" \
            "/f cux" "/f Cux" "/f cix" "/f Cix" \
            "/* ux" "/* Ux" "/* px" "/* Px" "/* cx" "/* Cx" "/* ix" \
            "/* pux" "/* Pux" "/* pix" "/* Pix" \
            "/* cux" "/* Cux" "/* cix" "/* Cix" \
	    "/f px -> b " "/f Px -> b" "/f cx -> b" "/f Cx -> b" \
            "/f pux -> b" "/f Pux -> b" "/f pix -> b" "/f Pix -> b" \
            "/f cux -> b" "/f Cux -> b" "/f cix -> b" "/f Cix -> b" \
            "/* px -> b" "/* Px -> b" "/* cx -> b" "/* Cx -> b" \
            "/* pux -> b" "/* Pux -> b" "/* pix -> b" "/* Pix -> b" \
            "/* cux -> b" "/* Cux -> b" "/* cix -> b" "/* Cix -> b" \
	    "file /f ux" "file /f Ux" "file /f px" "file /f Px" \
            "file /f cx" "file /f Cx" "file /f ix" \
            "file /f pux" "file /f Pux" "file /f pix" "file /f Pix" \
            "/f cux" "/f Cux" "/f cix" "/f Cix" \
            "file /* ux" "file /* Ux" "file /* px" "file /* Px" \
            "file /* cx" "file /* Cx" "file /* ix" \
            "file /* pux" "file /* Pux" "file /* pix" "file /* Pix" \
            "file /* cux" "file /* Cux" "file /* cix" "file /* Cix" \
	    "file /f px -> b " "file /f Px -> b" "file /f cx -> b" "file /f Cx -> b" \
            "file /f pux -> b" "file /f Pux -> b" "file /f pix -> b" "file /f Pix -> b" \
            "file /f cux -> b" "file /f Cux -> b" "file /f cix -> b" "file /f Cix -> b" \
            "file /* px -> b" "file /* Px -> b" "file /* cx -> b" "file /* Cx -> b" \
            "file /* pux -> b" "file /* Pux -> b" "file /* pix -> b" "file /* Pix -> b" \
            "file /* cux -> b" "file /* Cux -> b" "file /* cix -> b" "file /* Cix -> b"

do
	verify_binary_equality "allow modifier for \"${rule}\"" \
		"/t { ${rule}, }" \
		"/t { allow ${rule}, }"

	# skip rules that don't end with x perm
	if [ -n "${rule##*x}" ] ; then continue ; fi

	verify_binary_inequality "deny, audit deny modifier for \"${rule}\"" \
		"/t { ${rule}, }" \
		"/t { audit ${rule}, }" \
		"/t { audit allow ${rule}, }" \
		"/t { deny ${rule% *} x, }" \
		"/t { audit deny ${rule% *} x, }"
done

#Test equality of leading and trailing file permissions
for audit in "" "audit" ; do
	for allow in "" "allow" "deny" ; do
		for owner in "" "owner" ; do
			for f in "" "file" ; do
				prefix="$audit $allow $owner $f"
				for perm in "r" "w" "a" "l" "k" "m" "rw" "ra" \
					    "rl" "rk" "rm" "wl" "wk" "wm" \
					    "rwl" "rwk" "rwm" "ral" "rak" \
					    "ram" "rlk" "rlm" "rkm" "wlk" \
					    "wlm" "wkm" "alk" "alm" "akm" \
					    "lkm" "rwlk" "rwlm" "rwkm" \
					    "ralk" "ralm" "wlkm" "alkm" \
					    "rwlkm" "ralkm" ; do
					verify_binary_equality "leading and trailing perms" \
						"/t { ${prefix} /f ${perm}, }" \
						"/t { ${prefix} ${perm} /f, }"
				done
				if [ "$allow" == "deny" ] ; then continue ; fi
				for perm in "ux" "Ux" "px" "Px" "cx" "Cx" \
					    "ix" "pux" "Pux" "pix" "Pix" \
					    "cux" "Cux" "cix" "Cix"
				do
					verify_binary_equality "leading and trailing perms" \
						"/t { ${prefix} /f ${perm}, }" \
						"/t { ${prefix} ${perm} /f, }"
				done
				for perm in "px" "Px" "cx" "Cx" \
					    "pux" "Pux" "pix" "Pix" \
					    "cux" "Cux" "cix" "Cix"
				do
					verify_binary_equality "leading and trailing perms" \
						"/t { ${prefix} /f ${perm} -> b, }" \
						"/t { ${prefix} ${perm} /f -> b, }"
				done
			done
		done
	done
done

#Test rule overlap for x most specific match
for perm1 in "ux" "Ux" "px" "Px" "cx" "Cx" "ix" "pux" "Pux" \
	     "pix" "Pix" "cux" "Cux" "cix" "Cix" "px -> b" \
	     "Px -> b" "cx -> b" "Cx -> b" "pux -> b" "Pux ->b" \
	     "pix -> b" "Pix -> b" "cux -> b" "Cux -> b" \
	     "cix -> b" "Cix -> b"
do
	for perm2 in "ux" "Ux" "px" "Px" "cx" "Cx" "ix" "pux" "Pux" \
		     "pix" "Pix" "cux" "Cux" "cix" "Cix" "px -> b" \
	             "Px -> b" "cx -> b" "Cx -> b" "pux -> b" "Pux ->b" \
	             "pix -> b" "Pix -> b" "cux -> b" "Cux -> b" \
	             "cix -> b" "Cix -> b"
	do
		if [ "$perm1" ==  "$perm2" ] ; then
			verify_binary_equality "Exec - most specific match: same as glob" \
				"/t { /* px, /f px, }" \
				"/t { /* px, }"
		else
			verify_binary_inequality "Exec - most specific match: different from glob" \
				"/t { /* px, /f cx, }" \
				"/t { /* px, }"
		fi
	done
done

#Test deny carves out permission
verify_binary_inequality "Deny removes r perm" \
		       "/t { /foo/[abc] r, audit deny /foo/b r, }" \
		       "/t { /foo/[abc] r, }"

verify_binary_equality "Deny removes r perm" \
		       "/t { /foo/[abc] r, audit deny /foo/b r, }" \
		       "/t { /foo/[ac] r, }"

#this one may not be true in the future depending on if the compiled profile
#is explicitly including deny permissions for dynamic composition
verify_binary_equality "Deny of ungranted perm" \
		       "/t { /foo/[abc] r, audit deny /foo/b w, }" \
		       "/t { /foo/[abc] r, }"


if [ $fails -ne 0 -o $errors -ne 0 ]
then
	printf "ERRORS: %d\nFAILS: %d\n" $errors $fails 2>&1
	exit $(($fails + $errors))
fi

[ -z "${verbose}" ] && printf "\n"
printf "PASS\n"
exit 0
