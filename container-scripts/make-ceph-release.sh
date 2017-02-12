#!/bin/bash
set -e

# Common Variables
OS=("ubuntu:16.04" "ubuntu:14.04" "centos:7" "fedora:25")
REL=""
CONT_NAME=""
CONT_ARGS=""
DBG=false
declare -a DBG_ARGS
CEPH_EXTRA_CMAKE_ARGS='-DWITH_LTTNG=ON -DHAVE_BABELTRACE=ON -DWITH_EVENTTRACE=ON -DCMAKE_BUILD_TYPE=Debug -DCMAKE_C_FLAGS="-O0 -g3 -gdwarf-4 -ggd"'
DEB_BUILD_OPTIONS='nostrip noopt debug'
G_USER="$(git config user.name)"
G_EMAIL="$(git config user.email)"

function usage()
{
	echo ""
	echo "Script to create ceph release packages inside docker container, deb/rpm"
	echo ""
	echo "Usage: ${0} [-d | --dest ] [-s|--source]"
	echo ""
	echo "-d|--dest	:	Location for the resultant packages. Default: /tmp/release"
	echo "-s|--source:	Source directory for mounting"
	echo "-b|--debug:	Add debug flags to the build"
	echo ""
	exit 1
}

ARGS=$(getopt -o s:d:b -l source:,dest:,debug,help -- "$@");
if [ $? -ne 0 ]; then usage; fi
eval set -- "$ARGS"
while true; do
	case "$1" in
		-s|--source) SRC=$2; shift 2;;
		-d|--dest) DEST=$2; shift 2;;
		-b|--debug) DBG=true; shift 1;;
		-h|--help) usage; break;;
		--)shift; break;;
		*)usage;;
	esac
done

if [ -z "${SRC}" ] || [ -z "${DEST}" ]; then
	usage
fi

function populate_stuff()
{
	for i in $(seq 0 $((${#OS[*]} -1 )))
	do
		echo "$i * ${OS[$i]}"
	done
	echo -n "Which OS?:"
	read rel
	REL="${OS[$rel]}"
	CONT_NAME="ceph-builder-${REL/:/-}"

	CONT_ARGS+=" --name ${CONT_NAME} "
	# Find env variables that we might need
	if [ -n "${http_proxy}" ] || [ -n "${HTTP_PROXY}" ];
	then
		echo "Proxy detected. Will be set for containers"
		CONT_ARGS+="-e http_proxy=${http_proxy} \
					-e https_proxy=${https_proxy} \
					-e no_proxy=${no_proxy} "
	fi

	echo "Source ${SRC} will be mounted at /data/ceph-src"
	echo "${DEST} will be mounted at /data/ceph-dest"

	CONT_ARGS+="-v ${SRC}:/data/ceph-src -v ${DEST}:/data/ceph-dest "
}

function deb_release()
{
	echo "Starting build for ${REL}..."

	# Set things unique to these systems
	if ${DBG}; then
		DBG_ARGS+=("-e DEB_BUILD_OPTIONS=${DEB_BUILD_OPTIONS} -e CEPH_EXTRA_CMAKE_ARGS=${CEPH_EXTRA_CMAKE_ARGS} ")
	fi

	# Start Container
	echo docker run -it -d ${CONT_ARGS} "${DBG_ARGS[@]}" ${REL} bash
	docker run -it -d ${CONT_ARGS} "${DBG_ARGS[@]}" ${REL} bash

	# Setup packages for building
	docker exec -it ${CONT_NAME} apt-get update
	docker exec -it ${CONT_NAME} apt-get install --yes lsb-release reprepro
	docker exec -it ${CONT_NAME} bash -c \
		'cd /data/ceph-src; /data/ceph-src/install-deps.sh'

	# Start making the build
	docker exec -it ${CONT_NAME} bash -c \
		'/data/ceph-src/make-debs.sh /data/ceph-dest/ \
		2>&1 | tee /data/ceph-dest/build.log'
}

function rpm_release()
{
	echo "Starting build for ${REL}..."

	# Set things unique to these systems
	if ${DBG}; then
		DBG_ARGS+=("-e CEPH_EXTRA_CMAKE_ARGS=${CEPH_EXTRA_CMAKE_ARGS} ")
	fi

	# Start Container
	echo docker run -it -d ${CONT_ARGS} "${DBG_ARGS[@]}" ${REL} bash
	docker run -it -d ${CONT_ARGS} "${DBG_ARGS[@]}" ${REL} bash

	# Set some config for rpm build
	docker exec -it ${CONT_NAME} bash -c \
		'echo "%_topdir /data/ceph-dest" >> ~/.rpmmacros'
	docker exec -it ${CONT_NAME} bash -c \
		"echo '%packager ${G_USER} <${G_EMAIL}>' \
		>> ~/.rpmmacros" || { echo \
		'Unable to find user details. Going with standard'; \
		continue; }

	# Just flush the DEST dir before creating the new build. Clearly you don't
	# need it.
	docker exec -it ${CONT_NAME} bash -c \
		'rm -rf /data/ceph-dest/*'
	docker exec -it ${CONT_NAME} bash -c \
		'mkdir -p /data/ceph-dest/{BUILD,RPMS,SPECS,SOURCES,SRPMS}'

	# Setup packages for building
	docker exec -it ${CONT_NAME} yum --assumeyes update
	docker exec -it ${CONT_NAME} yum install --assumeyes \
		git rpm-build rpmdevtools
	docker exec -it ${CONT_NAME} bash -c \
		'cd /data/ceph-src; /data/ceph-src/install-deps.sh'

	# Start building packages
	docker exec -it ${CONT_NAME} bash -c \
		'cd /data/ceph-src; \
		/data/ceph-src/make-srpm.sh \
		2>&1 | tee /data/ceph-dest/build.log'
	docker exec -it ${CONT_NAME} bash -c \
		'cd /data/ceph-src; \
		rpmbuild --rebuild $(ls -1q /data/ceph-src/*.rpm) \
		2>&1 | tee -a /data/ceph-dest/build.log'
}

# Lets go!!

populate_stuff

if [[ "$REL" =~ "ubuntu" ]]; then
	deb_release
else
	rpm_release
fi

# Always clean container at the end.
docker stop ${CONT_NAME}
docker rm ${CONT_NAME}
