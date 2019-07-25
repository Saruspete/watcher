package Watcher;




# #########################################################
# Object management
# #########################################################

# Constructor
sub new {
	my ($class, $args) = @_;
	my $self = {
		watchers_inst => {},
		watchers_conf => {},
	};

	$class = ref $class || $class;
	bless $self, $class;

	$self->init($args);

	return $self;
}

# Destructor
sub DESTROY {
	my ($self) = @_;
	$self->stop();
}


sub init { return 1; }
sub stop { return 1; }


# #########################################################
# Event Processing and configuration
# #########################################################
sub poll { return 0; }

sub set_conf {
	
}

sub validate_event {
	my ($self, $id, $e) = @_;
	my $return = 0;

	#  $e = event

	my $c = $watchers_conf{$id};

	# ####################################
	# Check the mask
	my $maskok = 0;
	my $emask = $e->{evt_mask};

	log_debug("Checking path $e->{evt_path} for ".mask2name($emask));
	LOOP_MASKCHECK:
	foreach my $cmask (@{$c->{mask}}) {
		if ( ($emask & $cmask) == $emask) {
			log_debug(mask2name($cmask)."matched on $e->{evt_path}", 2);
			$maskok = 1;
			last LOOP_MASKCHECK;
		}
	}
	if (!$maskok) {
		log_debug("Event ".mask2name($emask)." on $e->{evt_path} didn't match", 2);
		return 0;
	}

	# ####################################
	# Check the path
	my $path = $e->{evt_path};

	# Only specific files to watch against
	if ($c->{watchonly}) {
		# Validate at least one pattern
		LOOP_PTRNMATCHONLY:
		foreach my $ptrn (@{$c->{watchonly}}) {
			if ($path =~ m/$ptrn/g) {
				log_debug("$path accepted by required pattern $ptrn", 2);
				$return = 1;
				last LOOP_PTRNMATCHONLY;
			}
		}
		# Not matched by any valid pattern
		if ($return != 1) {
			log_debug("$path refused by all required patterns", 2);
			return 0;
		}
	}

	# Files to exclude
	if ($c->{watchnot}) {
		# Any validated pattern is refused
		LOOP_PTRNMATCHNOT:
		foreach my $ptrn (@{$c->{watchnot}}) {
			if ($path =~ m/$ptrn/g) {
				log_debug("$path refused by pattern $ptrn", 2);
				return 0;
			}
			log_debug("$path not refused by pattern $ptrn", 2);
		}
	}

	# ####################################
	# Check for multiple masks
	if ($#{$c->{mask}} > 0) {

		# Create a per-watch index
		if (!$events_history4trg{$e->{evt_path}}{$id}) {
			$events_history4trg{$e->{evt_path}}{$id} = $emask;
		}
		$events_history4trg{$e->{evt_path}}{$id} |= $emask;

		# Mask of passed events
		my $evt_mask = $events_history4trg{$e->{evt_path}}{$id};

		# And check every required event
		LOOP_PASSEDEVENTS:
		foreach my $cmask (@{$c->{mask}}) {

			# Check if the current mask requirement is fullfiled
			if (! ($evt_mask & $cmask) ) {
				log_debug("Events ".mask2name($cmask)." didn't trigger yet", 2);
				return 0;
			}


#			# Check the timdiff between the events if required
#			my $ltime = $passed_events{$passed_event};
#			if ($c->{masktmout} && time() - $ltime > $c->{masktmout}) {
#				log_debug("Events ".mask2name($cmask)." triggered more than $c->{masktmout} sec ago", 2);
#				return 0;
#			}

		}
	}

	return 1;
}





# #########################################################
# Execution of program
# #########################################################

# Resolve between aliases and raw commands
sub execute_parse {
	my ($cmd, $params) = @_;

	# If there is an alias with this name, resolve it
	if ($aliases{$cmd}) {
		$cmd = $aliases{$cmd};
	}

	# Replace the arg in conf by the hash index
	$cmd =~ s/%([a-zA-Z0-9_]+)%/$params->{$1}/ge;

	return $cmd;
}


sub execute_action {
	my ($id, $params, $toprocess) = @_;

	my $conf = $watchers_conf{$id};

	my %ret_data;

	# Remove the SIGCHLD processing
	undef $SIG{CHLD};

	# If there is an action to process
	if ($conf->{$toprocess}) {

		# process every actions
		foreach my $conf_cmd (@{$conf->{$toprocess}}) {

			# resolve and parse the executable
			#my $exec_cmd = execute_parse($conf_cmd, $params);
			foreach my $exec_cmd (execute_parse($conf_cmd, $params)) {

				# Temp storage
				my $exec_info = '';
				my $exec_out = '';
				my $exec_ret = 0;

				# If it's valid, go for it
				log_debug("Starting exec of '$exec_cmd'", 1);
				$exec_out = `$exec_cmd`;
				#$exec_out = "" if (!$exec_out);

				if ($? & 127) {
					$exec_info .= "Died with signal ".($? & 127)." and "
								. ($? & 128)." coredump";
					$exec_ret = $? & 127;
				}
				else {
					$exec_ret += $? >> 8;
				}

				if ($!) {
					$exec_info .= "error: $!"
				}

				log_info("Finished '$exec_cmd' Return: $exec_ret / Output: $exec_out / Info: $exec_info");

				# Store in temp hash for further processing
				$ret_data{output} .= "# Output of $exec_cmd\n$exec_out\n";
				$ret_data{return} += $exec_ret;
			}
		}
	}

	return \%ret_data;
}


sub execute {

	my ($self, $id, $params) = @_;
	my $conf = $watchers_conf{$id};
	
	
	# Execution process
	# fork
	#  Prechecks
	#  Onfailure/onsuccess
	#  postchecks
	
	# use forkpool if available
	if ($forkpool) {
		$forkpool->start and return 1;
	}
	else {

		my $pid = fork();
		
		if ($pid > 0) {
			# Parent, return
			log_debug("Parent $$ Forked PID $pid", 2);
			return 1;
		}
		elsif ($pid == 0) {
			# Child, continue
		}
		else {
			log_error("Unable to fork");
			return 0;
		}
	}

	# try to execute the prefilter
	my %check_data = %{execute_action($id, $params, 'precheck')};
	my $check_result = $check_data{return};
	$params->{output_pre} = $check_data{output};

	# If the check was successful
	if ($check_data{return} == 0) {
		execute_action($id, $params, 'onsuccess');
	}
	else {
		execute_action($id, $params, 'onfailure');
	}

	execute_action($id, $params, 'postcheck');
	
	if ($forkpool) {
		$forkpool->finish();
	}
	else {
		exit 0;
	}
}

##
#
sub path2id {

	my ($path) = @_;
	my %ids;

	# Seek every IDs matching our path and upper
	# cnt is a infinite loop security
	my $cnt = 100;
	my $tmppath = $path;
	while ($tmppath ne '/' && $cnt) {

		if ($path2watch{$tmppath}) {
			foreach my $p (@{$path2watch{$tmppath}}) {
				$ids{$p} = 1;
			}
		}

		# One level up
		$tmppath = dirname($tmppath);
		$cnt--;
	}

	# Return the list
	my @ret = keys %ids;
	return \@ret;
}


1;
