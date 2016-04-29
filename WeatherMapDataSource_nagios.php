<?php
// Pluggable datasource for PHP Weathermap 0.9
// Obtain status for a Nagios host, either locally or via helper plugin

// Steve Shipway, 2007  http://www.steveshipway.org/forum

// Version 1.3  Jan 2007

// Weathermap is written by Howard Jones
// Nagios is written by Ethan Galstead, www.nagios.com

// TARGET nagios:hostname
// TARGET nagios:hostname:servicename
//
// If hostname or servicename contain spaces, they must be replaced with
// %20 because Weathermap tokenises on whitespace and does not recognise quotes
// Hostname cannot contain colons, although the servicename can
//
// Using http and the default CGI paths:
// SET nagios_host nagios.mydomain.co.uk
// Using normal CGIs but at nonstandard locations:
// SET nagios_extinfo http://nagiosserver/nagios/cgi-bin/extinfo.cgi
// Using local nagios.log file:
// SET nagios_logfile /usr/share/nagios/log/nagios.log
// Using helper cgi script on Nagios server
// SET nagios_helper http://nagios/cgi-bin/helper.cgi?host=
// If authentication is required:
// SET nagios_username username
// SET nagios_password password
//
// Then, you can use things like this:
// ICON icons/scale/host{node:this:bandwidth_in}.png
// provided you have the appropriate png files available, or
// SCALE updown 0 0.9       0 255   0
// SCALE updown 0.9 1.9   255 255   0
// SCALE updown 1.9 2.9   255   0   0
// SCALE updown 2.9 100     0   0 255
// NODE foo
//   USESCALE updown
// to set the label background colour to match the status according to the
// colours specified in scale 'updown'.
//
// Version 1.2 : Added helper.cgi support

class WeatherMapDataSource_nagios extends WeatherMapDataSource {

    function Init(&$map) {
		// do we have a normal CGI URL defined?
        $nagioshost = $map->get_hint("nagios_host");
		$nagiosurl = '';
		if( $nagioshost ) {
			$nagiosurl = "http://".$nagioshost.'/nagios/cgi-bin/extinfo.cgi';
		}
        $v = $map->get_hint("nagios_extinfo");
		if( $v ) {
			if(!preg_match("/^http/",$v,$matches)) { 
				warn("Nagios URL must be an http/https URL.\n");
				return(FALSE);
			}
			$nagiosurl = $v;
		}
		// How about a logfile?
        $nagioslogfile = $map->get_hint("nagios_logfile");
		if($nagioslogfile and !file_exists($nagioslogfile) ) {
			warn("Nagios logfile ".$nagioslogfile." does not exist.\n");
			return(FALSE);
		}
		// Or a helper cgi URL?
        $nagioshelper = $map->get_hint("nagios_helper");
		if($nagioshelper and !preg_match("/^http/",$nagioshelper,$matches)) {
			warn("Nagios helper URL must be an http/https URL\n");
			return(FALSE);
		}
		// Check that we know at least one way to get the data
		if( ! $nagiosurl and ! $nagioslogfile and ! $nagioshelper ) { 
			warn("Nagios datasource will not work unless you SET nagios_host, nagios_extinfo, nagios_logfile or nagios_helper.\n");
			return(FALSE); }
        return(TRUE);
    }

	function Recognise($targetstring) {
		if(preg_match("/^nagios:/",$targetstring,$matches)) {
			return TRUE;
		} else {
			return FALSE;
		}
	}

	function ReadData($targetstring, &$map, &$item) {
		$status = -1; // return a -1 for error (Nagios gives 3 for unknown)
		$data_time = 0;
		$hostname = '';
		$servicename = '';
		$username = ''; $password = '';
        $nagioshelper = $map->get_hint("nagios_helper");
        $nagioslogfile = $map->get_hint("nagios_logfile");

		// Any usernames or passwords set up?
        $username = $map->get_hint("nagios_username");
        $password = $map->get_hint("nagios_password");
		$nagiosurl = '';
        $nagioshost = $map->get_hint("nagios_host");
		if( $nagioshost ) {
			$nagiosurl = "http://".$nagioshost.'/nagios/cgi-bin/extinfo.cgi';
		}
        $v = $map->get_hint("nagios_extinfo");
		if( $v ) {
			if(preg_match("/^http/",$v,$matches)) { 
				$nagiosurl = $v;
			}
		}

		if(preg_match("/^nagios:([^:]+):(\S.*)$/",$targetstring,$matches)) {
			$hostname = $matches[1];
			$servicename = $matches[2];
		} else if(preg_match("/^nagios:(\S.*)$/",$targetstring,$matches)) {
			$hostname = $matches[1];
		}
		if($hostname) {
			$data = "";
			if($nagiosurl) {
				$ch = curl_init();
				if($servicename) {
					$servicename = preg_replace("/ /","%20",$servicename);
					curl_setopt($ch, CURLOPT_URL, $nagiosurl.'?type=2&host='.$hostname.'&service='.$servicename);
				} else {
					curl_setopt($ch, CURLOPT_URL, $nagiosurl.'?type=1&host='.$hostname);
				}
				curl_setopt($ch, CURLOPT_HEADER, 1);
				curl_setopt($ch, CURLOPT_USERAGENT, "Weathermap Nagios plugin v0.1");
				curl_setopt($ch, CURLOPT_FOLLOWLOCATION, 1);
				curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);
				curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, 0);
				curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, 0);
				if($username) {
					curl_setopt($ch, CURLOPT_USERPWD, $username.":".$password);
				}
				$data = curl_exec($ch);
				curl_close($ch);
				if ($data) {
					// parse the returned HTML web page	
					if(preg_match(
						'/ Status:.*DIV\s+CLASS=[\'"]?(host|service)(UP|DOWN|UNREACHABLE|CRITICAL|WARNING|UNKNOWN|OK)/i',
						$data,$matches)) {
						if($matches[2] == 'UP') { $status = 0; }
						else if($matches[2] == 'DOWN') { $status = 2; }
						else if($matches[2] == 'UNREACHABLE') { $status = 3; }
						else if($matches[2] == 'OK') { $status = 0; }
						else if($matches[2] == 'WARNING') { $status = 1; }
						else if($matches[2] == 'CRITICAL') { $status = 2; }
						else if($matches[2] == 'UNKNOWN') { $status = 3; }
						else {
							warn("Nagios ReadData: Unable to parse CGI output (".$matches[2].")\n");
						}
					} else {
						warn("Nagios ReadData: Unable to parse CGI output\n");
					}
				} else {
					warn("Nagios ReadData: Error:".curl_error($ch)."\n");
				}
			} else if( $nagioshelper ) {
				$data = "";
				$ch = curl_init();
				if($servicename) {
					$servicename = preg_replace("/ /","%20",$servicename);
					curl_setopt($ch, CURLOPT_URL, $nagioshelper.'?host='.$hostname.'&service='.$servicename);
				} else {
					curl_setopt($ch, CURLOPT_URL, $nagioshelper.'?host='.$hostname);
				}
				curl_setopt($ch, CURLOPT_HEADER, 1);
				curl_setopt($ch, CURLOPT_USERAGENT, "Weathermap Nagios plugin v0.1");
				curl_setopt($ch, CURLOPT_FOLLOWLOCATION, 1);
				curl_setopt($ch, CURLOPT_RETURNTRANSFER, 1);
				curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, 0);
				curl_setopt($ch, CURLOPT_SSL_VERIFYHOST, 0);
				if($username) {
					curl_setopt($ch, CURLOPT_USERPWD, $username.":".$password);
				}
				$data = curl_exec($ch);
				curl_close($ch);
				if ($data) {
					// parse the returned status info
					if(preg_match('/STATUS=(UP|DOWN|UNREACHABLE|CRITICAL|WARNING|UNKNOWN|OK)/i', $data,$matches)) {
						if($matches[1] == 'UP') { $status = 0; }
						else if($matches[1] == 'DOWN') { $status = 2; }
						else if($matches[1] == 'UNREACHABLE') { $status = 3; }
						else if($matches[1] == 'OK') { $status = 0; }
						else if($matches[1] == 'WARNING') { $status = 1; }
						else if($matches[1] == 'CRITICAL') { $status = 2; }
						else if($matches[1] == 'UNKNOWN') { $status = 3; }
						else {
							warn("Nagios ReadData: Unable to parse helper output (".$matches[1].")\n");
						}
					} else {
						warn("Nagios ReadData: Unable to parse helper output\n");
					}
				} else {
					warn("Nagios ReadData: Error:".curl_error($ch)."\n");
				}
			} else if( $nagioslogfile ) {
				if($servicename) {
					$servicename = preg_replace("/%20/"," ",$servicename);
					$matchstring = "/^\[\d+\] SERVICE;$hostname;$servicename;([^;]+);/i";
				} else {
					$matchstring = "/^\[\d+\] HOST;$hostname;([^;]+);/i";
				}
				if( ! is_readable($nagioslogfile) ) {
					warn("Cannot read Nagios logfile $nagioslogfile\n");
				} else {
					$fh = fopen($nagioslogfile,"r");
					if ($fh) {
						while (!feof($fh)) {
							$buffer = fgets($fh, 4096);
							if( preg_match($matchstring,$buffer,$matches) ) {
								if($matches[1] == 'UP') { $status = 0; }
								else if($matches[1] == 'DOWN') { $status = 2; }
								else if($matches[1] == 'UNREACHABLE') { $status = 3; }
								else if($matches[1] == 'OK') { $status = 0; }
								else if($matches[1] == 'WARNING') { $status = 1; }
								else if($matches[1] == 'CRITICAL') { $status = 2; }
								else if($matches[1] == 'UNKNOWN') { $status = 3; }
								else {
									warn("Nagios ReadData: Unable to parse status.log file (".$matches[2].")\n");
								}
								break;
							}
						}
						fclose($fh);
					} else {
						warn("Error opening Nagios logfile $nagioslogfile\n");
					}
				}
			} // operational modes
		} // check target format

		debug ("Nagios ReadData: Returning ($status,$data_time)\n");
		return( array($status, $status, $data_time) );
	}
}


// vim:ts=4:sw=4:
?>
