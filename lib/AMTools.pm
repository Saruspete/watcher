package AMTools;


###########################################################
# AMTools : Set of tools for my projects
#
# Licence : GNU GPLv3. See Licence.txt
#
###########################################################


use strict;
use base ("Exporter");

use FindBin;
use POSIX qw(strftime);
use Config::Std;
use File::Basename;
use Data::Dumper;


# Export utils functions
our @EXPORT = ('log_error', 'log_warning', 'log_info', 'log_debug',
				'lock_acquire', 'lock_release',
				'module_dynload', 
				'arrayize', 'push_unique');




# ##################################################################
# Log functions
# ##################################################################

my $_esc="";
my %COLORS = (#{{{
	'_BG_BLACK' => $_esc . '[40m',
	'_BG_BLUE' => $_esc . '[44m',
	'_BG_CYAN' => $_esc . '[46m',
	'_BG_DEFAULT' => $_esc . '[49m',
	'_BG_GREEN' => $_esc . '[42m',
	'_BG_LBLACK' => $_esc . '[48;5;8m',
	'_BG_MAGENTA' => $_esc . '[45m',
	'_BG_RED' => $_esc . '[41m',
	'_BG_WHITE' => $_esc . '[47m',
	'_BG_YELLOW' => $_esc . '[43m',
	'_FG_BLACK' => $_esc . '[30m',
	'_FG_BLUE' => $_esc . '[34m',
	'_FG_CYAN' => $_esc . '[36m',
	'_FG_DEFAULT' => $_esc . '[39m',
	'_FG_GREEN' => $_esc . '[32m',
	'_FG_MAGENTA' => $_esc . '[35m',
	'_FG_RED' => $_esc . '[31m',
	'_FG_WHITE' => $_esc . '[37m',
	'_FG_YELLOW' => $_esc . '[33m',
	'_BOLD' => $_esc . '[1m',
	'_RESET' => $_esc . '[0m',
	'_UNDERLINE' => $_esc . '[4m',
);#}}}

my $_log_color = 1;
my $_log_offset = 0;
my $_log_level = \$main::opt_verbose;
my $_log_display = \$main::opt_verbose;
my $_log_filehandle;
my $_log_filename = $0;
#$_log_filename =~ s/(.+\/)/\2/;
# TODO: FindBin : remove and call mail::rootpath
my $_log_file = "$FindBin::Bin/../var/log/$FindBin::Script.log";
open ($_log_filehandle, '>>', $_log_file);

sub _logwrite {
	my ($type, $tag, $text) = @_; 
	
	# default head: logtype
	my $head = sprintf("%-6s:", $type); 

	# Colorize the header 
	if ($_log_color) {
		if ($type eq 'LOG') {
			#$head = sprintf("%s%s%s%s", $COLORS{'_FG_WHITE'}, $COLORS{'_BG_GREEN'}, $head, $COLORS{'_RESET'});
			$head = $COLORS{'_FG_WHITE'}.$COLORS{'_BG_GREEN'}. $head .$COLORS{'_RESET'};
		}
		elsif ($type eq 'ERR') {
			#$head = sprintf("%s%s%s%s", $COLORS{'_FG_WHITE'}, $COLORS{'_BG_RED'}, $head, $COLORS{'_RESET'});
			$head = $COLORS{'_FG_WHITE'}.$COLORS{'_BG_RED'}. $head .$COLORS{'_RESET'};
		}
		elsif ($type eq 'WAR') {
			#$head = sprintf("%s%s%s%s", $COLORS{'_FG_BLUE'}, $COLORS{'_BG_YELLOW'}, $head, $COLORS{'_RESET'});
			$head = $COLORS{'_FG_BLUE'}.$COLORS{'_BG_YELLOW'}. $head .$COLORS{'_RESET'};
		}
		elsif ($type =~ m/^DBG/) {
			#$head = sprintf("%s%s%s%s", $COLORS{'_FG_WHITE'}, $COLORS{'_BG_BLUE'}, $head, $COLORS{'_RESET'});
			$head = $COLORS{'_FG_WHITE'}.$COLORS{'_BG_BLUE'}. $head .$COLORS{'_RESET'};
		}
	}
	
	my $strnow = strftime("[%y/%m/%d_%H:%M:%S]", localtime);
	my $strtype = "[$tag]" . ("  " x $_log_offset);
	
	# Output display. Errors or verbosity requested
	if ($tag eq 'ERR' || $$_log_display) {
		foreach my $line (split(/\n/, $text)) {
			print STDERR "${head}${strtype} $line\n";
		}
	}
	
	# File logging
	if ($_log_filehandle) {
		foreach my $line (split(/\n/, $text)) {
			print $_log_filehandle "${head}${strnow}${strtype} $line\n";
		}
	}


}

sub log_error {
	my ($text) = @_;
	my @call = caller(1);
	my $tag = $call[1].":".$call[2]."::".$call[3];
	_logwrite('ERR', $tag, $text);
}

sub log_warning {
	my ($text) = @_;
	my @call = caller(1);
	_logwrite('WAR', $call[3], $text);
}

sub log_info {
	my ($text) = @_;
	my @call = caller(1);
	_logwrite('LOG', $call[3], $text);
}

sub log_debug {
	my ($text, $lvl) = @_;

	$lvl = 1 if !$lvl;
	
	# If lower level, don't display
	# Adding 1 for displaying, 1 for debug
	if ($lvl+1 > $$_log_level) {
		return;
	}

	my @call = caller(1);
	_logwrite("DBG($lvl)", $call[3], $text);
}


# ##################################################################
# Configuration functions
# ##################################################################

# This config is a local buffer for conf_expand
my %config;
my %config_static;

sub conf_write {
#	write_config 
}

sub conf_expand {
	my ($sec, $key, $currsec, $idx) = @_;
	# Format : ${section/key}
	# or	 : ${key}
	# or	 : ${self/key}
	my $regvar = '\${(?:(\w*)/)?(\w+)}';
	
	
	# Special keyword 'self' referring to current section
	if ($sec eq 'self') {
		$sec = $currsec;
	}

	if (defined $config{$sec} && defined $config{$sec}{$key}) {
		
		# Copy to speedup replacement
		my $val = \$config{$sec}->{$key};
		
		
		# Special case : ARRAY
		if ( ref $$val eq 'ARRAY' ) {
			# If we have an ID, assume this is wanted, and replace the current
			# val by the one at the asked index
			if ( defined $idx ) {
				$val = \@{$config{$sec}->{$key}}[$idx];
			}
			# without index, we are called from conf_expand (or a dumb sub)
			# We don't replace array vars, only scalar. Error.
			else {
				log_warning('Cannot make reference to an array in config');
				return;
			}
		}
		
		
		# If we have another var in this key, expand it too
		if ($$val =~ m/$regvar/) {
			$$val =~ s/$regvar/conf_expand($1,$2,$sec)/ge;
		}
		
		# Return expanded (or simple string) value
		return $$val;
	}
	else {
		log_warning("Conf element {$sec}{$key} doesnt exists");
	}
}

sub conf_load {
	
	my ($conf_path, $mergeglobal) = @_;
	my %config_local;
	
	# Read config from Config::Std
	read_config $conf_path => %config_local;
	
	# Include files
	if (defined($config_local{include})) {
		foreach my $file ($config_local{include}{before}) {
			$file = dirname($conf_path).'/'.$file;

			# Merge the resulting config into the local config
			my %config_included = conf_load($file, $mergeglobal);
			@config_local{keys %config_included} = values %config_included;

		}
		delete $config_local{include}{before};
	}
	
	
	# Merge with the previous configurations if needed
	if ($mergeglobal) {
		%config = %config_static;
		@config{keys %config_local} = values %config_local;
	}
	else {
		%config = %config_local;
	}
	
	
	# Process our var replacement
	foreach my $sec (keys %config_local) {
		foreach my $key (keys %{$config{$sec}}) {
			
			# Scalar
			if ( ref $config{$sec}{$key} eq '' ) {
				$config_local{$sec}{$key} = conf_expand($sec, $key, $sec);
			}
			# Array, add the index arg
			elsif ( ref $config{$sec}{$key} eq 'ARRAY' ) {
				for my $idx (0 ..  $#{$config{$sec}{$key}}) {
					$config_local{$sec}{$key}[$idx] = conf_expand($sec, $key, $sec, $idx);
				}
			}
		}
	}
	
	# Save these results
	if ($mergeglobal) {
		%config_static = %config;
	}
	
	
	# Include files
	if (defined($config_local{include})) {
		foreach my $file ($config_local{include}{after}) {
			$file = dirname($conf_path).'/'.$file;

			# Merge the resulting config into the local config
			my %config_included = conf_load($file, $mergeglobal);
			@config_local{keys %config_included} = values %config_included;

		}
		delete $config_local{include};
	}

	return \%config_local;
}


# ##################################################################
# Utils
# ##################################################################

sub normalize_spaces {
	my ($str) = @_;
	return '' if (!$str);

	# Trim the spaces
	$str =~ s/(^\s*)|(\s*$)//;

	# Remove the newlines
	chomp($str);

	# Change the tabs
	$str =~ s/\t/ /g;

	# Supress the multiple spaces
	$str =~ s/\s+/ /g;

	return $str;
}


sub module_dynuse {
	my $modname = shift;
	# Load the definition module
	use lib '.';
	eval "use $modname";
	if ($@) {
		log_debug("Unable to load $modname : $@");
		return 0;
	}
	return 1;
}


sub module_dynload {
	my ($modname, $args) = @_;
	# Load the definition module
	if (module_dynuse($modname)) {
		return $modname->new($args);
	}
	return;
}


# Transform multiple output to a simple array
sub arrayize{
	my @arrays = @_;
	my @ret;
	foreach $a (@arrays) {
		my $r = ref($a);
		
		# Scalar
		if ($r eq '') {           @ret = (@ret, ($a));  }
		# Refs
		elsif ($r eq 'SCALAR') {  @ret = (@ret, ($$a)); }
		elsif ($r eq 'ARRAY')  {  @ret = (@ret, @$a);   }
		else {
			print "Unknown ref ".$r."\n";
		}
	}
	return \@ret;
}

sub push_unique {
	my ($array, $value) = @_;
	if (!grep $_ eq $value, @$array) {
		push @$array, $value;
	}
	return $array;
}

# ##################################################################
# Synchronization
# ##################################################################

sub lock_acquire {
	my ($lockname, $timeout) = @_;

	# If a timeout is set, use an alarm
	if ($timeout) {
		
	}
	
#	for (my $i=0; $i<$tries
}

sub lock_release {
	my ($lockname) = @_;

}


# ##################################################################
# Binaries execution
# ##################################################################

sub execute_find {
	my $cmd = shift;
	my @paths = split(/:/, $ENV{PATH});

	# Add some generic paths
	push (@paths, "/sbin");
	push (@paths, "/usr/sbin");
	push (@paths, "/usr/local/bin");
	push (@paths, "/usr/local/sbin");

	foreach my $path (@paths) {
		my $testpath = $path.'/'.$cmd;
		if (-x $testpath) {
			return $testpath;
		}
	}
	#logwarning('Utils:execute_find', "Unable to find path for $cmd");
	return $cmd;
}


sub execute_asroot {
	my ($cmd) = $_[0];
	if ($> eq 0) {
		return execute_find($cmd);
	}
	return execute_find("sudo")." ". execute_find($cmd);
}


1;
