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
my $fpgen = '';

GetOptions ('debug' => \$debug, 'fpgen' => \$fpgen);

log_info ("START JDTIME=$nowjd");

my $config_dir='z:/from_virt/exchange';
my $rc=read_conf("${config_dir}/server.json");
my $ac_names=al_names($config_dir);

my $htmldir=$rc->{VALUES}->{HTMLDIR}->{langvalue}->{rus};
my $clfdir=$rc->{VALUES}->{CLFDIR}->{langvalue}->{rus};
my $debug_dir=$rc->{VALUES}->{DEBUGDIR}->{langvalue}->{rus};
my $ftpdir=$rc->{VALUES}->{FTPDIR}->{langvalue}->{rus};
my $offsetpname=$rc->{VALUES}->{OFFSETPNAME}->{langvalue}->{rus};
my $clftypename=$rc->{VALUES}->{CLFTYPEPNAME}->{langvalue}->{rus};
my $next_tt_wait_delay=86400;


my $mon_work_template=$htmldir.'mon.html.tmp';
my $mon_template=$htmldir.'mon.html';


(my $ftp,my $ftp_err)=ftp_connect(
		$rc->{VALUES}->{FTPSERVER}->{langvalue}->{rus},
		$rc->{VALUES}->{FTPLOGIN}->{langvalue}->{rus},
		$rc->{VALUES}->{FTPPASS}->{langvalue}->{rus},
);

my $conf=read_conf("${config_dir}/chconfig.json");

open (MF,">$mon_work_template") || die "mon_template error file:$mon_template  error:$!" ;
print MF t_h();


my %clftypes = (
	63995=>'HardTime',
	63996=>'Manual',
);

for my $c (@$conf) {

	my $ck=read_conf("${config_dir}/channels/$c->{KEY}.json");  #LOCAL CONFIG
    my $index_iterator=$ck->{advindex} || 0;
    my $arkey_old=$ck->{activer};
	my $vic_index=0;
	my $tk;
	
	my $cc;
	my $accc;

	my $cp=$c->{VALUES}->{CHNLPREFIX}->{langvalue}->{rus};
	my $cpath=$c->{VALUES}->{CLFPATH}->{langvalue}->{rus};
	my $ttext=$c->{VALUES}->{TTOUTTEXT}->{langvalue}->{rus};
	my $cdelta=$c->{VALUES}->{BLOCKDURADD}->{value};
    my $absoffset=$c->{VALUES}->{$offsetpname}->{value};
    my $lnum=$c->{VALUES}->{CLFLNUM}->{value};
    my $blockdelay=$c->{VALUES}->{BLOCKDELAY}->{value};

    my $clfctype=$clftypes{$c->{VALUES}->{$clftypename}->{value}};

    my $agelabel=$c->{VALUES}->{AGELABEL}->{value};
    my $fullttable=$c->{VALUES}->{FULLTTABLE}->{value};
    my $ftlnum=$c->{VALUES}->{FTCLFLNUM}->{value};
    

    my $acdur=$c->{VALUES}->{ACDUR}->{value};
    my $evbegoffset=$c->{VALUES}->{EVBEGOFFSET}->{value};
    my $acclfctype=$clftypes{$c->{VALUES}->{ACCLFSTYPE}->{value}};
    my $aclnum=$c->{VALUES}->{ACCLFLNUM}->{value};
   
    my $c_ftp_err;
      

    if ($c->{VALUES}->{ACTIVECHANNEL}->{value}) {
		log_info ("START ($c->{KEY}) CDELTA:$cdelta ABSOFFSET:$absoffset LNUM:$lnum");
	} else {
    	log_warn ("SKIP OFFLINE CHANNEL  ($c->{KEY})");
    	next;
  	}	   
   	my $vicname=$c->{VALUES}->{VICNAME}->{langvalue}->{rus};
 
	unless ($ftp_err) {
		$c_ftp_err=file_get($ftp,$ftpdir,$config_dir,$vicname);
	}
   
   	my $vcontent;
   	open (VC2, "<${config_dir}/channels/${vicname}");
   	read (VC2,$vcontent,-s VC2);
   	close(VC2);
    log_info ("VICFILE UPLODAED $vicname SIZE:".length ($vcontent));
	  
   	my @lines=split("\n",$vcontent);

    my @viclist;
    my @acviclist;
    my @ftviclist;
    
    my $changes;
    my $acchanges;
    my $ftchanges;

    my $ftindex;
    my $ftdata;

    my $need_skip;
    my $ac_need_skip;
    my $broken_ttable;
    my $broken_n_ttable;
    my $need_write_conf;
    my $now_sec=now_sec();

   	log_info ("CHECK ACTIVE CONTAINER  $ck->{start}..$ck->{end} NOW:$now_sec");
	
    if ($now_sec>$ck->{start} && $now_sec<$ck->{end}) {
          log_warn ("ACTIVE CONTAINER SKIP PLAYLIST UPLOAD");
          $need_skip=1; 	
    }

    if ($agelabel) {
    	my $now_ts=time();
    	if ($now_ts>$ck->{acstartts} && $now_ts<$ck->{acendts}) {
         	log_warn ("AC ACTIVE CONTAINER SKIP PLAYLIST UPLOAD  [ $ck->{acstartts} < $now_ts > $ck->{acendts} ] ");
          	$ac_need_skip=1; 	
    	}	
    }

    if ($fullttable) {
    	$ftindex=$ck->{'ftindex'};
    	unless ($ftindex) {
    		 log_warn ("FT NO CURRENT INDEX NEED PLAYLIST GENERATE");
    		 $ftchanges=1;
    	}
    }

    my $can_start=0;
    my $tt_break;
    my $tt_day;

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
     	if ($h->{'time'} eq 'ON-AIR') {
     		$can_start=1;
     		next;
     	}
     	next unless $can_start;	

     	if ($agelabel) {
     		my $h_str=row_parse($row,$absoffset+$evbegoffset);
     		if ($h_str->{'grp'}) {
     			my $cid=$h_str->{'id'};
     			my $dtstr=strftime("%Y%m%d%H%M%S",localtime($h_str->{'ts'}));
 				my $acckey="R${cp}${dtstr}C$cid";
				push (@acviclist,$acckey);
            	$accc->{$acckey}=read_conf("${config_dir}/accontainers/$acckey.json");
				$accc->{$acckey}->{cid}=$cid;
				$accc->{$acckey}->{cnouttime}=$h_str->{'cnouttime'}; 
				$accc->{$acckey}->{crealdate}=strftime("%Y-%m-%d",localtime($h_str->{'ts'}));
 				$accc->{$acckey}->{grp}=$h_str->{'grp'};

     			$accc->{$acckey}->{startts}= $h_str->{'ts'} - $blockdelay;
                $accc->{$acckey}->{endts}  = $h_str->{'ts'} + $acdur;

            	my $rawstr=$accc->{$acckey}->{craw};

            	if ($rawstr ne $row) {
            		if ($ac_need_skip) {
						log_warn ("ac need skip changed container upload");
			    	} else {	
						$accc->{$acckey}->{craw}=$row;
               			log_warn ("write ac container ($acckey)");  
						write_conf("${config_dir}/accontainers/$acckey.json",$accc->{$acckey});
						$acchanges=1;
				    	$ck->{acutime}=time();
				    	$ck->{aclcid}=$cid;
				    	$need_write_conf=1; 		
				    }	
				}			
	
     		}
     	}

     	if ($h->{'index'} eq 'X' && $fullttable) {
     		my (undef, $ttb_ts) = calc_time($h->{'time'},$h->{'date'});
     	 	log_info ("FOUND START TTABLE ". scalar localtime ($ttb_ts));
			my $now_ts=time;
			my $break_day=strftime("%Y%m%d",localtime($ttb_ts+3600));
			if ($now_ts>($ttb_ts-300) && $break_day ne $ck->{'ttday'}) {
				$tt_day=$break_day;
				log_warn ("need switch ttday > $tt_day");
				$ftchanges=1;
			}

     		$tt_break=1;
     	}

		if ($h->{'name'}=~/К-р(\d+) \((\d\d)(\d\d)(\d\d\d\d)\)/) {

			my $cid=$1;
			my $rdate_d=$2;
			my $rdate_m=$3;
			my $rdate_y=$4;

			my $arkey="R${cp}${rdate_y}${rdate_m}${rdate_d}";
			$tk->{$arkey}=read_conf("${config_dir}/ttables/$arkey.json") unless $tk->{$arkey};

            if ($tk->{$arkey}) {

         
   	        	my $ckey="${arkey}C${cid}";
				push (@viclist,$ckey);
				push (@ftviclist,$cid) unless $tt_break ;
				
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
                
                
                my $ts=timelocal($tt_ss,$tt_mn,$tt_hr,$vd,$vm-1,$vy);  
                $ts+=86400 if $tt_hr<3; 
                
				$cc->{$ckey}->{cnoutdate}="$rdate_y-$rdate_m-$rdate_d";
				$cc->{$ckey}->{crealdate}=strftime("%Y-%m-%d",localtime($ts));
           
                $cc->{$ckey}->{start}=$ttsec_start;
                $cc->{$ckey}->{end}=$ttsec_end;

                $cc->{$ckey}->{startts}= $ts - $blockdelay;
                $cc->{$ckey}->{endts}  = $ts + $cc->{$ckey}->{dursec};

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

			my $ddts=timelocal(0,0,0,${rdate_d},${rdate_m}-1,${rdate_y})+86400;  
			if (($ddts - time) < $next_tt_wait_delay) {
            	my $narkey=strftime("R${cp}%Y%m%d",localtime($ddts));
				$tk->{$narkey}=read_conf("${config_dir}/ttables/$narkey.json") unless $tk->{$narkey};
    			unless  ($tk->{$narkey}) {
					log_error ("ttable future config read problem ${config_dir}/ttables/$narkey.json");
					$broken_n_ttable=1;
				}
			}	          

		}
	}
    
	my $fc=$viclist[0];
	my $now_sec=now_sec();
	my $now_ts_sec=time;
	if ($now_ts_sec>$ck->{endts}) {
		my $pst=strftime("%d.%m %H:%M:%S",localtime($cc->{$fc}->{startts}));
		my $est=strftime("%d.%m %H:%M:%S",localtime($cc->{$fc}->{endts}));
		log_info ("SWITCH ACTIVE CONTAINER : ${pst}..${est}");
		$ck->{start}=$cc->{$fc}->{start};
		$ck->{end}=$cc->{$fc}->{end};
		$ck->{startts}=$cc->{$fc}->{startts};
		$ck->{endts}=$cc->{$fc}->{endts};

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

	my $VICstatus="btn-success";
	my %p;
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
			if ($p{$cid}) {
				log_error ("CONTAINER $cid DOUBLES");
				$VICstatus="btn-warning";
			    $ec{$cid}=1;	
			}
			if ($dreps!=$d) {
				log_error ("CONTAINER $cid CONCISTENCY PROBLEM DUR:$d <=> BDUR:$dreps");
				$VICstatus="btn-danger";
				$ec{$cid}=1;	
			}
	    } else {	
	    	$VICstatus="btn-warning";
		 	log_error ("PROBLEM REPLACE  $arkey $cid");
		 	$ec{$cid}=1;
	    }
	    $p{$cid}=1;	 
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
	my $XMLstatus="btn-success";
	$XMLstatus="btn-warning" if $broken_n_ttable; 
	$XMLstatus="btn-danger" if $broken_ttable; 

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

    my $ccol=$ck->{cnouttime} ne $cc->{$viclist[0]}->{cnouttime}?'FFFF00':'D3D3D3';
	print MF qq (<h3 style="color:#${ccol};" class="center gray_bkgrnd">CUR: $ck->{cnouttime}</h3>);  
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

    my %processed; 

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
                ) if $changes && !$need_skip && !$clf_err && !$processed{$cid};

			    $cr++;
		    }
		    print MF qq (</th></tr>) if $counter<4;	    
        } 		    
	    $processed{$cid}=1;
	    
	}	
		
    print MF qq(
	  </tbody></table>
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

	if ($fullttable) {

		my $ftstr=join(';',@ftviclist);
        my $arkey="R${cp}$ck->{'ttday'}";

		if (!$ftindex=~/$ftstr/ || $fpgen) {
			my %h;
			my @final_index;
			my $final_str;
			for my $v (@ftviclist) {
				$h{$v}=1;
				push(@final_index,$v);
			}		
			my @ffindex=split(';',$ftindex);
			my $f_flag;
			for my $f (@ffindex) {
				$f_flag=1 if $h{$f};
				push (@final_index,$f) if !$h{$f} && $f_flag; 
			}	
            $final_str=join(';',@final_index);

			log_warn ("COMAPRE $ftstr : $ftindex FAILED NEED REBUID TTABLE $arkey >>>> $final_str");
			$ftindex=$final_str;
			$ftchanges=1;
		}


		if ($ftchanges && !$need_skip) {
			$ck->{'ttctime'}=strftime("%d.%m %H:%M",localtime());

			$ck->{'ttday'}=$tt_day if $tt_day;
			$ck->{'ttday'}=strftime("%Y%m%d",localtime(time)) unless $ck->{'ttday'};
            


            if ($tt_day || !$ftindex) {
            	$ftindex=$tk->{$arkey}->{'channel'}->{'VALUES'}->{'INDEXSTR'}->{'langvalue'}->{'rus'};
            	log_warn ("RESET TTINDEX: $arkey: $ftindex");	
            }
          
            log_warn ("GENERATE FTTABLE: $arkey");
			generate_ftt_playlist ({
				cpath=>$cpath,
				nowjd=>$nowjd,
				lnum=>$ftlnum,
				debug=>$debug,
				debug_dir=>$debug_dir,
				config_dir=>$config_dir,
				cp=>$cp,
				vicname=>$vicname,	
				ftindex=>$ftindex,
				ftdata=>$tk->{$arkey},
				clfctype=>$clfctype,
				dtkey=>$arkey,
			});

			$ck->{'ftindex'}=$ftindex;     		
			write_conf("${config_dir}/channels/$c->{KEY}.json",$ck);
		}	




		print MF qq(
         <div class="column"><div class="container">
	     <h3 style="color:#D3D3D3;" class="center gray_bkgrnd">$c->{NAME}  (FULLTABLE)</h3>
		);  

		$XMLstatus="btn-success";
		$VICstatus="btn-success";
		$CLFstatus="btn-success";
		$CLFstatus="btn-warning" if $ftchanges;
		$SKYstatus="btn-success";
		$SKYstatus="btn-warning" if $ftchanges;
		

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
 
		print MF qq (<h3 style="color:#D3D3D3;" class="center gray_bkgrnd">LAST XML: $ck->{'ttday'} </h3>);  
		print MF qq (<h3 style="color:#D3D3D3;" class="center gray_bkgrnd">LAST CLF: $ck->{'ttctime'}</h3>);  

    	print MF qq( 
			<div class="card gray_bkgrnd">
			<table class="table table-bordered table-striped table-dark" >
			<thead><tr class='blue_bkgrnd'>
					<th>ID</th><th>Start time</th><th>Duration</th>
			</tr></thead>
			<tbody>
		);

        $counter=0;
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
	    	);
	  
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
 
                	$cr++;
		    	}
		    	print MF qq (</th></tr>) if $counter<4;	    
        	} 		    
		}
    	print MF qq(
	  		</tbody></table>
  	  		</div> 
	  		</div></div>
		);



	}


	if ($agelabel) {

		my $clf_err;
		my $fc=$acviclist[0];
		my $now_ts_sec=time;
		if ($now_ts_sec>$ck->{acendts}) {
			my $pst=strftime("%d.%m %H:%M:%S",localtime($accc->{$fc}->{startts}));
			my $est=strftime("%d.%m %H:%M:%S",localtime($accc->{$fc}->{endts}));
			log_info ("SWITCH AC ACTIVE CONTAINER : ${pst}..${est}");
			$ck->{acstartts}=$accc->{$fc}->{startts};
			$ck->{acendts}=$accc->{$fc}->{endts};

			$ck->{accid}=$fc;
			$ck->{accnouttime}=$accc->{$fc}->{cnouttime};
			$need_write_conf=1;
		}

    	my $vicliststr=join(';',@acviclist);
		if (!$ck->{acviclist} || $vicliststr ne join(';',@{$ck->{acviclist}})) {
			log_warn ("accontainer list changed");
			$ck->{acviclist}=\@acviclist;
        	$need_write_conf=1;
    	}


		if ($need_write_conf) {
			log_warn ("WRITE CONF $c->{KEY}.json");
			write_conf("${config_dir}/channels/$c->{KEY}.json",$ck);
		}


 		my $acutime=strftime("%H:%M:%S",localtime($ck->{acutime}));

		print MF qq(
         <div class="column"><div class="container">
	     <h3 style="color:#D3D3D3;" class="center gray_bkgrnd">$c->{NAME}  (AGE CONTROL)</h3>
		);  

		if ($acchanges && !$ac_need_skip) {
    		log_warn ("CLF GENERATE $cpath/ac_playlist.clf");	
        	my $ccf=open (CLF,">$cpath/ac_playlist.clf");
        	if ($ccf) {
    			print CLF qq(<?xml version="1.0" encoding="UTF-8"?>
        		<castlist fps="25" list_upload_time="$nowjd" list_upload_layer="$aclnum">
    			);
        	} else {
        		$clf_err=1;
				log_error ("clf error file:$cpath error:$!");
			} 	
    	}	

		$XMLstatus="btn-success";
		$VICstatus="btn-success";
		$CLFstatus="btn-success";
    	$CLFstatus="btn-warning" if $acchanges;
    	$CLFstatus="btn-danger"  if $clf_err;
    	$SKYstatus="btn-warning" if $ac_need_skip;

		for (@acviclist) {
			my $cid=$accc->{$_}->{cid};
			unless ($ac_names->{$accc->{$_}->{grp}}) {
				log_error ("CONTAINER $cid UNKNOWN AGE MARKER $accc->{$_}->{grp}");
				$VICstatus="btn-warning";
				$ec{$cid}=1;	
			}
		}	


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

		my $acccol=$ck->{accnouttime} ne $accc->{$acviclist[0]}->{cnouttime}?'FFFF00':'D3D3D3';
		print MF qq (<h3 style="color:#${acccol};" class="center gray_bkgrnd">CUR: $ck->{accnouttime}</h3>);  
		print MF qq (<h3 style="color:#D3D3D3;" class="center gray_bkgrnd">CLF: $acutime ($ck->{aclcid})</h3>);  

    	print MF qq( 
			<div class="card gray_bkgrnd">
			<table class="table table-bordered table-striped table-dark" >
			<thead><tr class='blue_bkgrnd'>
				<th>ID</th>
				<th>Start time</th>
				<th>Label</th>
			</tr></thead>
			<tbody>
		);

 		my $counter=0; 

    	for my $rid (@acviclist) {
        	$counter++;
        	print MF qq (
	    		<tr>
            	<th>$accc->{$rid}->{cid}</th>
	        	<th>$accc->{$rid}->{crealdate} $accc->{$rid}->{cnouttime}</th>
	        	<th>$accc->{$rid}->{grp}</th>
	       		</tr>
	    	) if $counter<9;

        	my $framedur=$acdur*25;
            print CLF qq (
                	<item uri="$ac_names->{$accc->{$rid}->{grp}}"
        		  		start_type="$acclfctype"
        		  		start_time="$accc->{$rid}->{cnouttime}"
                  		start_date="$accc->{$rid}->{crealdate}"
                  		tc_orig=""
                  		in_point="0"
                  		out_point="$framedur"
                  		duration="$framedur"
                        trans_mode="Cut"
                        trans_speed="Fast"
                        lead_out="0"
                  		title="$accc->{$rid}->{cid}"
                  		group="$accc->{$rid}->{cid}"
                  		end_mode="none"
                  		tape_type="digital">
            		</item>
             ) if $acchanges && !$ac_need_skip && !$clf_err && $ac_names->{$accc->{$rid}->{grp}};

	    }	

    	print MF qq(
	  		</tbody></table>
  	  		</div> 
	  		</div></div>
		);

		if ($acchanges && !$ac_need_skip && !$clf_err) {
    		print CLF qq(</castlist>);
			close CLF;
			if ($debug) {
            	my $filename=$cp.strftime("%Y%m%d-%H%M%S_ac.clf",localtime());
				copy("$cpath/ac_playlist.clf","${debug_dir}/${filename}");
				my $vfilename=$cp.strftime("%Y%m%d-%H%M%S.vic",localtime());	
				copy("${config_dir}/channels/${vicname}","${debug_dir}/${vfilename}");
			}
		}	

	}


																															
}	
print MF t_b();
close MF;
move($mon_work_template,$mon_template);
log_info("PROCESSING ENDED");


#####################################
sub generate_ftt_playlist ($) {
	my ($cf)=@_;
	my $err;
	my $ffcname="$cf->{cpath}/fullplaylist.clf";

    my $ccf=open (XCLF,">$ffcname");
    unless ($ccf) {
    	log_error ("clf error file:$ffcname error:$!");
    	$err->{'xml'}=1;
    	return ($err);
    }

    print XCLF qq(<?xml version="1.0" encoding="UTF-8"?>
    	<castlist fps="25" list_upload_time="$cf->{nowjd}" list_upload_layer="$cf->{lnum}">
    );
    my @ftlist=split(';',$cf->{ftindex});

	log_warn ("FTCLF GENERATE $ffcname $ftlist[0]..$ftlist[-1]");	

	my ($vy,$vm,$vd)=($cf->{dtkey}=~/(\d{4})(\d{2})(\d{2})/);
	my $tsst=timelocal(0,0,0,$vd,$vm-1,$vy);  
   
   
	my $prev;
	my $etime;

    for my $cid (@ftlist) {
        my $cr=0;	  
        my @reps;
        if (ref $cf->{ftdata}->{c}->{$cid}->{reps} eq 'ARRAY') {
        	@reps=@{$cf->{ftdata}->{c}->{$cid}->{reps}}
        } elsif (ref $cf->{ftdata}->{c}->{'XX'}->{reps} eq 'ARRAY') {
        	log_error ("FT GENERATE ERROR > $cid");
        	@reps=@{$cf->{ftdata}->{c}->{'XX'}->{reps}};
        	$err->{'xml'}=1;
        } else {
        	log_error ("CANT GENERATE DANGER CONTAINER");
        	$err->{'xml'}=1;
        }
        
        (my $pth,my $ptm)=split(/:/,$cf->{ftdata}->{c}->{$cid}->{VALUES}->{PTIMECODE}->{langvalue}->{rus});
        my $xtime=$tsst+$pth*3600+$ptm*60;
		if ($xtime && $xtime<$prev) {
			$tsst+=86400; 
			$xtime+=86400;
		} 	
		$prev=$xtime;
		if ($xtime<$etime) {
			$xtime=$etime+300;
		}
	
        for my $rp (@reps) {
			my $k=$rp->{VALUES}->{SHNAME}->{langvalue}->{rus};
			my $dur=$rp->{VALUES}->{REPDUR}->{value};
			my $af=$rp->{VALUES}->{ADDFRAMES}->{value};
			
            my $rd=strftime("%Y-%m-%d",localtime($xtime));
            my $rt=strftime("%H:%M:%S:00",localtime($xtime));

			my $framedur=$dur*25+$af;
			$dur.=".$af" if $af;
			 
            my $itemtype=$cr?'Seq':$cf->{clfctype};	
            $rp->{NAME}=~s/"/&quot;/g; 
 
            print XCLF qq (
                <item uri="$k"
        		  	start_type="$itemtype"
        		  	start_time="$rt"
                  	start_date="$rd"
                  	tc_orig=""
                  	in_point="0"
                  	out_point="$framedur"
                  	duration="$framedur"
                    trans_mode="Cut"
                    trans_speed="Fast"
                    lead_out="0"
                  	title="$rp->{NAME}"
                  	group="$cid"
                  	end_mode="none"
                  	tape_type="digital">
            	</item>
            );
			$cr++;
			$xtime+=$dur;
			$etime=$xtime;
		}
	}	
    print XCLF qq(</castlist>);
	close XCLF;
	if ($cf->{debug}) {
    	my $filename=$cf->{cp}.strftime("%Y%m%d-%H%M%S_ft.clf",localtime());
		copy($ffcname,"$cf->{debug_dir}/${filename}");
		my $vfilename=$cf->{cp}.strftime("%Y%m%d-%H%M%S.vic",localtime());	
		copy("$cf->{config_dir}/channels/$cf->{vicname}","$cf->{debug_dir}/${vfilename}");
	}
	return $err;
}




sub al_names ($) {
	my ($config_dir)=@_;
	my $h;
	my $ac=read_conf("${config_dir}/acconfig.json");
	for (@$ac) {
		$h->{$_->{VALUES}->{ACVICLABEL}->{langvalue}->{rus}}=$_->{VALUES}->{RFNAME}->{langvalue}->{rus}
	}
	return $h
}


sub calc_time ($$;$) {
	my ($timestr,$datestr,$offset)=@_;

    my ($thr,$tmm,$tsec,$tfr)=split(/:/,$timestr);
    my $sfr=$tfr+$tsec*25+$tmm*25*60+$thr*25*60*60 + $offset;

	my $tt_hr=int($sfr/(25*60*60));
    $sfr-=$tt_hr*25*60*60;
    my $tt_mn=int($sfr/(25*60));
    $sfr-=$tt_mn*25*60;
    my $tt_ss=int($sfr/25);
    $sfr-=$tt_ss*25;

    my ($vm,$vd,$vy)=split(/\//,$datestr);

    my $next_day;
    if  ($tt_hr>23) {
    	$tt_hr=0;
    	$next_day=1;
    }

    my $ts=timelocal($tt_ss,$tt_mn,$tt_hr,$vd,$vm-1,$vy);  
    $ts+=86400 if $tt_hr<3; 
    $ts+=86400 if $next_day;

    my $dstr=sprintf("%02d:%02d:%02d:%02d",$tt_hr,$tt_mn,$tt_ss,$sfr);

    log_warn ("NEXT DAY :::: T:$timestr D:$datestr O:$offset) => $tt_hr:$tt_mn:$tt_ss ($dstr)") if $next_day;

    return ($dstr,$ts);    
}


sub row_parse ($$) {
	my ($row,$offset) = @_;
	my $r;
    $r->{'date'}=	substr($row,  9, 8);
    $r->{'time'}=	substr($row, 18,11);
    $r->{'index'}=	substr($row, 30, 2);
    $r->{'chrono'}=	substr($row, 32,11);
    $r->{'id'}=		substr($row, 65,16);
	$r->{'grp'}=	substr($row,116,16);
	$r->{'name'}=	substr($row,183,66);
	$r->{$_}=~s/\s+$// for keys %{$r};
	$r->{'grp'}=~s/^(\S_\d+).+$/$1/;
    ($r->{'cnouttime'},$r->{'ts'}) = calc_time($r->{'time'},$r->{'date'},$offset);
	return $r;
}

sub file_get ($$$$) {
	my ($ftp,$ftpdir,$config_dir,$vicname)=@_;
	my $err;

	for my $try (1..3) {
		my $cfile=$ftp->get("${ftpdir}${vicname}","${config_dir}/channels/${vicname}");
		if ($cfile) {
			$err=0;
			last;
		} else {
			log_warn  ("ftp fileget failed (TRY: $try FILENAME:$vicname)". $ftp->message);
			$err=1;
 		}
 		sleep 1;
 	}	
 	if ($err) {
 		log_error("CANT GET FILE ${ftpdir}${vicname}");	
 	}
 	return $err;	

}

sub ftp_connect {

	my ($serv,$login,$password)=@_;
	my $ftp;

	for my $try (1..3) {
		$ftp=Net::FTP->new($serv,Passive=>1,Timeout=>5);
		if ($ftp) {
			last;
		} else {
			sleep 5;
			log_error ("Try $try. Cannot connect ftp: ".encode('UTF-8',decode('Windows-1251',$@)));
		}	
	}
	return (undef, 1) unless $ftp;

	unless ($ftp->login($login,$password)) {
   		log_error("Cannot login: ". encode('UTF-8',decode('Windows-1251',$ftp->message)));
   		return (undef,1);
	}	  

	return ($ftp,0);
}

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



