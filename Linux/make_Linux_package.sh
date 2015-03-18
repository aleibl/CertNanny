#!/bin/bash

echo "Creating package..."
#arch=$(uname -p)
#ts=$(date +'%Y%m%d%H%M%S')
version=$(head -n 1 VERSION)
sed "s/VERSIONINFO/$version/" < Linux/certnanny.spec.in > Linux/certnanny.spec
#tar --transform "s/^\./certnanny-$version/" --exclude '.git' -czf $HOME/rpmbuild/SOURCES/certnanny-$version.tar.gz .
mkdir certnanny-$version
tar --exclude '.git' --exclude certnanny-$version -cf - . | (cd certnanny-$version; tar xf -)
tar -czf $HOME/rpmbuild/SOURCES/certnanny-$version.tar.gz certnanny-$version
rm -rf certnanny-$version
rpmbuild -bb Linux/certnanny.spec

