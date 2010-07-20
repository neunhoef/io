#############################################################################
##
##  background.gi               GAP 4 package IO
##                                                           Max Neunhoeffer
##
##  Copyright (C) 2006-2010 by Max Neunhoeffer
##
##  This file is free software, see license information at the end.
##
##  This file contains the implementations for background jobs using fork.
##

InstallGlobalFunction(DifferenceTimes,
  function(t1, t2)
    local x;
    x := (t1.tv_sec*1000000+t1.tv_usec) - (t2.tv_sec*1000000+t2.tv_usec);
    return rec(tv_usec := x mod 1000000,
               tv_sec := (x - x mod 1000000) / 1000000);
  end);

InstallGlobalFunction(CompareTimes,
  function(t1, t2)
    local a,b;
    a := t1.tv_sec * 1000000 + t1.tv_usec;
    b := t2.tv_sec * 1000000 + t2.tv_usec;
    if a < b then return -1;
    elif a > b then return 1;
    else return 0;
    fi;
  end);

InstallMethod(BackgroundJobByFork, "for a function and a list",
  [IsFunction, IsList],
  function(fun, args)
    return BackgroundJobByFork(fun, args, rec());
  end );

InstallValue(BackgroundJobByForkOptions,
  rec(
    TerminateImmediately := false,
    BufferSize := 8192,
  ));

InstallMethod(BackgroundJobByFork, "for a function, a list and a record",
  [IsFunction, IsList, IsRecord],
  function(fun, args, opt)
    local j, n;
    IO_InstallSIGCHLDHandler();
    for n in RecNames(BackgroundJobByForkOptions) do
        if not(IsBound(opt.(n))) then 
            opt.(n) := BackgroundJobByForkOptions.(n);
        fi;
    od;
    j := rec( );
    j.childtoparent := IO_pipe();
    if j.childtoparent = fail then
        Info(InfoIO, 1, "Could not create pipe.");
        return fail;
    fi;
    if opt.TerminateImmediately then
        j.parenttochild := false;
    else
        j.parenttochild := IO_pipe();
        if j.parenttochild = fail then
            IO_close(j.childtoparent.toread);
            IO_close(j.childtoparent.towrite);
            Info(InfoIO, 1, "Could not create pipe.");
            return fail;
        fi;
    fi;
    j.pid := IO_fork();
    if j.pid = fail then
        Info(InfoIO, 1, "Could not fork.");
        return fail;
    fi;
    if j.pid = 0 then
        # we are in the child:
        IO_close(j.childtoparent.toread);
        j.childtoparent := IO_WrapFD(j.childtoparent.towrite,
                                     false, opt.BufferSize);
        if j.parenttochild <> false then
            IO_close(j.parenttochild.towrite);
            j.parenttochild := IO_WrapFD(j.parenttochild.toread,
                                         opt.BufferSize, false);
        fi;
        BackgroundJobByForkChild(j, fun, args);
        IO_exit(0);  # just in case
    fi;
    # Here we are in the parent:
    IO_close(j.childtoparent.towrite);
    j.childtoparent := IO_WrapFD(j.childtoparent.toread,
                                 opt.BufferSize, false);
    if j.parenttochild <> false then
        IO_close(j.parenttochild.toread);
        j.parenttochild := IO_WrapFD(j.parenttochild.towrite,
                                     false, opt.BufferSize);
    fi;
    j.terminated := false;
    j.result := false;
    j.idle := false;
    Objectify(BGJobByForkType, j);
    return j;
  end );

InstallGlobalFunction(BackgroundJobByForkChild,
  function(j, fun, args)
    local ret;
    while true do   # will be left by break
        ret := CallFuncList(fun, args);
        IO_Pickle(j.childtoparent, ret);
        IO_Flush(j.childtoparent);
        if j.parenttochild = false then break; fi;
        args := IO_Unpickle(j.parenttochild);
        if not(IsList(args)) then break; fi;
    od;
    IO_Close(j.childtoparent);
    if j.parenttochild <> false then
        IO_Close(j.parenttochild);
    fi;
    IO_exit(0);
  end);

InstallMethod(IsIdle, "for a background job by fork",
  [IsBackgroundJobByFork],
  function(j)
    if j!.terminated then return fail; fi;
    # Note that we have to check every time, since the job might have
    # terminated in the meantime!
    if IO_HasData(j!.childtoparent) then
        j!.result := IO_Unpickle(j!.childtoparent);
        if j!.result = IO_Nothing or j!.result = IO_Error then
            j!.result := fail;
            j!.terminated := true;
            j!.idle := fail;
            IO_Close(j!.childtoparent);
            IO_WaitPid(j!.pid,true);
            return fail;
        fi;
        j!.idle := true;
        return true;
    fi;
    return j!.idle;
  end);

InstallMethod(HasTerminated, "for a background job by fork",
  [IsBackgroundJobByFork],
  function(j)
    if j!.terminated then return true; fi;
    return IsIdle(j) = fail;
  end);

InstallMethod(WaitUntilIdle, "for a background job by fork",
  [IsBackgroundJobByFork],
  function(j)
    local fd,idle,l;
    idle := IsIdle(j);
    if idle = true then return j!.result; fi;
    if idle = fail then return fail; fi;
    fd := IO_GetFD(j!.childtoparent);
    l := [fd];
    IO_select(l,[],[],false,false);
    j!.result := IO_Unpickle(j!.childtoparent);
    if j!.result = IO_Nothing or j!.result = IO_Error then
        j!.result := fail;
        j!.terminated := true;
        j!.idle := fail;
        IO_Close(j!.childtoparent);
        IO_WaitPid(j!.pid,true);
        return fail;
    fi;
    j!.idle := true;
    return j!.result;
  end);
 
InstallMethod(Kill, "for a background job by fork",
  [IsBackgroundJobByFork],
  function(j)
    if j!.terminated then return; fi;
    IO_kill(j!.pid,IO.SIGTERM);
    IO_WaitPid(j!.pid,true);
    j!.idle := fail;
    j!.terminated := true;
    j!.result := fail;
  end);

InstallMethod(ViewObj, "for a background job by fork",
  [IsBackgroundJobByFork],
  function(j)
    local idle;
    Print("<background job by fork pid=",j!.pid);
    idle := IsIdle(j);
    if idle = true then 
        Print(" currently idle>"); 
    elif idle = fail then
        Print(" already terminated>");
    else
        Print(" busy>");
    fi;
  end);

InstallMethod(GetResult, "for a background job by fork",
  [IsBackgroundJobByFork],
  function(j)
    return WaitUntilIdle(j);
  end);

InstallMethod(SendArguments, "for a background job by fork and an object",
  [IsBackgroundJobByFork, IsObject],
  function(j,o)
    local idle,res;
    if j!.parenttochild = false then
        Error("job terminated immediately after finishing computation");
        return fail;
    fi;
    idle := IsIdle(j);
    if idle = false then
        Error("job must be idle to send the next argument list");
        return fail;
    elif idle = fail then
        Error("job has already terminated");
        return fail;
    fi;
    res := IO_Pickle(j!.parenttochild,o);
    if res <> IO_OK then
        Info(InfoIO, 1, "problems sending argument list", res);
        return fail;
    fi;
    IO_Flush(j!.parenttochild);
    j!.idle := false;
    return true;
  end);

f := function(n,k)
  Sleep(k);
  return n*n;
end;

InstallMethod(ParTakeFirstResultByFork, "for two lists",
  [IsList, IsList],
  function(jobs, args)
    return ParTakeFirstResultByFork(jobs, args, rec());
  end);

InstallValue( ParTakeFirstResultByForkOptions,
  rec( TimeOut := rec(tv_sec := false, tv_usec := false),
  ));

InstallMethod(ParTakeFirstResultByFork, "for two lists and a record",
  [IsList, IsList, IsRecord],
  function(jobs, args, opt)
    local answered,answers,i,j,jo,n,pipes,r;
    if not(ForAll(jobs,IsFunction) and ForAll(args,IsList) and
           Length(jobs) = Length(args)) then
        Error("jobs must be a list of functions and args a list of lists, ",
              "both of the same length");
        return fail;
    fi;
    for n in RecNames(ParTakeFirstResultByForkOptions) do
        if not(IsBound(opt.(n))) then 
            opt.(n) := ParTakeFirstResultByForkOptions.(n); 
        fi;
    od;
    n := Length(jobs);
    jo := EmptyPlist(n);
    for i in [1..n] do
        jo[i] := BackgroundJobByFork(jobs[i],args[i],
                                     rec(ImmediatelyTerminate := true));
        if jo[i] = fail then
            for j in [1..i-1] do
                Kill(jo[i]);
            od;
            Info(InfoIO, 1, "Could not start all background jobs.");
            return fail;
        fi;
    od;
    pipes := List(jo,j->IO_GetFD(j!.childtoparent));
    r := IO_select(pipes,[],[],opt.TimeOut.tv_sec,opt.TimeOut.tv_usec);
    answered := [];
    answers := EmptyPlist(n);
    for i in [1..n] do
        if pipes[i] = fail then
            Kill(jo[i]);
            Info(InfoIO,2,"Child ",jo[i]!.pid," has been terminated.");
        else
            Add(answered,i);
        fi;
    od;
    Info(InfoIO,2,"Getting answers...");
    for i in answered do
        answers[i] := WaitUntilIdle(jo[i]);
        Info(InfoIO,2,"Child ",jo[i]!.pid," has terminated with answer.");
        Kill(jo[i]);  # this is to cleanup data structures
    od;
    return answers;
  end);

InstallMethod(ParDoByFork, "for two lists",
  [IsList, IsList],
  function(jobs, args)
    return ParDoByFork(jobs, args, rec());
  end);

InstallValue( ParDoByForkOptions,
  rec( TimeOut := rec(tv_sec := false, tv_usec := false),
  ));

InstallMethod(ParDoByFork, "for two lists and a record",
  [IsList, IsList, IsRecord],
  function(jobs, args, opt)
    local cmp,diff,fds,i,j,jo,jobnr,n,now,pipes,r,results,start;
    if not(ForAll(jobs,IsFunction) and ForAll(args,IsList) and
           Length(jobs) = Length(args)) then
        Error("jobs must be a list of functions and args a list of lists, ",
              "both of the same length");
        return fail;
    fi;
    for n in RecNames(ParDoByForkOptions) do
        if not(IsBound(opt.(n))) then 
            opt.(n) := ParDoByForkOptions.(n); 
        fi;
    od;
    n := Length(jobs);
    jo := EmptyPlist(n);
    for i in [1..n] do
        jo[i] := BackgroundJobByFork(jobs[i],args[i],
                                     rec(ImmediatelyTerminate := true));
        if jo[i] = fail then
            for j in [1..i-1] do
                Kill(jo[i]);
            od;
            Info(InfoIO, 1, "Could not start all background jobs.");
            return fail;
        fi;
    od;
    pipes := List(jo,j->IO_GetFD(j!.childtoparent));
    results := EmptyPlist(n);
    start := IO_gettimeofday();
    Info(InfoIO, 2, "Started ", n, " jobs..."); 
    while true do
        fds := EmptyPlist(n);
        jobnr := EmptyPlist(n);
        for i in [1..n] do
            if not(IsBound(results[i])) then
                Add(fds,pipes[i]);
                Add(jobnr,i);
            fi;
        od;
        if Length(fds) = 0 then break; fi;
        if opt.TimeOut.tv_sec = false then
            r := IO_select(fds,[],[],false,false);
        else
            now := IO_gettimeofday();
            diff := DifferenceTimes(now,start);
            cmp := CompareTimes(opt.TimeOut, diff);
            if cmp <= 0 then
                for i in [1..n] do
                    Kill(jo[i]);
                od;
                Info(InfoIO, 2, "Timeout occurred, all jobs killed.");
                return results;
            fi;
            diff := DifferenceTimes(opt.TimeOut, diff);
            r := IO_select(fds, [], [], diff.tv_sec, diff.tv_usec);
        fi;
        for i in [1..Length(fds)] do
            if fds[i] <> fail then
                j := jobnr[i];
                results[j] := WaitUntilIdle(jo[j]);
                Info(InfoIO,2,"Child ",jo[j]!.pid,
                     " has terminated with answer.");
                Kill(jo[j]);  # this is to cleanup data structures
            fi;
        od;
    od;
    return results;
  end);

InstallValue(ParMapReduceByForkOptions,
  rec( TimeOut := rec(tv_sec := false, tv_usec := false),
  ));

InstallGlobalFunction(ParMapReduceWorker,
  function(l, what, map, reduce)
    local res,i;
    res := map(l[what[1]]);
    for i in what{[2..Length(what)]} do
        res := reduce(res,map(l[i]));
    od;
    return res;
  end);

InstallMethod(ParMapReduceByFork, "for a list, two functions and a record",
  [IsList, IsFunction, IsFunction, IsRecord],
  function(l, map, reduce, opt)
    local args,i,jobs,m,n,res,res2,where;
    for n in RecNames(ParMapReduceByForkOptions) do
        if not(IsBound(opt.(n))) then 
            opt.(n) := ParMapReduceByForkOptions.(n); 
        fi;
    od;
    if not(IsBound(opt.NumberJobs)) then
        Error("Need component NumberJobs in options record");
        return fail;
    fi;
    if Length(l) = 0 then
        Error("List to work on must have length at least 1");
        return fail;
    fi;
    n := opt.NumberJobs;
    if Length(l) < n or n = 1 then
        return ParMapReduceWorker(l,[1..Length(l)],map,reduce);
    fi;
    m := QuoInt(Length(l),n);  # is at least 1 by now
    jobs := ListWithIdenticalEntries(n, ParMapReduceWorker);
    args := EmptyPlist(n);
    where := 0;
    for i in [1..n-1] do
        args[i] := [l,[where+1..where+m],map,reduce];
        where := where+m;
    od;
    args[n] := [l,[where+1..Length(l)],map,reduce];
    res := ParDoByFork(jobs,args,opt);  # hand down timeout
    res2 := reduce(res[1],res[2]);  # at least 2 jobs!
    for i in [3..n] do
        res2 := reduce(res2,res[i]);
    od;
    return res2;
  end);


##
##  This program is free software; you can redistribute it and/or modify
##  it under the terms of the GNU General Public License as published by
##  the Free Software Foundation; version 2 of the License.
##
##  This program is distributed in the hope that it will be useful,
##  but WITHOUT ANY WARRANTY; without even the implied warranty of
##  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
##  GNU General Public License for more details.
##
##  You should have received a copy of the GNU General Public License
##  along with this program; if not, write to the Free Software
##  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
##
