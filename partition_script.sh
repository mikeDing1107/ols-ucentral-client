#!/bin/sh

# PKI 2.0: This script provisions BIRTH certificates to the device partition.
# Birth certificates (cas.pem, cert.pem, key.pem) are used for initial EST enrollment.
# Operational certificates (operational.pem, operational.ca) are generated at runtime
# via EST protocol and stored in /etc/ucentral/ by the ucentral-client daemon.

REQUIRED_CERT_FILES="cas.pem cert.pem key.pem"
PART_LABEL="ONIE-TIP-CA-CERT"

get_partition_prefix()
{
    case "$1" in
        mmcblk*|nvme*) echo "p" ;;
        *) echo "" ;;
    esac
}

partition_replace_certs()
{
    local certs_rootdir=${2}

    tmp_dir=$(mktemp -d)
    mount /dev/$1 ${tmp_dir} 2>&1 >/dev/null
    if [ $? -ne 0 ] ; then
        echo "Failed to create/mount partition"
        exit 2
    fi

    rm -rf ${tmp_dir}/lost+found 2>&1 >/dev/null

    for x in $REQUIRED_CERT_FILES ; do
        echo "Copying cert file ${certs_rootdir}/$x to partition..."
        cp ${certs_rootdir}/$x ${tmp_dir}
        if [ $? -ne 0 ] ; then
            echo "Failed to copy ${certs_rootdir}/$x to partition..."
            umount /dev/$1
            exit 3
        fi
    done

    echo "MD5SUM after replace:"
    md5sum ${tmp_dir}/*
    sync

    echo && echo "### Certificates has been copied successfully!" && echo
    sync &&
    umount ${tmp_dir} 2>&1 >/dev/null
    rm -rf ${tmp_dir} 2>&1 >/dev/null
}

get_first_free_partition()
{
    local prefix=$(get_partition_prefix "$dev_name")

    for x in $(seq 1 10) ; do
        (ls /dev/${dev_name}${prefix}${x} 2>&1 >/dev/null) || break
    done
    return ${x}
}

partition_create()
{
    get_first_free_partition 2>&1 >/dev/null
    local part_idx=$?
    local dev_name=${1}
    local part_offs_start=${2}
    local part_offs_end=${3}
    local part_guid=${4}
    local part_name=${5}
    local prefix=$(get_partition_prefix "$dev_name")

    echo "Trying to create part idx ${part_idx}"

    if ! sgdisk -a 1 -n ${part_idx}:${part_offs_start}:${part_offs_end} \
           -t ${part_idx}:${part_guid} \
           -c ${part_idx}:${part_name} \
           /dev/${dev_name} 2>&1 >/dev/null ; then
        echo "sgdisk failed to create partition"
        exit 1
    fi

    partprobe || true
    sync

    if ! mkfs.ext4 -F -L ${part_name} /dev/${dev_name}${prefix}${part_idx} ; then
        echo "mkfs.ext4 failed"
        exit 1
    fi

    partprobe || true
    sync

    echo "Partition layout:"
    sgdisk -p /dev/${dev_name} | grep ${part_name} || true
    echo && echo "### Partition ${part_name} has been created at /dev/${dev_name}${prefix}${part_idx}" && echo

    partition_replace_certs "${dev_name}${prefix}${part_idx}" "${6}"
}

check_cert_file_exists()
{
    if [ ! -e "$1" ] ; then
        echo "File <$1> does not exists, or provided root directory is invalid"
        exit 1
    fi
}

if [ ! -d "$1" ] ; then
    echo "Root directory <$1> does not exists, or it's not a directory."
    echo "Please specify a valid folder that holds device certificates to be installed."
    exit 1
fi

for x in $REQUIRED_CERT_FILES ; do
    echo "Checking if $1/$x exists..."
    check_cert_file_exists "$1/$x"
done

# Auto-detect root disk (Marvell mmcblk0, NVMe, SATA/virtio)
root_part=$(findmnt -n -o SOURCE /host 2>/dev/null || \
            findmnt -n -o SOURCE / 2>/dev/null || \
            awk '$2=="/"{print $1}' /proc/mounts 2>/dev/null)
dev_name=$(echo "$root_part" | sed -E \
    -e 's|^/dev/||' \
    -e 's/^(mmcblk[0-9]+)p[0-9]+$/\1/' \
    -e 's/^([sh]d[a-z])[0-9]+$/\1/' \
    -e 's/^(nvme[0-9]+n[0-9]+)p[0-9]+$/\1/')
# ONIE rootfs is often reported as none/rootfs/overlay; validate a real block device
if [ -z "$dev_name" ] || [ ! -b "/dev/$dev_name" ]; then
    if [ -b "/dev/mmcblk0" ]; then
        dev_name="mmcblk0"
    elif [ -b "/dev/sda" ]; then
        dev_name="sda"
    else
        echo "ERROR: Cannot find target disk device (tried /dev/mmcblk0 and /dev/sda)"
        exit 1
    fi
fi

prefix=$(get_partition_prefix "$dev_name")

echo "Partition table before changes:"
sgdisk -p /dev/${dev_name}

sgdisk -p /dev/${dev_name} | grep "${PART_LABEL}" 2>&1 >/dev/null
if [ $? -ne 0 ] ; then
    echo "No <${PART_LABEL}> part found, creating..."
    partition_create $dev_name 34 2047 8300 "${PART_LABEL}" $1
    if [ $? -ne 0 ] ; then
        echo "Partition create failed"
        exit 1
    fi
else
    echo "Partition '${PART_LABEL}' already exists... not creating"
    echo "Trying to replace certificate on existing partition with new ones..."
    cert_part_idx=$(sgdisk -p /dev/${dev_name} | grep "${PART_LABEL}" | tail -1 | awk '{print $1}')
    echo "Cert partition is ${dev_name}${prefix}${cert_part_idx}"
    partition_replace_certs "${dev_name}${prefix}${cert_part_idx}" $1
fi
echo
echo "### Partition table after changes:"
sgdisk -p /dev/${dev_name}
exit 0
