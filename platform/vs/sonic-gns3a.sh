#!/bin/bash

# This script creates a .gns3a TertoOS appliance file
IMGFILE="sonic-vs.img"
RELEASE="latest"

usage() {
    echo "`basename $0` [ -r <ReleaseNumber> ] -b <TertoOS VS image: sonic-vs.img>"
    echo "e.g.: `basename $0` -r 1.1 -b <store_path>/sonic-vs.img"
    exit 0
}

while getopts "r:b:h" arg; do
  case $arg in
    h)
	usage
	;;
    r)
	RELEASE=$OPTARG
	;;
    b)
	IMGFILE=$OPTARG
	;;
  esac
done

if [ ! -e ${IMGFILE} ]; then
    echo "ERROR: ${IMGFILE} not found"
    exit 2
fi


MD5SUMIMGFILE=`md5sum  ${IMGFILE} | cut -f 1 -d " "`
LENIMGFILE=`stat -c %s ${IMGFILE}`
GNS3APPNAME="TertoOS-${RELEASE}.gns3a"
NAMEIMGFILE=`basename $IMGFILE`

echo "
{
    \"name\": \"TertoOS\",
    \"category\": \"router\",
    \"description\": \"TertoOS Virtual Switch/Router (SONiC-based)\",
    \"vendor_name\": \"Terto Networks\",
    \"vendor_url\": \"https://github.com/terto-networks/\",
    \"product_name\": \"TertoOS\",
    \"product_url\": \"https://github.com/terto-networks/\",
    \"registry_version\": 3,
    \"status\": \"experimental\",
    \"maintainer\": \"Terto Networks\",
    \"maintainer_email\": \"sonicproject@googlegroups.com\",
    \"usage\": \"Supports TertoOS release: ${RELEASE}\",
    \"first_port_name\": \"eth0\",
    \"qemu\": {
        \"adapter_type\": \"e1000\",
        \"adapters\": 10,
        \"ram\": 2048,
        \"hda_disk_interface\": \"virtio\",
        \"arch\": \"x86_64\",
        \"console_type\": \"telnet\",
        \"boot_priority\": \"d\",
        \"kvm\": \"require\"
    },
    \"images\": [
        {
            \"filename\": \"${NAMEIMGFILE}\",
            \"version\": \"${RELEASE}\",
            \"md5sum\": \"${MD5SUMIMGFILE}\",
            \"filesize\": ${LENIMGFILE}
        }
    ],
    \"versions\": [
        {
            \"name\": \"${RELEASE}\",
            \"images\": {
                \"hda_disk_image\": \"${NAMEIMGFILE}\"
            }
        }
    ]
}

" > ${GNS3APPNAME}

