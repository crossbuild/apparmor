#
# $Id$
#
OVERRIDE_TARBALL=yes

include common/Make.rules

DIRS=parser \
     profiles \
     utils \
     changehat/libapparmor \
     changehat/mod_apparmor \
     changehat/pam_apparmor \
     management/apparmor-dbus \
     management/applets/apparmorapplet-gnome \
     management/yastui \
     common \
     tests

REPO_URL=lp:apparmor
# alternate possibilities to export from
#REPO_URL=.
#REPO_URL="bzr+ssh://bazaar.launchpad.net/~sbeattie/+junk/apparmor-dev/"

RELEASE_DIR=apparmor-${VERSION}
SNAPSHOT_DIR=apparmor-${VERSION}-${REPO_VERSION}

.PHONY: tarball
tarball: clean
	make export_dir __EXPORT_DIR=${RELEASE_DIR}
	make setup __SETUP_DIR=${RELEASE_DIR}
	tar cvzf ${RELEASE_DIR}.tar.gz ${RELEASE_DIR}

.PHONY: snapshot
snapshot: clean
	make export_dir __EXPORT_DIR=${SNAPSHOT_DIR}
	make setup __SETUP_DIR=${SNAPSHOT_DIR}
	tar cvzf ${SNAPSHOT_DIR}.tar.gz ${SNAPSHOT_DIR}

${SNAPSHOT_DIR}:
	mkdir ${SNAPSHOT_DIR}

.PHONY: export_dir
export_dir:
	mkdir $(__EXPORT_DIR)
	/usr/bin/bzr export -r $(REPO_VERSION) $(__EXPORT_DIR) $(REPO_URL)
	echo "$(REPO_URL) $(REPO_VERSION)" > $(__EXPORT_DIR)/common/.stamp_rev

.PHONY: clean
clean:
	-rm -rf ${RELEASE_DIR} apparmor-${VERSION}-*

.PHONY: setup
setup:
	cd $(__SETUP_DIR)/libraries/libapparmor && ./autogen.sh

.PHONY: tag
tag:
	bzr tag apparmor_${VERSION}
