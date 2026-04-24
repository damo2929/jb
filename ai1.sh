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

# 3. Alignment and Sizing Logic
# 1 MiB = 2048 sectors (for 512B logical sectors)
ALIGN_SECTORS=2048 

# Determine partitions per source
parts_per_drive=$(( num_targets / num_sources + (num_targets % num_sources > 0) ))

echo "Found $num_targets targets and $num_sources sources."
echo "Creating $parts_per_drive partitions per source drive with 1MiB alignment."

target_idx=0
match_lines=()

for d in "${source_drives[@]}"; do
    echo "------------------------------------------------"
    echo "Processing /dev/$d..."
    /usr/sbin/parted -s "/dev/$d" mklabel gpt

    # Get total sectors and calculate usable area
    total_sectors=$(blockdev --getsz "/dev/$d")
    # Start the first partition at 1MiB (2048s) and leave 1MiB at the end for GPT backup
    usable_sectors=$(( total_sectors - (ALIGN_SECTORS * 2) ))
    
    # Calculate partition size: (usable / parts) rounded down to nearest 1MiB
    raw_part_size=$(( usable_sectors / parts_per_drive ))
    partition_size=$(( (raw_part_size / ALIGN_SECTORS) * ALIGN_SECTORS ))

    for ((p=1; p<=parts_per_drive; p++)); do
        if [ "$target_idx" -lt "$num_targets" ]; then
            # Start each partition at a 1MiB boundary. 
            # The gap between end of P1 and start of P2 will be exactly 2048 sectors (1MiB).
            start=$(( ALIGN_SECTORS + ((p - 1) * (partition_size + ALIGN_SECTORS)) ))
            end=$(( start + partition_size - 1 ))

            echo "  Creating Partition $p: Start ${start}s, End ${end}s"
            /usr/sbin/parted -s -a optimal "/dev/$d" unit s mkpart primary "${start}" "${end}"

            # Handle device naming (nvme0n1p1 vs sda1)
            source_dev=$([[ $d =~ [0-9]$ ]] && echo "${d}p${p}" || echo "${d}${p}")
            target_dev="${target_disks[$target_idx]}"
            
            match_lines+=("/usr/bin/pveceph osd create /dev/$target_dev -db_dev /dev/$source_dev --db_dev_size 150G")
            ((target_idx++))
        fi
    done
done

echo "------------------------------------------------"
echo "Refreshing partition tables and running OSD creation..."
for d in "${source_drives[@]}"; do
    /usr/sbin/partprobe "/dev/$d"
done

# Wait for device nodes to settle
sleep 2

for line in "${match_lines[@]}"; do
    echo "Executing: $line"
    eval "$line"
done
