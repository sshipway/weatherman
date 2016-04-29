#!/usr/bin/perl
# vim:ts=4
#
# Helper program for weatherman configuration frontend: Version 3.0
#
# Expects parameters:
# C : command
# A : argument
# F : uploaded file name(optional)
# P : password (if used)
#
# Returns: either text/plain or image.  In text mode, firstline is OK or ERROR
#          if ERROR, then second line is a friendly error message
#          if OK, then next line starts reply text depending on command
#
# Commands:
# LISTCFG : list all existing config files
# FETCHCFG <filename> : return contents of file
# SAVECFG <filename> : save uploaded file to filename
# FETCHIMG <name> : fetch this image file, if possible
# LISTLINKS <devicekey> : list TARGET\tBANDWDTH\tDesc from the MRTG .cfg file
# IDENTIFY <hostname> : try and identify the device key for this hostname
# NODETARGET <devicekey> : try to identify a TARGET for node status monitoring
# LISTIMAGES
# LISTICONS
# LISTSTATUSICONS
# SAVEICON <filename>
# SAVEIMAGE <filename>
# SAVEHTML <filename>
#
# This is the helper CGI to install on the weathermap server so that the
# weatherman configuration tool will work.
#
# Steve Shipway 2007
#
# 0.2 : initial MRTG/routers2 setup
# 1.0 : Added password control
# 1.1 : Added stubs for cacti support
# 2.3 :
# 3.0 : Support for weathermap 0.9

use strict;
use CGI;

### YOU MUST CONFIGURE THESE LINES CORRECTLY
my( $WEATHERMAP ) = "/u01/weathermap2"; # location of weathermap 
my( $ICONS      ) = "icons";           # subdir for icons
my( $SCALE      ) = "scale";           # subdir for scale icons, under $ICONS
my( $IMAGES     ) = "images";          # subdir for images
my( $CONFIG     ) = "configs";         # subdir for configs
my( $DOMAIN     ) = "auckland.ac.nz";  # our domain, if we want to define it
my( $BACKUP     ) = 1;                 # set to 1 to make backups of files
my( $AUTHPW     ) = "cheshirecat";     # set to a password if you want to have 
                                       # one.  If set, must match the one in 
                                       # the editor
my( $HTMLDIR    ) = "/u01/www/html/weathermap2";
                                       # where the maps are generated

## These are specific to which graphing tool you use, and tells the helper
## how to obtain the data and what URLs should be used.
# These are for MRTG/routers2
my( $POPUPGRAPH ) = 'https://mrtg.auckland.ac.nz/cgi-bin/routers2.cgi?page=image&xgtype=ds&xgstyle=x&rtr=%CFGFILE%&if=%TARGET%';
my( $NODEINFO   ) = 'https://mrtg.auckland.ac.nz/cgi-bin/routers2.cgi?xgtype=d&rtr=%CFGFILE%&if=__none';
my( $LINKINFO   ) = 'https://mrtg.auckland.ac.nz/cgi-bin/routers2.cgi?xgtype=d&rtr=%CFGFILE%&if=%TARGET%';
my( $RRDPATH    ) = "/u01/rrdtool";    # default dir for RRD files
my( $CONFPATH   ) = "/u01/mrtg/conf";  # root of MRTG config tree
my( $CFGSUBDIRS ) = "*";            # Shell wildcard matching MRTG subdirs
my( $DATABASE, $DBHOST, $DBUSER, $DBPASSWORD, $DBPORT ); # no database for MRTG
## These are for MRTG/mrtg-rrd : TBD
## These are for MRTG/14all : TBD
## These are for Cacti : NOT YET WORKING : TBD
#my( $POPUPGRAPH ) = '/cacti/graph_image.php?local_graph_id=%TARGET%&rra_id=0&graph_nolegend=true&graph_height=100&graph_width=300';
#my( $NODEINFO   ) = '';
#my( $LINKINFO   )= '/cacti/graph_image.php?local_graph_id=%TARGET%&rra_id=all';
#my( $DATABASE   ) = "cacti";
#my( $DBHOST     ) = "localhost";
#my( $DBUSER     ) = "cactiuser";
#my( $DBPASSWORD ) = "cacti";
#my( $DBPORT     ) = 3306;
#my( $RRDPATH    ) = "/var/www/html/cacti/rra";  
#my( $CONFPATH, $CFGSUBDIRS );
#
## Node Status support
## If you use Node status (v0.9 and later), then uncomment one of these 
my( $TARGETMODE ) = '';
#my( $TARGETMODE ) = 'nagios';
# Anything extra you need to strip from your hostname for it to be the Nagios
# hostname (usually, this will be blank, but UoA do some silly stuff)
my( $STRIPEXTRA ) = "";

### END

###########################################################################
my($VERSION) = '3.005';
my($CMD,$ARG);
my($q) = new CGI;
###########################################################################
sub do_error($) {
	print $q->header('text/plain');
	print "ERROR\n".$_[0]."\n";
	exit(0);
}
###########################################################################
sub do_listcfg($$)
{
	my($path,$pat) = @_;
	my(@allfiles);
	opendir DIRP, $path or 
		do_error("Unable to read directory: $!");
	@allfiles = grep !/^\./,readdir DIRP;
	closedir DIRP;
	print $q->header('text/plain');
	print "OK\n";
	foreach ( @allfiles ) { print "$_\n" if($_ =~ /$pat/ and -f "$path/$_"); }
	exit 0;
}
sub do_fetchcfg($) 
{
	open CONF, "<$WEATHERMAP/$CONFIG/".$_[0] or
		do_error("Unable to open ".$_[0]." for reading: $!");
	print $q->header('text/plain');
	print "OK\n";
	while ( <CONF> ) { print; }
	close CONF;
}
sub do_fetchimg($)
{
	my($f) = $_[0];
	$f = "$WEATHERMAP/$f" if( -f "$WEATHERMAP/$f" );
	$f = "$WEATHERMAP/$IMAGES/$f" if( -f "$WEATHERMAP/$IMAGES/$f" );
	$f = "$WEATHERMAP/$ICONS/$f" if( -f "$WEATHERMAP/$ICONS/$f" );
	open IMG, "<$f"  or
		do_error("Unable to open $f for reading: $!");
	binmode stdout;
	binmode IMG;
	print $q->header('image/png');
	while ( <IMG> ) { print; }
	close IMG;
}
# These are to provide a selectablelist of interfacekey,bandwidth,desc for a
# particular devicekey
sub do_listlinks_mrtg($)
{
	my($line,$target,$bandwidth,$desc);
	open CFG, "<$CONFPATH/".$_[0] or
		do_error("Unable to open that file: $!");
	$target = "";
	print $q->header('text/plain');
	print "OK\n";
	($bandwidth, $desc) = (0,"");
	while ( $line = <CFG> ) {
		chomp $line;
		if( $line =~ /^\s*Title\s*\[(\S+)\]\s*:\s*(\S.*)/ ) {
			if($target and ($1 ne $target)) {
				print "$target\t$bandwidth\t$desc\n" if($bandwidth);
				$bandwidth = 0;
			}
			($target,$desc) = ($1,$2);
		} elsif( $line =~ /^\s*MaxBytes\s*\[(\S+)\]\s*:\s*(\d+)/ ) {
			if($target and ($1 ne $target)) {
				print "$target\t$bandwidth\t$desc\n" if($bandwidth);
				$desc = $1;
			}
			($target,$bandwidth) = ($1,($2*8));
			if($bandwidth>1024000) {
				$bandwidth = (int ($bandwidth/1024000))."M" ;
			} elsif($bandwidth>1024) {
				$bandwidth = (int ($bandwidth/1024))."K" ;
			}
		} elsif( $line =~ /^\s*routers2?\.cgi\*Short(Name|Descr?(iption)?)\s*\[(\S+)\]\s*:\s*(\S.*)/ ) {
			if($target and ($3 ne $target)) {
				print "$target\t$bandwidth\t$desc\n" if($bandwidth);
				$bandwidth = 0;
			}
			($target,$desc) = ($3,$4);	
		}
	}
	close CFG;
	print "$target\t$bandwidth\t$desc\n" if($target and $bandwidth);
	exit 0;
}
sub do_linklinks_cacti($)
{
my($dataid);
my $SQL = "select graph_templates_item.local_graph_id, title_cache FROM graph_templates_item,graph_templates_graph,data_template_rrd where graph_templates_graph.local_graph_id = graph_templates_item.local_graph_id  and task_item_id=data_template_rrd.id and local_data_id=$dataid;";
}
sub do_listlinks($)
{
	do_listlinks_mrtg($_[0]) if($CONFPATH);
	do_listlinks_cacti($_[0]) if($DATABASE);
	do_error("Unable to get list of links");
}
# These are to identify a particular device key from a (partial) hostname
sub do_identify_mrtg($)
{
	my($k) = $_[0];

	$k =~ s/\.cfg$//;
	$k =~ s/\.$DOMAIN$//;
	foreach my $f ( "$CONFPATH/$k.cfg", "$CONFPATH/$k.conf", 
		glob( "$CONFPATH/$k*.cfg" ),
		glob( "$CONFPATH/$k*.conf" ),
		glob( "$CONFPATH/$CFGSUBDIRS/$k*.cfg" ),
		glob( "$CONFPATH/$CFGSUBDIRS/$k*.conf" )
 	) {
		if( -f $f ) {
			$f =~ s#^$CONFPATH/##;
			print $q->header('text/plain');
			print "OK\n$f\n";
			exit 0;
		}
	}
	do_error("Unable to find that name");
	exit 0;
}
sub do_identify_cacti($)
{
	my($sql) = "select data_template_data.local_data_id, data_template_data.name_cache, data_template_data.active, data_template_data.data_source_path from data_local,data_template_data,data_input,data_template where data_local.id=data_template_data.local_data_id and data_input.id=data_template_data.data_input_id and data_local.data_template_id=data_template.id order by name_cache;";
}
sub do_identify($)
{
	do_identify_mrtg($_[0]) if($CONFPATH);
	do_identify_cacti($_[0]) if($DATABASE);
	do_error("Unable to get list of nodes");
}

# This will save the $FILE file into the argument filename in configs
sub do_savecfg($) 
{
	my($f) = "$WEATHERMAP/$CONFIG/".$_[0];
	my($fh,$i);

	# check uploaded file
	$fh = $q->upload('F');
	do_error("No valid file upload was sent!") if(!$fh);

	# first, make backup if necessary
	if($BACKUP and -f $f) {
		$i = 0;
		while( -f "$f.$i" ) { $i += 1; }
		rename $f, "$f.$i" or do_error("Unable to create backup: $!");
	}
	open CONF,">$f" or do_error("Unable to create file: $!");
	print CONF "# Configuration uploaded by ["
		.$q->remote_user()."] on ".$q->remote_host()." at "
		.localtime()."\n";
	while( <$fh> ) { print CONF; }
	close CONF;
	close $fh;
	print $q->header('text/plain');
	print "OK\n";
}
sub do_savefile($) {
	my($f) = $_[0];
	my($fh,$i);

	# check uploaded file
	$fh = $q->upload('F');
	do_error("No valid file upload was sent!") if(!$fh);

	open F,">$f" or do_error("Unable to create file: $!");
	binmode F;
	binmode $fh;
	while( <$fh> ) { print F; }
	close F;
	close $fh;
	print $q->header('text/plain');
	print "OK\n";
}
sub do_fetchfile($) {
	open CONF, "<$HTMLDIR/".$_[0] or
		do_error("Unable to open ".$_[0]." for reading: $!");
	print $q->header('text/plain');
	print "OK\n";
	while ( <CONF> ) { print; }
	close CONF;
}
# Give config information
sub do_showconfig()
{
	print $q->header('text/plain');
	print "OK\n";
	print "confpath\t$CONFPATH\n";
	print "icons\t$ICONS\n";
	print "scale\t$SCALE\n";
	print "images\t$IMAGES\n";
	print "rrdpath\t$RRDPATH\n";
	print "popupgraph\t$POPUPGRAPH\n";
	print "nodeinfo\t$NODEINFO\n";
	print "linkinfo\t$LINKINFO\n";
	print "version\t$VERSION\n";
#	print "htmldir\t$HTMLDIR\n";
	print "domain\t$DOMAIN\n";
	print "targetmode\t$TARGETMODE\n";

}

# Work out a target link for a node status, if possible
sub do_target($)
{
	my($key) = $_[0];

	print $q->header('text/plain');
	if($DATABASE) { # Cacti
		print "OK\n";
		print "cactihost:$key\n";
		return;
	} elsif($TARGETMODE eq 'nagios' and $key=~/\.(cfg|conf)$/) {
		$key =~ s/\.(cfg|conf)$//;               # strip suffix
		$key =~ s/^.*[\/\\]//;                   # strip path name
		$key =~ s/\.$DOMAIN$// if($DOMAIN);      # strip domain name
		$key =~ s/$STRIPEXTRA// if($STRIPEXTRA); # strip domain name
		print "OK\nnagios:$key\n";
		return;
	} elsif($TARGETMODE eq 'nagios') {
		print "OK\n\n"; # respond with none as this is not a MRTG cfg file
		return;
	}
	print "ERROR\nNot supported by helper\n";
	return;
}
###########################################################################

$CMD = $q->param('C');
$ARG = $q->param('A');
if($AUTHPW) {
	if(! $q->param('P') or $q->param('P') ne $AUTHPW) {
		do_error("Authentication failed");
	}
}

do_error("No command specified") if(!$CMD);

if($CMD =~ /^LISTCFG/i) {
	do_listcfg("$WEATHERMAP/$CONFIG",'\.(cfg|conf|map)$');
} elsif($CMD =~ /^FETCHCFG/i) {
	do_error("Map '$ARG' was not found") 
		if(! -r "$WEATHERMAP/$CONFIG/$ARG" );
	do_fetchcfg($ARG);
} elsif($CMD =~ /^SAVECFG/i) {
	do_error("You must give a valid map name") if(!$ARG or $ARG=~/\//);
	do_savecfg($ARG);
} elsif($CMD =~ /^SAVEICON/i) {
	do_error("You must give a valid file name") if(!$ARG or $ARG=~/\//);
	do_error("Illegal filename") if( $ARG=~/\.\./);
	do_error("Icons must be 40x40 PNG files") if($ARG !~ /\.png$/);
	do_savefile("$WEATHERMAP/$ICONS/$ARG");	
	# we should also check the file size... and that it is a PNG
} elsif($CMD =~ /^SAVEIMAGE/i) {
	do_error("You must give a valid file name") if(!$ARG or $ARG=~/\//);
	do_error("Illegal filename") if( $ARG=~/\.\./);
	do_error("Background images must be PNG files") if($ARG !~ /\.png$/);
	do_savefile("$WEATHERMAP/$IMAGES/$ARG");
	# we should also check the file size... and that it is a PNG
} elsif($CMD =~ /^SAVEHTML/i) {
	do_error("You must give a valid file name") if(!$ARG);
	do_error("Illegal filename") if( $ARG=~/^[\.\\\/]/);
	do_error("Not an HTML file") if( $ARG!~/\.html?$/);
	do_savefile("$HTMLDIR/$ARG");
} elsif($CMD =~ /^FETCHHTML/i) {
	do_error("Illegal filename") if( $ARG=~/\.\./);
	do_error("Illegal filename") if( $ARG=~/[\\\/]/);
	do_error("File '$ARG' was not found") 
		if(! -r "$HTMLDIR/$ARG" );
	do_fetchfile($ARG);
} elsif($CMD =~ /^LISTICONS/i) {
	do_listcfg("$WEATHERMAP/$ICONS",'\.png$');
} elsif($CMD =~ /^LISTSTATUSICONS/i) {
	do_listcfg("$WEATHERMAP/$ICONS/$SCALE",'[^\d]\.png$');
} elsif($CMD =~ /^LISTSCALEICONS/i) {
	do_listcfg("$WEATHERMAP/$ICONS/$SCALE",'[^\d]\.png$');
} elsif($CMD =~ /^LISTIMAGES/i) {
	do_listcfg("$WEATHERMAP/$IMAGES",'\.png$');
} elsif($CMD =~ /^FETCHIMG/i) {
	do_error("You must give an image name") if(!$ARG);
	do_error("You must give a valid image name") if($ARG=~/\.\./);
	do_fetchimg($ARG);
} elsif($CMD =~ /^LISTLINKS/i) {
	$ARG =~ s/%2F/\//gi if($ARG);
	$ARG =~ s/\+/ /g if($ARG);
	do_error("You must give a valid config file name") 
		if(!$ARG or ! -f "$CONFPATH/$ARG" );
	do_listlinks($ARG);
} elsif($CMD =~ /^IDENTIFY/i) {
	do_error("You must give a device name to identify") if(!$ARG);
	do_identify($ARG);
} elsif($CMD =~ /^SHOWCONFIG/i) {
	do_showconfig();
} elsif($CMD =~ /^NODETARGET/i) {
	do_error("You must give a valid node name") if(!$ARG);
	do_target($ARG);
} else {
	do_error("Command '$CMD' not implemented");
}

exit(0);
