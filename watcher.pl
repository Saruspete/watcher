#!/usr/bin/perl


# ##################################################################
# Watcher - Watch files using different mechanisms
# ##################################################################
# Adrien Mahieux <adrien.mahieux@gmail.com>
# ##################################################################




# ##################################################################
# Initialization:
# 0) Check what mechanism is available
# 1) List every base path we want to keep track of
# 2) For all these path, place the inotify events
# 3) Start to listen to these events
#
# On signal:
# 1) Seek for watchers from the file to the root
# 2) for each watcher, keep matching ones (recurse+mask)
# 3) for each watcher left, fork and exec their action
#
# On shutdown:
# 1) Remove every watcher
#
# ##################################################################


use strict;
use warnings;

# Add the script's location to the list of libs
use FindBin;
use lib "$FindBin::Bin/lib";

use Cwd 'abs_path';
use Pod::Usage;
use Data::Dumper;
use Getopt::Long qw(:config no_ignore_case gnu_compat bundling permute auto_help);
use File::Basename;

use AMTools;



my $errors = 0;

our $opt_verbose = 0;
my $opt_help = 0;
my $opt_fileconf = "$FindBin::Bin/watcher.conf";

# How many seconds we should group the events
my $opt_trigger_grouptime = 0;

# ##################################################################
# Configuration
# ##################################################################


my @access_types = qw(all access read edit write close);

Getopt::Long::Configure('pass_through');
GetOptions(
	'help|h|?'          => \$opt_help,
	'verbose|v+'        => \$opt_verbose,
	'fileconf|f=s'      => \$opt_fileconf,
);



pod2usage(-verbose => 2) if ($opt_help && $opt_verbose);
pod2usage(-verbose => 1) if ($opt_help);



# ##################################################################
# Step 0 : load the configuration and caller informations
if (! -r $opt_fileconf) {
	log_error("Unable to read config file \"$opt_fileconf\"");
	exit 2;
}

my $conf = conf_load($opt_fileconf);
if (!$conf) {
	log_error("Unable to load the configuration file '$opt_fileconf'");
	exit 2;
}



my %watchers_conf;  # Watchers configuration
my %aliases;        #

my %path2watch;     # Base paths to watch from conf
my %events_history; # History of events
my %events_history4trg; # History of events for each watch

my $realuser = ($ENV{SUDO_UID}) ? "from $ENV{SUDO_USER} ($ENV{SUDO_UID})" : '';
log_info("Starting $0 as user $> $realuser");



# ##################################################################
# Initialize watchers

#
my $watcher;
my @watches = qw(Inotify Audit);

foreach my $watch (@watches) {
	if (! ($watcher = module_dynload("Watcher::$watch"))) {
		log_error("Unable to load watcher $watch");
	}
}

die ("Unable to load any watcher interface") if (!$watcher);


# ##################################################################
# Step 1 : Load configuration structure


# ##################################################################
# Step 2 : list the different paths to watch and adjust sys


# ##################################################################
# Step 3 : Add the watchers to the different paths

foreach my $path (keys %path2watch) {
	# Each registered path have at least one watcher
	my @watch_ids = @{$path2watch{$path}};

	my $recurse = 0;
	my $mask = 0;
	foreach my $watch_id (@watch_ids) {
		my $wc = $watchers_conf{$watch_id};
		$recurse += $wc->{recurse};
		foreach my $watch_mask (@{$wc->{mask}}) {
			$mask |= $watch_mask;
		}
	}

	# Add the watcher
	log_info("watching $path for $mask");
	my $listeners = $watcher->watch_add($path, $mask, $recurse);

	# If no listener was added, gotta error
	if (!$listeners) {
		log_error("Unable to watch \"$path\" in start loop");
		$errors++;
	}
	else {
		log_info("Added $listeners listener(s) for $path");
	}
}

# If we had errors, exit...
if ($errors) {
	log_error("Got $errors on startup. Exiting");
	$watcher->watch_del('/', 1);
	exit 5;
}


# ##################################################################
# Step 4 : And we're live !
local $SIG{ABRT}  =
local $SIG{INT}   =
local $SIG{TERM}  = \&sig_shutdown;
local $SIG{CHLD}  = 'IGNORE';
my    $sig_shutdown_cnt = 3;


# Try to load forkmanager
my $forkpool = module_dynload("Parallel::ForkManager", 20);

# Running loop
my $error;
my $continue = 1;
my $pause = 0;
while ( $continue ) {
	$error = $watcher->poll();

	while ($pause) {
		sleep(0.2);
	}
}




# ##################################################################
#
# General usage subs
#
# ##################################################################

sub conf_load {

	my $file = $_[1];
	if (! -r $file) {
		log_error("File $file is not readable");
		return;
	}

	# Load the raw configuration data
	my %conf = %{AMTools::conf_load($opt_fileconf, 1)};

	# Process each section
	CONFSECTION:
	foreach my $ck (keys %conf) {
		# The name is composed as : watcher.ELEMENT.ID
		my ($elem, $id) = split(/\./, $ck);

		$elem = '' if !$elem;

		# $ck = config key
		# $c  = config data
		my $c = $conf{$ck};

		# Elements of $c :
		# path
		#   mask
		#   masktmout
		#   recurse
		#   watchonly
		#   watchnot
		#   precheck
		#   postcheck
		#   onsuccess
		#   onfailure
		#
		# alias
		#   exec
		#
		#
		#
		# Matched elements :
		# paths, filters, actions, conf

		# Path to watch
		if ($elem eq 'path') {

			# Duplicate elements
			if ($watchers_conf{$id}) {
				log_error("Path ID $id il already defined");
				next CONFSECTION;
			}

			# Check the path
			if (!$c->{path}) {
				log_error("Path ID $id doesnt define a 'path' variable");
				next CONFSECTION;
			}
			# Be sure the path is absolute
			$c->{path} = abs_path($c->{path});

			# If the requested path donesnt exist
			if (!-e $c->{path}) {
				log_error("Path $c->{path} doesnt exists");
				next CONFSECTION;
			}

			# If the mask is not provided
			if (!$c->{mask}) {
				log_error("Path $id doesn't specify a triggering mask");
				next CONFSECTION;
			}

			# Transform to array some values
			foreach my $op (qw(watchonly watchnot precheck postcheck onsuccess onfailure)) {
				$c->{$op} = arrayize($c->{$c}) if $c->{$op};
			}

			# Parse the maskgrp
			my @maskparts = split(/\+/, $c->{mask});
			$c->{mask} = ();

			foreach my $maskpart (@maskparts) {

				# If this part is mapped
				if (!grep $_ eq $maskpart, @access_types) {
					log_error("Unknown mask part in $id: $maskpart");
					next CONFSECTION;
				}

				# Add the new mask to the mandatory list (AND'ed)
				push(@{$c->{mask}}, $maskpart);
			}

			# Add the watcher to the list
			$watchers_conf{$id} = $conf{$ck};
			push(@{$path2watch{$c->{path}}}, $id);

		}
		elsif ($elem eq 'alias') {

			$aliases{$id} = arrayize($c->{exec});

		}
		elsif ($elem eq 'watcher') {

			# Allow override of "opt_*" variables
			foreach my $var (keys %$c) {

				no strict 'refs';
				# If key exists, override it
				if (${'opt_'.$var}) {
					log_debug("Overriding opt_$var with $c->{$var}");
					${'opt_'.$var} = $c->{$var};
				}
			}
		}
		else {
			log_warning("Unreckognized element : $elem");
		}
	}

	return $conf;

}


# Shutdown the watcher
sub sig_shutdown {

	if ($sig_shutdown_cnt == 0) {
		log_info("Emergency shutdown requested. Exiting forcefully");
		exit 253;
	}
	else {
		log_info("Standard shutdown requested. Emergency shutdown in $sig_shutdown_cnt kills");

		# Remove every watcher
		$watcher->watch_del('/', 1);


		# Stop the loop
		$continue = 0;
	}

	$sig_shutdown_cnt--;
	return 1;
}

# Try to reload the configuration
sub sig_reload {

	# Load the new conf
	my %conf_new = %{AMTools::conf_load($opt_fileconf, 1)};

	# Pause processing & replace
	$pause = 1;


	# Resume processing
	$pause = 0;

	return 1;
}



__END__

=head1 NAME

watcher.pl - Watch for events and triggers actions

=head1 SYNOPSIS

watcher.pl [options]

 Options:
  -h, --help          this help
  -v, --verbose       increase verbosity level
  -f, --fileconf      configuration file (defaults to ../etc/sshkit/watcher.conf

For more details about this help, increase the verbosity level.

=head1 DESCRIPTION

This script manages INotify events to keep track of accessed/modified files.

It allows you to run defined commands upon triggering. You can validate a file
right after edition or record access of watched files.


Keep in mind Inotify events are asynchronous, thus you can only know the file
which was modified. The related user is available through a kernel patch.


=head2 USAGE



=head3 INotify events

Events and modificators are defined in /usr/include/linux/inotify.h
Here is the list and description of them :

  IN_ACCESS         File was accessed
  IN_MODIFY         File was modified
  IN_ATTRIB         Metadata was changed (owner, chmod...)
  IN_CLOSE_WRITE    A readwrite file descriptor was close
  IN_CLOSE_NOWRITE  A readonly  file descriptor was closed
  IN_OPEN           File was opened
  IN_MOVED_FROM     Object was moved from watched folder
  IN_MOVED_TO       Object was moved to   watched folder
  IN_CREATE         Object was created
  IN_DELETE         Object was deleted
  IN_DELETE_SELF    Watched object was deleted
  IN_MOVE_SELF      The watched object was moved
  IN_UNMOUNT        Backing FS was unmounted
  IN_DONT_FOLLOW    Don't follow symlinks


=head3 INotify groups

  IN_CLOSE   IN_CLOSE_WRITE | IN_CLOSE_NOWRITE 
  IN_MOVE    IN_MOVED_FROM | IN_MOVED_TO

  all        IN_ALL_EVENTS
  access     IN_ACCESS | IN_OPEN
  read       IN_OPEN
  edit       IN_MODIFY
  write      IN_MODIFY | IN_CREATE | IN_DELETE | IN_DELETE_SELF |
             IN_MOVED_FROM | IN_MOVED_TO | IN_MOVE_SELF
  closerw    IN_CLOSE_WRITE
  closero    IN_CLOSE_NOWRITE
  close      IN_CLOSE


=head2 CONFIGURATION

The format is standard ini configuration, with support of variables.


=head3 Configuration variables

The variables are under the form of ${varname} or ${section/varname}
You can reference the current section with section name "self"

  ; Simple "value1"
  globalkey1:  value1

  ; Expand to foobar_value2_snafubar
  globalkey3:  foobar_${section1/sec1key1}_snafubar

  [section1]
  sec1key1:   value2
  ; refers to global section (value1)
  sec1key2:   ${globalkey1}
  ; refers to current section (value2)
  sec1key3:   ${self/sec1key1}


=head3 Syntax, sections and values

In the following documentation, we use uppercase names to reflect parts you
must change. Their name describes their meaning.

Some values are expected to be within a certain range of values

  int    A signed number from 0 to +9007199254740992
  bool   0 (false) or 1 (true)

Special names
  PATH   A path (absolute or relative) to an element in the local FS
  REGEX  A PECL regular expression
  EXEC   An executable file path, or an element in section [watcher.alias.ID]
  MASK   An Inotify constant or an Inotify alias. 
         Can be 

Mandatory and repeatable elements

Each configuration key can be mandatory or optionnal, repeatable or unique.
The following symbols marks these requirements :
     : optionnal and unique
  *  : mandatory
   + : repeatable
  *+ : mandatory and repeatable


=head3 Section [include]

Use to include other files into the current configuration.
The path of these included files are relative to the current configuration file.

Available keys
  before:      + FILEPATH
  after:       + FILEPATH

=head3 Section [watcher.conf]

Global configuration variables.


=head3 Section [watcher.paths.WATCHERID]

Main configuration section. Defines the paths to be watched.

Available keys
  path:       *  PATH
  recurse:    *  1|0
  mask:       *  MASK [+ MASK...]
  masktmout:     int
  watchonly:   + REGEX
  watchnot:    + REGEX
  precheck:    + EXEC
  postcheck:   + EXEC
  onfailure:   + EXEC
  onsuccess:   + EXEC


=head3 Section [watcher.alias.ALIASNAME]

Available keys
  exec:       *  EXEC


Aliases to be used in watcher event.


=head1 CONTACT

=head1 AUTHOR

Adrien Mahieux <adrien.mahieux@gmail.com>

=head1 BUGS AND LIMITATIONS

You can open a ticket under Redmine:

  http://dev.mahieux.net/redmine/


