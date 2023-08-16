#!/bin/bash

# Associate SD Card UUID's with Mount Points
#  'disk' will be mounted at /mnt/sdcards/$key
declare -r -A disk=(
  ["chad/cd1"]="0119-B4DD"
  ["chad/cd2"]="04D5-EF09"
  ["chad/cd3"]="0E48-E749"
  ["chad/cd4"]="01E1-76E2"
  ["chad/cd5"]="0748-BDE0"
  ["chad/cd6"]="013F-C56C"
  ["chad/cd7"]="01DD-CB96"
  ["chad/cd8"]="9016-4EF8"
  ["chad/cd9"]="56B8-5A32"
  ["pete/pd1"]="abcd-1234"
  ["pete/pd2"]="efgh-5678"
  ["dan/dd1"]="ijkl-1234"
  ["dan/dd2"]="mnop-5678"
)

RED='\033[0;31m'
NC='\033[0m' # No Color

# Create a String of Known Device UUIDs we can use later for comparison to any new detected devices
knownd=""
for key in ${!disk[@]}; do
  knownd+="${disk[${key}]} "
done

# Get a list of devices
devices=$(blkid)
readarray -t y <<<"$devices"

# Find usb/dev/s* devices
for key in "${!y[@]}" 
do
  device=${y[$key]}
  #prefix="/dev/s"
  if [[ "$device" =~ ^"/dev/s" ]]; then
      dev=$( echo "$device" |cut -d':' -f1 )
      uuid=$(lsblk -n -o UUID $dev)
      if ! [[ "$knownd" == *"$uuid"* ]]; then
        printf "${RED}$uuid${NC} is a NEW device at ${RED}$dev${NC} "
        read -p "Press ENTER to Ignore, CTRL+C to Stop so you can add to config. Mount with 'mount UUID=$uuid /mnt/sdcards/tmp'"
      fi
  fi
done

# Mount / Check Mount of all Known Devices

for key in ${!disk[@]}; do
  if ls /dev/disk/by-uuid/${disk[${key}]} 1> /dev/null 2> /dev/null
  then
    echo /dev/disk/by-uuid/${disk[${key}]} Is Attached
    if findmnt /mnt/sdcards/${key} > /dev/null
    then
      echo "   and mounted at /mnt/sdcards/${key}"
    else
      echo "   and NOT mounted. Attempting to Mount.../mnt/sdcards/${key}"
      mount UUID=${disk[${key}]} /mnt/sdcards/${key}
    fi
  fi
done

# Do the rsync and copy all the files
rsync -nthavmL --info=progress2 --no-i-r  --include="*/" --include="*.MP4" --include="*.JPG" --exclude="*" sdcards/* /mnt/FlashStor/Import/
read -p "Press Enter to Start Copy if all looks good"
time rsync -thavmL --info=progress2 --no-i-r  --include="*/" --include="*.MP4" --include="*.JPG" --exclude="*" sdcards/* /mnt/FlashStor/Import/

chown -R Chad:users /mnt/FlashStor/*
chmod -R 755 /mnt/FlashStor/*

read -p "Copy Complete. Press Enter to Eject"

#Unmount the mounted disk
for key in ${!disk[@]}; do
  if findmnt /mnt/sdcards/$key > /dev/null
  then
    echo "Disk /mnt/sdcards/$key is Mounted. Attempting to Eject..."
    eject /mnt/sdcards/$key
  fi
done

echo "Disk have been ejected, please remove them from the system"


