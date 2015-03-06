#!/bin/bash

# Live Ubuntu Backup V2.2, Nov 4th,2009
# Copyright (C) 2009 billbear <billbear@gmail.com>
# Update(C)2014 leehom <clh021@gmail.com>

# This program is free software; you can redistribute it and/or modify it 
# under the terms of the GNU General Public License as published by 
# the Free Software Foundation; either version 2 of the License, 
# or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but 
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY 
# or FITNESS FOR A PARTICULAR PURPOSE. 
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with this program; 
# if not, see <http://www.gnu.org/licenses>.

mypath=$0

VOL_ID(){
	[ "$2" = "" ] && return
	local voluuid=""
	local voltype=""
	for i in `blkid $2`; do
	[ "${i#UUID=\"}" != "$i" ] && voluuid="${i#UUID=\"}" && voluuid="${voluuid%\"}"
	[ "${i#TYPE=\"}" != "$i" ] && voltype="${i#TYPE=\"}" && voltype="${voltype%\"}"
	done
	[ "$1" = "--uuid" ] && echo $voluuid
	[ "$1" = "--type" ] && echo $voltype
}

new_dir(){
	local newdir="$*"
	i=0
	while [ -e $newdir ]; do
	i=`expr $i + 1`
	newdir="$*-$i"
	done
	echo $newdir
}

echoredcn(){
	[ $lang = "cn" ] && echo -e "\033[31m$*\033[0m"
	return 0
}

echoreden(){
	[ $lang = "en" ] && echo -e "\033[31m$*\033[0m"
	return 0
}

echocn(){
	[ $lang = "cn" ] && echo $*
	return 0
}

echoen(){
	[ $lang = "en" ] && echo $*
	return 0
}

packagecheck_b(){
	dpkg -l | grep ^ii | sed 's/[ ][ ]*/ /g' | cut -d " " -f 2 | grep ^lupin-casper$ > /dev/null || { echoreden "Warning: lupin-casper is currently not installed. You can install it by typing:\nsudo apt-get install lupin-casper\nYou may need a working internet connection to do that.\nYou can also continue without installing it, but your backup may not be self-bootable. However, you can still restore your backup from something like a livecd environment.\nHit enter to continue and ctrl-c to quit"; echoredcn "警告: lupin-casper 尚未安装. 你可以用如下命令安装:\nsudo apt-get install lupin-casper\n这需要连上互联网。\n你也可以不安装而继续, 但生成的备份将不能够自行启动。\n不过你仍然可以从一个像 livecd 这样的环境中恢复你的备份。\n按回车不安装而继续, 按 ctrl-c 退出"; read yn; }

	dpkg -l | grep ^ii | sed 's/[ ][ ]*/ /g' | cut -d " " -f 2 | grep ^squashfs-tools$ > /dev/null || { echoreden "squashfs-tools is required to run this program. You can install it by typing:\nsudo apt-get install squashfs-tools\nYou may need a working internet connection to do that."; echoredcn "要运行此程序必须先安装 squashfs-tools。你可以用如下命令安装:\nsudo apt-get install squashfs-tools\n这需要连上互联网。"; exit 1; }
}

packagecheck_r(){
	dpkg -l | grep ^ii | sed 's/[ ][ ]*/ /g' | cut -d " " -f 2 | grep ^parted$ > /dev/null || { echoreden "parted is required to run this program. You can install it by typing:\nsudo apt-get install parted\nYou may need a working internet connection to do that."; echoredcn "要运行此程序必须先安装 parted。你可以用如下命令安装:\nsudo apt-get install parted\n这需要连上互联网。"; exit 1; }
}

rebuildtree(){ # Remounting the linux directories effectively excludes removable media, manually mounted devices, windows partitions, virtual files under /proc, /sys, /dev, the /host contents of a wubi install, etc. If your partition scheme is more complicated than listed below, you must add lines to rebuildtree() and destroytree(), otherwise the backup will be partial.
	mkdir /$1
	mount --bind / /$1
	mount --bind /boot /$1/boot
	mount --bind /home /$1/home
	mount --bind /tmp /$1/tmp
	mount --bind /usr /$1/usr
	mount --bind /var /$1/var
	mount --bind /srv /$1/srv
	mount --bind /opt /$1/opt
	mount --bind /usr/local /$1/usr/local
}

destroytree(){
	umount /$1/usr/local
	umount /$1/opt
	umount /$1/srv
	umount /$1/var
	umount /$1/usr
	umount /$1/tmp
	umount /$1/home
	umount /$1/boot
	umount /$1
	rmdir /$1
}

target_cmd(){
	mount --bind /proc $1/proc
	mount --bind /dev $1/dev
	mount --bind /sys $1/sys
	chroot $*
	umount $1/sys
	umount $1/dev
	umount $1/proc
}

dequotepath(){ # If drag n drop from nautilus into terminal, the additional single quotes should be removed first.
	local tmpath="$*"
	[ "${tmpath#\'}" != "$tmpath" ] && [ "${tmpath%\'}" != "$tmpath" ] && { tmpath="${tmpath#\'}"; tmpath="${tmpath%\'}"; }
	echo "$tmpath"
}

checkbackupdir(){
	[ "${1#/}" = "$1" ] && { echoreden "You must specify the absolute path"; echoredcn "请使用绝对路径"; exit 1; }
	[ -d "$*" ] || { echoreden "$* does not exist, or is not a directory"; echoredcn "$* 不存在, 或并非目录"; exit 1; }
	[ `ls -A "$*" | wc -l` = 0 ] || { echoreden "$* is not empty"; echoredcn "$* 不是空目录"; exit 1; }
}

probe_partitions(){
	for i in /dev/[hs]d[a-z][0-9]*; do
	blkid $i > /dev/null 2>&1 || continue
	parted -s $i print > /dev/null 2>&1 || continue
	part[${#part[*]}]=$i
	oldfstype[${#oldfstype[*]}]=`$VOL_ID --type $i`
	size=`parted -s $i print | grep $i`
	size=${size#*:}
	size=${size#*：}	#全角冒号，台湾 parted 输出用这个 :(
	partinfo[${#partinfo[*]}]="$i `$VOL_ID --type $i` $size"
	done
}

choose_partition(){
	select opt in "${partinfo[@]}"; do
	[ "$opt" = "" ] && continue
	arrno=`expr $REPLY - 1`
	[ $REPLY -gt ${#part[*]} ] && break
	echoreden "You selected ${part[$arrno]}, it currently contains these files/directories:"
	echoredcn "你选择的是 ${part[$arrno]}, 里面现有这些文件/目录:"
	tmpdir=`new_dir /tmp/mnt`
	[ "${oldfstype[$arrno]}" = "swap" ] || { mkdir $tmpdir; mount ${part[$arrno]} $tmpdir; ls -A $tmpdir; umount $tmpdir; rmdir $tmpdir; }
	echoreden "confirm?(y/N)"
	echoredcn "确定?(y/N)"
	read yn
	[ "$yn" != "y" ] && echoreden "Select again" && echoredcn "重新选择" && continue
	partinfo[$arrno]=""
	break
	done

	eval $1=$arrno
	[ $REPLY -gt ${#part[*]} ] && return
	[ $1 = swappart ] && echoreden "${part[$arrno]} will be formatted as swap." && echoredcn "${part[$arrno]} 将被格式化为 swap." && return

	if [ "${oldfstype[$arrno]}" = "ext2" -o "${oldfstype[$arrno]}" = "ext3" -o "${oldfstype[$arrno]}" = "ext4" -o "${oldfstype[$arrno]}" = "reiserfs" -o "${oldfstype[$arrno]}" = "jfs" -o "${oldfstype[$arrno]}" = "xfs" ]; then
	echoreden "Do you want to format this partition?(Y/n)"
	echoredcn "是否格式化此分区?(Y/n)"
	read yn
	[ "$yn" == "n" ] && newfstype[$arrno]="keep" && return
	fi
	# echoreden "Format ${part[$arrno]} as:"
	# echoredcn "格式化 ${part[$arrno]} 为:"

	# select opt in ext2 ext3 ext4 reiserfs jfs xfs; do
	# [ "$opt" = "" ] && continue
	# ls /sbin/mkfs.$opt > /dev/null 2>&1 && break
	# echoreden "mkfs.$opt is not installed."
	# echoredcn "mkfs.$opt 尚未安装。"
	# [ "$opt" = "reiserfs" ] && echoreden "You can install it by typing\nsudo apt-get install reiserfsprogs" && echoredcn "你可以通过如下命令安装\nsudo apt-get install reiserfsprogs"
	# [ "$opt" = "jfs" ] && echoreden "You can install it by typing\nsudo apt-get install jfsutils" && echoredcn "你可以通过如下命令安装\nsudo apt-get install jfsutils"
	# [ "$opt" = "xfs" ] && echoreden "You can install it by typing\nsudo apt-get install xfsprogs" && echoredcn "你可以通过如下命令安装\nsudo apt-get install xfsprogs"
	# echoreden "Please re-select file system type."
	# echoredcn "请重新选择文件系统。"
	# done

	# newfstype[$arrno]=$opt
 	echoredcn "准备格式化此分区为ext3..."
 	newfstype[$arrno]=ext3
}

setup_target_partitions(){
	rootpart=1000
	swappart=1000
	homepart=1000
	bootpart=1000
	tmppart=1000
	usrpart=1000
	varpart=1000
	srvpart=1000
	optpart=1000
	usrlocalpart=1000

	echoreden "Which partition do you want to use as / ?"
	echoredcn "将哪个分区作为 / ?"
	choose_partition rootpart

	[ $lang = "cn" ] && partinfo[${#partinfo[*]}]="无" || partinfo[${#partinfo[*]}]="None"
	[ $lang = "cn" ] && partinfo[${#partinfo[*]}]="无，并结束分区设定。" || partinfo[${#partinfo[*]}]="None and finish setting up partitions"

	echoreden "Which partition do you want to use as swap ?"
	echoredcn "将哪个分区作为 swap ?"
	choose_partition swappart
	[ $arrno -gt ${#part[*]} ] && return

	for i in home boot tmp usr var srv opt; do
	echoreden "Which partition do you want to use as /$i ?"
	echoredcn "将哪个分区作为 /$i ?"
	eval choose_partition ${i}part
	[ $arrno -gt ${#part[*]} ] && return
	done

	echoreden "Which partition do you want to use as /usr/local ?"
	echoredcn "将哪个分区作为 /usr/local ?"
	choose_partition usrlocalpart
}

umount_target_partitions(){
	for i in usrlocalpart swappart homepart bootpart tmppart usrpart varpart srvpart optpart rootpart; do
	eval thispart=\$$i
	[ "${part[$thispart]}" = "" ] && continue
	[ "${newfstype[$thispart]}" = "keep" ] && continue
		while mount | grep "^${part[$thispart]} " > /dev/null; do
		umount ${part[$thispart]} || { echoreden "Failed to umount ${part[$thispart]}"; echoredcn "无法卸载 ${part[$thispart]}"; exit 1; }
		done
	[ $i = swappart ] && continue
	swapon -s | grep "^${part[$thispart]} " > /dev/null && echoreden "swapoff ${part[$thispart]} and try again." && echoredcn "请先 swapoff ${part[$thispart]}" && exit 1
	done
}

format_target_partitions(){
	for i in rootpart homepart bootpart tmppart usrpart varpart srvpart optpart usrlocalpart; do
	eval thispart=\$$i
	[ "${part[$thispart]}" = "" ] && continue
	[ "${newfstype[$thispart]}" = "keep" ] && continue
	echoreden "Formatting ${part[$thispart]}"
	echoredcn "正在格式化 ${part[$thispart]}"
	[ "${newfstype[$thispart]}" = "xfs" ] && formatoptions=fq || formatoptions=q
	mkfs.${newfstype[$thispart]} -$formatoptions ${part[$thispart]} > /dev/null || { echoreden "Failed to format ${part[$thispart]}"; echoredcn "无法格式化 ${part[$thispart]}"; exit 1; }
	disk=`expr substr ${part[$thispart]} 1 8`
	num=${part[$thispart]#$disk}
	sfdisk -c -f $disk $num 83
	done

	[ "${part[$swappart]}" = "" ] && return
	[ "${oldfstype[$swappart]}" = "swap" ] && return
	echoreden "Formatting ${part[$swappart]}"
	echoredcn "正在格式化 ${part[$swappart]}"
	mkfs.ext2 -q ${part[$swappart]} || { echoreden "Failed to format ${part[$swappart]}"; echoredcn "无法格式化 ${part[$swappart]}"; exit 1; }
	mkswap ${part[$swappart]} || { echoreden "Failed to format ${part[$swappart]}"; echoredcn "无法格式化 ${part[$swappart]}"; exit 1; }
	disk=`expr substr ${part[$swappart]} 1 8`
	num=${part[$swappart]#$disk}
	sfdisk -c -f $disk $num 82
}

chkuuids(){
	uuids=""
	for i in /dev/[hs]d[a-z][0-9]*; do
	uuids="$uuids\n`$VOL_ID --uuid $i 2> /dev/null`"
	done
	[ "`echo -e $uuids | sort | uniq -d`" = "" ] && return
	echoreden "duplicate UUIDs detected! The program will now terminate."
	echoredcn "检测到某些分区有重复的 UUID! 程序将终止。"
	exit 1
}

mount_target_partitions(){
	tgt=`new_dir /tmp/target`
	mkdir $tgt
	mount ${part[$rootpart]} $tgt
	[ "${part[$homepart]}" != "" ] && mkdir -p $tgt/home && mount ${part[$homepart]} $tgt/home
	[ "${part[$bootpart]}" != "" ] && mkdir -p $tgt/boot && mount ${part[$bootpart]} $tgt/boot
	[ "${part[$tmppart]}" != "" ] && mkdir -p $tgt/tmp && mount ${part[$tmppart]} $tgt/tmp
	[ "${part[$usrpart]}" != "" ] && mkdir -p $tgt/usr && mount ${part[$usrpart]} $tgt/usr
	[ "${part[$varpart]}" != "" ] && mkdir -p $tgt/var && mount ${part[$varpart]} $tgt/var
	[ "${part[$srvpart]}" != "" ] && mkdir -p $tgt/srv && mount ${part[$srvpart]} $tgt/srv
	[ "${part[$optpart]}" != "" ] && mkdir -p $tgt/opt && mount ${part[$optpart]} $tgt/opt
	[ "${part[$usrlocalpart]}" != "" ] && mkdir -p $tgt/usr/local && mount ${part[$usrlocalpart]} $tgt/usr/local
}

gettargetmount(){ # Generate a list of mounted partitions and mount points of the restore target.
	for i in `mount | grep " $* "`; do
	[ "${i#/dev/}" != "$i" ] && echo $i
	[ "$i" = "$*"  ] && echo "$i/"
	done

	for i in `mount | grep " $*/"`; do
	[ "${i#/}" != "$i" ] && echo $i
	done
}

getdefaultgrubdev(){ # Find the root or boot partition.
	local bootdev=""
	local rootdev=""
	for i in $*; do
	[ "$i" = "$tgt/" ] && rootdev="$j" || j=$i
	[ "$i" = "$tgt/boot" ] && bootdev="$k" || k=$i
	done
	[ "$bootdev" = "" ] && echo $rootdev && return
	echo $bootdev && return 67
}

listgrubdev(){
	for i in /dev/[hs]d[a-z]; do
	echo $i,MBR
	done

	for i in /dev/[hs]d[a-z][0-9]*; do
	blkid $i > /dev/null 2>&1 || continue
	[ "`$VOL_ID --type $i`" = "ntfs" ] && continue
	parted -s $i print > /dev/null 2>&1 || continue
	echo $i,`$VOL_ID --type $i`
	done

	echoen none,not_recommended
	echocn 不安装（不推荐）
}

getmountoptions(){ # According to the default behavior of ubuntu installer. You can alter these or add options for other fs types.
	case "$*" in
	"/ ext4" ) echo relatime,errors=remount-ro;;
	"/ ext3" ) echo relatime,errors=remount-ro;;
	"/ ext2" ) echo relatime,errors=remount-ro;;
	"/ reiserfs" ) [ "$hasboot" = "yes" ] && echo relatime || echo notail,relatime;;
	"/ jfs" ) echo relatime,errors=remount-ro;;

	"/boot reiserfs" ) echo notail,relatime;;

	*"ntfs" ) echo defaults,umask=007,gid=46;;
	*"vfat" ) echo utf8,umask=007,gid=46;;
	*) echo relatime;;
	esac
}

generate_fstab(){
	local targetfstab="$*/etc/fstab"

	echo "# /etc/fstab: static file system information." > "$targetfstab"
	echo "#" >> "$targetfstab"
	echo "# <file system> <mount point>   <type>  <options>       <dump>  <pass>" >> "$targetfstab"
	echo "proc            /proc           proc    defaults        0       0" >> "$targetfstab"

	for i in $tgtmnt; do
	[ "${i#/dev/}" != "$i" ] && { echo "# $i" >> "$targetfstab"; j=$i; continue; }
	uuid="`$VOL_ID --uuid $j`"
	[ "$uuid" = "" ] && partition=$j || partition="UUID=$uuid"
	mntpnt=${i#$tgt}
	fs=`$VOL_ID --type $j`
	fsckorder=`echo "${i#$tgt/} s" | wc -w`
	echo "$partition $mntpnt $fs `getmountoptions "$mntpnt $fs"` 0 $fsckorder" >> "$targetfstab"
	done

	for i in /dev/[hs]d[a-z][0-9]*; do
	[ "`$VOL_ID --type $i 2> /dev/null`" = swap ] || continue
	echo "# $i" >> "$targetfstab"
	swapuuid="`$VOL_ID --uuid $i`"
	[ "$swapuuid" = "" ] && partition=$i || partition="UUID=$swapuuid"
	echo "$partition none swap sw 0 0" >> "$targetfstab"
	haswap="yes"
	[ -f $tgt/etc/initramfs-tools/conf.d/resume ] || { echo "RESUME=$partition" > $tgt/etc/initramfs-tools/conf.d/resume; continue; }
	lastresume="`cat $tgt/etc/initramfs-tools/conf.d/resume`"
	lastresume="${lastresume#RESUME=}"
	[ "${lastresume#UUID=}" != "$lastresume" ] && lastresume="`parted /dev/disk/by-uuid/${lastresume#UUID=} unit B print | grep /dev/`"
	[ "${lastresume#/dev/}" != "$lastresume" ] && lastresume="`parted $lastresume unit B print | grep /dev/`"
	lastresume=${lastresume#*:}
	lastresume=${lastresume#*：}	#有可能是全角冒号
	lastresume=${lastresume%B}
	thisresume="`parted $i unit B print | grep $i`"
	thisresume=${thisresume#*:}
	thisresume=${thisresume#*：}	#有可能是全角冒号
	thisresume=${thisresume%B}
	[ "$thisresume" -gt "$lastresume" ] && echo "RESUME=$partition" > $tgt/etc/initramfs-tools/conf.d/resume
	done

	echo "/dev/scd0 /media/cdrom0 udf,iso9660 user,noauto,exec,utf8 0 0" >> "$targetfstab"
}

makelostandfound(){ # If lost+found is removed from an ext? FS, create it with the command mklost+found. Don't just mkdir lost+found
	for i in $tgtmnt; do
	[ "${i#/dev/}" != "$i" ] && j=$i
	[ "${i#$tgt}" != "$i" ] &&  $VOL_ID --type $j | grep ext > /dev/null && cd $i && mklost+found 2> /dev/null
	done
}

makeswapfile(){
	echoreden "You do not have a swap partition. Would you like a swap file? Default is yes.(Y/n)"
	echoredcn "你没有 swap 分区。是否做一个 swap 文件? 默认的回答为是。(Y/n)"
	read yn
	[ "$yn" = "n" ] && return
	echoreden "The size of the swap file in megabytes, defaults to 512"
	echoredcn "做一个多少兆的 swap 文件? 默认值为 512"
	read swapsize
	swapsize=`expr $swapsize + 0 2> /dev/null`
	[ "$swapsize" = "" ] && swapsize=512
	[ "$swapsize" = "0" ] && swapsize=512
	local sf=`new_dir $*/swapfile`
	echoreden "Generating swap file..."
	echoredcn "正在创建 swap 文件..."
	dd if=/dev/zero of=$sf bs=1M count=$swapsize
	mkswap $sf
	echo "${sf#$*}  none  swap  sw  0 0" >> "$*/etc/fstab"
}

sqshboot_menulst(){ # Generate a windows-notepad-compatible menu.lst in the backup directory with instructions to boot backup.squashfs directly.
	[ $lang = "cn" ] && echo -e "# 这个 menu.lst 是给 grub4dos 用的。稍作修改才能用于 gnu grub\r
\r
\r
# 解压下载的 http://download.gna.org/grub4dos, 并拷贝其中的 grldr 和 grldr.mbr 到 c: 盘根目录\r
# 把这个 menu.lst 也拷贝到 c: 盘根目录\r
# 然后拷贝备份文件夹在任意 fat ntfs ext 分区(任意盘)根目录重命名为 \"casper\"\r
# 接着添加下面这行文字到 boot.ini 末尾 (不包含#号)重启进入 grub4dos 即可\r
# c:\grldr.mbr=\"grub4dos\"\r
# 
# 建议直接使用老毛桃PE，导出iso修改其中的/ILMT/GRUB/RUN.LST\r
#（做好的老毛桃PE也可以挂载直接修改U盘的，我是这么做的）\r
# 末尾加入如下菜单也可很方便的运用\r
# title Live Backup\r
# find --set-root /casper/vmlinuz\r
# kernel /casper/vmlinuz boot=casper ro ignore_uuid\r
# initrd /casper/initrd.img\r
\r
# 更多菜单列表可参考我的博客备份http://lianghong.sinaapp.com/grub.html\r
如果你使用下面这种菜单，只需要把备份文件夹拷贝到casper中改为对应的数字(这里是1)即可\r
# title Live Backup 1\r
# find --set-root /casper/1/vmlinuz\r
# kernel /casper/1/vmlinuz boot=casper ro ignore_uuid\r
# initrd /casper/1/initrd.img\r
\r
\r
\r
\r
#在 linux 机器上直接启动你的 $today.squashfs:\r
# 把menu.lst拷贝到启动分区根目录即可启动\r
\r
另一种ISO方式\r
拷贝$today.squashfs到要进行安装的ISO文件中替代其中的squashfs文件，到C盘iso目录重命名为ubuntu.iso即可。\r
启动iso后，先 sudo  umount -a  取消已挂载好的分区，再按桌面的安装程序进行安装。 \r
sudo umount -l /isodevice 命令在安装的时候或许可以帮你大忙\r
\r
\r
default	0\r
timeout 1\r
\r
title Live Ubuntu Backup $today\r
find --set-root /casper/vmlinuz-`uname -r`\r
kernel /casper/vmlinuz-`uname -r` boot=casper ro ignore_uuid\r
initrd /casper/initrd.img-`uname -r`\r
\r
title Boot in Ubuntu.iso\r
find --set-root /iso/vmlinuz\r
kernel /iso/vmlinuz boot=casper iso-scan/filename=/ubuntu.iso ro quiet locale=zh_CN.UTF-8\r
initrd /iso/initrd.lz \r
\r
\r
# 如何在 linux 机器上直接启动你的 backup$today.squashfs:\r
# 在任意 fat ntfs ext 分区根目录建立一个 \"casper\" 文件夹并拷贝 backup$today.squashfs, initrd.img-`uname -r`, vmlinuz-`uname -r` 到它里面(注意 gnu grub 不能读取 NTFS, 因此不能把 initrd.img-`uname -r`, vmlinuz-`uname -r` 放在那里，不过依然可以把 squashfs 放在那里)\r
# 然后拷贝下面的两个 Live Ubuntu Backup 启动项到 /boot/grub/menu.lst 末尾并把 \"find --set-root\" 行改为 \"root (hd?,?)\" (你创建 \"casper\" 文件夹的那个分区)\r" || echo -e "# This menu.lst is for grub4dos only. You must edit it to use with gnu grub\r
\r
\r
# Instructions to boot your backup$today.squashfs directly on a windows PC:\r
# Download the latest grub4dos from http://download.gna.org/grub4dos\r
# Unzip grub4dos, then copy grldr and grldr.mbr to the root of your c: drive\r
# Also copy this menu.lst to the root of your c: drive\r
# Then make a directory \"casper\" under the root of any fat, ntfs, or ext partition and copy backup$today.squashfs, initrd.img-`uname -r`, vmlinuz-`uname -r` to the directory\r
# Then add this line to boot.ini (without #)\r
# c:\grldr.mbr=\"grub4dos\"\r
##### On Windows Vista, you can still create a boot.ini yourself with these lines:\r
##### [boot loader]\r
##### [operating systems]\r
##### c:\grldr.mbr=\"grub4dos\"\r
# Reboot and select grub4dos\r
\r
\r
# Instructions to boot your backup$today.squashfs directly on a linux PC:\r
# Make a directory \"casper\" under the root of any fat, ntfs, or ext partition and copy backup$today.squashfs, initrd.img-`uname -r`, vmlinuz-`uname -r` to the directory. (Note that NTFS is not readable by gnu grub so don't put initrd.img-`uname -r` & vmlinuz-`uname -r`  there)\r
# Then copy the Live Ubuntu Backup entries below to the end of your /boot/grub/menu.lst file and change the \"find --set-root\" line to \"root (hd?,?)\" (where you created the directory \"casper\")\r"

echo -e "\r
\r
default	0\r
timeout 10\r
\r
title Live Ubuntu Backup $today\r
find --set-root /casper/vmlinuz-`uname -r`\r
kernel /casper/vmlinuz-`uname -r` boot=casper ro ignore_uuid\r
initrd /casper/initrd.img-`uname -r`\r
\r
title Live Ubuntu Backup $today, Recovery Mode\r
find --set-root /casper/vmlinuz-`uname -r`\r
kernel /casper/vmlinuz-`uname -r` boot=casper ro single ignore_uuid\r
initrd /casper/initrd.img-`uname -r`\r"
}

windowsentry(){
	for i in /dev/[hs]d[a-z][0-9]*; do
	volid="`$VOL_ID --type $i 2> /dev/null`"
	[ "$volid" != ntfs -a "$volid" != vfat ] && continue
	tmpdir=`new_dir /tmp/mnt`
	mkdir $tmpdir
	mount $i $tmpdir || { rmdir $tmpdir; continue; }
	disk=`expr substr $i 1 8`
	num=${i#$disk}
	num=`expr $num - 1`
	[ -f $tmpdir/bootmgr -o -f $tmpdir/ntldr ] && { echo >> $tgt/boot/grub/menu.lst; echo "# This entry may not be correct when you have multiple hard disks" >> $tgt/boot/grub/menu.lst; echo "title windows" >> $tgt/boot/grub/menu.lst; echo "rootnoverify (hd0,$num)" >> $tgt/boot/grub/menu.lst; echo "chainloader +1" >> $tgt/boot/grub/menu.lst; }
	umount $i
	rmdir $tmpdir
	done
}

grub1(){
	grub-install --root-directory="$tgt" $grubdev
	grub-install --root-directory="$tgt" $grubdev
	# grub-install (onto reiserfs) sometimes fails for unknown reason. Installing it twice succeeds most of the time.
	target_cmd "$tgt" update-grub -y
	sed -i "s/^hiddenmenu/#hiddenmenu/" $tgt/boot/grub/menu.lst
	windowsentry
}

grub2(){
	target_cmd "$tgt" grub-install $grubdev
	target_cmd "$tgt" grub-install $grubdev
	# grub-install onto reiserfs still buggy in grub2. Installing it twice fixs problems.
	target_cmd "$tgt" update-grub
}

cleartgtmnt(){
	[ "${part[$usrlocalpart]}" != "" ] && umount ${part[$usrlocalpart]}
	[ "${part[$homepart]}" != "" ] && umount ${part[$homepart]}
	[ "${part[$bootpart]}" != "" ] && umount ${part[$bootpart]}
	[ "${part[$tmppart]}" != "" ] && umount ${part[$tmppart]}
	[ "${part[$usrpart]}" != "" ] && umount ${part[$usrpart]}
	[ "${part[$varpart]}" != "" ] && umount ${part[$varpart]}
	[ "${part[$srvpart]}" != "" ] && umount ${part[$srvpart]}
	[ "${part[$optpart]}" != "" ] && umount ${part[$optpart]}
	umount ${part[$rootpart]} || { echoreden "Please umount $tgt yourself"; echoredcn "请自行卸载 $tgt"; }
}

dobackup(){
	bindingdir=`new_dir /tmp/bind`
	backupdir=`new_dir /home/remastersys/$today`
	bindingdir="${bindingdir#/}"
	backupdir="${backupdir#/}"
	packagecheck_b
	packagecheck_r
	echoreden "You are about to backup your system. It is recommended that you quit all open applications now."
	echoredcn "将要备份系统。建议退出其他程序。"
	# echoreden "You are about to backup your system. It is recommended that you quit all open applications now. Continue?(y/n)"
	# echoredcn "将要备份系统。建议退出其他程序。继续?(y/n)"
	read yn
	# [ "$yn" != "y" ] && exit 1
	echoreden "Specify an empty directory(absolute path) to save the backup. You can drag directory from Nautilus File Manager and drop it here. Feel free to use external media.
If you don't specify, the backup will be saved to /$backupdir"
	echoredcn "指定一个空目录 (绝对路径) 来存放备份。\n可以从 Nautilus 文件管理器拖放目录至此。\n可以使用移动硬盘。\n如果不指定, 将会存放到 /$backupdir"
	read userdefined_backupdir
	[ "$userdefined_backupdir" != "" ] && { userdefined_backupdir="`dequotepath "$userdefined_backupdir"`"; checkbackupdir "$userdefined_backupdir"; backupdir="${userdefined_backupdir#/}"; }

	exclude=`new_dir /tmp/exclude`
 	echo $backupdir > $exclude
 	echo $bindingdir >> $exclude
 	echo home/remastersys/ >> $exclude
	echo boot/grub >> $exclude
	echo etc/fstab >> $exclude
	echo etc/mtab >> $exclude
	echo etc/blkid.tab >> $exclude
	echo etc/udev/rules.d/70-persistent-net.rules >> $exclude
	echo lost+found >> $exclude
	echo boot/lost+found >> $exclude
	echo home/lost+found >> $exclude
	echo tmp/lost+found >> $exclude
	echo usr/lost+found >> $exclude
	echo var/lost+found >> $exclude
	echo srv/lost+found >> $exclude
	echo opt/lost+found >> $exclude
	echo usr/local/lost+found >> $exclude

	for i in `swapon -s | grep file | cut -d " " -f 1`; do
	echo "${i#/}" >> $exclude
	done

	for i in `ls /tmp -A`; do
	echo "tmp/$i" >> $exclude
	done

	echoreden "Do you want to exclude all user files in /home? (y/N)"
	echoredcn "是否排除 /home 里所有的用户文件? (y/N)"
	read yn
	if [ "$yn" = y ]; then
	for i in /home/*; do
	[ -f "$i" ] && echo "${i#/}" >> $exclude
	[ -d "$i" ] || continue
		for j in "$i"/*; do
		[ -e "$j" ] && echo "${j#/}" >> $exclude
		done
	done
	fi

	echoreden "Do you want to exclude all user configurations (hidden files) in /home as well? (y/N)"
	echoredcn "是否也排除 /home 里所有的用户配置文件(隐藏文件)? (y/N)"
	read yn
	if [ "$yn" = y ]; then
	for i in /home/*; do
	[ -d "$i" ] || continue
		for j in "$i"/.*; do
		[ "$j" = "$i/." ] && continue
		[ "$j" = "$i/.." ] && continue
		echo "${j#/}" >> $exclude
		done
	done
	fi

	echoreden "Do you want to exclude the local repository of retrieved package files in /var/cache/apt/archives/ ? (Y/n)"
	echoredcn "是否排除已下载软件包在 /var/cache/apt/archives/ 里的本地缓存 ? (Y/n)"
	read yn
	if [ "$yn" != n ]; then
	for i in /var/cache/apt/archives/*.deb; do
	[ -e "$i" ] && echo "${i#/}" >> $exclude
	done
	for i in /var/cache/apt/archives/partial/*; do
	[ -e "$i" ] && echo "${i#/}" >> $exclude
	done
	fi

	echoreden "(For advanced users only) Specify other files/folders you want to exclude from the backup, one file/folder per line. You can drag and drop from Nautilus. End with an empty line.\nNote that the program has automatically excluded all removable media, windows partitions, manually mounted devices, files under /proc, /sys, /tmp, the /host contents of a wubi install, etc. So in most cases you can just hit enter now.\nIf you exclude important system files/folders, the backup will fail to restore."
	echoredcn "(高级用户功能)指定其他需要排除的文件/目录, 一行写一个。以空行结束。\n可以从 Nautilus 文件管理器拖放至此。\n注意程序已经自动排除所有移动设备, windows 分区, 手动挂载的所有设备, /proc, /sys, /tmp 下的文件, wubi 的 /host 内容, 等等。\n所以在绝大多数情况下你只需要直接回车就可以了。\n如果你排除了重要的系统文件/目录, 不要指望你的备份能够工作。"
	read ex
	while [ "$ex" != "" ]; do
	ex=`dequotepath "$ex"`
	[ "${ex#/}" = "$ex" ] && { echoen "You must specify the absolute path"; echocn "请使用绝对路径"; read ex; continue; }
	[ -e "$ex" ] || { echoen "$ex does not exist"; echocn "$ex 并不存在"; read ex; continue; }
	ex="${ex#/}"
	echo $ex >> $exclude
	read ex
	done

	rebuildtree $bindingdir

	for i in /$bindingdir/media/*; do
	ls -ld "$i" | grep "^drwx------ " > /dev/null || continue
	[ `ls -A "$i" | wc -l` = 0 ] || continue
	echo "${i#/$bindingdir/}" >> $exclude
	done

	echoreden "Start to backup?(Y/n)"
	echoredcn "开始备份?(Y/n)"
	read yn
	[ "$yn" == "n" ] && { destroytree $bindingdir; rm $exclude; exit 1; }
	stime=`date +%F_%T`
	mkdir -p "/$backupdir"
	mksquashfs /$bindingdir "/$backupdir/$today.squashfs" -ef $exclude
	destroytree $bindingdir
	rm $exclude
	cp /boot/initrd.img-`uname -r` "/$backupdir"
	cp /boot/vmlinuz-`uname -r` "/$backupdir"
 	cp /boot/initrd.img-`uname -r` "/$backupdir/initrd.img"
 	cp /boot/vmlinuz-`uname -r` "/$backupdir/vmlinuz"
	sqshboot_menulst > "/$backupdir/menu.lst"
 	uname -a > "/$backupdir/$today.txt"
 	lsb_release -a >> "/$backupdir/$today.txt"
	thisuser=`basename ~`
	chown -R $thisuser:$thisuser "/$backupdir" 2> /dev/null
	chmod -R 555 "/$backupdir" 2> /dev/null
	echoreden "Your backup is ready in /$backupdir. Please read the menu.lst inside :)"
	echoreden " started at: $stime\nfinished at: `date +%F_%T`"
	echoredcn "已备份至 /$backupdir。请阅读里面的 menu.lst  ^_^ 哈！"
	echoredcn "开始于: $stime\n结束于: `date +%F_%T` \n搞定啦！ ^_^ 哈！"
	tput bel
}

dorestore(){
	sqshmnt="/rofs"
	tgtmnt=""
	haswap="no"
	hasboot="no"

	declare -a part oldfstype newfstype partinfo
	packagecheck_r
	# echoreden "This will restore your backup. Continue? (y/n)"
	# echoredcn "将恢复你的备份。继续? (y/n)"
	# read yn
	# [ "$yn" != "y" ] && exit 1

	echoreden "Specify the squashfs backup file (absolute path). You can drag the file from Nautilus File Manager and drop it here. If you are booting from the backup squashfs, you can just hit enter, and the squashfs you are booting from will be used."
	echoredcn "指定 squashfs 备份文件 (绝对路径)。可以从 Nautilus 文件管理器拖放。\n从备份的 squashfs 启动的,直接回车即可,将使用本次启动的 squashfs 文件。"
	read backupfile
	[ "$backupfile" = "" ] && { ls /rofs > /dev/null 2>&1 || { echoreden "/rofs not found"; echoredcn "/rofs 没看到。"; exit 1; } }
	[ "$backupfile" != "" ] && { backupfile="`dequotepath "$backupfile"`"; sqshmnt=`new_dir /tmp/sqsh`; mkdir $sqshmnt; mount -o loop "$backupfile" $sqshmnt 2> /dev/null || { echoreden "$backupfile mount error"; echoredcn "$backupfile 挂载不上"; rmdir $sqshmnt; exit 1; } }

	probe_partitions
	setup_target_partitions
	# echoreden "Start to format partitions (if any). Continue? (y/N)"
	# echoredcn "开始格式化分区 (如果有需要格式化的分区的话)。继续? (y/N)"
	# read yn
	echo "处理您选择的格式化分区...."
	yn="y"
	[ "$yn" != "y" ] && [ "$sqshmnt" != "/rofs" ] && { umount $sqshmnt; rmdir $sqshmnt; }
	[ "$yn" != "y" ] && exit 1
	umount_target_partitions
	format_target_partitions
	chkuuids
	mount_target_partitions

	echoreden "If you have other partitions for the target system, open another terminal and mount them to appropriate places under $tgt. Then press return."
	echoredcn "如果你为目标系统安排了其他分区, 现在打开另一个终端并挂载它们在 $tgt 下合适的地方。完成后回车。"
	read yn

	tgtmnt=`gettargetmount $tgt`
	defaultgrubdev=`getdefaultgrubdev "$tgtmnt"`
	[ $? = 67 ] && hasboot=yes
	echoreden "Specify the place into which you want to install GRUB."
	echoreden "`expr substr $defaultgrubdev 1 8` and $defaultgrubdev are recommended."
	echoredcn "把 GRUB 安装到哪里?"
	echoredcn "建议安装到 `expr substr $defaultgrubdev 1 8` 或 $defaultgrubdev"
	select grubdev in `listgrubdev`; do
	[ "$grubdev" = "" ] && continue
	break
	done
	grubdev=${grubdev%,*}

	echoreden "The restore process will launch. Continue?(Y/n)"
	echoredcn "将马上开始恢复。继续?(Y/n)"
	read yn
	[ "$yn" == "n" ] && [ "$sqshmnt" != "/rofs" ] && { umount $sqshmnt; rmdir $sqshmnt; }
	[ "$yn" == "n" ] && { cleartgtmnt; exit 1; }
	stime=`date +%F_%T`
	cp -av $sqshmnt/* $tgt
	rm -f $tgt/etc/initramfs-tools/conf.d/resume
	touch $tgt/etc/mtab
	generate_fstab "$tgt"
	target_cmd "$tgt" update-initramfs -u

	if [ "${grubdev#/dev/}" != "$grubdev" ]; then
	mv $tgt/boot/grub `new_dir $tgt/boot/grub.old` 2> /dev/null
	grub-install -v | grep 0. > /dev/null && grub1
	grub-install -v | grep 1. > /dev/null && grub2
	fi

	makelostandfound
	tput bel
	echoreden "Restore started at: $stime,\n       finished at: `date +%F_%T`"
	echoredcn "恢复过程开始于: $stime,\n        结束于: `date +%F_%T`"
	[ "$haswap" = "no" ] && makeswapfile $tgt
	[ "$sqshmnt" != "/rofs" ] && { umount $sqshmnt; rmdir $sqshmnt; }

	echoreden "Enter new hostname or leave blank to use the old one."
	echoredcn "输入新的主机名。留空将使用旧的主机名。"
	oldhostname=`cat $tgt/etc/hostname`
	echoreden "old hostname: $oldhostname"
	echoreden "new hostname:"
	echoredcn "旧的主机名: $oldhostname"
	echoredcn "新的主机名:"
	read newhostname
	[ "$newhostname" != "" ] && { echo $newhostname > $tgt/etc/hostname; sed -i "s/\t$oldhostname/\t$newhostname/g" $tgt/etc/hosts; }

	for i in `ls $tgt/home`; do
	[ -d $tgt/home/$i ] || continue
	target_cmd "$tgt" id $i 2> /dev/null | grep "$i" > /dev/null || continue
	echoreden "Do you want to change the name of user $i? (y/n)"
	echoredcn "是否改变用户名 $i? (y/n)"
	read yn
	[ "$yn" != "y" ] && continue
	echoreden "new username:"
	echoredcn "新的用户名:"
	read newname
		while target_cmd "$tgt" id $newname 2> /dev/null | grep "$newname" > /dev/null; do
		echoreden "$newname already exists"
		echoreden "new username:"
		echoredcn "$newname 已存在"
		echoredcn "新的用户名:"
		read newname
		done
	[ -e $tgt/home/$newname ] && mv $tgt/home/$newname `new_dir $tgt/home/$newname`
	target_cmd "$tgt" chfn -f $newname $i
	target_cmd "$tgt" usermod -l $newname -d /home/$newname -m $i
	target_cmd "$tgt" groupmod -n $newname $i
	done

	for i in `ls $tgt/home`; do
	[ -d $tgt/home/$i ] || continue
	target_cmd "$tgt" id $i 2> /dev/null | grep "$i" > /dev/null || continue
	echoreden "Do you want to change the password of user $i? (y/n)"
	echoredcn "是否改变用户 $i 的密码? (y/n)"
	read yn
		while [ "$yn" = "y" ]; do
		target_cmd "$tgt" passwd $i
		echoreden "If the password was not successfully changed, now you have another chance to change it. Do you want to change the password of user $i again? (y/n)"
		echoredcn "如果刚才的密码改变不成功, 你还有机会。是否再次改变用户 $i 的密码? (y/n)"
		read yn
		done
	done

	rm -f $tgt/etc/blkid.tab
	[ "${part[$usrlocalpart]}" != "" ] && umount ${part[$usrlocalpart]}
	[ "${part[$homepart]}" != "" ] && umount ${part[$homepart]}
	[ "${part[$bootpart]}" != "" ] && umount ${part[$bootpart]}
	[ "${part[$tmppart]}" != "" ] && umount ${part[$tmppart]}
	[ "${part[$usrpart]}" != "" ] && umount ${part[$usrpart]}
	[ "${part[$varpart]}" != "" ] && umount ${part[$varpart]}
	[ "${part[$srvpart]}" != "" ] && umount ${part[$srvpart]}
	[ "${part[$optpart]}" != "" ] && umount ${part[$optpart]}
	umount ${part[$rootpart]} || { echoreden "Please umount $tgt yourself"; echoredcn "请自行卸载 $tgt"; }

	echoreden "Done! Enjoy:)"
	echoredcn "搞定啦！ ^_^ 哈！"

	echoen "Be completed automatically restart it?(y/N)"
	echocn "完成后自动重启吗？(y/N)"
	read auto_reboot
	[ "$auto_reboot" == "y" ] && sudo reboot
}

echohelpen(){
	[ $lang = "en" ] && echo "live ubuntu backup $version, copyleft billbear <billbear@gmail.com>

This program can backup your running ubuntu system to a compressed, bootable squashfs file. When you want to restore, boot the squashfs backup and run this program again. You can also restore the backup to another machine. And with this script you can migrate ubuntu system on a virtual machine or a wubi installation to physical partitions.

Install:
Just copy this script anywhere and allow execution of the script. I put this script under /usr/local/bin, so that I don't have to type the path to this script everytime.

Use:
sudo /path/to/this/script -b
to backup or
sudo /path/to/this/script -r
to restore
You can also type
sudo bash /path/to/this/script -b
or
sudo bash /path/to/this/script -r

Note that
sudo sh /path/to/this/script -b
and
sudo sh /path/to/this/script -r
will not work.

Backup:
squashfs-tools is required for this program to backup your system. lupin-casper is required to make a bootable backup.
You can install them by typing
sudo apt-get install squashfs-tools lupin-casper
in a terminal.
Then you can backup your running ubuntu system by typing
sudo /path/to/this/script -b
If you put this script under /usr/local/bin, just type
sudo `basename $mypath` -b
and follow the instructions.
You can specify where to save the backup, files/folders you want to exclude from the backup.
You don't need to umount external media, windows partitions, or any manually mounted partitions. They will be automatically ignored. Therefore you can save the backup to external media, windows partitions, etc.
Waring: You must make sure you have enough space to save the backup.
The program will generate other files needed for booting the backup. Read the menu.lst file the program generated under the backup folder for details on how to boot the backup.

Restore:
Read the menu.lst file the program generated under the backup folder for details on how to boot the backup.
After booting into the live ubuntu backup, open a terminal and type
sudo /path/to/this/script -r
If you have put this script under /usr/local/bin when backup, now just type
sudo `basename $mypath` -r
and follow the instructions.
Note: This program does not provide a partitioner (it can only format partitions but cannot create, delete, or resize partitions). The backup can be restored to existing partitions. So it is recommended that you include gparted in the backup. And if the partition table has any error, you will not be able to restore the backup until the errors are fixed.
You can specify partitions and mount points, if you have no swap partition, the program will make a swap file for you if you tell it to do so. It will generate new fstab and install grub. It can also change the hostname, username and password if you tell it to do so." | more
}

echohelpcn(){
	[ $lang = "cn" ] && echo "live ubuntu backup $version, copyleft billbear <billbear@gmail.com>

本程序将帮助你备份运行中的 ubuntu 系统为一个可启动的 squashfs 压缩备份文件。
要恢复的时候, 从备份文件启动并再次运行本程序。
可以把备份文件恢复到另一台机器。
可以把虚拟机里的 ubuntu 迁移到真机。
可以把 wubi 安装的系统迁移到真分区。

安装:
只要拷贝此脚本到任何地方并赋予执行权限即可。
我喜欢把它放在 /usr/local/bin 里面, 这样每次运行的时候就不用写绝对路径了。

使用:
sudo 到此脚本的路径 -b
是备份，而
sudo 到此脚本的路径 -r
是恢复。
也可以用
sudo bash 到此脚本的路径 -b
和
sudo bash 到此脚本的路径 -r

注意不能用
sudo sh 到此脚本的路径 -b
和
sudo sh 到此脚本的路径 -r

备份:
程序依赖 squashfs-tools 来工作。
另外必须安装 lupin-casper 才能做出可启动的备份来。
在终端用如下命令来安装它们:
sudo apt-get install squashfs-tools lupin-casper
而后就可以用这样的命令来备份运行中的 ubuntu 系统了:
sudo 到此脚本的路径 -b
如果这个脚本在 /usr/local/bin, 只要这样
sudo `basename $mypath` -b
然后根据提示进行就可以了。
你可以指定存放备份的路径, 以及需要排除的文件和目录。
不必卸载移动硬盘, windows 分区, 或任何你手动挂载了的分区。它们将会自动被忽略。
因此你可以直接存放备份到移动硬盘, windows 分区等等。
小心: 你必须确定有足够的空间来存放备份。
脚本将会生成启动所需的另外几个文件。
阅读在备份存放目录生成的 menu.lst，里面会详细告诉你如何从备份文件直接启动。

恢复:
阅读在备份存放目录生成的 menu.lst，里面会详细告诉你如何从备份文件直接启动。
启动了 live ubuntu backup 之后, 打开一个终端输入
sudo 到此脚本的路径 -r
如果在备份时已经把此脚本放到了 /usr/local/bin, 现在只需敲入
sudo `basename $mypath` -r
并根据提示进行恢复就可以了。
注意:此脚本并不提供分区功能(只能格式化分区但不能创建,删除分区或调整分区大小)。
只能恢复备份到已有的分区。
因此建议在备份前安装 gparted，这样恢复时你就有分区工具可用了。
另外如果分区表有错误, 将不允许恢复备份，直到错误被修复。
你可以指定若干分区和它们的挂载点。
如果没有 swap 分区, 可以为你创建一个 swap 文件 (如果你这样要求的话)。
会自动生成新的 fstab 并安装 grub。
如果有必要, 还可以改变主机名, 用户名和密码。" | more
}


echousage(){
	[ $lang = "cn" ] && echo "用法:
备份:
sudo bash $mypath -b
恢复:
sudo bash $mypath -r
帮助:
bash $mypath -h" || echo "Usage:
sudo bash $mypath -b
to backup;
or
sudo bash $mypath -r
to restore;
or
bash $mypath -h
to view help."
}

back_website(){
	echo '将备份网站到 /home/remastersys 目录，请输入您要备份的网站目录名'
	read website
	echo "(高级用户功能)指定其他需要排除的文件/目录, 一行写一个。以空行结束。"
	read ex
	while [ "$ex" != "" ]; do
	ex=`dequotepath "$ex"`
	[ "${ex#/}" = "$ex" ] && { echo "请使用绝对路径"; read ex; continue; }
	[ -e "$ex" ] || { echo "$ex 并不存在"; read ex; continue; }
	ex="${ex#/}"
	echo $ex >> $exclude
	read ex
	done
	lastfix=$(date +%Y%m%d_%H%M%S)
	echo '请输入网站对应的数据库名：[无数据库或不备份 直接回车]'
	read mysql
	if [ "$mysql" != '' ]; then
		echo -e "正在导出数据库到/home/remastersys/$mysql.$lastfix.sql ..."
		mysqldump -uroot -proot $mysql > /home/remastersys/$mysql.$lastfix.sql
		#mysql -u用户名 -p 数据库名 < 数据库名.sql
		echo -e "导出数据库 $mysql 完成！"
		echo -e "开始压缩数据库到/var/www/$website/$mysql.$lastfix.sql.7z ..."
		7z a -t7z -r /var/www/$website/$mysql.$lastfix.sql.7z /home/remastersys/$mysql.$lastfix.sql
		echo "已备份至 /home/remastersys/$mysql.$lastfix.sql 。"
		echo "压缩为 /home/remastersys/$mysql.$lastfix.sql.7z"
	fi;
	stime=`date +%F_%T`
	echo -e "正在导出数据库到/home/remastersys/$mysql.$lastfix.sql ..."
	# tar -cvzpf /home/remastersys/$website.web.$(date +%Y.%m.%d_%H.%M.%S).tar.gz /home/remastersys/$website $exclude
	7z a -t7z -r /home/remastersys/$website.web.$lastfix.7z /var/www/$website $exclude
	echo "已备份至 /home/remastersys/$website.web.$lastfix.7z 。"
	echo -e "开始于: $stime\n结束于: `date +%F_%T`"
}


back_home(){
	stime=`date +%F_%T`
	echo '清理系统...'
	sudo apt-get autoclean
	sudo apt-get clean
	# sudo apt-get autoremove --purge
	# 清理个人所有缓存...
	sudo rm -fr ~/.cache/
	sudo mksquashfs /home/lee /home/remastersys/home.$(date +%Y%m%d%H%M%S).squashfs
	# chown -R lee:lee
	# sudo 7z a -t7z -r /home/remastersys/home.$(date +%Y%m%d%H%M%S).7z  ~
	echoredcn "开始于: $stime\n结束于: `date +%F_%T`"
	echoreden "started at: $stime\nfinished at: `date +%F_%T`"
}


clean_sys(){
	echo '清理系统...'
	sudo apt-get autoclean
	sudo apt-get clean
	sudo apt-get autoremove --purge
	# 清理个人所有缓存...
	sudo rm -fr ~/.cache/
	# 清理内核...
    	# clean_kernel
    	sudo update-grub
    	# 清除孤立的库文件
    	# sudo deborphan | xargs sudo apt-get -y remove --purge
	#清除所以删除包的残余配置文件
	# sudo dpkg -l |grep ^rc|awk '{print $2}' |tr ["\n"] [" "]|sudo xargs dpkg -P -
	#清理下载的软件包缓存...
	sudo rm -fr /var/cache/apt/archives/*.deb
	sudo rm -fr /var/cache/apt/archives/partial/*.deb
	#清理日志...
	sudo find /var/log -name '*[g|t].[0-9]*.gz' |xargs sudo rm -rf
	sudo find /var/log -name '*log.[0-9]*' |xargs sudo rm -rf
	sudo find /var/log -name 'history.[0-9]*' |xargs sudo rm -rf
	sudo find /var/backups -name '*stat[e|u]s.[0-9]*.gz' |xargs sudo rm -rf
	#清空回收站...
	sudo rm -fr ~/.local/share/Trash/files/
	echo '清理完毕！'
}

echolee(){
echo "==========Maybe Command==============
restart_work
lee_ssh
ln -s resource_folder target_folder
sudo lee -b 	--- backup system
sudo lee -r 	--- recovery system
sudo lee -bw 	--- backup website
sudo lee -bh 	--- backup home
sudo lee -clean --- clean system
find . -type f -mtime +30 -mtime -3600 -exec rm {}
find . -type f -size +10M
=====================================
chown root:root install.log
sudo tar -czf ~/lc.data$(date +%Y%m%d_%H%M%S).tar.gz /etc/hosts /etc/apache2/ /etc/php5/ /etc/mysql/ /var/www/ /usr/local/bin/ /home/lee/workspace/ /home/lee/LSF/ /home/lee/.fonts/ /home/lee/.filezilla/ /home/lee/.ssh/ /home/lee/.remmina/ /home/lee/.config/sublime-text-2/"
}







ls /sbin/vol_id > /dev/null 2>&1 && VOL_ID=vol_id || VOL_ID=VOL_ID
echo -e "\033[31me\033[0mnglish/\033[31mc\033[0mhinese?"
read lang
[ "$lang" = "c" ] && lang=cn || lang=en
today=`date +%Y%m%d%H%M`
[ "$lang" = "cn" ] && version="V1.2, 2014年6月12日" || version="V2.2, 2014/6/12"
[ "$*" = -h ] && { echohelpen; echohelpcn; exit 0; }
[ "$*" = -bw ] && { back_website; exit 0; }
[ "$*" = -bh ] && { back_home; exit 0; }
[ "$*" = -clean ] && { clean_sys; exit 0; }
[ "`id -u`" != 0 ] && { echoen "Root privileges are required for running this program."; echocn "备份和恢复需要 root 权限。"; echousage; echolee;exit 1; }
[ "$*" = -b ] && { dobackup; exit 0; }
[ "$*" = -r ] && { dorestore; exit 0; }
echousage
exit 1

