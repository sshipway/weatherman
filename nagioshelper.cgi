#!/usr/bin/perl -w
#
# Helper program for weatherman Nagios plugin

use strict;
use CGI;

my($STATUS) = "/u02/nagios/log/status.log";

my($q) = new CGI;
my($MATCH,$HOST,$SVC);

print $q->header('text/plain');
$HOST = $q->param('host');
$SVC  = $q->param('service');
if(!$HOST) {
	print "ERROR\nNo hostname specified\n";
	exit 0;
}
open STATUS,"<$STATUS" or do {
	print "ERROR\n$STATUS: $!\n";
	exit 0;
};
if($SVC) {
	$MATCH = "^\\[\\d+\]\\s+SERVICE;$HOST;$SVC;([^;]+);";
} else {
	$MATCH = "^\\[\\d+\]\\s+HOST;$HOST;([^;]+);";
}
while ( <STATUS> ) {
	next if(! /$MATCH/ );
	print "STATUS=$1\n";
	exit 0;
}
print "ERROR\nHost/Service not found in status.log file\n";
exit 0;
