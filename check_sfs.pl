#!/usr/bin/env perl
#
#  check_sfs.pl -  This file monitors the state of the SFS cluster. 
#
#
#
use strict;

#
# Globals
###########

my (%files, %email);

$files{'log'} = "/var/log/sfs.log"; # Log file
$files{'pid'} = "/var/run/check_sfs.pid"; # PID
$email{'adrs'} = "sysadm\@loni.ucla.edu"; # Email

my $debug = 0;
my $shutdown = 0;
my $daemon = 0;

# Command line args
foreach(@ARGV) {
    if(/^\-d$/) { $daemon = 1; }
    if(/^\-v$/) { $debug = 1; }
    if(/^\-s$/) { $shutdown = 1; }
}

#
# Subroutines
################

# Shutdown the daemon
sub shutdown_daemon {
    open(PID, $files{'pid'});
    my $pid = <PID>;
    close(PID);
    chomp $pid;
    if($pid) {
        print "Killing process $pid\n";
    	&write_log("Killing process $pid\n");
    	sleep(1);
    	system("kill $pid");
    }
    else {
        &write_log("No process found \n");
        print "No process found\n";
    }
    exit;
}

# Execute the program
sub execute {
    #Interval ( in seconds) to check for mounts
    my $interval = shift;
    while(1) {
        &fs_check();
        sleep($interval);
    }
}

# Logging
sub write_log {
    my $message = shift;
    open(LOG, ">>$files{'log'}");
    print LOG format_time(time) . ": $message\n";
    close(LOG);
}

# Format the time
sub format_time {
    my($sec, $min, $hour, $mday, $mon) = localtime($_[0]);
    my($fmt_mon) = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec')[$mon];
    return(sprintf("%s %d %.2d:%.2d:%.2d", $fmt_mon, $mday, $hour, $min, $sec));
}

# Email - Make sure to change the email address and subject
sub email {
    my $body = shift;
    my $subject = "[loni-sys] Ardon issues";
    
    # Send Email
    system("echo \"$body\" | mailx -s \"$subject\" $email{'adrs'}");
}

# Compare the Arrays
sub compare_arrays {
    my ($first, $second) = @_;
    return 0 unless @$first == @$second;
    for (my $i = 0; $i < @$first; $i++) {
        return 0 if $first->[$i] ne $second->[$i];
    }
    return 1;
}

# Create a mutidimensional array of /proc/sf/sfs
sub proc_check {
    my @s;
    open(PROC,"</proc/fs/sfs") || do 
        { 
            &write_log("Error opening /proc/fs/sfs.");
			printf("Error opening /proc/fs/sfs.");
			exit;
        };
    while (<PROC>) {
        if(/^[\n\t\ ]+$/) { next; } # skip blank lines
	if(/^#/) { next; }   # skip comments
	push @s, [split(/[ \t]+/)]; # create multidimensional array
    }
    close(PROC);
    return @s;	
}

# Return all sfs mounts in fstab
sub fstab_check {
    my @fstab;
    open(FSTAB,"</etc/fstab") || do 
        { 
            &write_log("Error opening /etc/fstab.");
			printf("Error opening /etc/fstab.");
			exit;
        };
    while (<FSTAB>) {
        if(/^[\n\t\ ]+$/) { next; } # skip blank lines
        if(/^#/) { next; }   # skip comments
        my @s = split(/[ \t]+/); 
        if (defined($s[2]) && ($s[2] eq "sfs")) {
            @fstab = (@fstab,$s[1]);
	}
    }
    close(FSTAB);
    return @fstab;	
}

# Check for loaded sfs modules
sub modules_check {
    my $found = 0;
    my $hostname = `hostname`;
    chomp $hostname;
    open(MODULES,"</proc/modules") || do
	{
        	&write_log("Error opening /proc/modules.");
	        printf("Error opening /proc/modules.");
	        exit;
	};
    while (<MODULES>) {
        my @s = split(/[ \t]+/);
        if (defined($s[0]) && ($s[0] eq "sfs")){
            $found = 1;
            last;
        }
    }
    close(MODULE);
    if ($found == 0) {
        &write_log ("SFS not found in /proc/modules rebooting $hostname");
        &email ("SFS not found in /proc/modules rebooting $hostname");
	sleep(2);
	exec('reboot') unless $debug;
    }	
}

# Check to make sure the count of /proc/fs/sfs is changing
sub sfscount_check {
    my @sfscount_t1 = @_;
    my @sfscount_t2;
    my @proc = &proc_check;
    my $hostname = `hostname`;
    chomp $hostname;
    for(my $i = 0; $i <= $#proc; $i++){
        push(@sfscount_t2, $proc[$i][4]);
    }
# compare the two arrays
    my $sfscount_are_eq = &compare_arrays(\@sfscount_t1, \@sfscount_t2);
    printf("comparing @sfscount_t1 to @sfscount_t2 \n") if $debug;
          
    if ($sfscount_are_eq) {
        &write_log("The SFS count is equal, trying again in 8 seconds");
        sleep(8);
        @proc=();
        @sfscount_t2=();
        my @proc = &proc_check;
        for(my $i = 0; $i <= $#proc; $i++){
            push(@sfscount_t2, $proc[$i][4]);
        }
        my $sfscount_are_eq_t2 = &compare_arrays(\@sfscount_t1, \@sfscount_t2);
        if ($sfscount_are_eq_t2) {
            &write_log("SFS count is the same on $hostname rebooting $hostname now.");
            &email("SFS count is the same on $hostname rebooting $hostname now.");
            sleep(2);
            exec('reboot') unless $debug;
        }
    }	
}

# Filesystem check
sub fs_check {
    my $hostname = `hostname`;	
    my (%seen, @proc, @procmount, @sfscount, @fstab, @unmounted_filesystems);
    chomp $hostname;
# Test to make sure modules are loaded.
    &modules_check();
# Get values from proc and fstab
    my @fstab = &fstab_check();
    my @proc = &proc_check();
# Pull needed values from the proc multidimensional array
    for(my $i = 0; $i <= $#proc; $i++){
        push(@procmount, $proc[$i][7]);
    }
    for(my $i = 0; $i <= $#proc; $i++){
        push(@sfscount, $proc[$i][4]);
    }
#  Compare mounting arrays
    foreach(@procmount) {$seen{$_} = 1}
    foreach(@fstab) {
        unless ($seen{$_}) {
            push(@unmounted_filesystems, $_)
        }
    }
    foreach(@unmounted_filesystems){ 
    	&write_log("Mount point(s) $_ is down on $hostname rebooting $hostname now.");
        &email("Mount point(s) $_ is down on $hostname rebooting $hostname now.");
        sleep(2);
        exec('reboot') unless $debug;
    }
# Sleep 5 seconds to allow for the sfs count to update.   
    sleep(10);
    &sfscount_check(@sfscount);
}
#
# Function
#############

if($shutdown) {
    &shutdown_daemon();
    exit;
}

if($daemon) {
    my $interval = "5";
    FORK: {
        if(my $pid = fork) {
            &write_log("Starting check_sfs.pl ($pid)");
            print "Starting check_sfs.pl ($pid) \n" if $debug;
            exit;
	}
	elsif (defined $pid) {
            &write_log("Child started ($$)");
            open(PIDFILE, ">" . $files{'pid'} ) || do 
                {
                    &write_log("Cannot write to $files{'pid'}, exiting");
                    print "Cannot write to $files{'pid'}, exiting \n" if $debug;
                    exit;
                };
                    print PIDFILE "$$";
		    close(PIDFILE);
                    &execute($interval);
                    &write_log("Execute loop closed, process ending");
                    print "Execute loop closed, process ending \n" if $debug;
    	}
	elsif ($! =~ /No more process/) {
            sleep 5;
	    redo FORK;
	}
	else {
            die 'Cannot fork: $!\n';
	}
    }
}
else {
    &fs_check();
    exit;
}