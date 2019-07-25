package Watcher::Audit;

use strict;
use warnings;
use base ('Watcher');

use File::Tail;

# dir=  recursive
# path= non-recursive
# -a exit,always  -F path=/home/raven/public_html -F perm=war -F key=raven-pubhtmlwatch


# Create File
# type=SYSCALL msg=audit(1424050327.236:485): arch=c000003e syscall=2 success=yes exit=3 a0=7fffacc24085 a1=941 a2=1b6 a3=7fffacc238e0 items=2 ppid=12923 pid=20431 auid=1000 uid=0 gid=0 euid=0 suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts10 ses=2 comm="touch" exe="/bin/touch" key="rofl"
# type=CWD msg=audit(1424050327.236:485):  cwd="/root"
# type=PATH msg=audit(1424050327.236:485): item=0 name="/tmp/rofl/" inode=155696 dev=08:35 mode=040755 ouid=0 ogid=0 rdev=00:00 nametype=PARENT
# type=PATH msg=audit(1424050327.236:485): item=1 name="/tmp/rofl/mao" inode=151940 dev=08:35 mode=0100644 ouid=0 ogid=0 rdev=00:00 nametype=CREATE
# type=UNKNOWN[1327] msg=audit(1424050327.236:485): proctitle=746F756368002F746D702F726F666C2F6D616F
#
#
# Create folder
# type=SYSCALL msg=audit(1424050340.461:487): arch=c000003e syscall=83 success=yes exit=0 a0=7fff2f290087 a1=1ff a2=1ff a3=7fff2f28f560 items=2 ppid=12923 pid=20463 auid=1000 uid=0 gid=0 euid=0 suid=0 fsuid=0 egid=0 sgid=0 fsgid=0 tty=pts10 ses=2 comm="mkdir" exe="/bin/mkdir" key="rofl"
# type=CWD msg=audit(1424050340.461:487):  cwd="/root"
# type=PATH msg=audit(1424050340.461:487): item=0 name="/tmp/rofl/hihi/" inode=155698 dev=08:35 mode=040755 ouid=0 ogid=0 rdev=00:00 nametype=PARENT
# type=PATH msg=audit(1424050340.461:487): item=1 name="/tmp/rofl/hihi/roho" inode=155699 dev=08:35 mode=040755 ouid=0 ogid=0 rdev=00:00 nametype=CREATE
# type=UNKNOWN[1327] msg=audit(1424050340.461:487): proctitle=6D6B646972002F746D702F726F666C2F686968692F726F686F


sub init {
	
}

sub stop {
	# Clean all watcher entries
	
}

# 
sub watch_add {
	my ($self, $path, $mask, $recurse) = @_;
	
	my $kpath = ($recurse) ? 'dir' : 'path';
	my $perm = $mask;

	my $cmd = "-a exit,always -F $kpath='$path' -F perm=$perm -F key=watcher-";
	
	
}

# 
sub watch_del {
	
}



1;
