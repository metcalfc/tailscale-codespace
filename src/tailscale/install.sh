#!/usr/bin/env bash
# Copyright (c) 2022 Tailscale Inc & AUTHORS All rights reserved.
# Use of this source code is governed by a BSD-style
# license that can be found in the LICENSE file.

set -euo pipefail

case $(uname -m) in
x86_64 | amd64)
  ARCH=amd64
  ;;
arm64 | aarch64)
  ARCH=arm64
  ;;
*)
  echo "Unsupported architecture: $(uname -m)" >&2
  exit 1
  ;;
esac

clean_download() {
    # Credit to Daniel Braun (danielbraun89) @ https://github.com/devcontainers-contrib/features
    # The purpose of this function is to download a file with minimal impact on container layer size
    # this means if no valid downloader is found (curl or wget) then we install a downloader (currently wget) in a
    # temporary manner, and making sure to
    # 1. uninstall the downloader at the return of the function
    # 2. revert back any changes to the package installer database/cache (for example apt-get lists)
    # The above steps will minimize the leftovers being created while installing the downloader
    # Supported distros:
    #  debian/ubuntu/alpine

    url=$1
    output_location=$2
    tempdir=$(mktemp -d)
    downloader_installed=""

    _apt_get_install() {
        tempdir=$1

        # copy current state of apt list - in order to revert back later (minimize contianer layer size)
        cp -p -R /var/lib/apt/lists $tempdir
        apt-get update -y
        apt-get -y install --no-install-recommends wget ca-certificates
    }

    _apt_get_cleanup() {
        tempdir=$1

        echo "removing wget"
        apt-get -y purge wget --auto-remove

        echo "revert back apt lists"
        rm -rf /var/lib/apt/lists/*
        rm -r /var/lib/apt/lists && mv $tempdir/lists /var/lib/apt/lists
    }

    _apk_install() {
        tempdir=$1
        # copy current state of apk cache - in order to revert back later (minimize contianer layer size)
        cp -p -R /var/cache/apk $tempdir

        apk add --no-cache  wget
    }

    _apk_cleanup() {
        tempdir=$1

        echo "removing wget"
        apk del wget
    }
    # try to use either wget or curl if one of them already installer
    if type curl >/dev/null 2>&1; then
        downloader=curl
    elif type wget >/dev/null 2>&1; then
        downloader=wget
    else
        downloader=""
    fi

    # in case none of them is installed, install wget temporarly
    if [ -z $downloader ] ; then
        if [ -x "/usr/bin/apt-get" ] ; then
            _apt_get_install $tempdir
        elif [ -x "/sbin/apk" ] ; then
            _apk_install $tempdir
        else
            echo "distro not supported"
            exit 1
        fi
        downloader="wget"
        downloader_installed="true"
    fi

    if [ $downloader = "wget" ] ; then
        wget -q $url -O $output_location
    else
        curl -sfL $url -o $output_location
    fi

    # NOTE: the cleanup procedure was not implemented using `trap X RETURN` only because
    # alpine lack bash, and RETURN is not a valid signal under sh shell
    if ! [ -z $downloader_installed  ] ; then
        if [ -x "/usr/bin/apt-get" ] ; then
            _apt_get_cleanup $tempdir
        elif [ -x "/sbin/apk" ] ; then
            _apk_cleanup $tempdir
        else
            echo "distro not supported"
            exit 1
        fi
    fi

}

tailscale_url="https://pkgs.tailscale.com/stable/tailscale_${VERSION}_${ARCH}.tgz"
echo "Downloading: $tailscale_url"

script_dir="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
scratch_dir="/tmp/tailscale"
scratch_file="/tmp/tailscale.tgz"
mkdir -p "$scratch_dir"
trap 'rm -rf "$scratch_dir $scratch_file"' EXIT

clean_download "$tailscale_url" "$scratch_file"
tar --strip-components=1 -C "$scratch_dir" -xzvf  "$scratch_file"
install "$scratch_dir/tailscale" /usr/local/bin/tailscale
install "$scratch_dir/tailscaled" /usr/local/sbin/tailscaled
install "$script_dir/tailscaled-entrypoint.sh" /usr/local/sbin/tailscaled-entrypoint

mkdir -p /var/lib/tailscale /var/run/tailscale

if ! command -v iptables >& /dev/null; then
  if command -v apt-get >& /dev/null; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends iptables
    rm -rf /var/lib/apt/lists/*
  else
    echo "WARNING: iptables not installed. tailscaled might fail."
  fi
fi
