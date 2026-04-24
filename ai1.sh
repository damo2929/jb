#!/bin/bash

# 1. Define the vendors
target_disk_vendor="WDC"
source_disk_vendor="TOSHIBA"

# 2. Identify Disks
readarray -t target_disks <<< "$(lsblk -do NAME,VENDOR | grep -i "$target_disk_vendor" | awk '{print $1}')"
readarray -t source_drives <<< "$(lsblk -do NAME,VENDOR | grep -i "$source_disk_vendor" | awk '{print $1}')"

num_targets=${#target_disks[@]}
num_sources=${#source_drives[@]}

if [ "$num_sources" -eq 0 ]; then
    echo "No source drives found."
    exit 1
fi

echo "Wiping target disks..."
for d in "${target_disks[@]}"; do
    wipefs --all --force "/dev/$d"
done

# Calculate partition sizing in sectors
# We leave a 2048 sector margin at start/end for GPT headers and alignment
parts_per_drive=$(( num_targets / num_sources + (num_targets % num_sources > 0) ))

target_idx=0
match_lines=()

for d in "${source_drives[@]}"; do
    echo "Processing /dev/$d..."
    /usr/sbin/parted -s "/dev/$d" mklabel gpt
    
    # Get total sectors of the drive
    total_sectors=$(blockdev --getsz "/dev/$d")
    # Reserve space for GPT (2048 at start, 2048 at end)
    usable_sectors=$(( total_sectors - 4096 ))
    # Calculate size per partition, leaving 1 sector gap for each
    partition_size=$(( (usable_sectors - parts_per_drive) / parts_per_drive ))

    for ((p=1; p<=parts_per_drive; p++)); do
        if [ "$target_idx" -lt "$num_targets" ]; then
            # Start at 2048, then add (size + 1 sector gap) for each previous partition
            start=$(( 2048 + ((p - 1) * (partition_size + 1)) ))
            end=$(( start + partition_size ))

            /usr/sbin/parted -s "/dev/$d" mkpart primary "${start}s" "${end}s"

            # Handle NVMe/MMC naming (p1) vs SATA (1)
            source_dev=$([[ $d =~ [0-9]$ ]] && echo "${d}p${p}" || echo "${d}${p}")
            
            target_dev="${target_disks[$target_idx]}"
            match_lines+=("/usr/bin/pveceph osd create /dev/$target_dev -db_dev /dev/$source_dev")

            ((target_idx++))
        fi
    done
done

echo "Refreshing partition tables..."
for d in "${source_drives[@]}"; do
    /usr/sbin/partprobe "/dev/$d"
done

sleep 2 # Short wait for kernel to register new device nodes

echo "Executing OSD creation..."
for line in "${match_lines[@]}"; do
    eval "$line"
done
