#!/usr/bin/env bash

# Copyright 2010 Alexandre Gomes (alegomes at gmail)
#
# This file is part of Catalina Monitor (C'Mon) Suite.
# 
# C'Mon is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
# 
# C'Mon is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with C'Mon.  If not, see <http://www.gnu.org/licenses/>.


LOGDIR=/var/log
#CATALINA_HOME=/Users/alegomes/workspace/sea/workshop_perftuning/liferay-portal-5.2-ee-sp4/tomcat-6.0.18
CATALINA_HOME=/usr/local/liferay/tomcat

CATALINA_STAT=$LOGDIR/cmon
THREADDUMP_STAT=$LOGDIR/threaddump

JSTAT_TEMP=/tmp/jstat.tomcat
THREADDUMP_TEMP=/tmp/threaddump.tomcat
NETSTAT_TEMP=/tmp/netstat.tomcat

AJP_PORT=8009
DB_PORT=1433

SLEEP_TIME=15

function usage() {
   
   echo
   echo "./cmon.sh <load_threshold>" 
   echo
   exit -1
}

function load() {

  catalina_pid=$(jps | grep -i bootstrap | awk '{print $1}') 

  uid=$(ps -p $catalina_pid -o euid=)

  if [ $(echo "$uid != $UID" | bc) -eq 1 ]; then 
    echo
    echo "You must invoke cmon using the same user used to invoke Tomcat."
    echo
    exit -1
  fi

  HEADER="Date/Time;Load;AjpEst;AjpTw;DBEst($DB_PORT);Young(%);Old(%);Perm(%);YGC(#);FGC(#);Threads(#);ThRun(%);ThBlk(%);ThTw(%)\n"

  last_load=0
  count=0
  while (true); do 

     now=`date '+%d/%m/%Y %H:%M:%S'`
     today=`date '+%Y%m%d'`
     
     if [ -z "$(uname | grep Darwin)" ]; then
        # Linux
        load=$(cat /proc/loadavg | awk '{print $1}')
     else
        # MacOS
        load=$(sysctl vm.loadavg | awk '{print $3}')
     fi

     #
	 # Warn the user if load has increased more than 5 points.
	 #
	
     # On linux boxes, printf decimal symbol is comma and it doesn't work in [ ] statements
	 load_diff=$(echo "$load - $last_load" | bc | xargs printf "%1.1f" | sed  s/,/./g)
	 if [ $(echo "$load_diff > 5" | bc) -eq 1 ]; then 

	     # A little mark to find overloaded moments
		loadincreasing="<---"
		
	 else
	    loadincreasing="" 
	 fi
	
	 #
	 # Save last thread dump if load has increased more than 15 points.
	 #
	 if [ $(echo "$load_diff > 15" | bc) -eq 1 ]; then 

		cat $THREADDUMP_TEMP >> $THREADDUMP_STAT.$(date +%Y%m%d%H%M).JustBeforeLoadPeak.$(hostname).txt
		
	 fi

     # Networkd conections

     netstat -an > $NETSTAT_TEMP

     ajp_estab=$(grep $AJP_PORT $NETSTAT_TEMP | grep -i estab | wc -l)
     ajp_timewait=$(grep $AJP_PORT $NETSTAT_TEMP | grep -i wait | wc -l)
     db_estab=$(grep $DB_PORT $NETSTAT_TEMP | grep -i estab | wc -l)

     # JVM memory 
     
     jstat -gcutil $catalina_pid | grep -v S0 > $JSTAT_TEMP 

     jvm_eden=$(grep -v S0 $JSTAT_TEMP | awk '{print $3}')
     jvm_old=$(grep -v S0 $JSTAT_TEMP | awk '{print $4}')
     jvm_perm=$(grep -v S0 $JSTAT_TEMP | awk '{print $5}')
     jvm_ygc=$(grep -v S0 $JSTAT_TEMP | awk '{print $6}')
     jvm_fgc=$(grep -v S0 $JSTAT_TEMP | awk '{print $8}')

     # JVM threads

     jstack $catalina_pid > $THREADDUMP_TEMP

     jvm_threads=$(grep "java.lang.Thread.State" $THREADDUMP_TEMP | wc -l)     
     jvm_th_run=$(grep "java.lang.Thread.State: RUNNABLE" $THREADDUMP_TEMP | wc -l)
     jvm_th_blk=$(grep "java.lang.Thread.State: BLOCK" $THREADDUMP_TEMP | wc -l)
     jvm_th_wait=$(grep WAITING $THREADDUMP_TEMP | wc -l)

	 if [ ! -z $jvm_threads ] && [ ! $(echo "$jvm_threads" | bc) -eq 0 ]; then
		 jvm_th_run_perc=$(echo "scale=2; (${jvm_th_run}/${jvm_threads})*100" | bc | xargs printf "%1.0f")
		 jvm_th_blk_perc=$(echo "scale=2; (${jvm_th_blk}/${jvm_threads})*100" | bc | xargs printf "%1.0f")
		 jvm_th_wait_perc=$(echo "scale=2; (${jvm_th_wait}/${jvm_threads})*100" | bc| xargs printf "%1.0f")
	 fi

     #
     # Print results in $LOGDIR/javastat.${today}.log
     #

     line=$(echo $HEADER \
                 "$now;" \
                 "$load;" \
                 "$ajp_estab;" \
                 "$ajp_timewait;" \
                 "$db_estab;" \
                 "$jvm_eden;" \
                 "$jvm_old;" \
                 "$jvm_perm;" \
                 "$jvm_ygc;" \
                 "$jvm_fgc;" \
                 "$jvm_threads;" \
                 "$jvm_th_run_perc;" \
                 "$jvm_th_blk_perc;" \
                 "$jvm_th_wait_perc;" \
                 "$loadincreasing"
           )

     let no_header=$count%15
     if (( $no_header )); then
        echo -e $line | column -t -s\; | grep -v Date >> $CATALINA_STAT.${today}.$(hostname).log
     else
        echo -e $line | column -t -s\; >> $CATALINA_STAT.${today}.$(hostname).log
     fi

     (( count = $count + 1 ))


     #
     # Check if there was a load spike. Saves a thread dump if any. 
     #

     overloaded=$(echo "$load > ${THRESHOLD}" | bc) 
     if [[ "$overloaded" -eq "1" ]]; then
        cat $THREADDUMP_TEMP >> $THREADDUMP_STAT.$(date +%Y%m%d%H%M).$(hostname).txt
     fi

	 #
	 # Save time of the last dump
	 #
	 last_dump_time=$(echo $now | awk '{print $2}')

     #
     # Save last load
     #
     last_load=$load

     sleep $SLEEP_TIME
  done
}

######################
#
# Script start
#
######################

if [[ -z "$1" ]]; then
   usage 
fi


THRESHOLD=$1
load
