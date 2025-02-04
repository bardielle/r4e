#!/bin/bash

set -e

# The script performs the following steps on rhel-8.5:
# * Create new rpms for yggdrasil, flotta-device-worker and Prometheus node_exporter
# * Publish rpms as yum repo to be consumed by image-builder
# * Publish rhel4edge image commit for edge-device
# * ./flotta-agent-sti-upgrade.sh -a <server_adress> -i <image_name> -o <operator_host_name:operator_port> -p <parent_commit> -v

IMAGE_SERVER_ADDRESS=
IMAGE_NAME=
HTTP_API=
FLOTTA_GITHUB_ORG=
FLOTTA_GITHUB_BRANCH=
VERBOSE=
OSTREE_COMMIT=
SUFFIX=$(date +%s)

usage()
{
cat << EOF
usage: $0 options
This script will create an image commit to be served for upgrade.
OPTIONS:
   -h      Show this message
   -a      Image server address
   -i      Original Image name(required)
   -o      Operator's HTTP API (required)
   -p      Ostree parent commit(required)
   -g      GitHub organization for flotta-device-worker repo (optional)
   -b      GitHub branch name for flotta-device-worker repo (optional)
   -v      Verbose
EOF
}

while getopts "h:a:i:o:p:g:b:v" option; do
    case "${option}"
    in
        h)
            usage
            exit 0
            ;;
        a) IMAGE_SERVER_ADDRESS=${OPTARG};;
        i) IMAGE_NAME=${OPTARG};;
        o) HTTP_API=${OPTARG};;
        p) OSTREE_COMMIT=${OPTARG};;
        g) FLOTTA_GITHUB_ORG=${OPTARG};;
        b) FLOTTA_GITHUB_BRANCH=${OPTARG};;
        v) VERBOSE=1;;
    esac
done

dnf install -y bind-utils
if [[ -z $IMAGE_SERVER_ADDRESS ]]; then
    hostname_output=$(host $(hostname))
    for word in $hostname_output
    do
      if [[ ($word =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$)  && ($word != "127.0.0.1")]]; then
        echo "found hostname"
        IMAGE_SERVER_ADDRESS=$word
        break
      fi
    done
    if [[ -z $IMAGE_SERVER_ADDRESS ]]; then
      echo "ERROR: server address is required"
      usage
      exit 1
    fi
fi
if [[ -z $IMAGE_NAME ]]; then
    echo "ERROR: Image name is required"
    usage
    exit 1
fi

if [[ -z $HTTP_API ]]; then
    echo "ERROR: Operator's HTTP-API url is required"
    usage
    exit 1
fi
if [[ -z $OSTREE_COMMIT ]]; then
    echo "ERROR: Ostree parent commit is required"
    usage
    exit 1
fi

if [[ ! -z $VERBOSE ]]; then
    echo "Building ${IMAGE_NAME} image for Operator's HTTP-API ${HTTP_API}"
    set -xv
fi

if [[ -z $FLOTTA_GITHUB_ORG ]]; then
   FLOTTA_GITHUB_ORG="project-flotta"
fi
if [[ -z $FLOTTA_GITHUB_BRANCH ]]; then
   FLOTTA_GITHUB_BRANCH="main"
fi

# export for use in templates
export IMAGE_NAME
export HTTP_API
export SUFFIX
export SOURCE_NAME="flotta-agent-$SUFFIX"
PACKAGES_REPO=flotta-repo-$SUFFIX
PACKAGE_REPO_URL=http://$IMAGE_SERVER_ADDRESS/$PACKAGES_REPO
BLUEPRINT_NAME=$IMAGE_NAME
IMAGE_UPGRADE_FOLDER=/var/www/html/$IMAGE_NAME-upgrade
IMAGE_UPGRADE_URL=http://$IMAGE_SERVER_ADDRESS/$IMAGE_NAME-upgrade

#---------------------------------
# Cleanup before running
#---------------------------------
rm -rf ~/rpmbuild/*
rm -rf /var/www/html/flotta-repo*
rm -rf /home/builder/yggdrasil
rm -rf /home/builder/flotta-device-worker
rm -rf /home/builder/prometheus-node_exporter-rpm
rm -rf /var/www/html/$IMAGE_UPGRADE_FOLDER
rm -rf /var/www/html/$IMAGE_NAME-upgrade
# need to remove all sources
composer-cli sources delete agent

#-----------------------------------
# Build packages for Flotta from source (change here the branches)
#-----------------------------------
# Build yggdrasil rpm
git clone https://github.com/jakub-dzon/yggdrasil.git /home/builder/yggdrasil
cd /home/builder/yggdrasil
export CGO_ENABLED=0

export ARCH=$(uname -i)
GOPROXY=proxy.golang.org,direct PWD=$PWD spec=$PWD outdir=$PWD make -f .copr/Makefile srpm
rpm -ihv $(ls -ltr yggdrasil-*.src.rpm | tail -n 1 | awk '{print $NF}')
if [ "$ARCH" = "aarch64" ]; then
    # Turn ELF binary stripping off in %post
    sed -i '1s/^/%global __os_install_post %{nil}/' ~/rpmbuild/SPECS/yggdrasil.spec
fi
rpmbuild -bb ~/rpmbuild/SPECS/yggdrasil.spec --target $ARCH

# Build flotta-device-worker rpm
git clone https://github.com/$FLOTTA_GITHUB_ORG/flotta-device-worker.git /home/builder/flotta-device-worker
cd /home/builder/flotta-device-worker
git checkout $FLOTTA_GITHUB_BRANCH

if [ "$ARCH" = "aarch64" ]; then
    make build-arm64
    make rpm-arm64
else
    make build
    make rpm
fi

# Build Prometheus node_exporter rpm
git clone https://github.com/project-flotta/prometheus-node_exporter-rpm.git /home/builder/prometheus-node_exporter-rpm
cd /home/builder/prometheus-node_exporter-rpm
make rpm

#---------------------------
# Create packages repository
#---------------------------
mkdir /var/www/html/$PACKAGES_REPO
cp /root/rpmbuild/RPMS/${ARCH}/*.${ARCH}.rpm /var/www/html/$PACKAGES_REPO/
createrepo /var/www/html/$PACKAGES_REPO/

#-----------------------------------
# Create and publish rhel4edge new commit
#-----------------------------------
cd /home/builder/r4e

export REPO_URL=$IMAGE_BASE_URL/repo

# make sure image does not already exist
if [ -e "$IMAGE_UPGRADE_FOLDER" ] ; then
    echo "$IMAGE_UPGRADE_FOLDER already exists"
    exit 1
fi

#-----------------------------------
# create source resource if rpm repository URL is provided
#-----------------------------------
cat << EOF > repo.toml
id = "$SOURCE_NAME"
name = "$SOURCE_NAME"
description = "Flotta agent repository"
type = "yum-baseurl"
url = "$PACKAGE_REPO_URL"
check_gpg = false
check_ssl = false
system = false
EOF

composer-cli sources add repo.toml
composer-cli blueprints depsolve $BLUEPRINT_NAME

#-----------------------------------
# create an image commit
#-----------------------------------
echo "Creating image $IMAGE_NAME"
BUILD_ID=$(composer-cli -j compose start-ostree $BLUEPRINT_NAME edge-commit --parent $OSTREE_COMMIT  | jq '.build_id')
echo "waiting for build $BUILD_ID to be ready..."
while [ $(composer-cli -j compose status  | jq -r '.[] | select( .id == '$BUILD_ID' ).status') == "RUNNING" ] ; do sleep 5 ; done
if [ $(composer-cli -j compose status  | jq -r '.[] | select( .id == '$BUILD_ID' ).status') != "FINISHED" ] ; then
    echo "image composition failed"
    echo "check 'composer-cli compose status'"
    exit 1
fi

#-----------------------------------
# extract image to web server folder
#-----------------------------------
echo "Saving image to web folder $IMAGE_UPGRADE_FOLDER"
composer-cli compose image $BUILD_ID
sudo mkdir $IMAGE_UPGRADE_FOLDER
sudo tar -xvf ${BUILD_ID//\"/}-commit.tar -C $IMAGE_UPGRADE_FOLDER

composer-cli sources delete "$SOURCE_NAME"
echo "commit is available in $IMAGE_UPGRADE_URL"