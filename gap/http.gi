#############################################################################
##
#W  http.gi               GAP 4 package `IO'  
##                                                            Max Neunhoeffer
##
#Y  Copyright (C)  2006,  Lehrstuhl D fuer Mathematik,  RWTH Aachen,  Germany
##
##  This file contains functions implementing the client side of the
##  HTTP protocol.
##

# The following is given as argument to IO_Select for the timeout
# values in a HTTP request.

InstallValue( HTTPTimeoutForSelect, [fail,fail] );

InstallGlobalFunction( OpenHTTPConnection,
  function(server,port)
    local lookup,res,s;
    s := IO_socket(IO.PF_INET,IO.SOCK_STREAM,"tcp");
    if s = fail then 
        return rec( sock := fail,
                    errormsg := "OpenHTTPConnection: cannot create socket" );
    fi;
    lookup := IO_gethostbyname(server);
    if lookup = fail then
        IO_close(s);
        return rec( sock := fail,
                    errormsg := "OpenHTTPConnection: cannot find hostname" );
    fi;
    res := IO_connect(s,IO_make_sockaddr_in(lookup.addr[1],port));
    if res = fail then
        IO_close(s);
        return rec( sock := fail,
                    errormsg := 
                      Concatenation("OpenHTTPConnection: cannot connect: ",
                                    LastSystemError().message) );
    fi;
    # Switch the socket to non-blocking mode, just to be sure!
    IO_fcntl(s,IO.F_SETFL,IO.O_NONBLOCK);

    return rec( sock := IO_WrapFD(s,false,false), 
                errormsg := "",
                host := lookup,
                closed := false );
  end );

  
InstallGlobalFunction( HTTPRequest,
  function(conn,method,uri,header,body,target)
    # method, uri are the strings for the first line of the request
    # header must be a record
    # body either false or a string
    # target either false or the name of a file where the body is stored
    local ParseHeader,bodyread,byt,chunk,contentlength,haveseenheader,
          inpos,k,msg,nr,out,outeof,r,responseheader,ret,w,SetError;

    if conn.sock = fail or conn.closed = true then
        Error("Trying to work with closed connection");
    fi;

    ParseHeader := function( out )
      # Now we want to take this apart:
      # This function modifies the variables ret and responseheader
      # in the outer function and returns the position of the first
      # byte in out after the header.
      local line,lineend,pos,pos2,pos3;
      pos := 0;
      lineend := Position(out,'\n');
      if lineend <> fail then
          if lineend >= 2 and out[lineend-1] = '\r' then
              line := out{[pos+1..lineend-2]};
          else
              line := out{[pos+1..lineend-1]};
          fi;
          ret.status := "Header corrupt";
          if line{[1..5]} = "HTTP/" and Length(line) >= 8 then
              ret.protoversion := line{[6..8]};
              pos3 := Position(line,' ');
              if pos3 <> fail then
                  pos2 := Position(line,' ',pos3);
                  if pos2 <> fail then
                      ret.statuscode := Int(line{[pos3+1..pos2-1]});
                      ret.status := line{[pos2+1..Length(line)]};
                  fi;
              fi;
          fi;
          pos := lineend;
      fi;

      while true do   # will be left by break
          lineend := Position(out,'\n',pos);
          if lineend = fail or lineend <= pos+2 then 
              if lineend <> fail then pos := lineend+1; fi;
              break;   # we have seen the header
          fi;
          if out[lineend-1] = '\r' then
              line := out{[pos+1..lineend-2]};
          else
              line := out{[pos+1..lineend-1]};
          fi;
          pos2 := PositionSublist(line,": ");
          if pos2 <> fail then
              responseheader.(line{[1..pos2-1]}) :=
                                      line{[pos2+2..Length(line)]};
          fi;
          pos := lineend;
      od;
      
      if lineend = fail then   # incomplete or corrupt header!
          return fail;
      else
          return pos;
      fi;
    end;

    # Maybe add some default values:
    if not(IsBound(header.UserAgent)) then
        header.UserAgent := Concatenation("GAP/IO/",
                                          PackageInfo("io")[1].Version);
    fi;
    if IsString(body) and Length(body) > 0 then
        header.Content\-Length := String(Length(body));
    fi;
    if not(IsBound(header.Host)) then
        header.Host := conn.host.name;
    fi;

    # Now we have a TCP connection, we can start talking:
    msg := Concatenation(method," ",uri," HTTP/1.1\r\n");
    for k in RecNames(header) do
        Append(msg,k);
        Append(msg,": ");
        Append(msg,header.(k));
        Append(msg,"\r\n");
    od;
    Append(msg,"\r\n");
    if IsString(body) then Append(msg,body); fi;

    # Here we collect first the header, then maybe the rest:
    out := "";

    # Now we have collected the complete request, we do I/O multiplexing
    # to send away everything eventually and getting back the answer:

    # Here we just do I/O multiplexing, sending away msg (if non-empty)
    # and receiving from the connection.

    # Note that we first look for the header to learn the content length:
    haveseenheader := false;

    # The answer:
    ret := rec( protoversion := "unknown",
                statuscode := 0,   # indicates an error
                status := "",      # will be filled before return
                header := fail,
                body := fail,
                closed := false );

    # The following function is used to report on errors:
    SetError := function(msg)
      # Changes the variable ret outside!
      ret.status := msg;
      ret.statuscode := 0;
      if haveseenheader then 
          ret.header := responseheader; 
      fi;
      if IsString(out) then 
          ret.body := out; 
      else
          IO_Close(out);
          ret.body := target;
      fi;
    end;

    inpos := 0;
    outeof := false;
    repeat
        if not(outeof) then
            r := [conn.sock];
        else
            r := [];
        fi;
        if inpos < Length(msg) then
            w := [conn.sock];
        else
            w := [];
        fi;
        nr := IO_Select(r,w,[],[],HTTPTimeoutForSelect[1],
                                  HTTPTimeoutForSelect[2]);
        if nr = fail then   # an error!
            SetError("Error in select, connection broken?");
            return ret;
        fi;
        if nr = 0 then      # a timeout
            SetError("Connection timed out");
            return ret;
        fi;

        # First writing:
        if Length(w) > 0 and w[1] <> fail then
            byt := IO_WriteNonBlocking(conn.sock,msg,inpos,
                        Minimum(Length(msg)-inpos,65536));
            if byt = fail and 
               LastSystemError().number <> IO.EWOULDBLOCK then   
                # an error occured, probably connection broken
                SetError("Connection broken");
                return ret;
            fi;
            inpos := inpos + byt;
        fi;
        # Now reading:
        if not(outeof) and r[1] <> fail then
            chunk := IO_Read(conn.sock,65536);
            if chunk = "" or chunk = fail then 
                outeof := true; 
                break;
            fi;

            # Otherwise it must be a non-empty string
            if not(haveseenheader) then
                Append(out,chunk);
                responseheader := rec();
                r := ParseHeader(out);
                if r <> fail then   # then it is a position number!
                    if not(IsBound(responseheader.Content\-Length)) then
                        Print("HTTP Warning: no content length!\n");
                        contentlength := infinity;
                    else
                        if method <> "HEAD" then
                            contentlength:=Int(responseheader.Content\-Length);
                        else
                            contentlength := 0;
                        fi;
                    fi;
                    chunk := out{[r..Length(out)]};

                    # See to the target:
                    if IsString(target) then
                        out := IO_File(target,"w",false);
                        IO_Write(out,chunk);
                        bodyread := Length(chunk);
                    else
                        out := chunk;
                        bodyread := Length(chunk);
                    fi;
                    haveseenheader := true;
                fi;
            else
                # We are only reading the body until done:
                if IsString(out) then
                    Append(out,chunk);
                else
                    IO_Write(out,chunk);
                fi;
                bodyread := bodyread + Length(chunk);
            fi;
        fi;
    until outeof or (haveseenheader and bodyread >= contentlength);
  
    if outeof and not(haveseenheader) then
        # Obviously, the connection broke:
        SetError("Connection broken");
        return ret;
    fi;

    # In the case that contentlength is infinity because it was not 
    # specified and we thus read until end of file we still report
    # success! This is some tolerance against faulty servers.

    ret.closed := outeof;
    ret.header := responseheader;
    if IsString(out) then
        ret.body := out;
    else
        IO_Close(out);
        ret.body := target;
    fi;
    return ret;
  end );
 
InstallGlobalFunction( CloseHTTPConnection,
  function( conn )
    IO_Close(conn.sock);
    conn.closed := true;
  end );

InstallGlobalFunction( SingleHTTPRequest,
  function(server,port,method,uri,header,body,target)
    local conn,r;
    conn := OpenHTTPConnection(server,port);
    if conn.sock = fail then
        return rec( protoversion := "unknown",
                    statuscode := 0,
                    status := conn.errormsg,
                    header := fail,
                    body := fail,
                    closed := true );
    fi;
    r := HTTPRequest(conn,method,uri,header,body,target);
    CloseHTTPConnection(conn);
    r.closed := true;
    return r;
  end );
