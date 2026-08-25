# relay-dist

Release binaries for [Relay](https://relay.glass). This repository holds no
source code: it exists so that the archives the installer downloads are
publicly readable, while the source repository stays private.

`relay.glass/dl` rewrites onto the releases here, so

    https://relay.glass/dl/v0.3.17/relay_v0.3.17_linux_amd64.tar.gz

and

    https://github.com/luthor007/relay-dist/releases/download/v0.3.17/relay_v0.3.17_linux_amd64.tar.gz

are the same bytes. Use whichever you prefer; the first is the one the
installer uses.

## What each release contains

Four archives, one per platform, each holding the `relay` and `relayd`
binaries:

    relay_<version>_darwin_amd64.tar.gz
    relay_<version>_darwin_arm64.tar.gz
    relay_<version>_linux_amd64.tar.gz
    relay_<version>_linux_arm64.tar.gz

and `checksums.txt`, the SHA-256 of all four.

## Verifying a download

The installer does this for you and refuses to install a binary it could not
verify. By hand:

    curl -fsSLO https://relay.glass/dl/v0.3.17/relay_v0.3.17_linux_amd64.tar.gz
    curl -fsSL  https://relay.glass/dl/v0.3.17/checksums.txt | sha256sum --check --ignore-missing

## Installing

Don't download by hand unless you want to. On macOS or Linux:

    curl -fsSL https://relay.glass/install | sh

On Windows, in PowerShell:

    irm https://relay.glass/install.ps1 | iex
