#!/usr/bin/perl -w
# 
#       WeatherMan - editor for weathermap configuration files via helper.cgi interface
#           Steve Shipway 2006 <steve@steveshipway.org>
#               adapted from :
#	Nagiosmap - Visual configuration tool for Nagios map
#		Copyright (C) 2002-2004 Stéphane Urbanovski <s.urbanovski@ac-nancy-metz.fr>
#		adapted from :
#	SaintMap v2.1 - Visual configuration tool for NetSaint
#		Copyright (C) 2000 David Kmoch <David.Kmoch@vslib.cz>
#
#	This program is free software; you can redistribute it and/or modify
#	it under the terms of the GNU General Public License as published by
#	the Free Software Foundation; either version 2 of the License, or
#	(at your option) any later version.
#
#	This program is distributed in the hope that it will be useful,
#	but WITHOUT ANY WARRANTY; without even the implied warranty of
#	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#	GNU General Public License for more details.
#
##################################################
#
# To run this on Windows, you will need:
#     Activeperl 5.8 or above (Activeperl 5.6 doesnt support PNG in Tk)
#     Tk libraries (installed by default with ActivePerl)
#     helper.cgi installed on the machine with MRTG/RRD and Weathermap
#     URL of helper.cgi and any required username/password
#     https libraries, if helper.cgi is on an https URL.  Otherwise not needed.
#     Set options in the next section below, and create temp directory.

##################################################
# These are the only things you need to change:

# URL of helper program: cannot use https unless you have installed
# the SSL module (and the USA refuses to let you have it for Windows, the gits)
my($HELPER) = "http://haruka.itss.auckland.ac.nz/cgi-bin/helper.cgi";
my($USERNAME,$PASSWORD) = ("",""); # only set if needed
# Temporary directory - must exist and be writeable
my($TMP) = 'C:\temp\wman';
# Auth password - if this is set in helper.cgi then it must also be set here
my($AUTHPW) = 'cheshirecat'; 

##################################################
#       NO CHANGES NEEDED BELOW                  # 
##################################################

my ($VERSION)="3.007"; # needs same major ver of helper.cgi

#############################################################
# Registry manipulation stuff so we can store updates.
my $Registry;
use Win32::TieRegistry 0.20 (
    TiedRef => \$Registry,  Delimiter => "/",  ArrayValues => 1,
    SplitMultis => 1,  AllowLoad => 1,
    qw( REG_SZ REG_EXPAND_SZ REG_DWORD REG_BINARY REG_MULTI_SZ
        KEY_READ KEY_WRITE KEY_ALL_ACCESS ),
);
require LWP;
{
	package MyAgent;
	@ISA = qw(LWP::UserAgent);
	sub new {
		my $self = LWP::UserAgent::new(@_);
		$self->agent("WeatherMan/$VERSION");
		$self;
	}
	sub get_basic_credentials {return($USERNAME,$PASSWORD); }
}
use strict;
use Tk;
use Tk::PNG;
use Tk::Dialog;
use Tk::NoteBook;
use Tk::LabEntry;
use Tk::BrowseEntry;

my (%nodes) = ();
my (%links) = ();
my (%global) = ();
my (@fontdefine) = ();
my (@set) = ();
my (%objprop) = ();
my (%rconfig) = ( icons=>"icons" );
my (%scale) = ();
my ($main,$menubar,$canvas,$font);
my ($MODE) = ""; my($linkstart,$linktarget);

my ($GRID_WIDTH,$GRID_HEIGHT,$GRID_STEP)=(800,600,20);
my ($ICON_WIDTH,$ICON_HEIGHT)=(60,50);

# default labels value :
my ($xpos,$ypos,$status)=(0,0,"");
my ($change) = 0;
my ($currentmap) = "";
my ($deficon) = "unknown.png";
my ($actionmenu);
my ($keyx,$keyy,$titlex,$titley,$maptitle,$keytitle,$timeformat,$timex,$timey);
my($titleobj,$keyobj,$timeobj);

my ($ua) = MyAgent->new;

# init temporary directory
mkdir('C:\temp') if(!-d 'C:\temp'); # should really use mkdirpath
mkdir $TMP if( ! -d $TMP );
mkdir "$TMP\\scale" if( ! -d "$TMP\\scale" );
unlink glob( "$TMP/*.png" );
&readregistry;
&loadrconfig;
&init_gui;
MainLoop;
exit 0;

########################### SUBS #################################
sub numerically { return ($a<=>$b); }
sub doalert($) # standard alert popup window
{
	my($msg) = $_[0];
	chomp $msg;
	if($main) {
	$main->Dialog(-title=>"Error",-text=>$msg,-bitmap=>"error",-buttons=>['Ok'])->Show('-global');
	} else {
		print STDERR "\nERROR: $msg\n";
	}

}
sub getreply($$) # param: cmd, arg; return: errormsg, data
{
	my($C,$A)=@_;
	my($url) = "$HELPER?C=$C&A=$A&P=$AUTHPW";
	my($req) = HTTP::Request->new(GET=>$url);
	my($res) = $ua->request($req);
	if(!$res->is_success) {
#		doalert ("HTTP error: ".$res->status_line);
		return ("HTTP error: ".$res->status_line);
	}
	my $data = $res->content;	
	if( $data =~ s/^OK\n// ) { return (0,$data); }
	if( $data =~ s/^ERROR\n// ) { return $data; }
	$data =~ s/\n.*$//;
	return "Unexpected response: '$data'";
}
sub getlist($$)
{
	my( $err, $data ) = getreply( $_[0],$_[1] );
	if($err) {
		# show error message here
		doalert("Failed: ".$err);
		$status = $err;
		return ();
	}
	return () if(!$data);
	return (split /\n/,$data);
}
sub getimage($) # param: imagename; return: errormsg
{
	my($A) = $_[0];
	return 0 if(!$A);
	return 0 if(-f "$TMP/$A"); # already retrieved
	my($url) = "$HELPER?C=FETCHIMG&A=$A&P=$AUTHPW";
	my($req) = HTTP::Request->new(GET=>$url);
	my($res) = $ua->request($req);
	if(!$res->is_success) {
		return ("HTTP error: ".$res->status_line);
	}
	if($res->header('Content-Type') !~ /image/) {
		return $res->content;
	}
	open IMG, ">$TMP/$A" or return "Unable to create file $TMP/$A";
	binmode IMG;
	print IMG $res->content;	
	close IMG;
	return 0;
}
sub loadcfg($)
{
	my( $current ) = "";
	my( $type ) = "";
	my( $rv, $linkinfo, @linkinfo );
	my( $err, $data ) = getreply( "FETCHCFG", $_[0] );
	if($err) {
		# show error message here
		$status = $err;
		doalert($err);
		return $err;
	}
	# now we have the cfg file, so we need to parse it 
	%nodes = ();
	%links = ();
	%global = ();
	$titlex = $titley = $timex = $timey = $keyx = $keyy = 0;
	$maptitle = $keytitle = $timeformat = "";
	$change = 0;
	foreach my $line ( split /\n/,$data ) {
		next if( $line =~ /^\s*#/ );
		if( $line =~ /^NODE\s+(\S+)/ ) {
			$current = $1;
			$type = "NODE";
			$nodes{$current} = {};
			($err,$rv) = getreply('IDENTIFY',$current);
			if($err) {
				$status = "Not able to identify node $current";
			} else {
				chomp $rv;
				$nodes{$current}{_CFGFILE} = $rv;
				$nodes{$current}{_LINKS} = {};
				foreach $linkinfo ( getlist('LISTLINKS',$rv) ) {
					@linkinfo = split /\t/,$linkinfo;
					$nodes{$current}{_LINKS}{$linkinfo[0]} = [@linkinfo];
				}
				
			}
		} elsif( $line =~ /^LINK\s+(\S+)/ ) {
			$current = $1;
			$type = "LINK";
			$links{$current} = {};
		} elsif( $line =~ /^\s+(\S+)\s+(\S.*)/ ) {
			my($k,$v) = ($1,$2);
			if($type eq 'NODE' ) {
				if( $k =~ /POSITION/i ) {
					if( $v =~ /(\d+)\s+(\d+)/ ) {
						$nodes{$current}{_X2d}=$1;
						$nodes{$current}{_Y2d}=$2;
					}
				} elsif( $k =~ /ICON/i ) {
					my($I) = $rconfig{icons};
					if( $v =~ /$I\/(\S+)/ ) {
						$nodes{$current}{$k} = $1;
					} else {
						$nodes{$current}{$k} = $v;
					}
				} else {
					$nodes{$current}{$k} = $v
				}
			} else {
				if( $k =~ /NODES/i ) {
					if( $v =~ /(\S+)\s+(\S+)/ ) {
						$links{$current}{_from}=$1;
						$links{$current}{_to}=$2;
					} else {
						$links{$current}{$k} = $v;
					}					
				} else {
					$links{$current}{$k} = $v;
				}
			}
		} elsif( $line =~ /^(\S+)\s+(\S.*)/ ) {
			my ($k,$v)=($1,$2);
			my $I = $rconfig{images};
			$v =~ s/^$I\/// if($k =~ /BACKGROUND/i);
			if($k =~ /^scale$/i) {
				my(@scale) = split " ",$v;
				my($kk) = "DEFAULT";
				$kk = shift @scale if($scale[0]!~/^\d+\.?\d*$/);
				$scale{$kk}{$scale[0]} = [ @scale ] if(!defined $scale{$kk}{$scale[0]});
			} elsif($k =~ /^fontdefine$/i) {
				push @fontdefine,$v;
			} elsif($k =~ /^set$/i) {
				push @set,$v;
			} else {
				$global{$k} = $v;
			}
		} elsif( $line =~ /^\s*$/ ) {
			# we can skip this
		} else {
			print STDERR "WARNING: Ignoring line '$line'\n";
		}
	}
	# set the global stuff up
	if( defined $global{KEYPOS} and $global{KEYPOS}=~/(\d+)\s+(\d+)\s*(.*)/) {
		($keyx, $keyy, $keytitle) = ($1,$2,$3);
	}
	if( defined $global{TIMEPOS} and $global{TIMEPOS}=~/(\d+)\s+(\d+)\s*(.*)/) {
		($timex, $timey, $timeformat) = ($1,$2,$3);
	}
	if( defined $global{TITLEPOS} and $global{TITLEPOS}=~/(\d+)\s+(\d+)\s*(.*)/) {
		($titlex, $titley, $maptitle) = ($1,$2,$3);
	}
	return 0;
}
sub loadrconfig {
	my($line);
	foreach $line ( getlist('SHOWCONFIG','') ) {
		chomp $line;
		$rconfig{$1}=$2 if($line =~ /^(\S+)\s+(\S.*)$/);
		$status = "Remote configuration loaded.";
	}
	if( $rconfig{version} and (int $rconfig{version})>(int $VERSION)) {
		# this version of the editor is no longer valid
		$main = MainWindow->new('-title'	=> 'WeatherMan v'.$VERSION);
		doalert("This version of the editor is obsolete.\nYou are running version $VERSION\n"
			."You need at least version ".(int $rconfig{version})
			."\nPlease upgrade your editor to continue.\n");
		exit 1;
	}
}
###########
sub readregistry() {
	my($p);
	$p = $Registry->{"LMachine/Software/Cheshire Cat/weatherman/helperurl"};
	$HELPER = $p->[0] if($p and $p->[0] and $p->[0]=~/^https?:\/\/.*\//);

	$p = $Registry->{"LMachine/Software/Cheshire Cat/weatherman/username"};
	$USERNAME = $p->[0] if($p);
	$p = $Registry->{"LMachine/Software/Cheshire Cat/weatherman/password"};
	$PASSWORD = $p->[0] if($p);
	$status = "Configuration loaded.";
}
sub editregistry() {
	my($k,$v);
	my(@resp,$url,$u,$p);

	$k = $Registry->{"LMachine/Software/Cheshire Cat/weatherman/"};
	if(!$k) {
		$k = $Registry->{"LMachine/Software/"};
		return if(!$k);
		$k = $k->CreateKey("Cheshire Cat");
		return if(!$k);
		$k = $k->CreateKey("weatherman");
		return if(!$k);
	}
	# Now we have a handle on the registry part...
	$k->SetValue('helperurl',$HELPER,REG_SZ);
	$k->SetValue('username',$USERNAME,REG_SZ);
	$k->SetValue('password',$PASSWORD,REG_SZ);

	# Prompt user for new URL
	@resp = prompt_string("Pickup URL","Enter URL of helper script on WeatherMap server",
		"URL:",$HELPER);
	$url = $resp[0];

	return if(!$url);

	# Check validity of URL
	if($url !~ /^https?:\/\/.*\//) {
		doalert("Bad format of URL: must be http:// or https://");
		return;
	}	
	# Save new value.
	$HELPER = $url;
	$k->SetValue('helperurl',$HELPER,REG_SZ);

	@resp = prompt_string("Username","Enter username for WeatherMap server, if any",
		"Username:",$USERNAME);
	$u = $resp[0];
	if($u) {
	@resp = prompt_string("Password","Enter password for WeatherMap server",
		"Password:",$PASSWORD);
	$p = $resp[0];
	} else { $p = ""; }
	$USERNAME = $u; $PASSWORD = $p;
	$k->SetValue('username',$USERNAME,REG_SZ);
	$k->SetValue('password',$PASSWORD,REG_SZ);
	$status = "New settings saved to registry.";
	loadrconfig;
}
###########

sub init_gui {	# Initialize main widget, menubar and canvas
	$main = MainWindow->new('-title'	=> 'WeatherMan v'.$VERSION);
	$main->geometry(&mw_size);
	$main->protocol('WM_DELETE_WINDOW',\&quit_it);
	&create_menubar;
	&prepare;
}

###########
sub prepare { # Additional initialization, used by &close
	undef %nodes;
	undef %links;
	undef %global;
	undef %objprop;
	undef %scale;
	$titlex = $titley = $timex = $timey = $keyx = $keyy = 0;
	$maptitle = $keytitle = $timeformat = "";
	$titleobj = $keyobj = $timeobj = undef;
	$change = 0;
	&create_canvas;
	&bgimage;
	&grid;
}
sub default_links($) { # default URLs for a node
	my($resp) = $_[0];
	my($err,$tgt,$cfg,$linkinfo,@linkinfo);

	return if(!defined $nodes{$resp}{_CFGFILE});
	$cfg = $nodes{$resp}{_CFGFILE};

	($err,$tgt) = getreply('NODETARGET',$cfg);
	if($tgt and !$err) {
		$nodes{$resp}{TARGET} = $tgt;
		$nodes{$resp}{USESCALE} = 'plain' if(!defined $nodes{$resp}{USESCALE});
		$nodes{$resp}{ICON} = 'scale/circle{nodes:this:bandwidth_in}.png' if(!defined $nodes{$resp}{ICON});
	}

	$nodes{$resp}{INFOURL} = $rconfig{nodeinfo};
	$nodes{$resp}{INFOURL} =~ s/\%CFGFILE\%/$cfg/g;	

	$nodes{$resp}{_LINKS} = {};
	foreach $linkinfo ( getlist('LISTLINKS',$cfg) ) {
		@linkinfo = split /\t/,$linkinfo;
		$nodes{$resp}{_LINKS}{$linkinfo[0]} = [@linkinfo];
		if($cfg and $linkinfo[0]=~/cpu/i) {
			$nodes{$resp}{OVERLIBGRAPH} = $rconfig{popupgraph};
			$nodes{$resp}{OVERLIBGRAPH} =~ s/\%CFGFILE\%/$cfg/g;
			$nodes{$resp}{OVERLIBGRAPH} =~ s/\%TARGET\%/$linkinfo[0]/g;
			last if($linkinfo[0]=~/^_CPU/);
		}
	}
}
sub default_links_link($) {
	my($linktarget) = $_[0];
	my($linkstart,$cfg);
	$links{$linktarget}{TARGET} = $rconfig{rrdpath}."/".(lc $linktarget).".rrd:ds0:ds1"
		if(defined $rconfig{rrdpath});
	$linkstart = $links{$linktarget}{_from};
	$cfg = $links{$linktarget}{_CFGFILE}; 
	$cfg = $nodes{$linkstart}{_CFGFILE} if(!$cfg); 
	chomp $cfg if($cfg);
	if( defined $rconfig{linkinfo} ) {
		$links{$linktarget}{INFOURL} = $rconfig{linkinfo};
		$links{$linktarget}{INFOURL} =~ s/\%CFGFILE\%/$cfg/g if($cfg);
		$links{$linktarget}{INFOURL} =~ s/\%TARGET\%/$linktarget/g if($linktarget);
	}
	if(defined $rconfig{popupgraph}) {
		$links{$linktarget}{OVERLIBGRAPH} = $rconfig{popupgraph};
		$links{$linktarget}{OVERLIBGRAPH} =~ s/\%CFGFILE\%/$cfg/g if($cfg);
		$links{$linktarget}{OVERLIBGRAPH} =~ s/\%TARGET\%/$linktarget/g if($linktarget);
	}
}
sub clear_ids {
	my($obj);
	foreach $obj ( keys %nodes ) {
		undef $nodes{$obj}{_LabelID};
		undef $nodes{$obj}{_LineID};
		undef $nodes{$obj}{_ID};
	}
	foreach $obj ( keys %links ) {
		undef $links{$obj}{_ID};
	}
	$titleobj = $keyobj = $timeobj = undef;
}
my($sortkey);
sub bynodelinkdesc {return ($nodes{$sortkey}{_LINKS}{$a}[2] cmp $nodes{$sortkey}{_LINKS}{$b}[2]);}
sub click_node_select_popup($$) {
	my($key,$urlref) = @_;
	my(@descs,@choices,$d,$linktarget,$url,$cfg);

	if( !defined $nodes{$key}{_LINKS} or !defined $nodes{$key}{_CFGFILE} ) {
		$status = "This node does not have any Targets.";
		doalert($status);
		return;
	}	
	@descs = @choices = (); $sortkey = $key;
	foreach ( sort bynodelinkdesc keys %{$nodes{$key}{_LINKS}} ) {	
		push @choices, $_;
		$d = $nodes{$key}{_LINKS}{$_}[2];
		$d = $_ if(!$d);
		push @descs, $d;
	}
	$linktarget = prompt_list("Select Target",
		"Select the target for the popup graph","","browse", \@choices, \@descs );
	return if( ! $linktarget );
	$cfg = $nodes{$key}{_CFGFILE};
	$url = $rconfig{popupgraph};
	$url =~ s/\%CFGFILE\%/$cfg/g;
	$url =~ s/\%TARGET\%/$linktarget/g;
	$$urlref = $url;
}
#########################################
# XXXXXXXX
sub click_node_select_source($$$$) {
	my($key,$urlref,$inforef,$targetref) = @_;
	# This will give a popup to select from available conf files, and set all the node info



}
sub click_node_select_map($$$$) {
	my($key,$urlref,$inforef,$targetref) = @_;
	my(@maps, $selectedmap);
	# use file/open map popup to select a map; then set defaults for the options

	@maps = getlist('LISTCFG','');
	@maps = sort @maps;
	$selectedmap = prompt_list( "Choose Map","Select the map to link to from the list",
		"","browse",\@maps);
	$selectedmap =~ s/\.conf$//;
	$$urlref = ''; # popup graph
	$$inforef = "${selectedmap}.html"; # link destination
	# $$targetref = ''; # datasource

}
sub click_link_select_source($$$$) {
	my($key,$urlref,$inforef,$targetref) = @_;
		my($d,@descs,@choices,$name,$nameto,$linktarget);
	my($overlibgraph,$target,$infourl);

		$name = $links{$key}{_from};				
		$nameto = $links{$key}{_to};
		return if(!defined $nodes{$name});
		if( !defined $nodes{$name}{_LINKS} or !defined $nodes{$name}{_CFGFILE} ) {
			$status = "The source node does not have any known Targets.";
			doalert($status);
			return;
		}	
		@descs = @choices = ();
		foreach ( sort keys %{$nodes{$name}{_LINKS}} ) {	
#			next if( defined $links{$_} );
			push @choices, $_;
			$d = $nodes{$name}{_LINKS}{$_}[2];
			$d = $_ if(!$d);
			push @descs, $d;
		}
		$linktarget = prompt_list("Select Target",
			"Select which targetname corresponds to the outgoing link",
			"","browse", \@choices, \@descs );
		if( ! $linktarget ) {
			$status = "Cancelled";
			return;
		}
#		if(defined $links{$linktarget} ) {
#			$status = "That link is already on the map";
#			doalert($status);
#			return;
#		}

	# OK, we now have a valid link selected; time to set the various defualts.
		my($cfg);
	$target = ''; $overlibgraph = ''; $infourl = '';
	$target = $rconfig{rrdpath}."/".(lc $linktarget).".rrd:ds0:ds1"
		if(defined $rconfig{rrdpath});
	$cfg = $nodes{$linkstart}{_CFGFILE} if(!$cfg); 
	chomp $cfg if($cfg);
	if( defined $rconfig{linkinfo} and $cfg) {
		$infourl = $rconfig{linkinfo};
		$infourl =~ s/\%CFGFILE\%/$cfg/g;
		$infourl =~ s/\%TARGET\%/$linktarget/g;
	}
	if(defined $rconfig{popupgraph} and $cfg) {
		$overlibgraph = $rconfig{popupgraph};
		$overlibgraph =~ s/\%CFGFILE\%/$cfg/g;
		$overlibgraph =~ s/\%TARGET\%/$linktarget/g;
	}

	$$urlref = $overlibgraph;
	$$inforef = $infourl;
	$$targetref = $target;

}
#########################################

###########
# Window title, text for prompt, default value
sub prompt_string {
	my(@fields) = @_;
	my( $title, $prompt, $prefix, $default );
	my( $rv ) = "";
	my(@rv,@fld,@def);
	my($over,$textf,$text,$butf,$retval,$yes,$no,$field,$fieldf);

	$title = shift @fields;
	$prompt = shift @fields;
	$over=$main->Toplevel('-title'=>$title);
	$over->geometry("+".int($main->width/2)."+".int($main->height/2));
	$over->transient($main);
	$over->grab;
	$textf=$over->Frame->pack;
	$text=$textf->Label('-text' => $prompt)->pack('-side' => 'left');
	$fieldf = $over->Frame->pack;

	while( @fields ) {
		$prefix = shift @fields;
		$default = shift @fields;
		$text=$fieldf->Label('-text' => $prefix)->pack(-side=>'left');
		$field = $fieldf->Text(
			'-wrap'	=> 'none',
			'-height' => 1,
			'-width' => 25
		)->pack('-side'=>'left');
		$field->insert('end',$default);
		push @fld, $field;
		push @def, $default;
	}

	$butf=$over->Frame->pack;
	$yes=$butf->Button(
		'-text'		=> "OK",
		'-command'	=> sub{ $retval = 1 }
	)->pack('-side' => 'left');
	$no=$butf->Button(
		'-text'		=> "Cancel",
		'-command'	=> sub{ $retval = 0 }
	)->pack('-side' => 'left');
	$over->waitVariable(\$retval);
	$over->grab;

	if(!$retval) {
		$over->destroy;
		return ();
	}
	while( @fld ) {
		$field = shift @fld; $default = shift @def;
		$rv = $field->get('1.0','end');
		$rv = $default if(!$rv);
		chomp $rv;
		push @rv, $rv;
	}
	$over->destroy;
	return (@rv);
}
sub prompt_list {
	my($title, $prompt, $default, $type, $values, $descs) = @_;
	my($rv);
	my($sb,$over,$textf,$text,$butf,$retval,$yes,$no,$field,$fieldf);
	$descs = $values if(!$descs);
	$type = 'browse' if(!$type);

	$over=$main->Toplevel('-title'=>$title);
	$over->geometry("+".int($main->width/2)."+".int($main->height/2));
	$over->transient($main);
	$over->grab;
	$textf=$over->Frame->pack;
	$text=$textf->Label('-text' => $prompt)->pack('-side' => 'left');
	$fieldf = $over->Frame->pack;
	$sb = $fieldf->Scrollbar(-orient=>'vertical');
	$field = $fieldf->Listbox('-selectmode'=>$type,
		'-width'=>40, '-height'=>20,
		'-yscrollcommand' => [ 'set'=>$sb ]
		);
	$field->insert('end',@$descs);
	$sb->configure(-command => [ 'yview' => $field ]);
	$sb->pack(-side => 'right', -fill => 'y');
	$field->pack(-side => 'left', -fill => 'both');
	$butf=$over->Frame->pack;
	$yes=$butf->Button(
		'-text'		=> "OK",
		'-command'	=> sub{ $retval = 1 }
	)->pack('-side' => 'left');
	$no=$butf->Button(
		'-text'		=> "Cancel",
		'-command'	=> sub{ $retval = 0 }
	)->pack('-side' => 'left');
	$over->waitVariable(\$retval);
	$over->grab;
	$rv = $field->curselection();
#	print STDERR "Sel[".$rv->[0]."]";
	if($rv eq "") { $retval = 0; }
#	else { $rv = $field->get($rv); }
	elsif($rv and defined $rv->[0] and defined $values->[$rv->[0]]) { $rv = $values->[$rv->[0]]; }
	else { $rv = 0; }
	$over->destroy;

	return 0 if(!$retval);
	return $rv;
}
sub prompt_colour($$) { # pass ref to button, and field to hold the colour code
	my($but,$txt) = @_;
	my($colour);
	$colour = $$txt;
	$colour = '' if($colour and $colour !~ /^#[0-9a-f]{6}/i);
	$colour = "#808080" if(!$colour);
	$colour = $main->chooseColor(-title=>'Choose colour',-initialcolor=>$colour);
	return if(!$colour);
	$$txt=$colour;
	$but->configure(-background=>$colour,-activebackground=>$colour) if($but);
}
###########
# general editing of an array, for SET or FONTDEFINE
sub do_arrayedit($$) {
	my($title,$aref) = @_;
	my($over,$butf,$retval,$yes,$no,$field,$fieldf,$text,$sb);

	$over=$main->Toplevel('-title'=>$title);
	$over->geometry("+".int($main->width/2)."+".int($main->height/2));
	$over->transient($main);
	$over->grab;
	$fieldf = $over->Frame->pack;

	$text = "";
	foreach ( @$aref ) {
		$text .= "\n" if($text);
		$text .= $_;
	}
	$sb = $fieldf->Scrollbar(-orient=>'vertical');
	$field = $fieldf->Text(	'-wrap'=>'none', '-height'=>10, '-width'=>60,
		'-yscrollcommand' => [ 'set'=>$sb ])->pack('-side'=>'left');
	$field->insert('end',$text);
	$sb->configure(-command => [ 'yview' => $field ]);
	$sb->pack(-side=>'right',-fill=>'y');
	$field->bind('<Return>',sub{Tk->break;}); # stop Enter from autoclicking OK

	$butf=$over->Frame->pack;
	$yes=$butf->Button(
		'-text'		=> "OK",
		'-command'	=> sub{ $retval = 1 }
	)->pack('-side' => 'left');
	$no=$butf->Button(
		'-text'		=> "Cancel",
		'-command'	=> sub{ $retval = 0 }
	)->pack('-side' => 'left');

	$over->waitVariable(\$retval);
	$over->grab;

	if(!$retval) {	$over->destroy;	return; }

	$text = $field->get('1.0','end');
	$text =~ s/\s*$//; # chop trailing space
	$text =~ s/\n\n+/\n/g;
	@$aref = split /\n/,$text;

	$over->destroy;
	return;
}
# Properties of a node or a link - the big tabbed window
sub do_properties($$) { # key
	my($type,$key) = @_;
	my($href);
	my($rv,$f,$n,$tlinks,$tlabel,$ticon,$tmisc,$tnotes,$tcolour,$sb);
	my($label,$labeloffset,$target,$overlibgraph,$infourl,$notes,$bwlabel,$icon,$scale);
	my($lwidth,$bandwidth,$arrowstyle,$labelbgcolor,$labeloutlinecolor,$cb);
	my($x,$y);

	if($type =~ /n/i) {
		$href = $nodes{$key};
		$label = $href->{LABEL}; 
		$icon = $href->{ICON};
		$scale = $href->{USESCALE};
		$labeloffset = $href->{LABELOFFSET};
		$labelbgcolor = $href->{LABELBGCOLOR};
		$labeloutlinecolor= $href->{LABELOUTLINECOLOR};
		$overlibgraph = $href->{OVERLIBGRAPH}; 
		$overlibgraph = "" if(!$overlibgraph);
		$labeloffset = "" if(!$labeloffset);
		$infourl = $href->{INFOURL};
		$target = $href->{TARGET};
		$bandwidth = $href->{BANDWIDTH};
		$bandwidth = $href->{MAXVALUE} if($href->{MAXVALUE});
	} elsif( $type =~ /l/i ) {
		$href = $links{$key};
		$overlibgraph = $href->{OVERLIBGRAPH}; 
		$infourl = $href->{INFOURL};
		$target = $href->{TARGET};
		$lwidth = $href->{WIDTH};
		$bwlabel = $href->{BWLABEL};
		$bandwidth = $href->{BANDWIDTH};
		$arrowstyle = $href->{ARROWSTYLE};
		$lwidth = "" if(!$lwidth);
		$bandwidth = "" if(!$bandwidth);
		$arrowstyle = "" if(!$arrowstyle);
		$bwlabel = "" if(!$bwlabel);
	} else {
		$href = 0;
		$label = "";
		$label = $maptitle if($key eq 'x-maptitle');
		$label = $keytitle if($key eq 'x-maplegend');
		$label = $timeformat if($key eq 'x-timeformat');
	}

	# now, we set up a special window, with multiple tabs
	$f = $main->DialogBox(-title => "Properties", 
              -buttons => ["OK", "Cancel"]);
	($x,$y) = $main->pointerxy();
#	$f->geometry("+$x+$y"); # doesnt work?
	$n = $f->NoteBook( -ipadx=>6, -ipady => 6);
	$n->pack(-side=>"top");
	$tlabel = $n->add("labeltab",  -label => "Label", -underline => 0); 
	$tlinks = $n->add("linkstab",  -label => "Links", -underline => 0) if($type=~/[nl]/i and $type!~/d/i);
	$ticon  = $n->add("icontab",  -label => "Icon", -underline => 0) if($type=~/n/i);
	$tmisc  = $n->add("misctab",  -label => "Misc", -underline => 0) if($type=~/[nl]/i);
	$tnotes = $n->add("notestab",  -label => "Notes", -underline => 0) if($type=~/n/i and $type!~/d/i);
	$tcolour= $n->add("colourtab", -label => "Colour", -underline => 0) if($type=~/[nl]/i);

	if($tlabel) {
		$tlabel->LabEntry(-label => (($type=~/n/i)?"Label text:":"Option:"), 
	         -labelPack => [-side => "left",  -anchor => "w"], -width => 20, -background=>'#ffffff',
        	 -textvariable => \$label )->pack(-side => "top", -anchor => "nw")
			if($type !~ /d/i and $type !~ /l/i );
		if($type=~/n/i) {
		$cb = $tlabel->BrowseEntry(-label => "Offset:", -autolimitheight=>1,
	         -labelPack => [-side => "left",  -anchor => "w"], -width => 10, -colorstate=>1,
        	 -variable => \$labeloffset,-choices=>["","N","S","E","W","NE","SE","SW","NW"]
		 )->pack(-side => "top", -anchor => "nw");
		}
		$cb = $tlabel->BrowseEntry(-label => "Style:", -autolimitheight=>1,
	         -labelPack => [-side => "left",  -anchor => "w"], -width => 10, -colorstate=>1,
        	 -variable => \$bwlabel,-choices=>["",'unformatted','none','bits','percent']
		 )->pack(-side => "top", -anchor => "nw")			
#		$tlabel->LabEntry(-label => "Style (unformatted/none/bits/percent):", 
#	         -labelPack => [-side => "left",  -anchor => "w"], -width => 10, -background=>'#ffffff',
#       	 -textvariable => \$bwlabel )->pack(-side => "top", -anchor => "nw")
			if($type=~/l/i);
	}
	if($type=~/l/) {
		$tmisc->LabEntry(-label => "Bandwidth (bps):", 
	         -labelPack => [-side => "left",  -anchor => "w"], -width => 10, -background=>'#ffffff',
        	 -textvariable => \$bandwidth )->pack(-side => "top", -anchor => "nw");
		$tmisc->LabEntry(-label => "Line Width (4-20):", 
	         -labelPack => [-side => "left",  -anchor => "w"], -width => 10, -background=>'#ffffff',
        	 -textvariable => \$lwidth )->pack(-side => "top", -anchor => "nw");
		$cb = $tmisc->BrowseEntry(-label => "Arrow type:", -autolimitheight=>1,
	         -labelPack => [-side => "left",  -anchor => "w"], -width => 10, -colorstate=>1,
        	 -variable => \$arrowstyle,-choices=>["",'compact','classic']
		 )->pack(-side => "top", -anchor => "nw");
#		$tmisc->LabEntry(-label => "Arrow (compact/classic):", 
#	         -labelPack => [-side => "left",  -anchor => "w"], -width => 20, -background=>'#ffffff',
#        	 -textvariable => \$arrowstyle )->pack(-side => "top", -anchor => "nw");
	}
	if($type=~/n/) {
		$tmisc->LabEntry(-label => "Max value (100):", 
	         -labelPack => [-side => "left",  -anchor => "w"], -width => 10, -background=>'#ffffff',
        	 -textvariable => \$bandwidth )->pack(-side => "top", -anchor => "nw");
	}
	if($tlinks) {
		$tlinks->LabEntry(-label => "Data source:", 
	        	 -labelPack => [-side => "left",  -anchor => "w"], -width => 60, -background=>'#ffffff',
	         	-textvariable => \$target )->pack(-side => "top", -anchor => "nw")
			if($type =~ /[ln]/i and $type !~ /d/i);
		$tlinks->LabEntry(-label => "Popup graph URL:", 
        	 	-labelPack => [-side => "left",  -anchor => "w"], -width => 60, -background=>'#ffffff',
		 	-textvariable => \$overlibgraph )->pack(-side => "top", -anchor => "nw")
			if($type =~ /[nl]/i);
		$tlinks->LabEntry(-label => "Link destination:", 
	        	-labelPack => [-side => "left",  -anchor => "w"], -width => 60, -background=>'#ffffff',
         		-textvariable => \$infourl )->pack(-side => "top", -anchor => "nw")
			if($type =~ /[nl]/i);
		
		$tlinks->Button(-text=>"Set to defaults",
			-command=>[\&click_node_default_links,$key,\$overlibgraph,\$infourl,\$target])
			->pack(-side=>"left",-anchor=>'nw')
			if($type =~ /n/i and $type !~ /d/i);
		$tlinks->Button(-text=>"Select popup graph",
			-command=>[\&click_node_select_popup,$key,\$overlibgraph])->pack(-side=>"left",-anchor=>'nw')
			if($type =~ /n/i and $type !~ /d/i);
		$tlinks->Button(-text=>"Set to link defaults",
			-command=>[\&click_link_default_links,$key,\$overlibgraph,\$infourl,\$target])->pack(-side=>"left",-anchor=>'nw')
			if($type =~ /l/i and $type !~ /d/i);

		$tlinks->Button(-text=>"Select Data Source",
			-command=>[\&click_node_select_source,$key,\$overlibgraph,\$infourl,\$target])->pack(-side=>"left",-anchor=>'nw')
			if($type =~ /n/i and $type !~ /d/i);

		$tlinks->Button(-text=>"Select Data Source",
			-command=>[\&click_link_select_source,$key,\$overlibgraph,\$infourl,\$target])->pack(-side=>"left",-anchor=>'nw')
			if($type =~ /l/i and $type !~ /d/i);

		$tlinks->Button(-text=>"Select Target Map",
			-command=>[\&click_node_select_map,$key,\$overlibgraph,\$infourl,\$target])->pack(-side=>"left",-anchor=>'nw')
			if($type =~ /n/i and $type !~ /d/i);

	}
	if($tnotes) {
		my($tx) = $nodes{$key}{NOTES};
		my($fr) = $tnotes->Frame->pack(-side=>'left',-anchor=>'nw');
		$sb = $fr->Scrollbar(-orient=>'vertical');
		$notes= $fr->Text('-wrap' => 'word','-height' => 8,'-width' => 60,
			'-yscrollcommand' => [ 'set'=>$sb ] )->pack(-side=>'left');
		$sb->configure(-command => [ 'yview' => $notes ]);
		$sb->pack(-side => 'right', -fill => 'y');
		if($tx) {
			$tx =~ s/<BR>/\n/gi; $tx=~ s/\s*$//;
			$notes->insert('end',$tx);
		}
		$notes->bind('<Return>',sub{Tk->break;});
	}
	if( $ticon ) {
		$ticon->LabEntry(-label => "Icon definition:", 
	        	-labelPack => [-side => "left",  -anchor => "w"], -width => 40, -background=>'#ffffff',
         		-textvariable => \$icon )->pack(-side => "top", -anchor => "nw")
			if($type =~ /[nl]/i);
		$ticon->Button(-text=>"Click here to choose icon",
			-command=>[\&change_node_icon,$key,\$icon,\$target])->pack(-side=>"left",-anchor=>"nw");
		$ticon->Button(-text=>"Click here to choose non-status icon",
			-command=>[\&change_node_icon,$key,\$icon,0])->pack(-side=>"left",-anchor=>"nw")
			if($target);
	}
	if($tcolour) {

		$cb = $tcolour->BrowseEntry(-label => "Scale Name:", -autolimitheight=>1,
	         -labelPack => [-side => "left",  -anchor => "w"], -width => 10, -colorstate=>1,
        	 -variable => \$scale,-choices=>["","none",keys %scale]
		 )->pack(-side => "top", -anchor => "nw")
			if($type =~ /[nl]/i);	
		if($type =~ /n/i) {
			my($fcolour);
			$fcolour = $tcolour->Frame->pack(-side=>'top',-anchor=>'nw');
			$fcolour->LabEntry(-label => "Label background:", 
			       	-labelPack => [-side => "left",  -anchor => "w"], -width => 15, -background=>'#ffffff',
         			-textvariable => \$labelbgcolor )->pack(-side => "left", -anchor => "nw");
			$cb=$fcolour->Button(-text=>"?",	
				-command=>[\&prompt_colour,0,\$labelbgcolor])->pack(-side=>"top");
			$cb->configure(-command=>[\&prompt_colour,$cb,\$labelbgcolor]);
			$cb->configure(-background=>$labelbgcolor,-activebackground=>$labelbgcolor) if($labelbgcolor and $labelbgcolor=~/^#[0-9a-f]{6}/i);

			$fcolour = $tcolour->Frame->pack(-side=>'top',-anchor=>'nw');
			$fcolour->LabEntry(-label => "Label outline:", 
			       	-labelPack => [-side => "left",  -anchor => "w"], -width => 15, -background=>'#ffffff',
         			-textvariable => \$labeloutlinecolor )->pack(-side => "left", -anchor => "nw");
			$cb=$fcolour->Button(-text=>"?",
				-command=>[\&prompt_colour,0,\$labeloutlinecolor])->pack(-side=>"top");
			$cb->configure(-command=>[\&prompt_colour,$cb,\$labeloutlinecolor]);
			$cb->configure(-background=>$labeloutlinecolor,-activebackground=>$labeloutlinecolor) if($labeloutlinecolor and $labeloutlinecolor=~/^#[0-9a-f]{6}/i);
		}
	}

	$f->grab;
	$rv = $f->Show();
	if($rv eq 'OK') {
		# save the changes
		if($type =~ /n/i) {
			foreach ( qw/OVERLIBGRAPH INFOURL LABEL LABELOFFSET TARGET NOTES ICON USESCALE LABELBGCOLOR LABELOUTLINECOLOR/ ) {undef $href->{$_};}
			if($type !~ /d/i) {
				$href->{OVERLIBGRAPH} = $overlibgraph if($overlibgraph);
			}
			$href->{LABELOFFSET} = $labeloffset if($labeloffset);
			$href->{LABELBGCOLOR} = $labelbgcolor if($labelbgcolor);
			$href->{LABELOUTLINECOLOR} = $labeloutlinecolor if($labeloutlinecolor);
			$href->{USESCALE} = $scale if($scale and ($scale eq 'none' or defined $scale{$scale}));
			if($type !~ /d/i) {
				my($tx);
				$href->{TARGET} = $target if($target);
				$href->{LABEL} = $label ;
				# if node label changed, update display object
				$canvas->itemconfigure($href->{_LabelID},-text=>$label);
				$href->{INFOURL} = $infourl;
				$tx = $notes->get('1.0','end');
				$tx =~ s/\s+$//; # trim off trailing whitespace
				$tx =~ s/\n/<BR>/g;
				if($tx) { $href->{NOTES} = $tx; } 
				$canvas->delete($href->{_LabelID});
				&create_label($key);
			} else { $icon = 'unknown.png' if(!$icon); }
			if($icon) {
				$href->{"ICON"} = $icon;
				$icon =~ s/\{.*\}//g;
				getimage($icon);
				if($type!~/d/i) {
					my($img)=$main->Photo('-file' => $TMP."\\".$icon);
					$canvas->itemconfigure($nodes{$key}{_ID},'-image' => $img);
				}
			}
		} elsif( $type =~ /l/i ) {
			foreach ( qw/OVERLIBGRAPH INFOURL WIDTH BANDWIDTH ARROWSTYLE BWLABEL TARGET/ ) {undef $href->{$_};}
			if($type !~ /d/i) {
				$href->{TARGET} = $target if($target);
				$href->{OVERLIBGRAPH} = $overlibgraph if($overlibgraph);
				$href->{INFOURL} = $infourl;
				$canvas->itemconfigure($links{$key}{_ID},-width=>(2*$lwidth)) 
					if($lwidth and $links{$key}{_ID});
			}
			$href->{WIDTH} = $lwidth if($lwidth);
			$href->{BANDWIDTH} = $bandwidth if($bandwidth);
			$href->{BWLABEL} = $bwlabel if($bwlabel);
			$href->{ARROWSTYLE} = $arrowstyle if($arrowstyle);
		} else {
			if($key eq 'x-maptitle') {
				$maptitle = $label;
				$canvas->itemconfigure($titleobj,-text=>$label);
			} elsif($key eq 'x-maplegend') {
				$keytitle = $label;
				$canvas->itemconfigure($keyobj,-text=>"Legend\ngoes\nhere:\n".($keytitle?$keytitle:"Traffic"));
			}
			$timeformat = $label if($key eq 'x-timeformat');
		}
	}
	$f->destroy;
}
sub click_node_default_links($$$$) {
	my($k,$op,$ip,$tp) = @_;
	default_links($k);
	$$op = $nodes{$k}{OVERLIBGRAPH};
	$$ip = $nodes{$k}{INFOURL};
	$$tp = $nodes{$k}{TARGET};
	$$op = "" if(!$$op);	
	$$ip = "" if(!$$ip);
	$$tp = "" if(!$$tp);
}
sub click_link_default_links($$$$) {
	my($k,$op,$ip,$tg) = @_;
	default_links_link($k);
	$$op = $links{$k}{OVERLIBGRAPH};
	$$ip = $links{$k}{INFOURL};
	$$tg = $links{$k}{TARGET};
	$$op = "" if(!$$op);	
	$$ip = "" if(!$$ip);
	$$tg = "" if(!$$tg);
}
my(%editscale) = ();
my(%fromfield) = ();
my(%tofield) = ();
my(%colourfield) = ();
my(%colourfieldb) = ();
my(%chkfield) = ();
sub change_range($) {
	# update other items if required to fit
	# add extra blank item if blank one used
}
sub pick_colour($$) { # pick colour for item 
	my($kk,$idx) = @_;
	my($colour);
	$colour = $main->chooseColor(-title=>'New colour',-initialcolor=>$editscale{$kk}[$idx][2]);
	return if(!$colour);
	$editscale{$kk}[$idx][2] = $colour;
	$colourfield{$kk}[$idx]->configure(-background=>$colour,-activebackground=>$colour);
}
sub pick_colourb($$) { # pick colour for item 
	my($kk,$idx) = @_;
	my($colour);
	$colour = $main->chooseColor(-title=>'New colour',-initialcolor=>$editscale{$kk}[$idx][3]);
	return if(!$colour);
	$editscale{$kk}[$idx][3] = $colour;
	$colourfieldb{$kk}[$idx]->configure(-background=>$colour,-activebackground=>$colour);
}
sub new_line($$$$) { #add new line to scale
	my($kk,$iref,$nlbref,$tf) = @_;
	my($field,$fieldb,$button,$buttonb,$chk);

	# add the line
	$field = $tf->Text(-wrap=>'none',-height=>1,-width=>5);
	push @{$fromfield{$kk}},$field;
	$fieldb = $tf->Text(-wrap=>'none',-height=>1,-width=>5);
	push @{$tofield{$kk}}, $fieldb;
	$button = $tf->Button(-text=>"Colour",-background=>"#808080",-activebackground=>"#808080",
		-command=>[\&pick_colour,$kk,$$iref]);
	push @{$colourfield{$kk}}, $button;
	$buttonb = $tf->Button(-text=>"Colour",-background=>"#808080",-activebackground=>"#808080",
		-command=>[\&pick_colourb,$kk,$$iref],-state=>'disabled');
	push @{$colourfieldb{$kk}}, $buttonb;
	$chk = $tf->Checkbutton(-text=>"R",-indicatoron=>0,-command=>[\&enable_range,$kk,$$iref]);
	push @{$chkfield{$kk}},$chk;
	$field->grid($fieldb,$button,$buttonb,$chk);
	push @{$editscale{$kk}}, [ "","","#808080","#808080",0];
	$$iref += 1;

}
sub enable_range($$) {
	my($kk,$idx) = @_;
	my($v);

	$v = $chkfield{$kk}[$idx]->{Value};
	$colourfieldb{$kk}[$idx]->configure(-state=>($v?'normal':'disabled'));
	$editscale{$kk}[$idx][4] = $v;
}
sub new_scale($$$) {
	my($fld,$notebook,$iref) = @_;
	my($t,$tf,$field,$fieldb,$chk,$button,$buttonb,$snlb);
	my($kk);

	$kk = $fld->get('1.0','end');
	$kk =~ s/\s*$//;$kk =~ s/ /_/g;
	$kk = "scale$kk" if($kk=~ /^\d+\.?\d*$/); 
	return if(!$kk);
	return if(defined $editscale{$kk});
	$t = $notebook->add("scaletab$kk",  -label => $kk, -underline => 0); 
	$tf = $t->Frame->pack(-side=>'top',-anchor=>'nw');
	$iref->{$kk} = 1;
	$field = $tf->Text(-wrap=>'none',-height=>1,-width=>5);
	push @{$fromfield{$kk}},$field;
	$fieldb = $tf->Text(-wrap=>'none',-height=>1,-width=>5);
	push @{$tofield{$kk}}, $fieldb;
	$button = $tf->Button(-text=>"Colour",-background=>"#808080",-activebackground=>"#808080",
		-command=>[\&pick_colour,$kk,\$iref->{$kk}]);
	push @{$colourfield{$kk}}, $button;
	$buttonb = $tf->Button(-text=>"Colour",-background=>"#808080",-activebackground=>"#808080",
		-command=>[\&pick_colourb,$kk,\$iref->{$kk}],-state=>'disabled');
	push @{$colourfieldb{$kk}}, $buttonb;
	$chk = $tf->Checkbutton(-text=>"R",-indicatoron=>0,-command=>[\&enable_range,$kk,\$iref->{$kk}]);
	push @{$chkfield{$kk}},$chk;
	$field->grid($fieldb,$button,$buttonb,$chk);
	push @{$editscale{$kk}}, [ "","","#808080","#808080",0];

	# 'new line' button
	$snlb = $t->Button(-text=>"Add new line",-command=>[\&new_line,$kk,\$iref->{$kk},\$snlb,$tf]);
	$snlb->pack(-side=>'left',-anchor=>'sw');


}
sub delete_scale($$$) {
	my($kk,$n,$t) = @_;
	if($kk eq 'DEFAULT') {
		$status = "Cannot delete default scale";
		$main->Dialog(-title=>"Error",-text=>$status,-bitmap=>"error",-buttons=>['Ok'])->Show('-global');
		return;
	}
	undef $editscale{$kk};
	undef $colourfield{$kk};
	undef $fromfield{$kk};
	undef $tofield{$kk};
	undef $chkfield{$kk};
	undef $colourfieldb{$kk};

	$t->destroy;

}
sub define_scale {
	my(@s,$kk, $s,$i,$f,$x,$y,$n,$t,$tf,$c,$r,$g,$b,$rv,$cb,$rg);
	my($field,$fieldb,$button,$ra,$rb,$snlb,$buttonb,$chk,%i,$nsf,$nsb,$delb);

	# load %scale into @editscale
	%editscale = %colourfield = %fromfield = %tofield = %chkfield = %colourfieldb = ();
	foreach $kk (keys %scale) {
		$editscale{$kk} = [];
		foreach ( sort numerically keys %{$scale{$kk}} ) {
			@s = @{$scale{$kk}{$_}};
			$c = sprintf '#%02X%02X%02X',$s[2],$s[3],$s[4];
			$cb = "#808080"; $rg = 0;
			if(defined $s[5]) {
				$rg = 1;
				$cb = sprintf '#%02X%02X%02X',$s[5],$s[6],$s[7];
			}
			push @{$editscale{$kk}}, [ $s[0], $s[1], $c, $cb, $rg ];
		}
		undef $editscale{$kk} if(! @{$editscale{$kk}} ); # empty list
	}
	if(! defined $editscale{DEFAULT} ) {
		# define default scale
		$editscale{DEFAULT} = [
			[  1, 10, "#ff80ff", "#808080", 0 ],
			[ 10, 25, "#8080ff", "#808080", 0 ],
			[ 25, 40, "#80ffff", "#808080", 0 ],
			[ 40, 55, "#80ff80", "#808080", 0 ],
			[ 55, 70, "#ffff80", "#808080", 0 ],
			[ 70, 85, "#ffcc80", "#808080", 0 ],
			[ 85,100, "#ff8080", "#808080", 0 ]
		];
	}
	if(! defined $editscale{plain} ) {
		# define default scale
		$editscale{plain} = [
			[  0, 100,"#ffffff", "#808080", 0 ]
		];
	}
	if(! defined $editscale{updown} ) {
		# define default node scale
		$editscale{updown} = [
			[  0, 0.9,"#00ff00", "#808080", 0 ],
			[ 0.9, 1.9, "#ffff00", "#808080", 0 ],
			[ 1.9, 2.9, "#ff0000", "#808080", 0 ],
			[ 2.9, 3.9, "#ff8000", "#808080", 0 ],
			[ 3.9, 100, "#0000ff", "#808080", 0 ]
		];
	}
	# create editing window
	$f = $main->DialogBox(-title => "Scale definitions", -buttons => ["OK", "Cancel"]);
#	($x,$y) = $main->pointerxy();
	$n = $f->NoteBook( -ipadx=>6, -ipady => 6);
	$n->pack(-side=>"top",-fill=>'x');

	foreach $kk ( keys %editscale ) {

	$t = $n->add("scaletab$kk",  -label => $kk, -underline => 0); 
	$tf = $t->Frame->pack(-side=>'top',-anchor=>'nw');
	# add all existing defined scale.  Define default scale if required.
	$i{$kk} = 0;
	foreach $s ( @{$editscale{$kk}} ) {
		print STDERR "$kk: ".(join " ",@$s)."\n";
		$field = $tf->Text(-wrap=>'none',-height=>1,-width=>5);
		$field->insert('end',$s->[0]);
		push @{$fromfield{$kk}},$field;
		$fieldb = $tf->Text(-wrap=>'none',-height=>1,-width=>5);
		$fieldb->insert('end',$s->[1]);
		push @{$tofield{$kk}}, $fieldb;
		$button = $tf->Button(-text=>"Colour",-background=>$s->[2],
			-activebackground=>$s->[2],-command=>[\&pick_colour,$kk,$i{$kk}]);
		push @{$colourfield{$kk}}, $button;
		$buttonb = $tf->Button(-text=>"Colour",-background=>$s->[3],
			-activebackground=>$s->[3],-command=>[\&pick_colourb,$kk,$i{$kk}],
			-state=>($s->[4]?'normal':'disabled'));
		push @{$colourfieldb{$kk}}, $buttonb;
		$chk = $tf->Checkbutton(-text=>"R",-indicatoron=>0,-command=>[\&enable_range,$kk,$i{$kk}]);
		push @{$chkfield{$kk}},$chk;
		$chk->select if($s->[4]);
		$field->grid($fieldb,$button,$buttonb,$chk);
		$i{$kk} += 1;
	}

	# 'new line' button
	$snlb = $t->Button(-text=>"Add new line",-command=>[\&new_line,$kk,\$i{$kk},\$snlb,$tf]);
	$snlb->pack(-side=>'left',-anchor=>'sw');
	$delb = $t->Button(-text=>"Delete Scale",-command=>[\&delete_scale,$kk,$n,$t]);
	$delb->pack(-side=>'left',-anchor=>'sw');

	} # end of different scales

	$nsf = $f->Frame->pack(-side=>'bottom',-anchor=>'sw');
	$field = $nsf->Text(-wrap=>'none',-height=>1,-width=>15);
	$nsb = $nsf->Button(-text=>"Add new scale",-command=>[\&new_scale,$field,$n,\%i]);
	$field->grid($nsb);

	# activate
	$f->grab;
	$rv = $f->Show();

	# process
	if($rv eq 'OK') {
	%scale = ();
	foreach $kk ( keys %editscale ) {
		# save edited items into %scale, ignore ones with blank keys
		next if(!$fromfield{$kk});
		%{$scale{$kk}} = ();
		while($i{$kk}) {
			$i{$kk} -= 1;
			$ra = $fromfield{$kk}[$i{$kk}]->get('1.0','end');
			next if($ra !~ /(\d+\.?\d*)/); $ra = $1;
			$rb = $tofield{$kk}[$i{$kk}]->get('1.0','end');
			next if($rb !~ /(\d+\.?\d*)/); $rb = $1;
			next if(!defined $ra or !defined $rb);
			next if(defined $scale{$kk}{$ra});
			$r = hex(substr($editscale{$kk}[$i{$kk}][2],1,2));
			$g = hex(substr($editscale{$kk}[$i{$kk}][2],3,2));
			$b = hex(substr($editscale{$kk}[$i{$kk}][2],5,2));
			$scale{$kk}{$ra} = [$ra,$rb,$r,$g,$b];
			if($editscale{$kk}[$i{$kk}][4]) {
				$r = hex(substr($editscale{$kk}[$i{$kk}][3],1,2));
				$g = hex(substr($editscale{$kk}[$i{$kk}][3],3,2));
				$b = hex(substr($editscale{$kk}[$i{$kk}][3],5,2));
				push @{$scale{$kk}{$ra}},($r,$g,$b);
			}
		}
	}
	}
	$f->destroy; # byebye!
}
###########
sub enable_save {
	$menubar->entryconfigure(("Save map"),'-state' => 'normal');
	$menubar->entryconfigure(("Save as..."),'-state' => 'normal');
	$menubar->entryconfigure(("Close"),'-state' => 'normal');
	$menubar->entryconfigure(("Open map"),'-state' => 'normal');
	$menubar->entryconfigure(("New map"),'-state' => 'normal');
}
sub disable_save {
	$menubar->entryconfigure(("Save map"),'-state' => 'disabled');
	$menubar->entryconfigure(("Save as..."),'-state' => 'disabled');
	$menubar->entryconfigure(("Close"),'-state' => 'disabled');
	$menubar->entryconfigure(("Open map"),'-state' => 'normal');
	$menubar->entryconfigure(("New map"),'-state' => 'normal');
}
sub send_file($$) {
	my($c,$f)=@_;
	my($b) = $f;
	my($req,$resp,$boundary,$content);

	$boundary = "fileup$$";

	$b =~ s/^.*[\/\\]//;

	$req = HTTP::Request->new('POST'=>$HELPER);
	$req->header('Content-Type'=>"multipart/form-data; boundary=$boundary");	
	$content = "--$boundary\r\nContent-Disposition: form-data; name=\"C\"\r\n\r\n"
		."$c\r\n"
		."--$boundary\r\nContent-Disposition: form-data; name=\"A\"\r\n\r\n"
		."$b\r\n"
		."--$boundary\r\nContent-Disposition: form-data; name=\"P\"\r\n\r\n"
		."$AUTHPW\r\n"
		."--$boundary\r\nContent-Disposition: form-data; name=\"F\"; filename=\"$f\"\r\n"
		."Content-Type: application/octet-stream\r\n"
		."\r\n";
	open F, "<$f" or do { doalert("Unable to open file: $!"); return; };
	binmode F;
	while ( <F> ) { $content .= $_; }
	close F;
	$content .= "\r\n--$boundary--\r\n";
	$req->content( $content );
	$resp = $ua->request($req);
	if(!$resp or $resp->is_error()) {
		$status = "HTTP error trying to post image.";
		doalert("HTTP error");
	} elsif($resp->content() =~ /^ERROR\n(.*)/) {
		$status = "ERROR: helper: $1";
		doalert("ERROR: $1");
	} elsif( $resp->content() !~ /^OK/ ) {
		$status = "ERROR: Unexpected response from server: ".$resp->content();
		doalert("ERROR: Unexpected response");
	} else { $status = "Saved OK."; } 
}
sub up_image {
	my($f,$b);
	my($types) = [
		["PNG Images",".png"],
		["All files","*"]
	];
	# prompt for png file
	$f = $main->getOpenFile(-defaultextension=>'.png',-filetypes=>$types,
		-title=>"Select image");
	send_file('SAVEIMAGE',$f) if($f);
}
sub up_icon {
	my($f,$b);
	my($types) = [
		["PNG Images",".png"],
		["All files","*"]
	];
	# prompt for png file
	$f = $main->getOpenFile(-defaultextension=>'.png',-filetypes=>$types,
		-title=>"Select icon");
	send_file('SAVEICON',$f) if($f);
}
sub set_bg {
	my(@imgs,$img);

	@imgs = getlist('LISTIMAGES','');
	$img = prompt_list( "Set background","Select the image for the background",
		"","browse",\@imgs);
	if($img) {
		getimage($img);
		$global{BACKGROUND}=$img;
		&bgimage;
		
	} else {
		undef $global{BACKGROUND};
		$canvas->delete('bgimg');
	}
}
sub create_menubar {	# Create menubar, specify callbacks
	my $menuframe = $main->Frame(
		'-relief'		=> 'raised',
		'-borderwidth'	=> 2
	)->pack(
		'-side'			=> 'top',
		'-anchor'		=> "n",
		'-expand'		=> 1,
		'-fill'			=> 'x'
	);
	my $statusframe = $main->Frame(
		'-relief'		=> 'raised',
		'-borderwidth'	=> 2
	)->pack(
		'-side'			=> 'bottom',
		'-anchor'		=> "n",
		'-expand'		=> 1,
		'-fill'			=> 'x'
	);

	$menubar = $menuframe->Menubutton(
		'-tearoff' 	=> 0,
		'-text'		=> ("File"),
		'-underline' 	=> 0 ,
		'-menuitems' 	=> [
			[ Button => ("New map"),	'-command' => [\&new_map] ],
			[ Button => ("Open map"),	'-command' => [\&open_map] ],
			[ Button => ("Options"), '-command' => [\&editregistry] ],
			[ Button => ("Save as..."),	'-command' => [\&save_map_as], '-state' => 'disabled' ],
			[ Button => ("Save map"),	'-command' => [\&save_map], '-state' => 'disabled' ],
			[ Button => ("Close"),	'-command' => [\&close_current], '-state' => 'disabled' ],
			[ Button => ("Quit"),	'-command' => [\&quit_it] ],
		]
	)->pack('-side' => 'left');
	my $menubar2 = $menuframe->Menubutton(
		'-tearoff'	=> 0,
		'-text'		=> ("Global"),
		'-underline' 	=> 0 ,
		'-menuitems' 	=> [
			[ Button => ("Background Image"),'-command' => [\&set_bg] ],
			[ Button => ("Upload Icon"),	'-command' => [\&up_icon] ],
			[ Button => ("Upload Image"),	'-command' => [\&up_image] ],
			[ Button => ("Toggle grid"),	'-command' => [\&grid] ],
			[ Button => ("Set title"),	'-command' => [\&set_title] ],
			[ Button => ("Reset legends"),	'-command' => [\&reset_legends] ],
			[ Button => ("Default Node"),	'-command' => [\&default_node] ],
			[ Button => ("Default Link"),	'-command' => [\&default_link] ],
			[ Button => ("Define Scale"),   '-command' => [\&define_scale] ],
			[ Button => ("SET options"),   '-command' => [\&do_arrayedit,"SET options",\@set] ],
			[ Button => ("Define fonts"),   '-command' => [\&do_arrayedit,"FONTDEFINE options",\@fontdefine] ]
		]
	)->pack('-side' => 'left');  
 
	$actionmenu = $menuframe->Menubutton(
		'-tearoff'	=> 1,
		'-text'		=> ("Action"),
		'-underline' 	=> 0 ,
		'-menuitems' 	=> [
			[ Button => "New node",		'-command' => [\&new_node] ],
			[ Button => "New submap",	'-command' => [\&new_sub] ],
			[ Button => "New link",		'-command' => [\&new_link] ],
			[ Button => "New Vlink",	'-command' => [\&new_vlink] ],
			[ Button => "Delete",		'-command' => [\&delete_object] ]
		]
	)->pack('-side' => 'left'); 

	my $gridb = $menuframe->Button(
		'-text'			=> ("Grid"),
		'-relief'		=> 'raised',
		'-command'		=> \&grid,
	)->pack('-side' 	=> 'left');

	my $dob = $menuframe->Button(
		'-text'			=> ("Delete"),
		'-relief'		=> 'raised',
		'-command'		=> \&delete_object,
	)->pack('-side' 	=> 'left');

	my $nnb = $menuframe->Button(
		'-text'			=> ("New node"),
		'-relief'		=> 'raised',
		'-command'		=> \&new_node,
	)->pack('-side' 	=> 'left');
	my $nlb = $menuframe->Button(
		'-text'			=> ("New link"),
		'-relief'		=> 'raised',
		'-command'		=> \&new_link,
	)->pack('-side' 	=> 'left');
	my $nvlb = $menuframe->Button(
		'-text'			=> ("New vlink"),
		'-relief'		=> 'raised',
		'-command'		=> \&new_vlink,
	)->pack('-side' 	=> 'left');
	my $nsb = $menuframe->Button(
		'-text'			=> ("New submap"),
		'-relief'		=> 'raised',
		'-command'		=> \&new_sub,
	)->pack('-side' 	=> 'left');
	my $ncb = $menuframe->Button(
		'-text'			=> ("Cancel"),
		'-relief'		=> 'raised',
		'-command'		=> \&cancel_mode,
	)->pack('-side' 	=> 'left');

	my $coordframe = $menuframe->Frame(
		'-relief'		=> 'groove',
		'-borderwidth'	=> 2
	)->pack('-side' 	=> 'right');

 	my $aboutb = $menuframe->Button(
		'-text'			=> ("About"),
		'-relief'		=> 'flat',
		'-command'		=> [\&about],
	)->pack('-side'		=> 'right');

 	my $xlabel = $coordframe->Label(
		'-text'			=> ' X '
	)->pack('-side'		=> 'left');

	my $xvalue = $coordframe->Label(
		'-background'	=> 'white',
		'-takefocus'	=> 0,
		'-textvariable'	=> \$xpos,
		'-width'		=> 4,
	)->pack('-side'		=> 'left');

	my $ylabel = $coordframe->Label(
		'-text'			=> ' Y '
	)->pack('-side'		=> 'left');

	my $yvalue = $coordframe->Label(
		'-background'	=> 'white',
		'-takefocus'	=> 0,
		'-textvariable'	=> \$ypos,
		'-width'		=> 4,
		'-relief'		=> 'flat',
	)->pack('-side'		=> 'left');



	my $statusvalue = $statusframe->Label(
		'-takefocus'	=> 0,
		'-textvariable'	=> \$status,
	)->pack('-side'		=> 'left');
}

sub create_canvas {	# Create canvas, bind specific actions
	my($cw,$ch);

	$main->update;
	$cw = $GRID_WIDTH;
	$ch = $GRID_HEIGHT;
	foreach my $obj ( keys %nodes ) {
		$cw = $nodes{$obj}{X2d} if($nodes{$obj}{X2d} and $nodes{$obj}{X2d}>$cw);
		$ch = $nodes{$obj}{Y2d} if($nodes{$obj}{Y2d} and $nodes{$obj}{Y2d}>$ch);
	}
	my $c = $main->Scrolled("Canvas",
		'-width'		=> $main->width,
		'-height'		=> $main->height,
		'-scrollregion'	=> [0,0,$cw,$ch],
		'-bg'			=> 'gray80',
		'-scrollbars'	=> 'osoe',
	)->pack(
		'-fill'			=> 'both',
		'-expand'		=> 1
	);

	$canvas=$c->Subwidget("canvas");
	$canvas->Tk::bind("<1>", [ \&get_pos, Ev('x'), Ev('y')]);
	$canvas->Tk::bind("<B1-Motion>", [ \&get_pos, Ev('x'), Ev('y')]);
	$canvas->bind("moveable","<1>", [ \&drag_start, Ev('x'), Ev('y') ]);
	$canvas->bind("moveable","<B1-Motion>", [ \&drag_it, Ev('x'), Ev('y') ]);
	$canvas->bind("moveable","<Any-Enter>", [ \&highlight,Ev('T')]);
	$canvas->bind("moveable","<Any-Leave>", [ \&highlight,Ev('T')]);
	$canvas->bind("moveable","<3>", [ \&change_node,Ev('x'), Ev('y')]);
	$canvas->bind("line","<1>", [ \&delete_link,Ev('x'), Ev('y')]);
	$canvas->bind("line","<3>", [ \&change_link,Ev('x'), Ev('y')]);
	$canvas->bind("line","<Any-Enter>", [ \&lhighlight,Ev('T')]);
	$canvas->bind("line","<Any-Leave>", [ \&lhighlight,Ev('T')]);
}  


############
sub bgimage { # If defined, show background image
	my($bg_image);
	$bg_image = $global{'BACKGROUND'};
	if ($bg_image) {
		getimage($bg_image);
		my $img=$main->Photo('-file'	=> $TMP."\\".$bg_image);
		$canvas->createImage(0, 0,
			'-image'	=> $img,
			'-anchor'	=> 'nw',
			'-tags'		=> ["bgimg"]
		);
		$canvas->lower("bgimg","all");
	}
}  

sub new_node {
	$status = "Click to create a new node";
	$main->configure(-cursor=>"plus");
	$MODE="NODE1";
}
sub new_link {
	$status = "Click on primary node for the new link";
	$main->configure(-cursor=>"plus");
	$MODE = "LINK1";
}
sub new_vlink {
	$status = "Click on primary node for the new link";
	$main->configure(-cursor=>"plus");
	$MODE = "VLINK1";
}sub new_sub {
	$status = "Click to create a new submap icon";
	$main->configure(-cursor=>"plus");
	$MODE = "SUB1";
}
sub delete_object {
	$status = "Click on the object to be deleted";
	$main->configure(-cursor=>"cross");
	$MODE = "DELETE";
}
sub cancel_mode {
	$status = "";
	$MODE = "";
	$main->configure(-cursor=>"arrow");

}
############
sub grid { # Show/hide grid

	if ($canvas->find("withtag","grid")) {
		$canvas->delete("grid");
	} else {
		for ( my $i=($GRID_STEP) ; $i<$GRID_WIDTH ; $i+=($GRID_STEP) ) {
			$canvas->createLine($i,0,$i,$GRID_HEIGHT,
				'-fill'	=> 'gray70',
				'-tags'	=> ["grid"]
			);
		}
		for ( my $i=($GRID_STEP) ; $i<$GRID_HEIGHT ; $i+=($GRID_STEP) ) {
			$canvas->createLine(0,$i,$GRID_WIDTH,$i,
				'-fill' => 'gray70',
				'-tags' => ["grid"]
			);
		}
		$canvas->lower("grid","all");
		if ($global{BACKGROUND}) {
			$canvas->raise("grid","bgimg")
		}
	}
}  

sub get_pos {	# Callback for position indicators
	my ($obj,$x,$y)=@_;
	my($err,$resp,@resp,,$cfg,$deficon);
	my($linkinfo,@linkinfo);
	$xpos=$canvas->canvasx($x);
	$ypos=$canvas->canvasy($y);
	# clicked on background: any special action?
	if($MODE eq 'SUB1') {
		$MODE = "";
		$main->configure(-cursor=>"arrow"); # back to normal
		@resp = prompt_string("New Submap","Enter the name of the submap","File:","");
		$resp = $resp[0];
		if($resp) {
			# New submap!
			$resp =~ s/ /_/g;
			if(defined $nodes{$resp}) {
				$status = "Submap already exists!";
				doalert($status);
				return;
			}
			$nodes{$resp}{_X2d} = $xpos;
			$nodes{$resp}{_Y2d} = $ypos;
			$nodes{$resp}{LABEL} = $resp;
			$nodes{$resp}{LABEL} =~ s/\.conf$//;
			$nodes{$resp}{INFOURL} = $nodes{$resp}{LABEL};
			$nodes{$resp}{INFOURL} .= ".html";
			getimage($deficon) if($deficon);
			&create_node($resp);
		} else { $status = "Cancelled"; }
	
	} elsif($MODE eq 'NODE1') {
		$MODE = "";
		$main->configure(-cursor=>"arrow"); # back to normal
		@resp = prompt_string("New Node","Enter the DNS name of the device","DNS:","");
		$resp = $resp[0];
		if($resp) {
			# New node!
			($err,$cfg) = getreply('IDENTIFY',$resp);
			if($err or !$cfg) {
				chomp $err;
				$status = "Error: $err";
				doalert($err);
				return;
			} else {
				chomp $cfg;
				$status = "Node identified as $cfg";
				$resp = $cfg; $resp =~ s/\.cfg$//;
				$resp =~ s/^.*\///;
			}
			if(defined $nodes{$resp}) {
				$status = "Node already exists!";
				doalert($status);
				return;
			}
			$nodes{$resp}{_X2d} = $xpos;
			$nodes{$resp}{_Y2d} = $ypos;
			$nodes{$resp}{LABEL} = "$resp";
			$nodes{$resp}{_CFGFILE} = $cfg if($cfg);
			default_links($resp);
			getimage($deficon) if($deficon);
			&create_node($resp);
			$change = 1;
		} else { $status = "Cancelled"; }

	}
}
sub set_title {
	my(@resp,$resp);
	@resp = prompt_string("Map Title","Enter new map title","Title:",($maptitle?$maptitle:"Network Weathermap"));
	$resp = $resp[0];
	if($resp) {
		$maptitle = $resp;
		$canvas->itemconfigure($titleobj,-text=>$maptitle);		
		$change = 1;
	}
}
###########
sub mw_size { # Set MainWindow size
	my $size=0.9;
	my($dx,$dy)=($main->screenwidth,$main->screenheight);
	$dx = $dx > 1024 ? 1024 : $dx;
	$dy = $dy > 768 ? 768 : $dy;
	return int($size*$dx)."x".int($size*$dy)
}

############
sub selectmap {
	my(@maps);

	@maps = getlist('LISTCFG','');
	@maps = sort @maps;
	$currentmap = prompt_list( "Open Map","Select the map to open from the list",
		"","browse",\@maps);

}

sub open_map {
	$canvas->parent->destroy if($canvas);
	&prepare;
	selectmap();
	return if(!$currentmap);
	$status = "Loading in map '$currentmap'";
	return if(loadcfg($currentmap));
	&update_objects;
	$status = "Creating objects...";
	&clear_ids;
	&create_objects;
	&bgimage;
	$status = "Map loaded OK.";
	$main->configure('-title'	=> 'WeatherMan v'.$VERSION.": $currentmap");
	$change = 0;
}
sub new_map {
	$canvas->parent->destroy if($canvas);
	&prepare;
	&update_objects;
	&clear_ids;

	# Need to set up some defaults here, though
	$global{HEIGHT} = 600;
	$global{WIDTH} = 800;
	$global{HTMLSTYLE} = "overlib";
	$nodes{DEFAULT}{ICON} = 'router.png';
        $nodes{DEFAULT}{LABELOFFSET}='S';
        $nodes{DEFAULT}{OVERLIBWIDTH}= 400;
        $nodes{DEFAULT}{OVERLIBHEIGHT}= 200;
	$links{DEFAULT}{OVERLIBWIDTH}= 400;
        $links{DEFAULT}{OVERLIBHEIGHT}= 200;

	($keyx,$keyy,$keytitle) = (5,430,"");
	$global{KEYPOS} = "$keyx $keyy"; $global{KEYPOS}.=" $keytitle" if($keytitle);
	($timex,$timey,$timeformat) = (610,580,"");
	$global{TIMEPOS} = "$timex $timey"; $global{TIMEPOS}.=" $timeformat" if($timeformat);
	($titlex,$titley,$maptitle) = (400,10,"New Map");
	$global{TITLEPOS} = "$titlex $titley"; $global{TITLEPOS}.=" $maptitle" if($maptitle);

	&create_objects;
	&bgimage;
	$currentmap = "";
	$main->configure('-title'	=> 'WeatherMan v'.$VERSION);
	$change = 0;
}

sub reset_legends {
	$canvas->delete($titleobj) if($titleobj);
	$canvas->delete($keyobj) if($keyobj);
	$canvas->delete($timeobj) if($timeobj);

	($keyx,$keyy,$keytitle) = (5,430,"");
	$global{KEYPOS} = "$keyx $keyy"; $global{KEYPOS}.=" $keytitle" if($keytitle);
	($timex,$timey,$timeformat) = (610,580,"");
	$global{TIMEPOS} = "$timex $timey"; $global{TIMEPOS}.=" $timeformat" if($timeformat);
	($titlex,$titley,$maptitle) = (400,10,"New Map");
	$global{TITLEPOS} = "$titlex $titley"; $global{TITLEPOS}.=" $maptitle" if($maptitle);
	&create_titles();
	$change = 1;
}

############
sub writemap {
	my($k,$kk,$v,$n,$l);
	my($req,$resp,$map,$stub);
	my($boundary) = "-----------------------".time();

	$stub = $currentmap; $stub =~ s/\.conf$//;

	$global{IMAGEOUTPUTFILE} =  "$stub.png";
	$global{HTMLOUTPUTFILE} =  "$stub.html";
	foreach ( qw/KEYPOS TIMEPOS TITLEPOS/ ) { undef $global{$_}; }
	if($keyx and $keyy) {
		$global{KEYPOS} = "$keyx $keyy"; $global{KEYPOS}.=" $keytitle" if($keytitle);
	}
	if($timex and $timey) {
		$global{TIMEPOS} = "$timex $timey"; $global{TIMEPOS}.=" $timeformat" if($timeformat);
	}
	if($titlex and $titley) {
		$global{TITLEPOS} = "$titlex $titley"; $global{TITLEPOS}.=" $maptitle" if($maptitle);
	}

	$map = "";
	$map .= "# Configuration generated by Weatherman v$VERSION editor, S Shipway 2007\n";
	$map .= "#\n# Global definitions\n";
	foreach $k ( sort keys %global ) { 
		if($k =~ /BACKGROUND/i) {
			$map .= "$k ".$rconfig{images}."/".$global{$k}."\n"; 
		} else {
			$map .= "$k ".$global{$k}."\n"; 
		}
	}
	$map .= "\n#\n# Set options\n";
	foreach $k ( @set ) {
		$map .= "SET $k\n";
	}
	$map .= "\n#\n# Font definitions\n";
	foreach $k ( @fontdefine ) {
		$map .= "FONTDEFINE $k\n";
	}
	$map .= "#\n# Scale definitions\n";
	foreach $kk ( sort keys %scale ) {
		$map .= "# Scale: $kk\n";
		foreach $k ( sort keys %{$scale{$kk}} ) {
			$map .= "SCALE ".(($kk eq 'DEFAULT')?"":$kk)." "
				.(join " ",@{$scale{$kk}{$k}})."\n";
		}
	}
	$map .= "\n#\n# Default Node definition\nNODE DEFAULT\n";
	foreach $k ( sort keys %{$nodes{DEFAULT}} ) {
		next if($k =~ /^_/);
		$v = $nodes{DEFAULT}{$k};
		$v = $rconfig{icons}.'/'.$v if($rconfig{icons} and $k eq "ICON" and $v !~/\//);
		$map .= "\t$k $v\n" if($v);
	}
	$map .= "\n#\n# Default Link definition\nLINK DEFAULT\n";
	foreach $k ( sort keys %{$links{DEFAULT}} ) {
		next if($k =~ /^_/);
		$v = $links{DEFAULT}{$k};
		$map .= "\t$k $v\n" if($v);
	}
	$map .= "\n#\n# Node definitions\n";
	foreach $n ( sort keys %nodes ) {
		next if(!$n or $n eq 'DEFAULT');
		next if(!defined $nodes{$n}{_X2d} and !defined $nodes{$n}{POSITIOn});
		$map .= "NODE $n\n";
		foreach $k ( sort keys %{$nodes{$n}} ) {
			next if($k =~ /^_/);
			$v = $nodes{$n}{$k};
			$v = $rconfig{icons}.'/'.$v if($rconfig{icons} and $k eq "ICON");
			$map .= "\t$k $v\n" if($v);
		}
		$map .= "\tPOSITION ".$nodes{$n}{_X2d}." ".$nodes{$n}{_Y2d}."\n"
			if($nodes{$n}{_X2d});
		$map .= "\n";
	}
	$map .= "\n#\n# Link definitions\n";
	foreach $l ( sort keys %links ) {
		next if(!$l or $l eq 'DEFAULT');
		next if(!defined $links{$l}{_from} and !defined $links{$l}{NODES});
		$map .= "LINK $l\n";
		foreach $k ( sort keys %{$links{$l}} ) {
			next if($k =~ /^_/);
			$v = $links{$l}{$k};
			$map .= "\t$k $v\n" if($v);
		}
		$map .= "\tNODES ".$links{$l}{_from}." ".$links{$l}{_to}."\n"
			if($links{$l}{_from});
		$map .= "\n";
	}
	$map .= "\n# End of file.  Generated ".localtime()."\n";

	open CFG,">$TMP/$currentmap";
	print CFG $map;
	close CFG;
	# call to put to remote :line630
	$req = HTTP::Request->new('POST'=>$HELPER);
	$map = "--$boundary\r\nContent-Disposition: form-data; name=\"C\"\r\n\r\n"
		."SAVECFG\r\n"
		."--$boundary\r\nContent-Disposition: form-data; name=\"A\"\r\n\r\n"
		."$currentmap\r\n"
		."--$boundary\r\nContent-Disposition: form-data; name=\"P\"\r\n\r\n"
		."$AUTHPW\r\n"
		."--$boundary\r\nContent-Disposition: form-data; name=\"F\"; filename=\"$currentmap\"\r\n"
		."Content-Type: application/octet-stream\r\n"
#		."Content-Length: ".length($map)."\r\n"
		."\r\n"
		.$map."\r\n--$boundary--\r\n";
	$req->header('Content-Type'=>"multipart/form-data; boundary=$boundary");	
#	$req->header('Content-Length'=>length($map));
	$req->content( $map );
#	print STDERR $req->as_string;
	$resp = $ua->request($req);
	if(!$resp or $resp->is_error()) {
		$status = "HTTP error trying to post map.";
		doalert("HTTP error");
	} elsif($resp->content() =~ /^ERROR\n(.*)/) {
		$status = "ERROR: helper: $1";
		doalert("ERROR: $1");
	} elsif( $resp->content() !~ /^OK/ ) {
		$status = "ERROR: Unexpected response from server: ".$resp->content();
		doalert("ERROR: Unexpected response");
	} else { $status = "Saved OK."; } 
	# clean up
	unlink "$TMP/map.conf";
}

sub save_map_as {
	my($newname,@resp);
	my(@maps);
	$status = "";
	@resp = prompt_string("Save As","Give a name for this new map","File:","default.conf");
	$newname = $resp[0];
	return if(!$newname);
	$newname .= ".conf" if($newname !~ /\.conf$/);
	if($newname =~ /\//) { $status = "Invalid name: may not contain /"; doalert($status); return; }
	@maps = getlist('LISTCFG','');
	foreach ( @maps ) {
		if( $_ eq $newname ) {
			if( ! &overwrite("$newname") ) { $status = "Cancelled"; return; }
			last;
		}
	}
	$currentmap = $newname;
	$main->configure('-title' => 'WeatherMan v'.$VERSION.": $currentmap");
	writemap();
}

sub save_map {
	$status = "";
	if($currentmap) {
		if( &overwrite("$currentmap") ) {
			writemap();
		} else { $status = "Cancelled"; }
	} else { save_map_as(); }
}


############
sub overwrite { # Toplevel overwrite dialog, returns 0 or 1
	my($file)=$_[0];
	my($retval,$dialog);

	$dialog = $main->Dialog(
		-title => "Overwrite confirm",	
		-text => "$file already exists\nOverwite?",
		-bitmap => 'warning',
		-buttons => [ qw/OK Cancel/ ],
		-default_button => 'Cancel'
	);
	$retval = $dialog->Show('-global');
	return 1 if($retval eq 'OK');
	return 0;
}

############
sub ask_save { # Toplevel ask dialog, returns 0 or 1
	my($retval,$dialog);

	$dialog = $main->Dialog(
		-title => "Save Map",	
		-text => "Save the current map?",
		-bitmap => 'question',
		-buttons => [ qw/Yes No/ ],
		-default_button => 'Yes'
	);
	$retval = $dialog->Show('-global');
	return 1 if($retval eq 'Yes');
	return 0;
}

############
sub update_objects { # Correcting read values
	my ($x,$y) = ($ICON_WIDTH,$ICON_HEIGHT);
	my ($deficon) = $nodes{DEFAULT}{ICON};
	$deficon = "unknown.png" if(!$deficon);
	getimage($deficon);
	foreach my $obj (keys %nodes) {
		next if ($obj eq 'DEFAULT');
		unless (defined $nodes{$obj}->{"_Y2d"}) {
			$nodes{$obj}->{"_X2d"} = $x;
			$nodes{$obj}->{"_Y2d"} = $y;
			$x += $ICON_WIDTH;
			if ($x > $GRID_WIDTH-$ICON_WIDTH) {
				$x = $ICON_WIDTH;
				$y += $ICON_HEIGHT;
			}
		}
		if ( defined $nodes{$obj}->{"ICON"} ) {
			my $img = $nodes{$obj}->{"ICON"};
			$img =~ s/\{.*\}//;
			getimage($img);
			if ( ! -f $TMP."\\".$img) {
				print STDERR "NOTICE: Image not found for $obj : '".$TMP."\\".$nodes{$obj}->{"ICON"}."', using default !\n";
			}
		}
		
	}
}
############
sub create_label($) {
	my($obj) = $_[0];
	my($font);
	my ($l,$t,$r,$b,$xpos,$ypos,$pos,$anchor);

	if(!$obj) {
		print STDERR "Error: passed a null node key.\n";
		return;
	}

	$font = $canvas->fontCreate('flabel',-family=>'fixed',-size=>(10));

	($l,$t,$r,$b)=$canvas->bbox($nodes{$obj}{"_ID"});
	($xpos,$ypos) = ($l+20,$b+10);
	$pos = 'S'; $anchor = 'center';
	$pos = $nodes{DEFAULT}{LABELOFFSET} if(defined $nodes{DEFAULT}{LABELOFFSET});
	$pos = $nodes{$obj}{LABELOFFSET} if(defined $nodes{$obj}{LABELOFFSET});
	if($pos =~ /ne/i ) {
		($xpos,$ypos) = ($r+5,$t-5); $anchor = 'sw';
	} elsif($pos =~ /nw/i ) {
		($xpos,$ypos) = ($l-5,$t-5); $anchor = 'se';
	} elsif($pos =~ /n/i ) {
		($xpos,$ypos) = ($l+20,$t-5); $anchor = 's';
	} elsif($pos =~ /se/i ) {
		($xpos,$ypos) = ($r+5,$b+5); $anchor = 'nw';
	} elsif($pos =~ /sw/i ) {
		($xpos,$ypos) = ($l-5,$b+5); $anchor = 'ne';
	} elsif($pos =~ /s/i ) {
		($xpos,$ypos) = ($l+20,$b+5); $anchor = 'n';
	} elsif($pos =~ /e/i ) {
		($xpos,$ypos) = ($r+5,$t+20); $anchor = 'w';
	} elsif($pos =~ /w/i ) {
		($xpos,$ypos) = ($l-5,$t+20); $anchor = 'e';
	} 
	$nodes{$obj}{_LabelID}=$canvas->createText(
		$xpos,$ypos,
		'-font'		=> 'flabel',
		'-text'		=> ($nodes{$obj}{LABEL}?$nodes{$obj}{LABEL}:$obj),
		'-anchor'	=> $anchor
	);

	$canvas->fontDelete($font);
}
sub create_node($) {
	my($obj) = $_[0];
	my($icon);

	if(!$obj) {
		print STDERR "Error: passed a null node key.\n";
		return;
	}
	$icon = ((defined $nodes{$obj}{"ICON"})?$nodes{$obj}{"ICON"}:$deficon);
	$icon =~ s/\{.*\}//;
	getimage($icon) if($icon);
	print STDERR "n(".$nodes{$obj}{"_X2d"}.",".$nodes{$obj}{"_Y2d"}.")";
	if( ! -r $TMP."\\".$icon ) {
		$icon = $deficon; getimage($icon);
	}
	if( -r $TMP."\\".$icon ) {	
		my $img = $main->Photo('-file'=>$TMP."\\".$icon, -format=>"PNG");
		$nodes{$obj}{"_ID"} = $canvas->createImage(
			$nodes{$obj}{"_X2d"},
			$nodes{$obj}{"_Y2d"},
			'-image'	=> $img,
			'-tags'		=> ["moveable",$obj]
		);
	}
	create_label($obj);
}
sub create_link($) {
	my($link) = $_[0];
	my($lineid,$fromobj,$toobj,$dx,$dy,$angle);
	my($w);

	if(!$link) {
		print STDERR  "Error: passed a null link key\n";
		return;
	}
	return if($link eq 'DEFAULT');

	print STDERR "l";
	$fromobj = $links{$link}{_from};
	$toobj = $links{$link}{_to};
	if(!$fromobj or !defined $nodes{$fromobj}) {
		print STDERR "Error: $link: Cannot find parent [$fromobj]\n";
		return;
	}
	if(!$toobj or !defined $nodes{$toobj}) {
		print STDERR "Error: $link: Cannot find parent [$toobj]\n";
		return;
	}
	$w = 10;
	$w = $links{DEFAULT}{WIDTH} if(defined $links{DEFAULT}{WIDTH});
	$w = $links{$link}{WIDTH} if(defined $links{$link}{WIDTH});
	if( defined $links{$link}{VIA} and $links{$link}{VIA}=~/(\d+\.?\d*)\s+(\d+\.?\d*)/ ) {
		my($x,$y) = ($1,$2);
		my($dx2,$dy2);
		$dx = $x - $nodes{$fromobj}{_X2d};
		$dy = $y - $nodes{$fromobj}{_Y2d};
		$angle = atan2($dy,$dx);
		$dx = 20 * cos($angle); $dy = 20 * sin($angle);
		$dx2 = $nodes{$toobj}{_X2d} - $x;
		$dy2 = $nodes{$toobj}{_Y2d} - $y;
		$angle = atan2($dy2,$dx2);
		$dx2 = 20 * cos($angle); $dy2 = 20 * sin($angle);
		my $viaid = $canvas->createOval($x-5,$y-5,$x+5,$y+5,
			-fill => 'White', -outline => 'Green',
			-width => 2, -tags=> ["via","V:$link","moveable"] 
		);
		$links{$link}{_ViaID} = $viaid;
		$lineid=$canvas->createLine(
			$nodes{$fromobj}{_X2d}+$dx,$nodes{$fromobj}{_Y2d}+$dy,
			$x,$y,
			$nodes{$toobj}{_X2d}-$dx2,$nodes{$toobj}{_Y2d}-$dy2,
			'-tags'		=> ["line",$link],
			'-arrow'	=> 'last',
			'-width'	=> ($w*2),
			'-smooth'	=> 1
		);
		$canvas->lower($lineid,$viaid);
		$links{$link}{_vx} = $x;
		$links{$link}{_vy} = $y;
	} else {
		$dx = $nodes{$toobj}{_X2d} - $nodes{$fromobj}{_X2d};
		$dy = $nodes{$toobj}{_Y2d} - $nodes{$fromobj}{_Y2d};
		$angle = atan2($dy,$dx);
		$dx = 20 * cos($angle); $dy = 20 * sin($angle);
		$lineid=$canvas->createLine(
			$nodes{$fromobj}{_X2d}+$dx,$nodes{$fromobj}{_Y2d}+$dy,
			$nodes{$toobj}{_X2d}-$dx,$nodes{$toobj}{_Y2d}-$dy,
			'-tags'		=> ["line",$link],
			'-arrow'	=> 'last',
			'-width'	=> ($w*2)
		);
	}
	$links{$link}{_ID} = $lineid;
	$nodes{$fromobj}{_LineID}{$link}=$toobj;
	$nodes{$toobj}{_LineID}{$link}=$fromobj;
}
sub create_titles {
	my($font);
	# Now create the moveable labels for the title, legend and time
	if($titlex and $titley) {
		$font = $canvas->fontCreate('ftitle',-family=>'fixed',-size=>(10));
		$titleobj = $canvas->createText(
			$titlex,$titley,
			'-font'		=> 'ftitle', '-anchor' => 'nw',
			'-text'		=> ($maptitle?$maptitle:"MAP TITLE"),
			'-tags'		=> ['moveable','x-maptitle']
		);
		$canvas->fontDelete($font);
	}
	if($timex and $timey) {
		$font = $canvas->fontCreate('ftimestamp',-family=>'fixed',-size=>(10));
		$timeobj = $canvas->createText(
			$timex,$timey,
			'-font'		=> 'ftimestamp','-anchor' => 'nw',
			'-text'		=> "Timestamp goes here",  # Line 1239
			'-tags'		=> ['moveable','x-maptimestamp']
		);
		$canvas->fontDelete($font);
	}
	if($keyx and $keyy) {
		$font = $canvas->fontCreate('fkey',-family=>'fixed',-size=>(20));
		$keyobj = $canvas->createText(
			$keyx,$keyy,
			'-font'		=> 'fkey',
			'-anchor' 	=> 'nw', 
			'-justify'	=>'center',
			'-text'		=> "Legend\ngoes\nhere:\n".($keytitle?$keytitle:"Traffic"),
			'-tags'		=> ['moveable','x-maplegend']
		);
		$canvas->fontDelete($font);
		# $canvas->itemconfigure($keyobj,-background=>'grey');
	}
}
sub create_objects { # Create canvas objects stored in %nodes/%links
	$deficon = $nodes{DEFAULT}{ICON};
	$deficon = "unknown.png" if(!$deficon);
	getimage($deficon);

	foreach my $obj (keys %nodes) {
		next if($obj eq 'DEFAULT');
		create_node($obj);
	}
	foreach my $link ( keys %links ) {
		next if($link eq 'DEFAULT');
		create_link($link);
	}

	create_titles();

	$canvas->lower("line","moveable");
	$canvas->lower("grid","line");
	
	enable_save;
#	print STDERR "\n";
	$status = "Objects created";
}

############
sub highlight { # Highlight objects label under the mouse cursor
	my($obj,$event)=@_;
	my($name,$amp);
	return if($MODE);
	$name=($canvas->gettags($canvas->find("withtag","current")))[1];
	return if(!defined $nodes{$name}); # this is a label
	if ($event eq 'EnterNotify') {
		$canvas->itemconfigure($nodes{$name}->{_LabelID},'-fill' => 'Red');
		if( defined $nodes{$name}{INFOURL} and $nodes{$name}{INFOURL}=~/^[^\/].*\.html?$/) {
			$status = "SUBMAP: $name";
		} else {
			$status = "NODE: $name";
		}
		for my $line (keys %{$nodes{$name}{_LineID}}) {
			$canvas->itemconfigure($line,'-fill' => 'Red')
				if( $links{$line}{_from} eq $name );
		}
	} else {
		$canvas->itemconfigure($nodes{$name}->{_LabelID},'-fill' => 'Black');
		$status = "";
		for my $line (keys %{$nodes{$name}{_LineID}}) {
			$canvas->itemconfigure($line,'-fill' => 'Black')
				if( $links{$line}{_from} eq $name );
		}
	}
}
sub lhighlight { # link highlight
	my($obj,$event)=@_;
	my($name,$amp);
	return if($MODE);
	$name=($canvas->gettags($canvas->find("withtag","current")))[1];
	if ($event eq 'EnterNotify') {
		$canvas->itemconfigure($name,'-fill' => 'Red');
		$status = "LINK: $name (".$links{$name}{_from}.")";
		$canvas->itemconfigure($links{$name}{_ViaID},'-fill' => 'Red')
			if(defined $links{$name}{_ViaID});

	} else {
		$canvas->itemconfigure($name,'-fill' => 'Black');
		$canvas->itemconfigure($links{$name}{_ViaID},'-fill' => 'White')
			if(defined $links{$name}{_ViaID});
		$status = "";
	}
}

############
sub snaptogrid {
	my ($v)=@_;
	if ($canvas->find("withtag","grid")) {
		return 5*int($v/5);
	}
	return $v;
}

############
sub del_link($) {
	my($name) = $_[0];
	my(%list);
	foreach my $node ( $links{$name}{_from}, $links{$name}{_to} ) {
		%list = ();
		foreach ( keys %{$nodes{$node}{_LineID}} ) {
			$list{$_}=$nodes{$node}{_LineID}{$_} if($_ ne $name);
		}
		$nodes{$node}{_LineID} = { %list };
	}
	$canvas->delete($links{$name}{_ID});
	$canvas->delete($links{$name}{_ViaID}) if(defined $links{$name}{_ViaID});
	undef $links{$name};
}

sub drag_start { # Callback for button 1 click
	my ($obj,$x,$y) = @_;
	my($id,$name);

	$id = $canvas->find("withtag","current");
	$name = ($canvas->gettags($id))[1];

	if($MODE eq 'DELETE') {
		# delete links
		return if(!defined $nodes{$name}); # avoid via points and labels 
		foreach ( keys %{$nodes{$name}{_LineID}} ) {
			del_link(($canvas->gettags($_))[1]);
		}
		# delete node
		$canvas->delete($id);
		$canvas->delete($nodes{$name}{_LabelID});
		undef $nodes{$name};
		$status = "Node deleted.";
		$MODE = "";
		$main->configure(-cursor=>"arrow"); # back to normal
		return;
	} elsif( $MODE =~ /LINK1/ ) { # Start creating link - pick targetname
		my($d,@descs,@choices);
		return if(!defined $nodes{$name});
		$linkstart = $name;
		if( !defined $nodes{$name}{_LINKS} or !defined $nodes{$name}{_CFGFILE} ) {
			$status = "This node does not have any Targets.";
			doalert($status);
			$MODE = "";
			$main->configure(-cursor=>"arrow"); # back to normal
			return;
		}	
		@descs = @choices = ();
		foreach ( sort keys %{$nodes{$name}{_LINKS}} ) {	
			push @choices, $_;
			$d = $nodes{$name}{_LINKS}{$_}[2];
			$d = $_ if(!$d);
			push @descs, $d;
		}
		$linktarget = prompt_list("Select Interface",
"Select which targetname corresponds to the outgoing interface","",
"browse", \@choices, \@descs );
		if( ! $linktarget ) {
			$status = "Cancelled";
			$MODE = "";
			$main->configure(-cursor=>"arrow"); # back to normal
			return;
		}
		if(defined $links{$linktarget} ) {
			$status = "This link is already on the map";
			doalert($status);
			$MODE = "";
			$main->configure(-cursor=>"arrow"); # back to normal
			return;
		}
		$status = "Now click on the destination node.";
		if($MODE =~ /^V/) { $MODE = "VLINK2"; } else { $MODE = "LINK2"; }
		return;
	} elsif( $MODE =~ /LINK2/ ) { # finish creating link
		my($cfg,$viax,$viay);
		return if(!defined $nodes{$name});
		if($linkstart eq $name) {
			$status = "Cannot link back to same node!";
			doalert($status);
			$MODE = "";
			$main->configure(-cursor=>"arrow"); # back to normal
			return;
		}
		$links{$linktarget}{_from} = $linkstart;				
		$links{$linktarget}{_to} = $name;
		default_links_link($linktarget);
		$links{$linktarget}{BANDWIDTH} = $nodes{$linkstart}{_LINKS}{$linktarget}[1];
		if($MODE eq 'VLINK2') {
			$viax = int( ($nodes{$linkstart}{_X2d} + $nodes{$name}{_X2d} ) / 2);
			$viay = int( ($nodes{$linkstart}{_Y2d} + $nodes{$name}{_Y2d} ) / 2);
			$links{$linktarget}{VIA} = "$viax $viay" if($viax and $viay);
		}
		create_link($linktarget);
		$MODE = "";
		$main->configure(-cursor=>"arrow"); # back to normal
		return;
	} 

	# so, it is something draggable.

	$objprop{x} = $x;
	$objprop{y} = $y;
	$objprop{obj} = $id;

	my ($l1,$t1) = $canvas->bbox($objprop{obj});
	$objprop{x} = snaptogrid($x)+($l1-snaptogrid($l1));
	$objprop{y} = snaptogrid($y)+($t1-snaptogrid($t1));
}
sub delete_link {
	my ($obj,$x,$y) = @_;
	my ($name);

	return if( $MODE ne 'DELETE' );	
	$name = ($canvas->gettags($canvas->find("withtag","current")))[1];
	del_link($name);
	$status = "Link deleted.";
	$MODE = "";
	$main->configure(-cursor=>"arrow"); # back to normal
}


############
sub drag_it { # Callback for button 1 motion - moves object, label and lines
	my ($obj,$x,$y) = @_;
	my ($dx,$dy,$dx2,$dy2,$angle,$x1,$y1);

	$change = 1;

	$x = snaptogrid($x);
	$y = snaptogrid($y);
	
	$dx = ($x-$objprop{x});
	$dy = ($y-$objprop{y});
	
	$objprop{x} = $x;
	$objprop{y} = $y;

	$xpos = $x ;
	$ypos = $y ;
	
	# move icon :
	$canvas->move($objprop{obj},$dx,$dy);

	# get key
	my $name = ($canvas->gettags($objprop{obj}))[1];

	# bonding coords
	my ($l1,$t1,$r1,$b1) = $canvas->bbox($objprop{obj});

	# show object coords :
	($xpos,$ypos) = ($l1,$t1); 

	# is this a label, or a node?
	if(!defined $nodes{$name}) {
		
		# its a label
		if($name eq 'x-maptitle') {
#			$status = "Moved to: $l1,$t1,$r1,$b1 -- x/y = $x,$y -- ypos = $ypos";
			($titlex,$titley)=($l1,$t1);
		} elsif($name eq 'x-maptimestamp')	{
			($timex,$timey)=($l1,$t1);
		} elsif($name eq 'x-maplegend') {	
			($keyx,$keyy)=($l1,$t1);
		} elsif( $name =~ /^V:(\S+)/ ) { # its a via point. oh dear.
			$name = $1; # now we have the real link name
			$links{$name}{VIA}=~/(\d+\.?\d*)\s+(\d+\.?\d*)/;
			$x1 = int($1 + $dx); $y1 = int($2 + $dy);
			$links{$name}{VIA} = "$x1 $y1";
			$dx = $x1 - $nodes{$links{$name}{_from}}->{"_X2d"};
			$dy = $y1 - $nodes{$links{$name}{_from}}->{"_Y2d"};
			$angle = atan2($dy,$dx);
			$dx = 20 * cos($angle); $dy = 20 * sin($angle);
			$dx2 = $nodes{$links{$name}{_to}}->{"_X2d"} - $x1;
			$dy2 = $nodes{$links{$name}{_to}}->{"_Y2d"} - $y1;
			$angle = atan2($dy2,$dx2);
			$dx2 = 20 * cos($angle); $dy2 = 20 * sin($angle);
			$canvas->coords($links{$name}{_ID},
				$nodes{$links{$name}{_from}}{_X2d}+$dx,
				$nodes{$links{$name}{_from}}{_Y2d}+$dy,
				$x1,$y1,
				$nodes{$links{$name}{_to}}{_X2d}-$dx2,
				$nodes{$links{$name}{_to}}{_Y2d}-$dy2
			);
			$links{$name}{_vx} = $x1;
			$links{$name}{_vy} = $y1;
		} else { $status = "Warning: unknown label $name"; }
		return;
	}
	# so, its a node.

	# move label :
	$canvas->move($nodes{$name}->{_LabelID},$dx,$dy);

	# save objects coords :
	($nodes{$name}{"_X2d"},$nodes{$name}{"_Y2d"}) = $canvas->coords($objprop{obj});
	if(( $nodes{$name}{"_X2d"} < 0 ) or ( $nodes{$name}{"_Y2d"} < 0 )) {
		$nodes{$name}{"_X2d"} = 5; $nodes{$name}{"_Y2d"} = 5;
	}

	# center coords
	($x1,$y1) = ($l1+(int(($r1-$l1)/2)),$t1+(int(($b1-$t1)/2)));

	# move all wires :
	for my $line (keys %{$nodes{$name}{_LineID}}) {
		if( defined $links{$line}{_ViaID}  ) {
			my($vx,$vy);
			$links{$line}{VIA}=~/(\d+\.?\d*)\s+(\d+\.?\d*)/;
			($vx,$vy) = ($1,$2);
			#$status = "Link via ".$links{$line}{VIA};
			$dx = $vx - $nodes{$links{$line}{_from}}->{"_X2d"};
			$dy = $vy - $nodes{$links{$line}{_from}}->{"_Y2d"};
			$angle = atan2($dy,$dx);
			$dx = 20 * cos($angle); $dy = 20 * sin($angle);
			$dx2 = $nodes{$links{$line}{_to}}->{"_X2d"} - $vx;
			$dy2 = $nodes{$links{$line}{_to}}->{"_Y2d"} - $vy;
			$angle = atan2($dy2,$dx2);
			$dx2 = 20 * cos($angle); $dy2 = 20 * sin($angle);
			$canvas->coords($links{$line}{_ID},
				$nodes{$links{$line}{_from}}{_X2d}+$dx,
				$nodes{$links{$line}{_from}}{_Y2d}+$dy,
				$vx,$vy,
				$nodes{$links{$line}{_to}}{_X2d}-$dx2,
				$nodes{$links{$line}{_to}}{_Y2d}-$dy2
			);
		} else {
			$dx = $nodes{$links{$line}{_to}}->{"_X2d"} - $nodes{$links{$line}{_from}}->{"_X2d"};
			$dy = $nodes{$links{$line}{_to}}->{"_Y2d"} - $nodes{$links{$line}{_from}}->{"_Y2d"};
			$angle = atan2($dy,$dx);
			$dx = 20 * cos($angle); $dy = 20 * sin($angle);
			$canvas->coords($links{$line}{_ID},
				$nodes{$links{$line}{_from}}{_X2d}+$dx,
				$nodes{$links{$line}{_from}}{_Y2d}+$dy,
				$nodes{$links{$line}{_to}}{_X2d}-$dx,
				$nodes{$links{$line}{_to}}{_Y2d}-$dy
			);
		}
	}


}

############
sub change_node {
	my($obj,$x,$y)=@_;
	my($id,$name,$img,$choice);
	$change = 1;
	$id = $canvas->find("withtag","current");
	$name = ($canvas->gettags($id))[1];

	if(!defined $nodes{$name}) {
#		if( $name eq 'x-maptitle' ) {
			do_properties('t',$name);
#		}
		$status = "";
		return;
	}
	do_properties('n',$name);
	$status = "";

}
sub change_node_icon { 
	my($name,$ref,$targetref)=@_;
	my($id,$img,$choice,$statusmode);
	$change = 1;
	$statusmode = 0; $statusmode = 1 if($targetref and $$targetref);
	$img = $nodes{$name}{"ICON"};  $img =~ s/\{.*\}//g if($statusmode);
	$choice = &choose_type($img,$statusmode);
	if($choice) {
		if($ref) {
			$$ref = $choice;
		} else {
			$choice =~ s/\.png$/{node:this:bandwidth_in}.png/ if($statusmode);
			$nodes{$name}{"ICON"} = $choice;
			$choice =~ s/\{.*\}//g;
			getimage($choice);
			if($name ne 'DEFAULT') {
				$img=$main->Photo('-file' => $TMP."\\".$choice);
				$canvas->itemconfigure($nodes{$name}{_ID},'-image' => $img);
			}
		}
	}
}
sub change_link { # Callback for button 3 - change type of the object
	my($obj,$x,$y)=@_;
	my($id,$name,$img,$choice);
	$change = 1;
	$id = $canvas->find("withtag","current");
	$name = ($canvas->gettags($id))[1];
	
	do_properties('l',$name);
	$status = "";
}
sub default_node {
	do_properties('nd','DEFAULT');
}
sub default_link {
	do_properties('ld','DEFAULT');
}
############
sub choose_type { # Change type top level widget - returns image file
	my ($current,$statusmode)=@_;
	my ($count,$cv,$type,$img,$i,$h,$w,$wmax,$hsum,$x,$y);
	my $space = 4;
	my @images = ();

	$type=$main->Toplevel('-title'	=>("Choose type"));
	$x = $main->pointerx();
	$y = $main->pointery();
	$type->geometry("+$x+$y");
	$type->resizable(0,1);
	$type->transient($main);
	$x = $type->Scrolled('Canvas', 
		'-height'		=> 300,
		'-scrollbars'	        =>'osoe',
	)->pack(
		'-fill'			=> 'both',
		'-expand'		=> 1
	);
	$cv = $x->Subwidget("canvas");
	$hsum = 0;
	$count = $space;
	$wmax = 0;

	if($statusmode) {
		$current =~ s/\{.*\}//g;
		@images = getlist("LISTSTATUSICONS",'');
	} else {
		@images = getlist("LISTICONS",'');
	}
	for $img (@images) {
		$img = $rconfig{scale}."/$img" if($statusmode);
		getimage($img);
		if( ! -f $TMP."\\".$img ) {
			print STDERR "Unable to retrieve ".$TMP."\\".$img."\n";
		}
		$i=$main->Photo(
			'-file'			=> $TMP."\\".$img,
		);
		$h=$i->height;
		$w=$i->width;
		$wmax= $w > $wmax ? $w : $wmax;
		$hsum+=$h;
		$y=$cv->Radiobutton(
			'-image'		=> $i,
			'-height'		=> $h,
			'-value'		=> $img,
			'-variable'		=> \$current,
			'-command'		=> sub{$type->grabRelease;$type->destroy},
		);
		$cv->createWindow($w,$count+int($i->height/2), '-window' => $y);
		$count=$count+$h+$space;
	}
	$x->configure(
		'-width'			=> $wmax+50,
		'-scrollregion'		=> [0, 0, $wmax+50, $space+$hsum+$#images*$space]
	);
	$type->update;
	$type->grab;
	$type->waitWindow;
	if($statusmode) {
		$current =~ s/\.png$/{node:this:bandwidth_in}.png/;
	}
	return $current;
}

############
sub close_current { # Close current map 
	if ($change) { save_map; }

	disable_save;

	$canvas->parent->destroy;
	&prepare;
}

############
sub about { # Show about
	my($label,$about,$but);
	my $MSG="Copyright (c) 2000-2007\n";

	$MSG.="\nAuthors:\n";

	$MSG.="	Steve Shipway <steve\@steveshipway.org> (heavily modified original framework for Weathermap use)\n";
	$MSG.="	Stéphane Urbanovski <s.urbanovski\@ac-nancy-metz.fr> (Nagios adaptation and i18n support)\n";
	$MSG.="	David Kmoch <David.Kmoch\@vslib.cz> (original NetSaint map editor author)\n";
	$MSG.="\nThanks to:\n";
	$MSG.="	Petr Adamec <Petr.Adamec\@vslib.cz> for the idea
	Ethan Galstad <netsaint\@netsaint.org> for NetSaint and Nagios
	Adrian Pavlykevych <pam\@polynet.lviv.ua> and
	Szilard Fulop <silas\@fornax.hu> for patches and new ideas.\n";

	$MSG.="\nLicense:\n";
	$MSG.="	This program is free software; you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation; either version 2 of the License, or
	(at your option) any later version.
	";
	$MSG.= "	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.
	";

	$about=$main->Toplevel(
		'-title'	=> ("About WeatherMan")
	);
	$about->geometry("+".int($main->width/4)."+".int($main->height/4));
	$about->transient($main);
	$about->resizable(0,0);
	$about->grab;
	$label=$about->Label(
		'-text'		=> "WeatherMan v$VERSION\nHelper.cgi v".$rconfig{version}."\n\n$MSG",
#		'-font'		=> "7x13",
		'-justify'	=> 'left'
	)->pack(
		'-padx'		=> 5,
		'-pady'		=> 5,
		'-expand'	=> 1,
	);
	$but=$about->Button(
		'-text'		=> ("OK"),
		'-command'	=> sub{$about->grabRelease;$about->destroy},
	)->pack(
		'-pady'		=> 10
	);
}

############
sub quit_it { # Obvious
	$main->destroy;
	exit;
}  
