package Watcher::Inotify;

use strict;
use warnings;
use base ('Watcher');

use Linux::Inotify2;




my %mask_mapping = (
	all		=> IN_ALL_EVENTS,
	access	=> IN_ACCESS | IN_OPEN,
	read	=> IN_OPEN,
	edit	=> IN_MODIFY,
	write	=> IN_MODIFY | IN_CREATE | IN_DELETE | IN_DELETE_SELF |
				IN_MOVED_FROM | IN_MOVED_TO | IN_MOVE_SELF,
	closerw	=> IN_CLOSE_WRITE,
	closero	=> IN_CLOSE_NOWRITE,
	close	=> IN_CLOSE,
);

# Flags are defined from their order in Linux::Inotify2
my %masks_name = (
	  1 => 'IN_ACCESS',      # Accessed
	  2 => 'IN_MODIFY',      # Modified
	  4 => 'IN_ATTRIB',      # Metadata changed
	  8 => 'IN_CLOSE_WRITE', # Writeable FD was closed

	 16 => 'IN_CLOSE_NOWRITE',# Readonly FD was closed
	 32 => 'IN_OPEN',         # obj was opened
	 64 => 'IN_MOVED_FROM',   # obj moved from this directory
	128 => 'IN_MOVED_TO',     # obj moved to   this directory

	256 => 'IN_CREATE',       # obj created in this directory
	512 => 'IN_DELETE',       # obj deleted from this directory
   1024 => 'IN_DELETE_SELF',  # obj itself was deleted
   2048 => 'IN_MOVE_SELF',    # obj itself was moved

   4096 => 'IN_ALL_EVENTS',   # All above events
   8192 => 'IN_UNMOUNT',      # Mountpoint was unmounted
  16384 => 'IN_Q_OVERFLOW',   # Event queue overflow
  32768 => 'IN_IGNORED',      # 

  65536 => 'IN_CLOSE',        # IN_CLOSE_WRITE | IN_CLOSE_NOWRITE
 131072 => 'IN_MOVE',         # IN_MOVED_FROM  | IN_MOVED_TO
 262144 => 'IN_ISDIR',        # 

 524288 => 'IN_ONESHOT',      # Only send event once
1048576 => 'IN_MASK_ADD',     # Unsupported
2097152 => 'IN_DONT_FOLLOW',  # Dont follow symlinks
4194304 => 'IN_ONLYDIR',      # only watch if path is a directory
);


sub set_max {
	my ($count) = @_;

	# TODO: use execute_asroot
	# max = 1569325055
	my $out = `sysctl fs.inotify.max_user_watches=$count`
}


# #########################################################
# Object management
# #########################################################

# Constructor
sub init {
	my ($self, $args) = @_;
	$self->{inotify} = Linux::Inotify2->new();
	$self->{instances} = ();
	$self->{history} = {};
}

# Destructor
sub stop {
	my ($self) = @_;
}





# #########################################################
#  Watcher management
# #########################################################

#
# Add a watcher
#
sub watch_add {

	my ($self, $path, $mask, $recurse) = @_;
	my $inotify = $self->{inotify};


	# If recursion is needed add the write flags
	if ($recurse) {
		$mask |= $mask_mapping{write};
	}

	# Add the inotify watcher
	my $watcher = $inotify->watch($path, $mask, \&{$self->callback});

	# An error occured
	if (!$watcher) {
		my $err = $!;
	 
		if ($err eq 'EBADF') {
			log_error("Path $path is invalid");
		}
		elsif ($err eq 'EINVAL') {
			log_error("Mask $mask contains no legal event");
		}
		elsif ($err eq 'ENOMEM') {
			log_error("Not enough kernel space");
		}
		elsif ($err eq 'ENOSPC') {
			log_error("Max inotify limit reached");
		}
		elsif ($err eq 'EACCESS') {
			log_error("Read access to $path refused");
		}
		else {
			log_error("Unknown error while watching $path for $mask");
		}
		return 0;
	}	

	# Add the watcher to the hash
	$self->{instances}{$path} = $watcher;
	my $added_cnt = 1; 

	# recursive call
	if ($recurse) {
		# Only works for directories
		if (-d$path) {
			opendir(FD, $path);
			FILE_RECURSE:
			foreach my $file (readdir(FD)) {
				# Skip these special directories
				next FILE_RECURSE if ($file eq '..' || $file eq '.');
	 
				my $tmppath = "$path/$file";
				if (-d$tmppath) {
					log_debug("Adding $tmppath from recursion", 2);
					$added_cnt += $self->watch_add($tmppath, $mask, $recurse);
				}
			}
		}
	}	

	return $added_cnt;
}

#
# Remove a watcher
# 
sub watch_del {
	my ($self, $path, $recurse) = @_;
	my $cnt = 0; 

	# If this path is being watched
	if ($self->{instances}{$path}) {
	 
		# Remove the inotify element
		$self->{instances}{$path}->cancel;
		delete $self->{instances}{$path};

		$cnt++;
		log_info("removed watcher for $path");
	}	

	# If recursion was activated on this object
	if ($recurse) {
		# Remove all matching watcher
		foreach my $tmppath (keys %{$self->{instances}}) {
			# If the path matches, remove it too
			if (substr($tmppath, 0, length($path)) eq $path) {

				$self->{instances}{$tmppath}->cancel;
				delete $self->{instances}{$tmppath};
				log_debug("removed $tmppath from recursion", 2);
				$cnt++;
			}
		}
	 
		log_debug("removed $cnt watchers as per recursive removal");
	}

	return $cnt;
}


# #########################################################
# Event processing
# #########################################################

sub poll {
	my ($self) = @_;
	return $self->{inotify}->poll();
}


# real processing
sub callback {
	my ($self, $e) = @_;
	my $w = $e->{w};  # Watcher

	my $recurse = 0;
	my $mask = 0;

	# Cleanup for the mask
	#$e->{mask} &= 0xFFFFFFFF;

	my $data = {
		inot_file   => $w->{name},
		inot_mask   => $w->{mask},

		evt_path	=> $w->{name}."/".$e->{name},
		evt_file	=> $e->{name},
		evt_mask	=> $e->{mask},
		evt_cookie  => $e->{cookie},

		evt_isdir   => $e->{mask} & IN_ISDIR,   # event ocurred against dir
		evt_isend   => $e->{mask} & IN_IGNORED, # If the file gone
	};
	#$data->{evt_isdir} = (-d $data->{evt_path});

	# 
	return 1 if ($data->{evt_file} eq '');

	# Skip dirs Opened OR closed_nowrite
	return 1 if ($data->{evt_mask} & IN_ISDIR && $data->{evt_mask} & (IN_CLOSE_NOWRITE|IN_OPEN));

	log_debug("Event ".mask2name($data->{evt_mask})." on $data->{evt_path}");


	# lookup the original ID frm the list
	my @ids = @{$self->path2id($data->{evt_path})};
	if (!@ids) {
		log_error("Cannot find source ID for $data->{evt_path}");
		return 0;
	}


	# Check if we have recursive configuration in our watchs
	foreach my $id (@ids) {
		my $conf = $self->{watchers_conf}->{$id};
		$recurse += $conf->{recurse};
		$mask += $conf->{mask};
	}

	# #############################################################
	# inotify watchers management
	#

	# If we had events, in a folder
	if ($data->{evt_isdir}) {

		# Adding a new folder in our list
		if ($data->{evt_mask} & (IN_CREATE|IN_MOVED_TO) && $recurse) {

			if ($self->watch_add($data->{evt_path}, $mask, $recurse)) {
				log_info("New object : $e->{name} from watcher $w->{name}");
			}
			else {
				log_error("cannot add new watcher to $data->{evt_path}");
			}
		}

		# Removing a folder in our list
		if ($data->{evt_mask} & (IN_DELETE|IN_DELETE_SELF|IN_MOVED_FROM)) {
			my $cnt = $self->watch_del($data->{evt_path}, $recurse);
			log_info("Removed $cnt watchers from $data->{evt_path}");

			# And remove history for the whole hierarchy
			delete $self->{history}->{$data->{evt_path}};
		}
	}

	# not a folder ? Ok, simple file then
	else {
		# special : moved_self
		if ($data->{evt_mask} & IN_MOVE_SELF) {

		}

		# If it's a remove from watch
		if ($data->{evt_mask} & (IN_DELETE|IN_DELETE_SELF|IN_MOVED_FROM) ) {
			# remove the history
			delete $self->{history}->{$data->{evt_path}};
		}
	}
   # Avoid repeating signals in short period
#   if ($events_history{$idname} && 
#	   time() - $events_history{$idname} < $opt_trigger_grouptime) {
#	   
#	   return 1;
#   }   
#   $events_history{$data->{evt_path}}{$data->{evt_mask}} = time();

	if (!$self->{history}->{$data->{evt_path}}) {
		$self->{history}->{$data->{evt_path}} = {};
	}


	# #############################################################
	# Callback and real user processing


	# If the configured mask does not match, skip it
	LOOP_EXECUTE:
	foreach my $id (@ids) {

		# If the event isn't valid, skip
		next LOOP_EXECUTE if (!validate_event($id, $data));


		# Process the event
		my $params = {
			file	=> $data->{evt_path},
			mask	=> $data->{evt_mask},
		};

		log_info("Object $data->{evt_path} triggered $id");

		# Execute the callback

		$self->execute($id,$params);

		# Remove the history for this watcher (reset the requirements)
		delete $self->{history}->{$data->{evt_path}}{$id};
	}

	return 1;
}



# #############################################################
# Static sub
# #############################################################

# Change a bitmask to a name
sub mask2name {
	my ($mask) = @_;
	my $name = '';

	foreach my $evtid (keys %masks_name) {
		if ($mask & $evtid) {
			$name .= $masks_name{$evtid}." ";
		}
	}

	return $name;
}




1;
