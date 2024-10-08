#!/bin/bash

RELEASES=${1:-"master scarthgap styhead kirkstone"}
echo "RELEASES=$RELEASES"

ARCHS=${2:-"qemuarm64 qemux86-64"}
echo "ARCHS=$ARCHS"

setup_config() {
# keep indent!
cat <<EOF >>$BUILDDIR/conf/local.conf
# Required to disable KVM/hypervisor mode.
QEMU_USE_KVM = ""

# use slirp networking instead of TAP interface (require root rights)
QEMU_USE_SLIRP = "1"
TEST_SERVER_IP = "127.0.0.1"

# this will specify what test should run when running testimage cmd - oeqa layer tests + ptests:
# Ping and SSH are not required, but do help in debugging. ptest will discover all ptest packages.
TEST_SUITES = " ping ssh ptest"

# this will allow - running testimage cmd: bitbake core-image-minimal -c testimage
IMAGE_CLASSES += "testimage"

# PUT = package under test / this is set in auto.conf
PUT ?= ""
IMAGE_INSTALL:append = " ptest-runner ssh \${PUT}"

# INHERIT += "cve-check"
# include cve-extra-exclusions.inc

# INHERIT += "create-spdx"
# SPDX_PRETTY = "1"

INHERIT += "rm_work"

# BB_ENV_PASSTHROUGH_ADDITIONS="SSTATE_DIR $BB_ENV_PASSTHROUGH_ADDITIONS" SSTATE_DIR="/sstate" ./meta-aws-release-tests.sh
SSTATE_DIR ?= "\${TOPDIR}/../../sstate-cache"
DL_DIR ?= "\${TOPDIR}/../../downloads"
EOF
}

set +exuo pipefail

for RELEASE in $RELEASES ; do

    # always delete old files, rebuilding from sstate will be fast enough
    if [ -d yocto_$RELEASE ]
    then
        echo "deleting $PWD/yocto_$RELEASE"
        tmp_del_dir=delme_$RANDOM
        mkdir $tmp_del_dir
        mv yocto_$RELEASE $tmp_del_dir
        rm -rf $tmp_del_dir &
    fi

    mkdir yocto_$RELEASE

    cd yocto_$RELEASE/
writeups of different topics
    git clone git://git.yoctoproject.org/poky -b  $RELEASE
    git clone https://github.com/aws4embeddedlinux/meta-aws.git -b $RELEASE-next
    git clone https://github.com/openembedded/meta-openembedded.git -b $RELEASE

    source poky/oe-init-build-env build

    # add necessary layers
    bitbake-layers add-layer ../meta-openembedded/meta-oe
    bitbake-layers add-layer ../meta-openembedded/meta-python
    bitbake-layers add-layer ../meta-openembedded/meta-networking
    bitbake-layers add-layer ../meta-openembedded/meta-multimedia
    bitbake-layers add-layer ../meta-aws

    # setup build/local.conf
    setup_config

    # find all recipes in meta-aws
    ALL_RECIPES=`find ../meta-aws -name *.bb -type f  | sed 's!.*/!!' | sed 's!.bb!!' | sed 's!_.*!!' | sort | uniq | sed -z 's/\n/ /g'`

    # find all recipes having a ptest in meta-aws
    ptest_recipes=`find ../meta-aws -name *.bb -type f -print | xargs grep -l 'inherit.*ptest.*'| sed 's!.*/!!' | sed 's!.bb!!' | sed 's!_.*!!' | sort | uniq | sed -z 's/\n/ /g'`

    # make array out of string
    ptest_recipes_array=($(echo "$ptest_recipes" | tr ',' '\n'))

    # add -ptest suffix
    ptest_recipes_names_array_with_ptest=("${ptest_recipes_array[@]/%/-ptest}")

    # make string again
    PTEST_RECIPE_NAMES_WITH_PTEST_SUFFIX="${ptest_recipes_names_array_with_ptest[@]}"

    for ARCH in $ARCHS ; do

        # build everything in meta-aws layer and save errors
        MACHINE=$ARCH bitbake $ALL_RECIPES -k | tee -a ../../$RELEASE-$ARCH-build.log

        # do ptests for all recipes having a ptest in meta-aws

        echo PUT = \"${PTEST_RECIPE_NAMES_WITH_PTEST_SUFFIX}\" > $BUILDDIR/conf/auto.conf

        MACHINE=$ARCH bitbake core-image-minimal

#        cp $BUILDDIR/tmp/log/cve/cve-summary.json ../../$RELEASE-$ARCH-cve-summary.json

        MACHINE=$ARCH bitbake core-image-minimal -c testimage

        rm  $BUILDDIR/conf/auto.conf

        cp $BUILDDIR/tmp/log/oeqa/testresults.json ../../$RELEASE-$ARCH-testresults.json

        # show results
        resulttool report ../../$RELEASE-$ARCH-testresults.json

    done
    # cd ../build
    cd ../

    # cd ../yocto_$RELEASE/
    cd ../
done

# search for build errors
echo  "manually check (if found) build errors: "
grep -A3 " failed"  *.log
grep -A3 " ERROR:"  *.log
