#!/usr/bin/perl
use strict;
use Net::FTP;
use File::Listing qw(parse_dir);
use Data::Dumper;
use JSON;
use Encode;
use POSIX qw (strftime);
use ISO8601 qw(ymd_to_cjdn);
use File::Copy;
use Getopt::Long;
use Time::Local;

my @d=localtime;
my $nowjd=ymd_to_cjdn($d[5]+1900,$d[4]+1,$d[3])+(($d[2]*60*60+$d[1]*60+$d[0]+20)/86400);

my $debug = '';

GetOptions ('debug' => \$debug);

log_info ("START JDTIME=$nowjd");

my $config_dir='z:/from_virt/exchange';
my $rc=read_conf("${config_dir}/server.json");
my $htmldir=$rc->{VALUES}->{HTMLDIR}->{langvalue}->{rus};
my $clfdir=$rc->{VALUES}->{CLFDIR}->{langvalue}->{rus};
my $debug_dir=$rc->{VALUES}->{DEBUGDIR}->{langvalue}->{rus};
my $ftpdir=$rc->{VALUES}->{FTPDIR}->{langvalue}->{rus};
my $offsetpname=$rc->{VALUES}->{OFFSETPNAME}->{langvalue}->{rus};



my $mon_work_template=$htmldir.'mon.html.tmp';
my $mon_template=$htmldir.'mon.html';
my $ftp_err;

my $ftp = Net::FTP->new(
	$rc->{VALUES}->{FTPSERVER}->{langvalue}->{rus},
	Passive=>1
); 

unless ($ftp) {
	log_error ("Cannot connect ftp: $@");
	$ftp_err=1;
}

unless ($ftp_err) {
	my $f=$ftp->login($rc->{VALUES}->{FTPLOGIN}->{langvalue}->{rus},$rc->{VALUES}->{FTPPASS}->{langvalue}->{rus});
	unless ($f) {
   		$ftp_err=1;
   		log_error("Cannot login: ". $ftp->message);
	}
}	  

my $conf=read_conf("${config_dir}/chconfig.json");

open (MF,">$mon_work_template") || die "mon_template error file:$mon_template  error:$!" ;
print MF t_h();


my %clftypes = (
	63995=>'HardTime',
	63996=>'Manual',
);

for my $c (@$conf) {

	my $ck=read_conf("${config_dir}/channels/$c->{KEY}.json");
    my $index_iterator=$ck->{advindex} || 0;
    my $arkey_old=$ck->{activer};
	my $vic_index=0;
	my $tk;
	my $cc;
	my $cp=$c->{VALUES}->{CHNLPREFIX}->{langvalue}->{rus};
	my $cpath=$c->{VALUES}->{CLFPATH}->{langvalue}->{rus};
	my $ttext=$c->{VALUES}->{TTOUTTEXT}->{langvalue}->{rus};
	my $cdelta=$c->{VALUES}->{BLOCKDURADD}->{value};
    my $absoffset=$c->{VALUES}->{$offsetpname}->{value};
    my $lnum=$c->{VALUES}->{CLFLNUM}->{value};
    my $blockdelay=$c->{VALUES}->{BLOCKDELAY}->{value};
    my $clfctype=$clftypes{$c->{VALUES}->{CLFSTYPE}->{value}};
    my $c_ftp_err;
      

    if ($c->{VALUES}->{ACTIVECHANNEL}->{value}) {
		log_info ("START ($c->{KEY}) CDELTA:$cdelta ABSOFFSET:$absoffset LNUM:$lnum");
	} else {
    	log_warn ("SKIP OFFLINE CHANNEL  ($c->{KEY})");
    	next;
  	}	   
   	my $vicname=$c->{VALUES}->{VICNAME}->{langvalue}->{rus};
 
	unless ($ftp_err) {
		my $cfile=$ftp->get("${ftpdir}${vicname}","${config_dir}/channels/${vicname}");
		unless ($cfile) {
			log_error  ("ftp get failed (FILENAME:$vicname)". $ftp->message);
			$c_ftp_err=1;
 		}
	}
   
   	my $vcontent;
   	open (VC2, "<${config_dir}/channels/${vicname}");
   	read (VC2,$vcontent,-s VC2);
   	close(VC2);
    log_info ("VICFILE UPLODAED $vicname SIZE:".length ($vcontent));
	  
   	my @lines=split("\n",$vcontent);

    my @viclist;
    my $changes;
    my $need_skip;
    my $broken_ttable;
    my $need_write_conf;
    my $now_sec=now_sec();

   	log_info ("CHECK ACTIVE CONTAINER  $ck->{start}..$ck->{end} NOW:$now_sec");
	
    if ($now_sec>$ck->{start} && $now_sec<$ck->{end}) {
          log_warn ("ACTIVE CONTAINER SKIP PLAYLIST UPLOAD");
          $need_skip=1; 	
    }


   	for my $row (@lines) {
   		my @recs=split (/\s+/,$row);
		shift @recs;
		my $h;
		$h->{'date'}=shift @recs;
       	$h->{'time'}=shift @recs;
        $h->{'index'}=shift @recs;
		$h->{'chrono'}=shift @recs;
		$h->{'server'}=shift @recs;
		$h->{'btcode'}=shift @recs;
		$h->{'id'}=shift @recs;
  		$h->{'name'}=join(' ',@recs);
     	next if $h->{'time'} eq 'ON-AIR';

		if ($h->{'name'}=~/К-р(\d+) \((\d\d)(\d\d)(\d\d\d\d)\)/) {

			my $cid=$1;
			my $rdate_d=$2;
			my $rdate_m=$3;
			my $rdate_y=$4;
			
			my $arkey="R${cp}${rdate_y}${rdate_m}${rdate_d}";
			
			$tk->{$arkey}=read_conf("${config_dir}/ttables/$arkey.json");
            if ($tk->{$arkey}) {
			        	
   	        	my $ckey="${arkey}C${cid}";
				push (@viclist,$ckey);
            	$cc->{$ckey}=read_conf("${config_dir}/containers/$ckey.json");
				$cc->{$ckey}->{dur}=$tk->{$arkey}->{c}->{$cid}->{VALUES}->{ADVTKEEP}->{langvalue}->{rus};
				$cc->{$ckey}->{dursec}= $tk->{$arkey}->{c}->{$cid}->{VALUES}->{ADVTKEEPDUR}->{value};
				$cc->{$ckey}->{durfr}= $tk->{$arkey}->{c}->{$cid}->{VALUES}->{DFR}->{value};
				
				$cc->{$ckey}->{cid}=$cid;
				$cc->{$ckey}->{arkey}=$arkey;

				
            	my ($thr,$tmm,$tsec,$tfr)=split(/:/,$h->{'time'});
            	my $sfr=$tfr+$tsec*25+$tmm*25*60+$thr*25*60*60;
            	$sfr-=$cdelta;
            	$sfr+=$absoffset;
            
            	my $tt_hr=int($sfr/(25*60*60));
            	$sfr-=$tt_hr*25*60*60;
            	my $tt_mn=int($sfr/(25*60));
            	$sfr-=$tt_mn*25*60;
            	my $tt_ss=int($sfr/25);
            	$sfr-=$tt_ss*25;

	        	my $rawstr=$cc->{$ckey}->{craw};
            
            	my $ttsec_start=$tt_ss+$tt_mn*60+$tt_hr*3600 - $blockdelay;
            	my $ttsec_end=$ttsec_start+$cc->{$ckey}->{dursec} + $blockdelay;

				$cc->{$ckey}->{cnouttime}=sprintf("%02d:%02d:%02d:%02d",$tt_hr,$tt_mn,$tt_ss,$sfr);

				my ($vm,$vd,$vy)=split(/\//,$h->{'date'});
                
                my $ts=timelocal(0,0,0,$vd,$vm-1,$vy);  
                $ts+=86400 if $tt_hr<3; 
                

                #warn "$h->{'date'} ---->   $tt_hr $tt_mn"	

				$cc->{$ckey}->{cnoutdate}="$rdate_y-$rdate_m-$rdate_d";
				$cc->{$ckey}->{crealdate}=strftime("%Y-%m-%d",localtime($ts));
           
                $cc->{$ckey}->{start}=$ttsec_start;
                $cc->{$ckey}->{end}=$ttsec_end;

           
	        	if ($rawstr ne $row) {
					$cc->{$ckey}->{craw}=$row;
                	$cc->{$ckey}->{reps}=$tk->{$arkey}->{c}->{$cid};
                
			    	if ($cc->{$ckey}->{reps}) {
			    		if ($need_skip) {
							log_warn ("need skip changed container upload");
			    		} else {
							log_warn ("write container $arkey : ($cid:$ckey)  ($h->{'time'} -> $cc->{$ckey}->{cnouttime})  $ttsec_start..$ttsec_end");  
							write_conf("${config_dir}/containers/$ckey.json",$cc->{$ckey});
							$changes=1;
				    		$ck->{utime}=time();
				    		$ck->{lcid}=$cid;
				    		$need_write_conf=1; 
				    	} 	
					} else{  
						log_error ("replace error $arkey $cid skip container");
					}	
				} 
			} else { 
				log_error ("ttable config read problem ${config_dir}/ttables/$arkey.json");
				$broken_ttable=1;
			}    			
		}
	}
    
	my $fc=$viclist[0];
	my $now_sec=now_sec();
	#warn "CK PERIOD  $ck->{start}..$ck->{end} FC PERIOD $cc->{$fc}->{start}..$cc->{$fc}->{end} NOW:$now_sec";
	if (	!$ck->{end} || 
			$now_sec>$ck->{end} || 
			($ck->{end}>86400 && $now_sec+86400>$ck->{end})      ) {
		log_info ("SWITCH ACTIVE CONTAINER");
		$ck->{start}=$cc->{$fc}->{start};
		$ck->{end}=$cc->{$fc}->{end};
		$ck->{cid}=$fc;
		$ck->{cnouttime}=$cc->{$fc}->{cnouttime};
		$need_write_conf=1;
	}

    my $vicliststr=join(';',@viclist);
	if (!$ck->{viclist} || $vicliststr ne join(';',@{$ck->{viclist}})) {
		log_warn ("container list changed");
		$ck->{viclist}=\@viclist;
        $need_write_conf=1;
    }

    if ($need_write_conf) {
		log_warn ("WRITE CONF $c->{KEY}.json");
		write_conf("${config_dir}/channels/$c->{KEY}.json",$ck);
	}


    my $utime=strftime("%H:%M:%S",localtime($ck->{utime}));

	print MF qq(
         <div class="column"><div class="container">
	     <h3 style="color:#D3D3D3;" class="center gray_bkgrnd">$c->{NAME}  </h3>
	);  
	
    my %ec;

	my $XMLstatus="btn-success";
    for (@viclist) {
    	my $cid=$cc->{$_}->{cid};
        my $arkey=$cc->{$_}->{arkey};
	    if ($tk->{$arkey}->{c}->{$cid}->{reps}) {
	    	my $d=$cc->{$_}->{durfr}+$cc->{$_}->{dursec}*25;
	    	my $dreps=0;
	    	for (@{$tk->{$arkey}->{c}->{$cid}->{reps}}) {
			 	my $dur=$_->{VALUES}->{REPDUR}->{value};
			    my $af=$_->{VALUES}->{ADDFRAMES}->{value};
			    $dreps+=$dur*25+$af;
			}
			if ($dreps!=$d) {
				log_error ("CONTAINER $cid CONCISTENCY PROBLEM DUR:$d <=> BDUR:$dreps");
				$XMLstatus="btn-danger";
				$ec{$cid}=1;	
			}
	    } else {	
	    	$XMLstatus="btn-danger";
		 	log_error ("PROBLEM REPLACE  $arkey $cid");
		 	$ec{$cid}=1;
	    }	 
    }

    my $clf_err;
	if ($changes && !$need_skip) {
    	log_warn ("CLF GENERATE $cpath/playlist.clf");	
        my $ccf=open (CLF,">$cpath/playlist.clf");
        if ($ccf) {
    		print CLF qq(<?xml version="1.0" encoding="UTF-8"?>
        	<castlist fps="25" list_upload_time="$nowjd" list_upload_layer="$lnum">
    		);
        } else {
        	$clf_err=1;
			log_error ("clf error file:$cpath error:$!");
		} 	
    }	

    my $FTPstatus="btn-success";
	$FTPstatus="btn-danger" if $ftp_err || $c_ftp_err; 
	my $VICstatus="btn-success";
	$VICstatus="btn-danger" if $broken_ttable; 
    my $CLFstatus="btn-success";
    $CLFstatus="btn-warning" if $changes;
    $CLFstatus="btn-danger"  if $clf_err;
    my $SKYstatus="btn-success";
    $SKYstatus="btn-warning" if $need_skip;

    print MF qq(
	    <div class="center gray_bkgrnd"><div class="btn-group btn-group-justified" role="group" aria-label="...">
               <div class="btn-group" role="group">
	          <button type="button" class="btn btn-default $FTPstatus">FTP</button>
	          <button type="button" class="btn btn-default $XMLstatus">XML</button>
		  <button type="button" class="btn btn-default $VICstatus">VIC</button>
		  <button type="button" class="btn btn-default $CLFstatus">CLF</button>
		  <button type="button" class="btn btn-default $SKYstatus">SKY</button>
	       </div>
	    </div></div>   
	);

	print MF qq (<h3 style="color:#D3D3D3;" class="center gray_bkgrnd">CLF: $utime ($ck->{lcid})</h3>);  

    print MF qq( 
		<div class="card gray_bkgrnd">
		<table class="table table-bordered table-striped table-dark" >
		<thead><tr class='blue_bkgrnd'>
			<th>ID</th><th>Start time</th><th>Duration</th>
		</tr></thead>
		<tbody>
	);

    my $counter=0; 

    for my $rid (@viclist) {
        $counter++;

  		my $cid=$cc->{$rid}->{cid};
	    my $arkey=$cc->{$rid}->{arkey};

        my $dr=$cc->{$rid}->{dur};
        $dr=~s/^00://; 

        my $cl=$ec{$cid}?'class="repdanger"':'';  
	    print MF qq (
	    	<tr>
            <th $cl>$cid</th>
	        <th $cl>$cc->{$rid}->{crealdate} $cc->{$rid}->{cnouttime}</th>
	        <th $cl>$dr</th>   
	    	</tr>
	    );# if $counter<9;
	  
        if ($tk->{$arkey}->{c}->{$cid}->{reps}) {
        	my $cr=0;
        	print MF qq (<tr><th colspan='3' class="repcell">) if $counter<4;
		    for (@{$tk->{$arkey}->{c}->{$cid}->{reps}}) {
			    my $k=$_->{VALUES}->{SHNAME}->{langvalue}->{rus};
			    my $dur=$_->{VALUES}->{REPDUR}->{value};
			    my $af=$_->{VALUES}->{ADDFRAMES}->{value};
			    my $framedur=$dur*25+$af;
			    $dur.=".$af" if $af;
			 
			    print MF qq ($k : $dur сек <br/>) if $counter<4; 

                my $itemtype=$cr?'Seq':$clfctype;	
                $_->{NAME}=~s/"/&quot;/g; 
 
                print CLF qq (
                	<item uri="$k"
        		  		start_type="$itemtype"
        		  		start_time="$cc->{$rid}->{cnouttime}"
                  		start_date="$cc->{$rid}->{crealdate}"
                  		tc_orig=""
                  		in_point="0"
                  		out_point="$framedur"
                  		duration="$framedur"
                        trans_mode="Cut"
                        trans_speed="Fast"
                        lead_out="0"
                  		title="$_->{NAME}"
                  		group="$cid"
                  		end_mode="none"
                  		tape_type="digital">
            		</item>
                ) if $changes && !$need_skip && !$clf_err;

			    $cr++;
		    }
		    print MF qq (</th></tr>) if $counter<4;	    
        } 		    
	    
	    
	}	
		
    print MF qq(
	  </tbody></table>
      <span style="color:#D3D3D3;">CUR:$ck->{cnouttime}<br/>$ttext</span>;
	  </div> 
	  </div></div>
	);

	if ($changes && !$need_skip && !$clf_err) {
    	print CLF qq(</castlist>);
		close CLF;
		if ($debug) {
            my $filename=$cp.strftime("%Y%m%d-%H%M%S.clf",localtime());
			copy("$cpath/playlist.clf","${debug_dir}/${filename}");
			my $vfilename=$cp.strftime("%Y%m%d-%H%M%S.vic",localtime());	
			copy("${config_dir}/channels/${vicname}","${debug_dir}/${vfilename}");
		}

	}	
																															
}	
print MF t_b();
close MF;
move($mon_work_template,$mon_template);
log_info("PROCESSING ENDED");


#####################################

sub log_message ($$) {
	my ($type,$message)=@_;
	my $ts=strftime("%Y-%m-%d - %H:%M:%S",localtime);
	warn "$ts - $type - $message\n";
}


sub log_warn ($) {
	log_message('WARN',$_[0]);
}

sub log_info ($) {
	log_message('INFO',$_[0]);
}

sub log_error ($) {
	log_message('ERRR',$_[0]);
}


sub now_sec () {
	my @d=localtime;
	my $now_hh=$d[2];
	my $now_mm=$d[1];
	my $now_ss=$d[0];
	return  $now_ss+$now_mm*60+$now_hh*3600;
}


sub write_conf ($$) {
	my $filename = shift;
	my $conf = shift;
	$conf = decode('UTF-8', encode_json($conf));
	open (FF,">$filename");
	print FF $conf;
        close $conf;	
}	

sub read_conf ($) {
        my $filename=shift;
	my $content;
	open (FF, "<$filename");
	read (FF,$content,-s FF);
	close(FF);
	$content = encode('UTF-8', $content);
	return $content?decode_json($content):undef;
}

sub t_b {
	my $tse2=strftime("%Y-%m-%d %H:%M:%S",localtime);
   return qq(</div>
   	<span style='color:white'>Обновление закончено в $tse2</span>
   	</body></html>);  
}	

sub t_h {

     my $ts=strftime("%d.%m %H:%M",localtime);
     my $ts2=strftime("%Y-%m-%d %H:%M:%S",localtime);
     my $h_var=qq(

<html>
    <head>
               
    <link rel="stylesheet" href="./bootstrap.min.css"/>

    <script>
    	// Chrome autoplay sound fix.
    	// chrome://flags/#autoplay-policy 
    	// set Autoplay policy to No user gesture
    	window.onload = function() {
    		if (document.getElementsByClassName('btn-danger').length > 0) {
    			var sound = new Audio("./00183.mp3");
    			sound.play();
    		}
    	};
    </script>


	<style>
    body{
		background-color: #494949;
    }
    .container {
		width: 300px;
		padding-right: 10px;
		padding-left: 10px;
		margin-right: auto;
		margin-left: auto;
    }
    .center {
		text-align: center;
		border: 3px;
    }
    table {
		text-align: center;
		border-collapse: collapse;
		border-radius: 1em;
		overflow: hidden;
		color:#D3D3D3;
    }
    th, td {
		text-align: center;
		padding: 1em;
		border-bottom: 2px solid white;
		color:#FFFFFF;
    }
    .row {
		padding: 20px;
    }
    .column {
    }
    .row:after {
		content: "";
		display: table;
		clear: both;
    }
    .gray_bkgrnd {
		background: #494949;
		border-style: none;
    }
    .blue_bkgrnd {
		background: #0000FF;
		border-style: none;
    }     
    .repcell {
    	text-align: left;
        color:#888888;
    }
    .repdanger {
    	color:#FF0000;	
    }   
    </style>
    <title>ПКВС: $ts</title>
    <meta charset="utf-8">
    <meta http-equiv="refresh" content="30" />
 </head>
 <body>  
     <span style='color:white'>Обновлено в $ts2</span>
     <div class="row">
);
return $h_var;

}



