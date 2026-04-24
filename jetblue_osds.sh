#!/bin/bash

# 1. Define the vendors
target_disk_vendor="WDC"
source_disk_vendor="TOSHIBA"

# 2. Identify Disks
readarray -t target_disks <<< "$(lsblk -do NAME,VENDOR,MODEL,SERIAL  | grep -i "$target_disk_vendor" | awk '{print $1}')"
readarray -t source_drives <<< "$(lsblk -do NAME,VENDOR,MODEL,SERIAL  | grep -i "$source_disk_vendor" | awk '{print $1}')"

# 3. Dynamic Calculation
num_targets=${#target_disks[@]}
num_sources=${#source_drives[@]}

if [ "$num_sources" -eq 0 ]; then
    echo "No source drives found."
    exit 1
fi




echo "------------------------------------------------"
echo "Running wipe on all source drives..."
for d in "${target_disks[@]}"; do
    echo "wipefs --all --force /dev/$d"
    wipefs --all --force /dev/$d
done



# Determine partitions per source (rounding up if necessary)
parts_per_drive=$(( num_targets / num_sources + (num_targets % num_sources > 0) ))
percentage_step=$(( (100 + (parts_per_drive / 2)) / parts_per_drive ))

echo "Found $num_targets targets and $num_sources sources."
echo "Creating $parts_per_drive partitions per source drive ($percentage_step% each)."
echo "------------------------------------------------"

target_idx=0
match_lines=()

for d in "${source_drives[@]}"; do
    echo "Processing /dev/$d... and creating partitions"
    /usr/sbin/parted -s "/dev/$d" mklabel gpt

    for ((p=1; p<=parts_per_drive; p++)); do
        if [ "$target_idx" -lt "$num_targets" ]; then
            start=$(( (p - 1) * percentage_step ))
            end=$(( p * percentage_step ))

            /usr/sbin/parted -s "/dev/$d" mkpart primary "${start}%" "${end}%"

            if [[ $d =~ [0-9]$ ]]; then
                source_dev="${d}p${p}"
            else
                source_dev="${d}${p}"
            fi

            target_dev="${target_disks[$target_idx]}"
            match_lines+=("/usr/bin/pveceph osd create /dev/$target_dev -db_dev /dev/$source_dev")

            ((target_idx++))
        fi
    done
done

echo "------------------------------------------------"
echo "Running partprobe on all source drives..."
for d in "${source_drives[@]}"; do
    echo "Running partprobe on /dev/$d"
    /usr/sbin/partprobe "/dev/$d"
done

echo "------------------------------------------------"
echo "Captured matches:"
for line in "${match_lines[@]}"; do
    $line
done
