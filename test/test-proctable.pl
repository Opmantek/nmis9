#!/usr/bin/perl
# A cheap and sleazy version of ps
 use Proc::ProcessTable;

 $FORMAT = "%-6s %-10s %-8s %-24s %s\n";
 $t = new Proc::ProcessTable;
 printf($FORMAT, "PID", "TTY", "STAT", "START", "COMMAND"); 
 foreach $p ( @{$t->table} ){
   printf($FORMAT, 
          $p->pid, 
          $p->ttydev, 
          $p->state, 
          scalar(localtime($p->start)), 
          $p->cmndline);
 }


 # Dump all the information in the current process table
 use Proc::ProcessTable;

 $t = new Proc::ProcessTable;

 foreach $p (@{$t->table}) {
  print "--------------------------------\n";
  foreach $f ($t->fields){
    print $f, ":  ", $p->{$f}, "\n";
  }
 }              
